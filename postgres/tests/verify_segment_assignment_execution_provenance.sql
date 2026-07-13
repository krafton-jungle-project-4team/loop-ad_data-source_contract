\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.expect_failure(
    p_statement TEXT,
    p_expected_sqlstate TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    actual_sqlstate TEXT;
BEGIN
    BEGIN
        EXECUTE p_statement;
    EXCEPTION WHEN OTHERS THEN
        actual_sqlstate := SQLSTATE;
        IF p_expected_sqlstate IS NOT NULL
           AND actual_sqlstate <> p_expected_sqlstate THEN
            RAISE EXCEPTION
                'expected SQLSTATE %, received % for: %',
                p_expected_sqlstate,
                actual_sqlstate,
                p_statement;
        END IF;
        RETURN;
    END;

    RAISE EXCEPTION 'statement unexpectedly succeeded: %', p_statement;
END
$$;

DO $$
BEGIN
    IF to_regclass('segment_assignment_executions') IS NULL THEN
        RAISE EXCEPTION 'segment_assignment_executions is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'user_segment_assignments'::regclass
          AND attname = 'segment_assignment_execution_id'
          AND atttypid = 'character varying'::regtype
          AND atttypmod = 104
          AND NOT attnotnull
          AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION 'assignment execution FK column differs';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM user_segment_assignments
        WHERE segment_assignment_execution_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'existing assignment unexpectedly has execution provenance';
    END IF;

    IF position(
        'segment_assignment_executions' IN
        pg_get_viewdef('active_ad_serving_assignments'::regclass, true)
    ) <> 0 THEN
        RAISE EXCEPTION 'active serving view now depends on execution provenance';
    END IF;
END
$$;

INSERT INTO segment_assignment_executions (
    segment_assignment_execution_id,
    promotion_run_id,
    request_fingerprint,
    input_fingerprint,
    matcher_strategy,
    matcher_version,
    vector_version,
    source_cutoff_at,
    input_manifest_json
)
VALUES (
    'assignment_execution_exact_v1',
    'run_onsite_a2',
    repeat('a', 64),
    repeat('b', 64),
    'exact_cosine',
    'matcher-v1',
    'fixture-v1',
    '2026-07-12 12:00:00+00',
    '{"user_count":4,"source":"user_behavior_vector_revisions"}'::jsonb
);

UPDATE user_segment_assignments
SET segment_assignment_execution_id = 'assignment_execution_exact_v1'
WHERE promotion_run_id = 'run_onsite_a2'
  AND user_id = 'demo_user_onsite_cutover';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM user_segment_assignments AS assignments
        JOIN segment_assignment_executions AS executions
          USING (segment_assignment_execution_id)
        WHERE assignments.promotion_run_id = 'run_onsite_a2'
          AND assignments.user_id = 'demo_user_onsite_cutover'
          AND executions.matcher_strategy = 'exact_cosine'
    ) THEN
        RAISE EXCEPTION 'assignment execution FK link failed';
    END IF;
END
$$;

SELECT pg_temp.expect_failure(
    format(
        $sql$INSERT INTO segment_assignment_executions (
            segment_assignment_execution_id,
            promotion_run_id,
            request_fingerprint,
            input_fingerprint,
            matcher_strategy,
            matcher_version,
            vector_version,
            source_cutoff_at,
            input_manifest_json
        ) VALUES (
            'assignment_execution_duplicate_request',
            'run_onsite_a2',
            %L,
            %L,
            'ann',
            'matcher-v2',
            'fixture-v1',
            now(),
            '{}'::jsonb
        )$sql$,
        repeat('a', 64),
        repeat('c', 64)
    ),
    '23505'
);

INSERT INTO segment_assignment_executions (
    segment_assignment_execution_id,
    promotion_run_id,
    request_fingerprint,
    input_fingerprint,
    matcher_strategy,
    matcher_version,
    vector_version,
    source_cutoff_at,
    input_manifest_json
)
VALUES (
    'assignment_execution_other_request',
    'run_onsite_a2',
    repeat('c', 64),
    repeat('d', 64),
    'ann_with_exact_rescue',
    'matcher-v2',
    'fixture-v1',
    '2026-07-12 12:00:00+00',
    '{}'::jsonb
);

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO segment_assignment_executions (
        segment_assignment_execution_id,
        promotion_run_id,
        request_fingerprint,
        input_fingerprint,
        matcher_strategy,
        matcher_version,
        vector_version,
        source_cutoff_at,
        input_manifest_json
    ) VALUES (
        'assignment_execution_bad_fingerprint',
        'run_onsite_a2',
        'ABC',
        repeat('e', 64),
        'exact',
        'v1',
        'fixture-v1',
        now(),
        '{}'::jsonb
    )$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO segment_assignment_executions (
        segment_assignment_execution_id,
        promotion_run_id,
        request_fingerprint,
        input_fingerprint,
        matcher_strategy,
        matcher_version,
        vector_version,
        source_cutoff_at,
        input_manifest_json
    ) VALUES (
        'assignment_execution_bad_input_fingerprint',
        'run_onsite_a2',
        repeat('e', 64),
        repeat('F', 64),
        'exact',
        'v1',
        'fixture-v1',
        now(),
        '{}'::jsonb
    )$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO segment_assignment_executions (
        segment_assignment_execution_id,
        promotion_run_id,
        request_fingerprint,
        input_fingerprint,
        matcher_strategy,
        matcher_version,
        vector_version,
        source_cutoff_at,
        input_manifest_json
    ) VALUES (
        'assignment_execution_bad_manifest',
        'run_onsite_a2',
        repeat('e', 64),
        repeat('f', 64),
        'exact',
        'v1',
        'fixture-v1',
        now(),
        '[]'::jsonb
    )$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO segment_assignment_executions (
        segment_assignment_execution_id,
        promotion_run_id,
        request_fingerprint,
        input_fingerprint,
        matcher_strategy,
        matcher_version,
        vector_version,
        source_cutoff_at,
        input_manifest_json
    ) VALUES (
        'assignment_execution_blank_strategy',
        'run_onsite_a2',
        repeat('e', 64),
        repeat('f', 64),
        '   ',
        'v1',
        'fixture-v1',
        now(),
        '{}'::jsonb
    )$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$UPDATE user_segment_assignments
         SET segment_assignment_execution_id = 'missing_execution'
         WHERE promotion_run_id = 'run_email_a1'
           AND user_id = 'demo_user_email_awaiting'$sql$,
    '23503'
);

ROLLBACK;
