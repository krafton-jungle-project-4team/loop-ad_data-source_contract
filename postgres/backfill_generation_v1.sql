-- Phase 2: normalize legacy Generation rows without inventing request identity
-- or claiming that visual artifacts were published without durable evidence.
-- Rerunnable. Apply after Generation dual-writes the expanded columns.

BEGIN;

LOCK TABLE public.generation_runs IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.content_candidates IN SHARE ROW EXCLUSIVE MODE;

DO $$
DECLARE
    invalid_generation_id public.generation_runs.generation_id%TYPE;
BEGIN
    SELECT generation_id
    INTO invalid_generation_id
    FROM public.generation_runs
    WHERE retry_count < 0
       OR (
            request_fingerprint IS NOT NULL
            AND request_fingerprint !~ '^[0-9a-f]{64}$'
       )
       OR (
            idempotency_key IS NOT NULL
            AND request_fingerprint IS NULL
       )
    ORDER BY generation_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'generation v1 backfill failed [request_identity]: generation_id=%',
            invalid_generation_id;
    END IF;
END
$$;

-- A legacy running row has no safe fencing owner if any lease component is
-- absent. Preserve its first-start timestamp, but put it back in the durable
-- requested queue and clear the partial lease instead of fabricating a token.
UPDATE public.generation_runs
SET status = 'requested',
    started_at = COALESCE(started_at, created_at),
    finished_at = NULL,
    next_retry_at = NULL,
    worker_id = NULL,
    lease_token = NULL,
    heartbeat_at = NULL,
    lease_expires_at = NULL
WHERE status = 'running'
  AND (
        worker_id IS NULL
        OR lease_token IS NULL
        OR heartbeat_at IS NULL
        OR lease_expires_at IS NULL
  );

-- Normalize lifecycle timestamps and clear fencing data outside an active
-- running attempt. Existing valid request fingerprints and idempotency keys
-- are deliberately left untouched; NULL legacy identities stay NULL.
UPDATE public.generation_runs
SET started_at = CASE
        WHEN status IN ('running', 'completed', 'failed')
        THEN COALESCE(started_at, created_at)
        ELSE started_at
    END,
    finished_at = CASE
        WHEN status IN ('completed', 'failed')
        THEN COALESCE(finished_at, updated_at, created_at)
        ELSE NULL
    END,
    next_retry_at = CASE
        WHEN status = 'requested' THEN next_retry_at
        ELSE NULL
    END,
    worker_id = CASE
        WHEN status = 'running' THEN worker_id
        ELSE NULL
    END,
    lease_token = CASE
        WHEN status = 'running' THEN lease_token
        ELSE NULL
    END,
    heartbeat_at = CASE
        WHEN status = 'running' THEN heartbeat_at
        ELSE NULL
    END,
    lease_expires_at = CASE
        WHEN status = 'running' THEN lease_expires_at
        ELSE NULL
    END;

CREATE OR REPLACE FUNCTION pg_temp.generation_v1_try_timestamptz(
    p_value TEXT
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_value IS NULL OR btrim(p_value) = '' THEN
        RETURN NULL;
    END IF;

    RETURN p_value::timestamptz;
EXCEPTION
    WHEN invalid_datetime_format
        OR datetime_field_overflow
        OR invalid_parameter_value THEN
        RETURN NULL;
END
$$;

-- Resolve only fields that already exist as explicit columns or in
-- metadata_json.creative.artifact. For visual candidates, an image URL is
-- evidence of image completion. A published artifact additionally requires
-- its explicit published status and every durable publication field.
WITH artifact_evidence AS (
    SELECT
        cc.content_id,
        cc.channel,
        cc.image_url,
        cc.creative_format AS current_creative_format,
        cc.image_generation_status AS current_image_status,
        cc.artifact_status AS current_artifact_status,
        NULLIF(btrim(cc.artifact_storage_key), '') AS current_storage_key,
        NULLIF(btrim(cc.artifact_public_url), '') AS current_public_url,
        NULLIF(btrim(cc.artifact_sha256::text), '') AS current_sha256,
        NULLIF(btrim(cc.artifact_content_type), '') AS current_content_type,
        NULLIF(btrim(cc.artifact_error_code), '') AS current_error_code,
        cc.artifact_published_at AS current_published_at,
        cc.updated_at AS candidate_updated_at,
        cc.metadata_json #> '{creative,artifact}' AS artifact_json,
        COALESCE(
            cc.metadata_json #>> '{creative,image_generation_status}',
            cc.metadata_json ->> 'image_generation_status'
        ) AS metadata_image_status
    FROM public.content_candidates AS cc
), resolved_evidence AS (
    SELECT
        evidence.*,
        COALESCE(
            evidence.current_storage_key,
            NULLIF(btrim(evidence.artifact_json ->> 'storage_key'), ''),
            NULLIF(
                btrim(evidence.artifact_json ->> 'artifact_storage_key'),
                ''
            )
        ) AS resolved_storage_key,
        COALESCE(
            evidence.current_public_url,
            NULLIF(btrim(evidence.artifact_json ->> 'public_url'), ''),
            NULLIF(
                btrim(evidence.artifact_json ->> 'artifact_public_url'),
                ''
            )
        ) AS resolved_public_url,
        CASE
            WHEN evidence.current_sha256 ~ '^[0-9a-f]{64}$'
            THEN evidence.current_sha256
            WHEN evidence.artifact_json ->> 'sha256'
                 ~ '^[0-9a-f]{64}$'
            THEN evidence.artifact_json ->> 'sha256'
            WHEN evidence.artifact_json ->> 'artifact_sha256'
                 ~ '^[0-9a-f]{64}$'
            THEN evidence.artifact_json ->> 'artifact_sha256'
            ELSE NULL
        END AS resolved_sha256,
        COALESCE(
            evidence.current_content_type,
            NULLIF(btrim(evidence.artifact_json ->> 'content_type'), ''),
            NULLIF(
                btrim(evidence.artifact_json ->> 'artifact_content_type'),
                ''
            )
        ) AS resolved_content_type,
        COALESCE(
            evidence.current_error_code,
            NULLIF(btrim(evidence.artifact_json ->> 'error_code'), ''),
            NULLIF(
                btrim(evidence.artifact_json ->> 'artifact_error_code'),
                ''
            )
        ) AS resolved_error_code,
        COALESCE(
            evidence.current_published_at,
            pg_temp.generation_v1_try_timestamptz(
                COALESCE(
                    evidence.artifact_json ->> 'published_at',
                    evidence.artifact_json ->> 'artifact_published_at'
                )
            ),
            CASE
                -- The legacy Decision artifact payload did not carry a
                -- published_at member. Its row update time is acceptable
                -- only when metadata explicitly records publication; it is
                -- never used to promote an evidence-free visual candidate.
                WHEN evidence.artifact_json ->> 'artifact_status' = 'published'
                THEN evidence.candidate_updated_at
            END
        ) AS resolved_published_at
    FROM artifact_evidence AS evidence
), normalized AS (
    SELECT
        resolved.*,
        CASE resolved.channel
            WHEN 'email' THEN 'email_html'
            WHEN 'onsite_banner' THEN 'banner_html'
            WHEN 'sms' THEN 'sms_text'
        END AS resolved_creative_format,
        CASE
            WHEN resolved.channel = 'sms' THEN 'not_required'
            WHEN resolved.current_image_status IN (
                'pending', 'running', 'failed'
            ) THEN resolved.current_image_status
            WHEN resolved.current_image_status = 'completed'
                 AND resolved.image_url IS NOT NULL THEN 'completed'
            WHEN resolved.metadata_image_status IN (
                'pending', 'running', 'failed'
            ) THEN resolved.metadata_image_status
            WHEN resolved.image_url IS NOT NULL THEN 'completed'
            ELSE 'pending'
        END AS resolved_image_status,
        CASE
            WHEN resolved.channel = 'sms' THEN 'not_required'
            WHEN resolved.current_artifact_status = 'published'
                 AND resolved.resolved_storage_key IS NOT NULL
                 AND resolved.resolved_public_url IS NOT NULL
                 AND resolved.resolved_sha256 IS NOT NULL
                 AND resolved.resolved_content_type IS NOT NULL
                 AND resolved.resolved_published_at IS NOT NULL
            THEN 'published'
            WHEN resolved.current_artifact_status = 'failed'
                 AND resolved.resolved_error_code IS NOT NULL
            THEN 'failed'
            WHEN resolved.current_artifact_status = 'pending' THEN 'pending'
            WHEN resolved.artifact_json ->> 'artifact_status' = 'published'
                 AND resolved.resolved_storage_key IS NOT NULL
                 AND resolved.resolved_public_url IS NOT NULL
                 AND resolved.resolved_sha256 IS NOT NULL
                 AND resolved.resolved_content_type IS NOT NULL
                 AND resolved.resolved_published_at IS NOT NULL
            THEN 'published'
            WHEN resolved.artifact_json ->> 'artifact_status' = 'failed'
                 AND resolved.resolved_error_code IS NOT NULL
            THEN 'failed'
            ELSE 'pending'
        END AS resolved_artifact_status
    FROM resolved_evidence AS resolved
)
UPDATE public.content_candidates AS cc
SET creative_format = normalized.resolved_creative_format,
    image_generation_status = normalized.resolved_image_status,
    artifact_status = normalized.resolved_artifact_status,
    artifact_storage_key = normalized.resolved_storage_key,
    artifact_public_url = normalized.resolved_public_url,
    artifact_sha256 = normalized.resolved_sha256,
    artifact_content_type = normalized.resolved_content_type,
    artifact_error_code = normalized.resolved_error_code,
    artifact_published_at = normalized.resolved_published_at
FROM normalized
WHERE normalized.content_id = cc.content_id;

DO $$
DECLARE
    invalid_generation_id public.generation_runs.generation_id%TYPE;
    invalid_content_id public.content_candidates.content_id%TYPE;
BEGIN
    SELECT generation_id
    INTO invalid_generation_id
    FROM public.generation_runs
    WHERE (status = 'running' AND (
                started_at IS NULL
                OR worker_id IS NULL
                OR lease_token IS NULL
                OR heartbeat_at IS NULL
                OR lease_expires_at IS NULL
          ))
       OR (status IN ('completed', 'failed') AND (
                started_at IS NULL OR finished_at IS NULL
          ))
       OR (status NOT IN ('completed', 'failed') AND finished_at IS NOT NULL)
       OR (status <> 'running' AND (
                worker_id IS NOT NULL
                OR lease_token IS NOT NULL
                OR heartbeat_at IS NOT NULL
                OR lease_expires_at IS NOT NULL
          ))
       OR (next_retry_at IS NOT NULL AND status <> 'requested')
    ORDER BY generation_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'generation v1 backfill failed [job_lifecycle]: generation_id=%',
            invalid_generation_id;
    END IF;

    SELECT content_id
    INTO invalid_content_id
    FROM public.content_candidates
    WHERE creative_format IS NULL
       OR image_generation_status IS NULL
       OR artifact_status IS NULL
       OR NOT (
            (channel = 'email' AND creative_format = 'email_html')
            OR (
                channel = 'onsite_banner'
                AND creative_format = 'banner_html'
            )
            OR (channel = 'sms' AND creative_format = 'sms_text')
       )
       OR NOT (
            (
                creative_format = 'sms_text'
                AND image_generation_status = 'not_required'
                AND artifact_status = 'not_required'
            )
            OR (
                creative_format IN ('email_html', 'banner_html')
                AND image_generation_status IN (
                    'pending', 'running', 'completed', 'failed'
                )
                AND artifact_status IN ('pending', 'published', 'failed')
            )
       )
       OR (
            image_generation_status = 'completed'
            AND image_url IS NULL
       )
       OR (
            artifact_status = 'published'
            AND (
                artifact_storage_key IS NULL
                OR artifact_public_url IS NULL
                OR artifact_sha256 IS NULL
                OR artifact_content_type IS NULL
                OR artifact_published_at IS NULL
            )
       )
       OR (
            artifact_status = 'failed'
            AND artifact_error_code IS NULL
       )
    ORDER BY content_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'generation v1 backfill failed [candidate_lifecycle]: content_id=%',
            invalid_content_id;
    END IF;
END
$$;

COMMIT;
