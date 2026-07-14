-- Phase 3: validate the final Generation v1 job/artifact contract and enable
-- the strict serving readiness gate. Rerunnable after backfill succeeds.

BEGIN;

LOCK TABLE public.generation_runs IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.content_candidates IN SHARE ROW EXCLUSIVE MODE;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = 'chk_generation_runs_running_lease'
    ) THEN
        ALTER TABLE public.generation_runs
            ADD CONSTRAINT chk_generation_runs_running_lease
            CHECK (
                status <> 'running'
                OR (
                    started_at IS NOT NULL
                    AND worker_id IS NOT NULL
                    AND lease_token IS NOT NULL
                    AND heartbeat_at IS NOT NULL
                    AND lease_expires_at IS NOT NULL
                )
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = 'chk_generation_runs_terminal_times'
    ) THEN
        ALTER TABLE public.generation_runs
            ADD CONSTRAINT chk_generation_runs_terminal_times
            CHECK (
                status NOT IN ('completed', 'failed')
                OR (started_at IS NOT NULL AND finished_at IS NOT NULL)
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = 'chk_generation_runs_nonterminal_finished_at'
    ) THEN
        ALTER TABLE public.generation_runs
            ADD CONSTRAINT chk_generation_runs_nonterminal_finished_at
            CHECK (
                status IN ('completed', 'failed')
                OR finished_at IS NULL
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = 'chk_generation_runs_inactive_lease_cleared'
    ) THEN
        ALTER TABLE public.generation_runs
            ADD CONSTRAINT chk_generation_runs_inactive_lease_cleared
            CHECK (
                status = 'running'
                OR (
                    worker_id IS NULL
                    AND lease_token IS NULL
                    AND heartbeat_at IS NULL
                    AND lease_expires_at IS NULL
                )
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = 'chk_generation_runs_retry_schedule'
    ) THEN
        ALTER TABLE public.generation_runs
            ADD CONSTRAINT chk_generation_runs_retry_schedule
            CHECK (
                next_retry_at IS NULL
                OR status = 'requested'
            ) NOT VALID;
    END IF;
END
$$;

ALTER TABLE public.generation_runs
    VALIDATE CONSTRAINT chk_generation_runs_retry_count;
ALTER TABLE public.generation_runs
    VALIDATE CONSTRAINT chk_generation_runs_fingerprint;
ALTER TABLE public.generation_runs
    VALIDATE CONSTRAINT chk_generation_runs_idempotency_fingerprint;
ALTER TABLE public.generation_runs
    VALIDATE CONSTRAINT chk_generation_runs_running_lease;
ALTER TABLE public.generation_runs
    VALIDATE CONSTRAINT chk_generation_runs_terminal_times;
ALTER TABLE public.generation_runs
    VALIDATE CONSTRAINT chk_generation_runs_nonterminal_finished_at;
ALTER TABLE public.generation_runs
    VALIDATE CONSTRAINT chk_generation_runs_inactive_lease_cleared;
ALTER TABLE public.generation_runs
    VALIDATE CONSTRAINT chk_generation_runs_retry_schedule;

ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_creative_format;
ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_channel_format;
ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_image_generation_status;
ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_artifact_status;
ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_channel_lifecycle;
ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_artifact_sha256;
ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_completed_image;
ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_published_artifact;
ALTER TABLE public.content_candidates
    VALIDATE CONSTRAINT chk_content_candidates_artifact_error;

-- These are created validated on an empty expand-phase table. Explicit
-- validation also covers a pre-existing generation_rag table that adopted
-- the same named constraints through a compatible rollout.
ALTER TABLE generation_rag.retrieval_documents
    VALIDATE CONSTRAINT fk_generation_rag_project;
ALTER TABLE generation_rag.retrieval_documents
    VALIDATE CONSTRAINT chk_generation_rag_source_kind;
ALTER TABLE generation_rag.retrieval_documents
    VALIDATE CONSTRAINT chk_generation_rag_chunk_index;
ALTER TABLE generation_rag.retrieval_documents
    VALIDATE CONSTRAINT chk_generation_rag_status;
ALTER TABLE generation_rag.retrieval_documents
    VALIDATE CONSTRAINT chk_generation_rag_active_embedding;
ALTER TABLE generation_rag.retrieval_documents
    VALIDATE CONSTRAINT chk_generation_rag_content_sha256;

-- Cross-table completion invariants cannot be expressed as ordinary CHECK
-- constraints. Refuse the cutover until every completed run has exactly the
-- requested options for its immutable target segment set and every candidate
-- satisfies its channel readiness contract. Legacy rows without a snapshot
-- use the analysis-owned confirmed target rows only for migration validation.
DO $$
DECLARE
    invalid_generation_id public.generation_runs.generation_id%TYPE;
    invalid_snapshot BOOLEAN;
BEGIN
    WITH completed_runs AS (
        SELECT
            generation_id,
            analysis_id,
            content_option_count,
            input_json,
            input_json ? 'target_segments' AS has_target_snapshot,
            COALESCE(
                input_json ->> 'schema_version' = 'generation.request.v1',
                false
            ) AS requires_target_snapshot
        FROM public.generation_runs
        WHERE status = 'completed'
    ), invalid_snapshot_runs AS (
        SELECT run.generation_id
        FROM completed_runs AS run
        WHERE (
              run.requires_target_snapshot
              AND NOT run.has_target_snapshot
          )
           OR (
              run.has_target_snapshot
              AND (
              jsonb_typeof(run.input_json -> 'target_segments')
                  IS DISTINCT FROM 'array'
              OR jsonb_array_length(
                  CASE
                      WHEN jsonb_typeof(
                          run.input_json -> 'target_segments'
                      ) = 'array'
                      THEN run.input_json -> 'target_segments'
                      ELSE '[]'::jsonb
                  END
              ) = 0
              OR EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements(
                      CASE
                          WHEN jsonb_typeof(
                              run.input_json -> 'target_segments'
                          ) = 'array'
                          THEN run.input_json -> 'target_segments'
                          ELSE '[]'::jsonb
                      END
                  ) AS target(value)
                  WHERE jsonb_typeof(target.value) <> 'object'
                     OR NULLIF(
                         btrim(target.value ->> 'segment_id'),
                         ''
                     ) IS NULL
              )
              OR (
                  SELECT count(*) <> count(
                      DISTINCT btrim(target.value ->> 'segment_id')
                  )
                  FROM jsonb_array_elements(
                      CASE
                          WHEN jsonb_typeof(
                              run.input_json -> 'target_segments'
                          ) = 'array'
                          THEN run.input_json -> 'target_segments'
                          ELSE '[]'::jsonb
                      END
                  ) AS target(value)
              )
              )
          )
    ), snapshot_segments AS (
        SELECT
            run.generation_id,
            btrim(target.value ->> 'segment_id') AS segment_id
        FROM completed_runs AS run
        CROSS JOIN LATERAL jsonb_array_elements(
            CASE
                WHEN jsonb_typeof(run.input_json -> 'target_segments') = 'array'
                THEN run.input_json -> 'target_segments'
                ELSE '[]'::jsonb
            END
        ) AS target(value)
        WHERE run.has_target_snapshot
    ), expected_segments AS (
        SELECT generation_id, segment_id
        FROM snapshot_segments

        UNION

        SELECT run.generation_id, target.segment_id
        FROM completed_runs AS run
        JOIN public.promotion_target_segments AS target
          ON target.analysis_id = run.analysis_id
        WHERE NOT run.has_target_snapshot
          AND NOT run.requires_target_snapshot
    )
    SELECT
        run.generation_id,
        invalid.generation_id IS NOT NULL
    INTO invalid_generation_id, invalid_snapshot
    FROM completed_runs AS run
    LEFT JOIN invalid_snapshot_runs AS invalid
      USING (generation_id)
    WHERE invalid.generation_id IS NOT NULL
       OR NOT EXISTS (
            SELECT 1
            FROM expected_segments AS expected
            WHERE expected.generation_id = run.generation_id
        )
       OR EXISTS (
            SELECT 1
            FROM expected_segments AS expected
            WHERE expected.generation_id = run.generation_id
              AND (
                  SELECT count(*)
                  FROM public.content_candidates AS candidate
                  WHERE candidate.generation_id = run.generation_id
                    AND candidate.segment_id = expected.segment_id
              ) <> run.content_option_count
        )
       OR EXISTS (
            SELECT 1
            FROM public.content_candidates AS candidate
            WHERE candidate.generation_id = run.generation_id
              AND NOT EXISTS (
                  SELECT 1
                  FROM expected_segments AS expected
                  WHERE expected.generation_id = run.generation_id
                    AND expected.segment_id = candidate.segment_id
              )
        )
    ORDER BY (invalid.generation_id IS NOT NULL) DESC, run.generation_id
    LIMIT 1;

    IF FOUND THEN
        IF invalid_snapshot THEN
            RAISE EXCEPTION
                'generation v1 finalize failed [completed_target_snapshot]: generation_id=%',
                invalid_generation_id;
        ELSE
            RAISE EXCEPTION
                'generation v1 finalize failed [completed_candidate_count]: generation_id=%',
                invalid_generation_id;
        END IF;
    END IF;

    SELECT run.generation_id
    INTO invalid_generation_id
    FROM public.generation_runs AS run
    WHERE run.status = 'completed'
      AND (
          NOT EXISTS (
              SELECT 1
              FROM public.content_candidates AS candidate
              WHERE candidate.generation_id = run.generation_id
          )
          OR EXISTS (
              SELECT 1
              FROM public.content_candidates AS candidate
              WHERE candidate.generation_id = run.generation_id
                AND (
                    (
                        candidate.channel = 'sms'
                        AND candidate.creative_format = 'sms_text'
                        AND candidate.message IS NOT NULL
                        AND candidate.image_generation_status = 'not_required'
                        AND candidate.artifact_status = 'not_required'
                    )
                    OR
                    (
                        candidate.channel IN ('email', 'onsite_banner')
                        AND candidate.creative_format = CASE candidate.channel
                            WHEN 'email' THEN 'email_html'
                            ELSE 'banner_html'
                        END
                        AND candidate.image_generation_status = 'completed'
                        AND candidate.image_url IS NOT NULL
                        AND candidate.artifact_status = 'published'
                        AND candidate.artifact_storage_key IS NOT NULL
                        AND candidate.artifact_public_url IS NOT NULL
                        AND candidate.artifact_sha256 IS NOT NULL
                        AND candidate.artifact_content_type IS NOT NULL
                        AND candidate.artifact_published_at IS NOT NULL
                    )
                ) IS NOT TRUE
          )
      )
    ORDER BY run.generation_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'generation v1 finalize failed [completed_candidate_readiness]: generation_id=%',
            invalid_generation_id;
    END IF;

    SELECT run.generation_id
    INTO invalid_generation_id
    FROM public.generation_runs AS run
    JOIN public.content_candidates AS candidate
      USING (generation_id)
    WHERE run.status = 'completed'
      AND candidate.artifact_status = 'published'
      AND (
          candidate.created_at > candidate.artifact_published_at
          OR candidate.artifact_published_at > run.finished_at
      )
    ORDER BY run.generation_id, candidate.content_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'generation v1 finalize failed [completed_candidate_timeline]: generation_id=%',
            invalid_generation_id;
    END IF;
END
$$;

CREATE OR REPLACE VIEW public.active_ad_serving_assignments AS
SELECT
    usa.project_id,
    usa.promotion_run_id,
    usa.user_id,
    usa.segment_id,
    usa.ad_experiment_id,
    usa.content_id,
    usa.content_option_id,
    usa.fallback,
    usa.similarity_score,
    usa.assigned_at,
    usa.expires_at,

    ae.campaign_id,
    ae.promotion_id,
    ae.channel,
    ae.loop_count,
    ae.status AS ad_experiment_status,

    cc.subject,
    cc.preheader,
    cc.title,
    cc.body,
    cc.cta,
    cc.message,
    cc.image_prompt,
    cc.image_url,
    cc.landing_url,
    cc.status AS content_status,
    cc.creative_format,
    cc.image_generation_status,
    cc.artifact_status,
    cc.artifact_public_url,
    cc.artifact_content_type
FROM public.user_segment_assignments AS usa
JOIN public.ad_experiments AS ae
  ON usa.ad_experiment_id = ae.ad_experiment_id
JOIN public.content_candidates AS cc
  ON usa.content_id = cc.content_id
JOIN public.generation_runs AS gr
  ON cc.generation_id = gr.generation_id
-- Preserve the latest promotion scope/fallback contract's historical
-- evaluation provenance rule while adding only Generation readiness gates.
WHERE (
        ae.status IN ('approved', 'running')
        OR
        (
            ae.status IN ('goal_met', 'goal_not_met', 'insufficient_data')
            AND ae.ended_at IS NULL
            AND EXISTS (
                SELECT 1
                FROM public.promotion_evaluations AS pe
                WHERE pe.ad_experiment_id IS NOT NULL
                  AND pe.project_id = ae.project_id
                  AND pe.campaign_id = ae.campaign_id
                  AND pe.promotion_id = ae.promotion_id
                  AND pe.promotion_run_id = ae.promotion_run_id
                  AND pe.ad_experiment_id = ae.ad_experiment_id
                  AND pe.status = ae.status
            )
        )
    )
  AND cc.status IN ('approved', 'active')
  AND gr.status = 'completed'
  AND (
        (
            cc.channel = 'sms'
            AND cc.message IS NOT NULL
            AND cc.artifact_status = 'not_required'
        )
        OR
        (
            cc.channel IN ('email', 'onsite_banner')
            AND cc.image_generation_status = 'completed'
            AND cc.image_url IS NOT NULL
            AND cc.artifact_status = 'published'
            AND cc.artifact_public_url IS NOT NULL
        )
      )
  AND (usa.expires_at IS NULL OR usa.expires_at > now());

COMMIT;
