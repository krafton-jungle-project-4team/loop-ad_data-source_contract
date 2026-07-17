\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
    mismatch_count BIGINT;
    missing_count BIGINT;
    view_tail TEXT[];
BEGIN
    IF to_regclass('generation_rag.retrieval_documents') IS NULL THEN
        RAISE EXCEPTION 'generation_rag.retrieval_documents is missing';
    END IF;

    WITH expected_columns (column_name, data_type, is_not_null, default_sql) AS (
        VALUES
            ('started_at', 'timestamp with time zone', false, NULL),
            ('finished_at', 'timestamp with time zone', false, NULL),
            ('retry_count', 'integer', true, '0'),
            ('next_retry_at', 'timestamp with time zone', false, NULL),
            ('last_error_code', 'character varying(100)', false, NULL),
            ('last_error_message', 'text', false, NULL),
            ('worker_id', 'character varying(200)', false, NULL),
            ('lease_token', 'uuid', false, NULL),
            ('heartbeat_at', 'timestamp with time zone', false, NULL),
            ('lease_expires_at', 'timestamp with time zone', false, NULL),
            ('idempotency_key', 'character varying(200)', false, NULL),
            ('request_fingerprint', 'character(64)', false, NULL)
    )
    SELECT count(*)
    INTO mismatch_count
    FROM expected_columns AS expected
    LEFT JOIN pg_attribute AS attribute
      ON attribute.attrelid = 'public.generation_runs'::regclass
     AND attribute.attname = expected.column_name
     AND attribute.attnum > 0
     AND NOT attribute.attisdropped
    LEFT JOIN pg_attrdef AS attribute_default
      ON attribute_default.adrelid = attribute.attrelid
     AND attribute_default.adnum = attribute.attnum
    WHERE attribute.attname IS NULL
       OR format_type(attribute.atttypid, attribute.atttypmod)
            IS DISTINCT FROM expected.data_type
       OR attribute.attnotnull IS DISTINCT FROM expected.is_not_null
       OR pg_get_expr(attribute_default.adbin, attribute_default.adrelid)
            IS DISTINCT FROM expected.default_sql;

    IF mismatch_count <> 0 THEN
        RAISE EXCEPTION '% generation_runs columns differ from Generation v1',
            mismatch_count;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'public.generation_runs'::regclass
          AND attname = 'generation_status'
          AND attnum > 0
          AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION 'generation_status duplicates generation_runs.status';
    END IF;

    WITH expected_columns (column_name, data_type) AS (
        VALUES
            ('creative_format', 'character varying(50)'),
            ('image_generation_status', 'character varying(50)'),
            ('artifact_status', 'character varying(50)'),
            ('artifact_storage_key', 'text'),
            ('artifact_public_url', 'text'),
            ('artifact_sha256', 'character(64)'),
            ('artifact_content_type', 'character varying(100)'),
            ('artifact_error_code', 'character varying(100)'),
            ('artifact_published_at', 'timestamp with time zone')
    )
    SELECT count(*)
    INTO mismatch_count
    FROM expected_columns AS expected
    LEFT JOIN pg_attribute AS attribute
      ON attribute.attrelid = 'public.content_candidates'::regclass
     AND attribute.attname = expected.column_name
     AND attribute.attnum > 0
     AND NOT attribute.attisdropped
    LEFT JOIN pg_attrdef AS attribute_default
      ON attribute_default.adrelid = attribute.attrelid
     AND attribute_default.adnum = attribute.attnum
    WHERE attribute.attname IS NULL
       OR format_type(attribute.atttypid, attribute.atttypmod)
            IS DISTINCT FROM expected.data_type
       OR attribute.attnotnull
       OR attribute_default.oid IS NOT NULL;

    IF mismatch_count <> 0 THEN
        RAISE EXCEPTION '% content candidate columns differ from nullable rollout',
            mismatch_count;
    END IF;

    SELECT count(*)
    INTO missing_count
    FROM unnest(ARRAY[
        'chk_generation_runs_retry_count',
        'chk_generation_runs_fingerprint',
        'chk_generation_runs_idempotency_fingerprint',
        'chk_generation_runs_running_lease',
        'chk_generation_runs_terminal_times',
        'chk_generation_runs_nonterminal_finished_at',
        'chk_generation_runs_inactive_lease_cleared',
        'chk_generation_runs_retry_schedule'
    ]) AS expected(constraint_name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = expected.constraint_name
          AND contype = 'c'
          AND convalidated
    );

    IF missing_count <> 0 THEN
        RAISE EXCEPTION '% Generation run constraints are missing or unvalidated',
            missing_count;
    END IF;

    SELECT count(*)
    INTO missing_count
    FROM unnest(ARRAY[
        'chk_content_candidates_creative_format',
        'chk_content_candidates_channel_format',
        'chk_content_candidates_image_generation_status',
        'chk_content_candidates_artifact_status',
        'chk_content_candidates_channel_lifecycle',
        'chk_content_candidates_artifact_sha256',
        'chk_content_candidates_completed_image',
        'chk_content_candidates_published_artifact',
        'chk_content_candidates_artifact_error'
    ]) AS expected(constraint_name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = expected.constraint_name
          AND contype = 'c'
          AND convalidated
    );

    IF missing_count <> 0 THEN
        RAISE EXCEPTION '% content readiness constraints are missing or unvalidated',
            missing_count;
    END IF;

    SELECT count(*)
    INTO missing_count
    FROM unnest(ARRAY[
        'fk_generation_rag_project',
        'chk_generation_rag_source_kind',
        'chk_generation_rag_chunk_index',
        'chk_generation_rag_status',
        'chk_generation_rag_active_embedding',
        'chk_generation_rag_content_sha256',
        'uq_generation_rag_source_context_chunk_embedding'
    ]) AS expected(constraint_name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'generation_rag.retrieval_documents'::regclass
          AND conname = expected.constraint_name
          AND convalidated
    );

    IF missing_count <> 0 THEN
        RAISE EXCEPTION '% Generation RAG constraints are missing', missing_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'generation_rag.retrieval_documents'::regclass
          AND attname = 'embedding'
          AND format_type(atttypid, atttypmod) = 'vector(1024)'
          AND NOT attnotnull
    ) THEN
        RAISE EXCEPTION 'Generation RAG embedding must be nullable vector(1024)';
    END IF;

    SELECT count(*)
    INTO missing_count
    FROM (
        VALUES
            ('public', 'generation_runs', 'uq_generation_runs_project_idempotency'),
            ('public', 'generation_runs', 'idx_generation_runs_claimable'),
            ('public', 'generation_runs', 'idx_generation_runs_expired_lease'),
            ('public', 'content_candidates', 'idx_content_candidates_artifact_status'),
            ('generation_rag', 'retrieval_documents', 'idx_generation_rag_retrieval_filter'),
            ('generation_rag', 'retrieval_documents', 'idx_generation_rag_source')
    ) AS expected(schema_name, table_name, index_name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = expected.schema_name
          AND tablename = expected.table_name
          AND indexname = expected.index_name
    );

    IF missing_count <> 0 THEN
        RAISE EXCEPTION '% Generation v1 indexes are missing', missing_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_index
        WHERE indexrelid =
              'public.uq_generation_runs_project_idempotency'::regclass
          AND indisunique
          AND indpred IS NOT NULL
          AND pg_get_expr(indpred, indrelid) LIKE
              '%idempotency_key IS NOT NULL%'
    ) THEN
        RAISE EXCEPTION 'Generation idempotency index is not partial unique';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_index AS index_definition
        JOIN pg_class AS index_relation
          ON index_relation.oid = index_definition.indexrelid
        JOIN pg_am AS access_method
          ON access_method.oid = index_relation.relam
        WHERE index_definition.indrelid =
              'generation_rag.retrieval_documents'::regclass
          AND access_method.amname IN ('hnsw', 'ivfflat')
    ) THEN
        RAISE EXCEPTION 'Generation RAG v1 must not create an ANN index';
    END IF;

    SELECT array_agg(column_name ORDER BY ordinal_position)
    INTO view_tail
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'active_ad_serving_assignments'
      AND ordinal_position > (
          SELECT max(ordinal_position) - 5
          FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name = 'active_ad_serving_assignments'
      );

    IF view_tail IS DISTINCT FROM ARRAY[
        'creative_format',
        'image_generation_status',
        'artifact_status',
        'artifact_public_url',
        'artifact_content_type'
    ]::TEXT[] THEN
        RAISE EXCEPTION 'serving view Generation columns are missing or reordered: %',
            view_tail;
    END IF;

    IF NOT (
        SELECT
            project_id IS NULL
            AND campaign_id IS NULL
            AND promotion_id IS NULL
            AND query_preview_id IS NULL
            AND source = 'system_default'
            AND status = 'active'
        FROM segment_definitions
        WHERE segment_id = 'seg_existing_all'
    ) THEN
        RAISE EXCEPTION 'global fallback segment contract changed';
    END IF;
END
$$;

-- Validate the database state that existed before this test creates any
-- temporary positive/negative rows. Completed runs must match their immutable
-- target segment set and may not contain a NULL or pending readiness state.
DO $$
DECLARE
    invalid_generation_id generation_runs.generation_id%TYPE;
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
        FROM generation_runs
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
        JOIN promotion_target_segments AS target
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
                  FROM content_candidates AS candidate
                  WHERE candidate.generation_id = run.generation_id
                    AND candidate.segment_id = expected.segment_id
              ) <> run.content_option_count
        )
       OR EXISTS (
            SELECT 1
            FROM content_candidates AS candidate
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
                'completed generation target snapshot is malformed: %',
                invalid_generation_id;
        ELSE
            RAISE EXCEPTION
                'completed generation candidate scope/count mismatch: %',
                invalid_generation_id;
        END IF;
    END IF;

    SELECT run.generation_id
    INTO invalid_generation_id
    FROM generation_runs AS run
    WHERE run.status = 'completed'
      AND (
          NOT EXISTS (
              SELECT 1
              FROM content_candidates AS candidate
              WHERE candidate.generation_id = run.generation_id
          )
          OR EXISTS (
              SELECT 1
              FROM content_candidates AS candidate
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
            'completed generation candidate readiness mismatch: %',
            invalid_generation_id;
    END IF;

    SELECT run.generation_id
    INTO invalid_generation_id
    FROM generation_runs AS run
    JOIN content_candidates AS candidate
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
            'completed generation artifact timeline mismatch: %',
            invalid_generation_id;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.expect_generation_check_violation(
    p_generation_id TEXT,
    p_status TEXT,
    p_started_at TIMESTAMPTZ,
    p_finished_at TIMESTAMPTZ,
    p_retry_count INT,
    p_next_retry_at TIMESTAMPTZ,
    p_worker_id TEXT,
    p_lease_token UUID,
    p_heartbeat_at TIMESTAMPTZ,
    p_lease_expires_at TIMESTAMPTZ,
    p_idempotency_key TEXT,
    p_request_fingerprint TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        INSERT INTO generation_runs (
            generation_id,
            analysis_id,
            project_id,
            campaign_id,
            promotion_id,
            content_option_count,
            status,
            started_at,
            finished_at,
            retry_count,
            next_retry_at,
            worker_id,
            lease_token,
            heartbeat_at,
            lease_expires_at,
            idempotency_key,
            request_fingerprint
        )
        VALUES (
            p_generation_id,
            'analysis_sms_a1',
            'demo_project',
            'camp_expedia_hotel_demo',
            'promo_expedia_sms_near_checkin',
            1,
            p_status,
            p_started_at,
            p_finished_at,
            p_retry_count,
            p_next_retry_at,
            p_worker_id,
            p_lease_token,
            p_heartbeat_at,
            p_lease_expires_at,
            p_idempotency_key,
            p_request_fingerprint
        );
        RAISE EXCEPTION '% unexpectedly satisfied Generation checks',
            p_generation_id;
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT pg_temp.expect_generation_check_violation(
    'test_generation_negative_retry',
    'requested',
    NULL,
    NULL,
    -1,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.expect_generation_check_violation(
    'test_generation_bad_fingerprint',
    'requested',
    NULL,
    NULL,
    0,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    repeat('g', 64)
);

SELECT pg_temp.expect_generation_check_violation(
    'test_generation_key_without_fingerprint',
    'requested',
    NULL,
    NULL,
    0,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    'test-key-without-fingerprint',
    NULL
);

SELECT pg_temp.expect_generation_check_violation(
    'test_generation_running_without_lease',
    'running',
    now(),
    NULL,
    0,
    NULL,
    'worker-test',
    NULL,
    now(),
    now() + interval '5 minutes',
    NULL,
    NULL
);

SELECT pg_temp.expect_generation_check_violation(
    'test_generation_terminal_without_finish',
    'completed',
    now(),
    NULL,
    0,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.expect_generation_check_violation(
    'test_generation_nonterminal_with_finish',
    'requested',
    NULL,
    now(),
    0,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.expect_generation_check_violation(
    'test_generation_inactive_with_lease',
    'completed',
    now() - interval '1 minute',
    now(),
    0,
    NULL,
    'worker-test',
    '00000000-0000-0000-0000-000000000001'::UUID,
    now(),
    now() + interval '5 minutes',
    NULL,
    NULL
);

SELECT pg_temp.expect_generation_check_violation(
    'test_generation_terminal_with_retry_schedule',
    'completed',
    now() - interval '1 minute',
    now(),
    0,
    now() + interval '5 minutes',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

INSERT INTO generation_runs (
    generation_id,
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    content_option_count,
    status,
    started_at,
    finished_at,
    retry_count,
    next_retry_at,
    worker_id,
    lease_token,
    heartbeat_at,
    lease_expires_at,
    idempotency_key,
    request_fingerprint
)
VALUES
(
    'test_generation_valid_requested',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    1,
    'requested',
    NULL,
    NULL,
    1,
    now() + interval '5 minutes',
    NULL,
    NULL,
    NULL,
    NULL,
    'test-generation-idempotency',
    repeat('a', 64)
),
(
    'test_generation_valid_running',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    1,
    'running',
    now() - interval '1 minute',
    NULL,
    0,
    NULL,
    'worker-test',
    '00000000-0000-0000-0000-000000000002'::UUID,
    now(),
    now() + interval '5 minutes',
    NULL,
    NULL
),
(
    'test_generation_valid_completed',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    1,
    'completed',
    now() - interval '2 minutes',
    now() - interval '1 minute',
    0,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
),
(
    'test_generation_valid_failed',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    1,
    'failed',
    now() - interval '2 minutes',
    now() - interval '1 minute',
    2,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

DO $$
BEGIN
    BEGIN
        INSERT INTO generation_runs (
            generation_id,
            analysis_id,
            project_id,
            campaign_id,
            promotion_id,
            status,
            idempotency_key,
            request_fingerprint
        )
        VALUES (
            'test_generation_duplicate_idempotency',
            'analysis_sms_a1',
            'demo_project',
            'camp_expedia_hotel_demo',
            'promo_expedia_sms_near_checkin',
            'requested',
            'test-generation-idempotency',
            repeat('a', 64)
        );
        RAISE EXCEPTION 'duplicate project idempotency key was accepted';
    EXCEPTION
        WHEN unique_violation THEN NULL;
    END;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.expect_candidate_check_violation(
    p_content_id TEXT,
    p_channel TEXT,
    p_creative_format TEXT,
    p_image_generation_status TEXT,
    p_artifact_status TEXT,
    p_image_url TEXT,
    p_artifact_storage_key TEXT,
    p_artifact_public_url TEXT,
    p_artifact_sha256 TEXT,
    p_artifact_content_type TEXT,
    p_artifact_error_code TEXT,
    p_artifact_published_at TIMESTAMPTZ
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        INSERT INTO content_candidates (
            content_id,
            content_option_id,
            generation_id,
            analysis_id,
            project_id,
            campaign_id,
            promotion_id,
            segment_id,
            channel,
            message,
            image_url,
            creative_format,
            image_generation_status,
            artifact_status,
            artifact_storage_key,
            artifact_public_url,
            artifact_sha256,
            artifact_content_type,
            artifact_error_code,
            artifact_published_at
        )
        VALUES (
            p_content_id,
            p_content_id,
            'test_generation_valid_completed',
            'analysis_sms_a1',
            'demo_project',
            'camp_expedia_hotel_demo',
            'promo_expedia_sms_near_checkin',
            'seg_near_checkin',
            p_channel,
            'Generation v1 contract test message.',
            p_image_url,
            p_creative_format,
            p_image_generation_status,
            p_artifact_status,
            p_artifact_storage_key,
            p_artifact_public_url,
            p_artifact_sha256,
            p_artifact_content_type,
            p_artifact_error_code,
            p_artifact_published_at
        );
        RAISE EXCEPTION '% unexpectedly satisfied candidate checks', p_content_id;
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT pg_temp.expect_candidate_check_violation(
    'test_candidate_channel_format',
    'sms',
    'email_html',
    'not_required',
    'not_required',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.expect_candidate_check_violation(
    'test_candidate_channel_lifecycle',
    'sms',
    'sms_text',
    'pending',
    'not_required',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.expect_candidate_check_violation(
    'test_candidate_completed_without_image',
    'email',
    'email_html',
    'completed',
    'pending',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.expect_candidate_check_violation(
    'test_candidate_incomplete_published_artifact',
    'onsite_banner',
    'banner_html',
    'completed',
    'published',
    'https://example.test/image.png',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.expect_candidate_check_violation(
    'test_candidate_bad_artifact_hash',
    'onsite_banner',
    'banner_html',
    'pending',
    'pending',
    NULL,
    NULL,
    NULL,
    repeat('g', 64),
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.expect_candidate_check_violation(
    'test_candidate_failed_without_error',
    'email',
    'email_html',
    'failed',
    'failed',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
);

INSERT INTO content_candidates (
    content_id,
    content_option_id,
    generation_id,
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_id,
    channel,
    message,
    image_url,
    creative_format,
    image_generation_status,
    artifact_status,
    artifact_storage_key,
    artifact_public_url,
    artifact_sha256,
    artifact_content_type,
    artifact_published_at
)
VALUES
(
    'test_candidate_valid_sms',
    'test_candidate_valid_sms',
    'test_generation_valid_completed',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'seg_near_checkin',
    'sms',
    'Valid SMS candidate.',
    NULL,
    'sms_text',
    'not_required',
    'not_required',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
),
(
    'test_candidate_valid_banner',
    'test_candidate_valid_banner',
    'test_generation_valid_completed',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'seg_near_checkin',
    'onsite_banner',
    NULL,
    'https://example.test/image.png',
    'banner_html',
    'completed',
    'published',
    'genai/demo/test.html',
    'https://example.test/test.html',
    repeat('b', 64),
    'text/html; charset=utf-8',
    now() - interval '1 minute'
);


DO $$
DECLARE
    invalid_count BIGINT;
    fixture_count BIGINT;
BEGIN
    SELECT count(*)
    INTO invalid_count
    FROM generation_runs
    WHERE retry_count < 0
       OR (idempotency_key IS NOT NULL AND request_fingerprint IS NULL)
       OR (
            request_fingerprint IS NOT NULL
            AND request_fingerprint !~ '^[0-9a-f]{64}$'
       )
       OR (
            status = 'running'
            AND (
                started_at IS NULL
                OR worker_id IS NULL
                OR lease_token IS NULL
                OR heartbeat_at IS NULL
                OR lease_expires_at IS NULL
            )
       )
       OR (
            status IN ('completed', 'failed')
            AND (started_at IS NULL OR finished_at IS NULL)
       )
       OR (status NOT IN ('completed', 'failed') AND finished_at IS NOT NULL)
       OR (
            status <> 'running'
            AND (
                worker_id IS NOT NULL
                OR lease_token IS NOT NULL
                OR heartbeat_at IS NOT NULL
                OR lease_expires_at IS NOT NULL
            )
       )
       OR (next_retry_at IS NOT NULL AND status <> 'requested')
       OR (finished_at IS NOT NULL AND finished_at < started_at);

    IF invalid_count <> 0 THEN
        RAISE EXCEPTION '% generation fixtures violate durable job state',
            invalid_count;
    END IF;

    SELECT count(*)
    INTO fixture_count
    FROM generation_runs
    WHERE generation_id IN (
        'generation_email_a1',
        'generation_email_a2',
        'generation_onsite_a1',
        'generation_onsite_a2',
        'generation_sms_a1',
        'generation_sms_a2'
    );

    IF fixture_count <> 6 THEN
        RAISE EXCEPTION 'Generation dummy run count mismatch: %', fixture_count;
    END IF;

    SELECT count(*)
    INTO invalid_count
    FROM generation_runs AS generation
    JOIN promotions AS promotion
      ON promotion.promotion_id = generation.promotion_id
    WHERE generation.generation_id IN (
        'generation_email_a1',
        'generation_email_a2',
        'generation_onsite_a1',
        'generation_onsite_a2',
        'generation_sms_a1',
        'generation_sms_a2'
      )
      AND (
          generation.created_at > generation.started_at
          OR generation.request_fingerprint IS DISTINCT FROM encode(
              digest(
                  convert_to(generation.input_json::text, 'UTF8'),
                  'sha256'
              ),
              'hex'
          )
          OR generation.input_json ->> 'schema_version' IS DISTINCT FROM
              'generation.request.v1'
          OR generation.input_json ->> 'project_id'
              IS DISTINCT FROM generation.project_id
          OR generation.input_json ->> 'campaign_id'
              IS DISTINCT FROM generation.campaign_id
          OR generation.input_json ->> 'promotion_id'
              IS DISTINCT FROM generation.promotion_id
          OR generation.input_json ->> 'analysis_id'
              IS DISTINCT FROM generation.analysis_id
          OR generation.input_json ->> 'channel'
              IS DISTINCT FROM promotion.channel
          OR generation.input_json -> 'content_option_count'
              IS DISTINCT FROM to_jsonb(generation.content_option_count)
          OR generation.input_json ->> 'operator_instruction'
              IS DISTINCT FROM generation.operator_instruction
          OR CASE
              WHEN jsonb_typeof(
                  generation.input_json -> 'target_segments'
              ) = 'array'
              THEN jsonb_array_length(
                  generation.input_json -> 'target_segments'
              ) = 0
              ELSE true
          END
          OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          generation.input_json -> 'target_segments'
                      ) = 'array'
                      THEN generation.input_json -> 'target_segments'
                      ELSE '[]'::jsonb
                  END
              ) AS snapshot_target(value)
              LEFT JOIN promotion_target_segments AS confirmed_target
                ON confirmed_target.analysis_id = generation.analysis_id
               AND confirmed_target.segment_id =
                    snapshot_target.value ->> 'segment_id'
              WHERE jsonb_typeof(snapshot_target.value) <> 'object'
                 OR confirmed_target.segment_id IS NULL
                 OR snapshot_target.value -> 'content_brief'
                      IS DISTINCT FROM confirmed_target.content_brief_json
                 OR snapshot_target.value -> 'data_evidence'
                      IS DISTINCT FROM confirmed_target.data_evidence_json
          )
          OR EXISTS (
              SELECT 1
              FROM promotion_target_segments AS confirmed_target
              WHERE confirmed_target.analysis_id = generation.analysis_id
                AND NOT EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(
                        CASE
                            WHEN jsonb_typeof(
                                generation.input_json -> 'target_segments'
                            ) = 'array'
                            THEN generation.input_json -> 'target_segments'
                            ELSE '[]'::jsonb
                        END
                    ) AS snapshot_target(value)
                    WHERE snapshot_target.value ->> 'segment_id' =
                          confirmed_target.segment_id
                )
          )
          OR generation.input_json #>>
              '{brand_context,manifest_key}' IS NULL
          OR generation.input_json #>>
              '{brand_context,manifest_sha256}' IS NULL
          OR generation.input_json #>> '{brand_context,manifest_sha256}'
              !~ '^[0-9a-f]{64}$'
          OR generation.input_json #>>
              '{brand_context,guide_version}' IS NULL
          OR generation.input_json #>>
              '{brand_context,asset_manifest_version}' IS NULL
          OR generation.input_json #>>
              '{brand_context,catalog_version}' IS NULL
          OR generation.input_json #>> '{placement,type}' IS NULL
          OR generation.input_json #>> '{offer,type}'
              IS DISTINCT FROM promotion.offer_type
          OR generation.input_json #>> '{offer,message_brief}'
              IS DISTINCT FROM promotion.message_brief
          OR generation.input_json #>> '{landing,url}'
              IS DISTINCT FROM promotion.landing_url
          OR generation.input_json #>> '{landing,type}'
              IS DISTINCT FROM promotion.landing_type
          OR generation.input_json #>> '{versions,embedding}' IS DISTINCT FROM
              'text-embedding-3-large-1024-v1'
          OR generation.input_json #>> '{versions,content_spec}'
              IS DISTINCT FROM 'generation-v1'
          OR generation.input_json #>> '{versions,renderer}'
              IS DISTINCT FROM 'generation-v1'
          OR generation.input_json #>> '{versions,guardrail}'
              IS DISTINCT FROM 'generation-v1'
          OR generation.input_json #>> '{versions,model}'
              IS DISTINCT FROM 'fixture-generation-model-v1'
          OR generation.input_json #>> '{versions,prompt}'
              IS DISTINCT FROM 'generation-v1'
          OR generation.input_json #>> '{versions,retrieval_policy}'
              IS DISTINCT FROM 'exact-cosine-v1'
          OR generation.output_json #>>
              '{retrieval_snapshot,retrieval_policy_version}'
              IS DISTINCT FROM 'exact-cosine-v1'
          OR generation.output_json #>>
              '{retrieval_snapshot,query_version}' IS NULL
          OR generation.output_json #>>
              '{retrieval_snapshot,embedding_version}'
              IS DISTINCT FROM 'text-embedding-3-large-1024-v1'
          OR jsonb_typeof(
              generation.output_json #> '{retrieval_snapshot,documents}'
          ) IS DISTINCT FROM 'array'
          OR jsonb_array_length(
              CASE
                  WHEN jsonb_typeof(
                      generation.output_json #>
                          '{retrieval_snapshot,documents}'
                  ) = 'array'
                  THEN generation.output_json #>
                      '{retrieval_snapshot,documents}'
                  ELSE '[]'::jsonb
              END
          ) = 0
          OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          generation.output_json #>
                              '{retrieval_snapshot,documents}'
                      ) = 'array'
                      THEN generation.output_json #>
                          '{retrieval_snapshot,documents}'
                      ELSE '[]'::jsonb
                  END
              ) AS document(value)
              WHERE NULLIF(
                      btrim(document.value ->> 'document_id'),
                      ''
                    ) IS NULL
                 OR NULLIF(
                      btrim(document.value ->> 'source_kind'),
                      ''
                    ) IS NULL
                 OR NULLIF(
                      btrim(document.value ->> 'source_id'),
                      ''
                    ) IS NULL
                 OR NULLIF(
                      btrim(document.value ->> 'source_version'),
                      ''
                    ) IS NULL
                 OR jsonb_typeof(document.value -> 'distance')
                      IS DISTINCT FROM 'number'
                 OR NOT EXISTS (
                      SELECT 1
                      FROM generation_rag.retrieval_documents AS retrieval
                      WHERE retrieval.document_id =
                              document.value ->> 'document_id'
                        AND retrieval.project_id = generation.project_id
                        AND retrieval.context_version = generation.input_json
                            #>> '{brand_context,context_version}'
                        AND retrieval.source_kind =
                              document.value ->> 'source_kind'
                        AND retrieval.source_id =
                              document.value ->> 'source_id'
                        AND retrieval.source_version =
                              document.value ->> 'source_version'
                        AND retrieval.status = 'active'
                 )
          )
      );

    IF invalid_count <> 0 THEN
        RAISE EXCEPTION '% Generation request snapshots are incomplete or unstable',
            invalid_count;
    END IF;

    SELECT count(*)
    INTO invalid_count
    FROM content_candidates AS candidate
    JOIN generation_runs AS generation
      USING (generation_id)
    WHERE generation.generation_id IN (
          'generation_email_a1',
          'generation_email_a2',
          'generation_onsite_a1',
          'generation_onsite_a2',
          'generation_sms_a1',
          'generation_sms_a2'
      )
      AND generation.status = 'completed'
      AND (
          (
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
          OR jsonb_typeof(
              candidate.metadata_json #>
                  '{creative,lineage,document_ids}'
          ) IS DISTINCT FROM 'array'
          OR jsonb_array_length(
              CASE
                  WHEN jsonb_typeof(
                      candidate.metadata_json #>
                          '{creative,lineage,document_ids}'
                  ) = 'array'
                  THEN candidate.metadata_json #>
                      '{creative,lineage,document_ids}'
                  ELSE '[]'::jsonb
              END
          ) = 0
          OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          candidate.metadata_json #>
                              '{creative,lineage,document_ids}'
                      ) = 'array'
                      THEN candidate.metadata_json #>
                          '{creative,lineage,document_ids}'
                      ELSE '[]'::jsonb
                  END
              ) AS lineage_document_id(value)
              WHERE jsonb_typeof(lineage_document_id.value) <> 'string'
                 OR NULLIF(
                      btrim(lineage_document_id.value #>> '{}'),
                      ''
                    ) IS NULL
          )
          OR (
              SELECT count(*) <> count(
                  DISTINCT lineage_document_id.value #>> '{}'
              )
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          candidate.metadata_json #>
                              '{creative,lineage,document_ids}'
                      ) = 'array'
                      THEN candidate.metadata_json #>
                          '{creative,lineage,document_ids}'
                      ELSE '[]'::jsonb
                  END
              ) AS lineage_document_id(value)
          )
          OR jsonb_typeof(
              candidate.metadata_json #> '{creative,lineage,documents}'
          ) IS DISTINCT FROM 'array'
          OR jsonb_array_length(
              CASE
                  WHEN jsonb_typeof(
                      candidate.metadata_json #>
                          '{creative,lineage,documents}'
                  ) = 'array'
                  THEN candidate.metadata_json #>
                      '{creative,lineage,documents}'
                  ELSE '[]'::jsonb
              END
          ) = 0
          OR (
              SELECT count(*) <> count(
                  DISTINCT lineage_document.value ->> 'document_id'
              )
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          candidate.metadata_json #>
                              '{creative,lineage,documents}'
                      ) = 'array'
                      THEN candidate.metadata_json #>
                          '{creative,lineage,documents}'
                      ELSE '[]'::jsonb
                  END
              ) AS lineage_document(value)
          )
          OR ARRAY(
              SELECT lineage_document_id.value #>> '{}'
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          candidate.metadata_json #>
                              '{creative,lineage,document_ids}'
                      ) = 'array'
                      THEN candidate.metadata_json #>
                          '{creative,lineage,document_ids}'
                      ELSE '[]'::jsonb
                  END
              ) AS lineage_document_id(value)
              ORDER BY lineage_document_id.value #>> '{}'
          ) IS DISTINCT FROM ARRAY(
              SELECT lineage_document.value ->> 'document_id'
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          candidate.metadata_json #>
                              '{creative,lineage,documents}'
                      ) = 'array'
                      THEN candidate.metadata_json #>
                          '{creative,lineage,documents}'
                      ELSE '[]'::jsonb
                  END
              ) AS lineage_document(value)
              ORDER BY lineage_document.value ->> 'document_id'
          )
          OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          candidate.metadata_json #>
                              '{creative,lineage,documents}'
                      ) = 'array'
                      THEN candidate.metadata_json #>
                          '{creative,lineage,documents}'
                      ELSE '[]'::jsonb
                  END
              ) AS lineage_document(value)
              WHERE NULLIF(
                      btrim(lineage_document.value ->> 'document_id'),
                      ''
                    ) IS NULL
                 OR NULLIF(
                      btrim(lineage_document.value ->> 'source_kind'),
                      ''
                    ) IS NULL
                 OR NULLIF(
                      btrim(lineage_document.value ->> 'source_id'),
                      ''
                    ) IS NULL
                 OR NULLIF(
                      btrim(lineage_document.value ->> 'source_version'),
                      ''
                    ) IS NULL
                 OR jsonb_typeof(lineage_document.value -> 'distance')
                      IS DISTINCT FROM 'number'
                 OR NOT EXISTS (
                      SELECT 1
                      FROM generation_rag.retrieval_documents AS retrieval
                      WHERE retrieval.document_id =
                              lineage_document.value ->> 'document_id'
                        AND retrieval.project_id = generation.project_id
                        AND retrieval.context_version =
                              candidate.metadata_json #>>
                                  '{creative,lineage,context_version}'
                        AND retrieval.source_kind =
                              lineage_document.value ->> 'source_kind'
                        AND retrieval.source_id =
                              lineage_document.value ->> 'source_id'
                        AND retrieval.source_version =
                              lineage_document.value ->> 'source_version'
                        AND retrieval.status = 'active'
                 )
                 OR NOT EXISTS (
                      SELECT 1
                      FROM jsonb_array_elements(
                          CASE
                              WHEN jsonb_typeof(
                                  generation.output_json #>
                                      '{retrieval_snapshot,documents}'
                              ) = 'array'
                              THEN generation.output_json #>
                                  '{retrieval_snapshot,documents}'
                              ELSE '[]'::jsonb
                          END
                      ) AS run_document(value)
                      WHERE run_document.value ->> 'document_id' =
                              lineage_document.value ->> 'document_id'
                        AND run_document.value ->> 'source_kind' =
                              lineage_document.value ->> 'source_kind'
                        AND run_document.value ->> 'source_id' =
                              lineage_document.value ->> 'source_id'
                        AND run_document.value ->> 'source_version' =
                              lineage_document.value ->> 'source_version'
                        AND run_document.value -> 'distance'
                              IS NOT DISTINCT FROM
                            lineage_document.value -> 'distance'
                 )
          )
          OR candidate.metadata_json #>>
              '{creative,lineage,provider_request_id}' IS NULL
          OR (
              candidate.channel IN ('email', 'onsite_banner')
              AND candidate.metadata_json #>>
                  '{creative,lineage,selected_asset_id}' IS NULL
          )
          OR (
              candidate.channel IN ('email', 'onsite_banner')
              AND NOT EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements(
                      candidate.metadata_json #>
                          '{creative,lineage,documents}'
                  ) AS asset_document(value)
                  WHERE asset_document.value ->> 'source_kind' =
                          'brand_asset'
                    AND asset_document.value ->> 'source_id' =
                          candidate.metadata_json #>>
                              '{creative,lineage,selected_asset_id}'
              )
          )
          OR candidate.metadata_json #>>
              '{creative,artifact,artifact_status}'
              IS DISTINCT FROM candidate.artifact_status
      );

    IF invalid_count <> 0 THEN
        RAISE EXCEPTION '% completed-generation candidates are not ready',
            invalid_count;
    END IF;

    SELECT count(*)
    INTO invalid_count
    FROM content_candidates AS candidate
    JOIN generation_runs AS generation
      USING (generation_id)
    WHERE generation.generation_id IN (
          'generation_email_a1',
          'generation_email_a2',
          'generation_onsite_a1',
          'generation_onsite_a2',
          'generation_sms_a1',
          'generation_sms_a2'
      )
      AND generation.status = 'completed'
      AND candidate.artifact_status = 'published'
      AND (
          candidate.created_at > candidate.artifact_published_at
          OR candidate.artifact_published_at > generation.finished_at
      );

    IF invalid_count <> 0 THEN
        RAISE EXCEPTION '% artifact publication timelines are invalid',
            invalid_count;
    END IF;

    WITH fixture_generations AS (
        SELECT
            generation_id,
            content_option_count,
            input_json
        FROM generation_runs
        WHERE generation_id IN (
              'generation_email_a1',
              'generation_email_a2',
              'generation_onsite_a1',
              'generation_onsite_a2',
              'generation_sms_a1',
              'generation_sms_a2'
          )
          AND status = 'completed'
    ), expected_segments AS (
        SELECT
            generation.generation_id,
            target.value ->> 'segment_id' AS segment_id
        FROM fixture_generations AS generation
        CROSS JOIN LATERAL jsonb_array_elements(
            generation.input_json -> 'target_segments'
        ) AS target(value)
    ), invalid_generations AS (
        SELECT generation.generation_id
        FROM fixture_generations AS generation
        WHERE NOT EXISTS (
                SELECT 1
                FROM expected_segments AS expected
                WHERE expected.generation_id = generation.generation_id
            )
           OR EXISTS (
                SELECT 1
                FROM expected_segments AS expected
                WHERE expected.generation_id = generation.generation_id
                  AND (
                      SELECT count(*)
                      FROM content_candidates AS candidate
                      WHERE candidate.generation_id = generation.generation_id
                        AND candidate.segment_id = expected.segment_id
                  ) <> generation.content_option_count
            )
           OR EXISTS (
                SELECT 1
                FROM content_candidates AS candidate
                WHERE candidate.generation_id = generation.generation_id
                  AND NOT EXISTS (
                      SELECT 1
                      FROM expected_segments AS expected
                      WHERE expected.generation_id = generation.generation_id
                        AND expected.segment_id = candidate.segment_id
                  )
            )
    )
    SELECT count(*)
    INTO invalid_count
    FROM invalid_generations;

    IF invalid_count <> 0 THEN
        RAISE EXCEPTION '% completed generations have unexpected candidate counts',
            invalid_count;
    END IF;

    SELECT count(*)
    INTO invalid_count
    FROM promotion_runs AS promotion_run
    JOIN generation_runs AS generation
      USING (generation_id)
    WHERE promotion_run.started_at IS NOT NULL
      AND generation.finished_at IS NOT NULL
      AND promotion_run.started_at < generation.finished_at;

    IF invalid_count <> 0 THEN
        RAISE EXCEPTION '% promotion runs started before Generation completed',
            invalid_count;
    END IF;

    SELECT count(*)
    INTO invalid_count
    FROM ad_experiments AS experiment
    JOIN generation_runs AS generation
      USING (generation_id)
    WHERE experiment.started_at IS NOT NULL
      AND generation.finished_at IS NOT NULL
      AND experiment.started_at < generation.finished_at;

    IF invalid_count <> 0 THEN
        RAISE EXCEPTION '% experiments started before Generation completed',
            invalid_count;
    END IF;

    SELECT count(*)
    INTO fixture_count
    FROM generation_rag.retrieval_documents
    WHERE document_id IN (
        'rag_demo_home_hero_v1_0',
        'rag_demo_brand_voice_v1_0'
    )
      AND project_id = 'demo_project'
      AND status = 'active'
      AND embedding_model = 'text-embedding-3-large'
      AND embedding_version = 'text-embedding-3-large-1024-v1'
      AND vector_dims(embedding) = 1024;

    IF fixture_count <> 2 THEN
        RAISE EXCEPTION 'Generation RAG dummy contract mismatch: %', fixture_count;
    END IF;

    SELECT count(*)
    INTO fixture_count
    FROM active_ad_serving_assignments
    WHERE promotion_run_id = 'run_onsite_a2'
      AND user_id = 'demo_user_onsite_fallback'
      AND segment_id = 'seg_existing_all'
      AND ad_experiment_id = 'exp_onsite_a2_fallback'
      AND content_id = 'content_onsite_a2_near'
      AND fallback = true;

    IF fixture_count <> 1 THEN
        RAISE EXCEPTION 'ready fallback assignment is not exposed: %', fixture_count;
    END IF;

    SELECT count(*)
    INTO fixture_count
    FROM active_ad_serving_assignments
    WHERE promotion_run_id = 'run_sms_a1'
      AND user_id = 'demo_user_sms_rejected'
      AND content_id = 'content_sms_a1_near';

    IF fixture_count <> 1 THEN
        RAISE EXCEPTION 'ready SMS assignment is not exposed: %', fixture_count;
    END IF;

    SELECT count(*)
    INTO fixture_count
    FROM active_ad_serving_assignments
    WHERE promotion_run_id = 'run_sms_a1'
      AND user_id = 'demo_user_sms_no_provenance';

    IF fixture_count <> 0 THEN
        RAISE EXCEPTION 'serving view lost legacy provenance filtering';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.expect_rag_check_violation(
    p_document_id TEXT,
    p_source_kind TEXT,
    p_chunk_index INT,
    p_status TEXT,
    p_embedding vector,
    p_content_sha256 TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        INSERT INTO generation_rag.retrieval_documents (
            document_id,
            project_id,
            context_version,
            source_kind,
            source_id,
            source_version,
            chunk_index,
            document_text,
            embedding,
            embedding_model,
            embedding_version,
            content_sha256,
            status
        )
        VALUES (
            p_document_id,
            'demo_project',
            'test-v1',
            p_source_kind,
            p_document_id,
            'v1',
            p_chunk_index,
            'Generation RAG contract test document.',
            p_embedding,
            'text-embedding-3-large',
            'text-embedding-3-large-1024-v1',
            p_content_sha256,
            p_status
        );
        RAISE EXCEPTION '% unexpectedly satisfied RAG checks', p_document_id;
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT pg_temp.expect_rag_check_violation(
    'test_rag_bad_source',
    'unknown_source',
    0,
    'pending',
    NULL,
    repeat('a', 64)
);

SELECT pg_temp.expect_rag_check_violation(
    'test_rag_bad_chunk',
    'brand_guide',
    -1,
    'pending',
    NULL,
    repeat('a', 64)
);

SELECT pg_temp.expect_rag_check_violation(
    'test_rag_bad_status',
    'brand_guide',
    0,
    'ready',
    NULL,
    repeat('a', 64)
);

SELECT pg_temp.expect_rag_check_violation(
    'test_rag_active_without_embedding',
    'brand_guide',
    0,
    'active',
    NULL,
    repeat('a', 64)
);

SELECT pg_temp.expect_rag_check_violation(
    'test_rag_bad_hash',
    'brand_guide',
    0,
    'pending',
    NULL,
    repeat('g', 64)
);

INSERT INTO generation_rag.retrieval_documents (
    document_id,
    project_id,
    context_version,
    source_kind,
    source_id,
    source_version,
    chunk_index,
    document_text,
    embedding,
    embedding_model,
    embedding_version,
    content_sha256,
    status
)
VALUES
(
    'test_rag_valid_pending',
    'demo_project',
    'test-v1',
    'brand_guide',
    'test-pending',
    'v1',
    0,
    'Pending embedding is allowed.',
    NULL,
    'text-embedding-3-large',
    'text-embedding-3-large-1024-v1',
    repeat('c', 64),
    'pending'
),
(
    'test_rag_valid_active',
    'demo_project',
    'test-v1',
    'brand_asset',
    'test-active',
    'v1',
    0,
    'Active embedding has exactly 1024 dimensions.',
    array_fill(0.003::real, ARRAY[1024])::vector(1024),
    'text-embedding-3-large',
    'text-embedding-3-large-1024-v1',
    repeat('d', 64),
    'active'
);

DO $$
DECLARE
    distance DOUBLE PRECISION;
BEGIN
    SELECT embedding <=> embedding
    INTO distance
    FROM generation_rag.retrieval_documents
    WHERE document_id = 'test_rag_valid_active';

    IF distance IS DISTINCT FROM 0::DOUBLE PRECISION THEN
        RAISE EXCEPTION 'Generation RAG cosine distance contract failed: %',
            distance;
    END IF;

    BEGIN
        INSERT INTO generation_rag.retrieval_documents (
            document_id,
            project_id,
            context_version,
            source_kind,
            source_id,
            source_version,
            chunk_index,
            document_text,
            embedding,
            embedding_model,
            embedding_version,
            content_sha256,
            status
        )
        VALUES (
            'test_rag_duplicate_identity',
            'demo_project',
            'test-v1',
            'brand_asset',
            'test-active',
            'v1',
            0,
            'Duplicate retrieval identity.',
            array_fill(0.003::real, ARRAY[1024])::vector(1024),
            'text-embedding-3-large',
            'text-embedding-3-large-1024-v1',
            repeat('e', 64),
            'active'
        );
        RAISE EXCEPTION 'duplicate Generation RAG source identity was accepted';
    EXCEPTION
        WHEN unique_violation THEN NULL;
    END;

    BEGIN
        INSERT INTO generation_rag.retrieval_documents (
            document_id,
            project_id,
            context_version,
            source_kind,
            source_id,
            source_version,
            chunk_index,
            document_text,
            embedding,
            embedding_model,
            embedding_version,
            content_sha256,
            status
        )
        VALUES (
            'test_rag_wrong_dimension',
            'demo_project',
            'test-v1',
            'brand_asset',
            'test-wrong-dimension',
            'v1',
            0,
            'Wrong vector dimension.',
            '[1,2,3]'::vector,
            'text-embedding-3-large',
            'text-embedding-3-large-1024-v1',
            repeat('f', 64),
            'active'
        );
        RAISE EXCEPTION 'non-1024 Generation RAG vector was accepted';
    EXCEPTION
        WHEN data_exception THEN NULL;
    END;
END
$$;

DO $$
DECLARE
    original_finished_at TIMESTAMPTZ;
    visible_count BIGINT;
BEGIN
    SELECT finished_at
    INTO original_finished_at
    FROM generation_runs
    WHERE generation_id = 'generation_onsite_a2';

    UPDATE generation_runs
    SET status = 'requested',
        finished_at = NULL
    WHERE generation_id = 'generation_onsite_a2';

    SELECT count(*)
    INTO visible_count
    FROM active_ad_serving_assignments
    WHERE promotion_run_id = 'run_onsite_a2'
      AND user_id = 'demo_user_onsite_fallback';

    IF visible_count <> 0 THEN
        RAISE EXCEPTION 'non-completed generation remained serveable';
    END IF;

    UPDATE generation_runs
    SET status = 'completed',
        finished_at = original_finished_at
    WHERE generation_id = 'generation_onsite_a2';

    UPDATE content_candidates
    SET artifact_status = 'pending'
    WHERE content_id = 'content_onsite_a2_near';

    SELECT count(*)
    INTO visible_count
    FROM active_ad_serving_assignments
    WHERE promotion_run_id = 'run_onsite_a2'
      AND user_id = 'demo_user_onsite_fallback';

    IF visible_count <> 0 THEN
        RAISE EXCEPTION 'unpublished artifact remained serveable';
    END IF;

    UPDATE content_candidates
    SET artifact_status = 'published',
        image_generation_status = 'pending'
    WHERE content_id = 'content_onsite_a2_near';

    SELECT count(*)
    INTO visible_count
    FROM active_ad_serving_assignments
    WHERE promotion_run_id = 'run_onsite_a2'
      AND user_id = 'demo_user_onsite_fallback';

    IF visible_count <> 0 THEN
        RAISE EXCEPTION 'incomplete image remained serveable';
    END IF;

    UPDATE content_candidates
    SET image_generation_status = 'completed'
    WHERE content_id = 'content_onsite_a2_near';

    SELECT count(*)
    INTO visible_count
    FROM active_ad_serving_assignments
    WHERE promotion_run_id = 'run_onsite_a2'
      AND user_id = 'demo_user_onsite_fallback';

    IF visible_count <> 1 THEN
        RAISE EXCEPTION 'ready fallback assignment was not restored';
    END IF;
END
$$;

ROLLBACK;
