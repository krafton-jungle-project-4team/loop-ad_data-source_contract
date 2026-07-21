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
    IF to_regclass('uplift_model_versions') IS NULL THEN
        RAISE EXCEPTION 'uplift_model_versions is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'uplift_model_versions'::regclass
          AND conname = 'uq_uplift_model_versions_dataset_code'
    ) THEN
        RAISE EXCEPTION 'uplift model dataset idempotency constraint is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_index AS model_index
        JOIN pg_class AS index_relation
          ON index_relation.oid = model_index.indexrelid
        WHERE model_index.indrelid = 'uplift_model_versions'::regclass
          AND index_relation.relname =
              'uq_uplift_model_versions_active_contract'
          AND model_index.indisunique
          AND model_index.indpred IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'compatible active model partial unique index is missing';
    END IF;
END
$$;

INSERT INTO uplift_model_versions (
    model_version_id,
    project_id,
    model_type,
    validation_scope,
    dataset_fingerprint,
    dataset_manifest_json,
    feature_contract_hash,
    outcome_contract_hash,
    training_code_version,
    validation_policy_version,
    split_policy_version,
    model_payload_json,
    metrics_json
) VALUES (
    'uplift_model_registry_a',
    'demo_project',
    'transformed_outcome_ridge',
    'loopad_randomized_experiments',
    repeat('a', 64),
    '{"schema_version":"uplift-dataset-manifest.v1","experiment_ids":["adexp_a"]}'::jsonb,
    repeat('b', 64),
    repeat('c', 64),
    'uplift-training.v1',
    'uplift-validation.v1',
    'experiment-time-holdout.v1',
    '{"schema_version":"uplift-model-payload.v1","feature_names":["hotel_search_count"]}'::jsonb,
    '{"auuc":0.12,"qini":0.08}'::jsonb
);

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO uplift_model_versions (
        model_version_id,
        project_id,
        model_type,
        validation_scope,
        dataset_fingerprint,
        dataset_manifest_json,
        feature_contract_hash,
        outcome_contract_hash,
        training_code_version,
        validation_policy_version,
        split_policy_version,
        model_payload_json
    ) VALUES (
        'uplift_model_registry_duplicate',
        'demo_project',
        'transformed_outcome_ridge',
        'loopad_randomized_experiments',
        repeat('a', 64),
        '{}'::jsonb,
        repeat('b', 64),
        repeat('c', 64),
        'uplift-training.v1',
        'uplift-validation.v1',
        'experiment-time-holdout.v1',
        '{}'::jsonb
    )$sql$,
    '23505'
);

SELECT pg_temp.expect_failure(
    $sql$UPDATE uplift_model_versions
        SET lifecycle_status = 'active',
            serving_eligible = true,
            validated_at = now(),
            activated_at = now(),
            approved_by = 'reviewer',
            approved_at = now(),
            validation_result_json = '{"passed":true}'::jsonb
        WHERE model_version_id = 'uplift_model_registry_a'$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$UPDATE uplift_model_versions
        SET lifecycle_status = 'collecting_data'
        WHERE model_version_id = 'uplift_model_registry_a'$sql$,
    '23514'
);

UPDATE uplift_model_versions
SET lifecycle_status = 'validated',
    validation_result_json = '{"passed":true,"policy":"uplift-validation.v1"}'::jsonb,
    validated_at = clock_timestamp()
WHERE model_version_id = 'uplift_model_registry_a';

SELECT pg_temp.expect_failure(
    $sql$SELECT activate_uplift_model_version(
        'uplift_model_registry_a',
        ''
    )$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$UPDATE uplift_model_versions
        SET lifecycle_status = 'active',
            serving_eligible = true,
            activated_at = now()
        WHERE model_version_id = 'uplift_model_registry_a'$sql$,
    '23514'
);

SELECT model_version_id
FROM activate_uplift_model_version(
    'uplift_model_registry_a',
    'model-reviewer@example.com'
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM uplift_model_versions
        WHERE model_version_id = 'uplift_model_registry_a'
          AND lifecycle_status = 'active'
          AND validation_scope = 'loopad_randomized_experiments'
          AND serving_eligible
          AND approved_by = 'model-reviewer@example.com'
          AND approved_at IS NOT NULL
          AND activated_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'validated LoopAd model was not activated';
    END IF;
END
$$;

INSERT INTO uplift_model_versions (
    model_version_id,
    project_id,
    model_type,
    validation_scope,
    dataset_fingerprint,
    dataset_manifest_json,
    feature_contract_hash,
    outcome_contract_hash,
    training_code_version,
    validation_policy_version,
    split_policy_version,
    model_payload_json,
    metrics_json
) VALUES (
    'uplift_model_registry_b',
    'demo_project',
    'transformed_outcome_ridge',
    'loopad_randomized_experiments',
    repeat('d', 64),
    '{"schema_version":"uplift-dataset-manifest.v1","experiment_ids":["adexp_b"]}'::jsonb,
    repeat('b', 64),
    repeat('c', 64),
    'uplift-training.v1',
    'uplift-validation.v1',
    'experiment-time-holdout.v1',
    '{"schema_version":"uplift-model-payload.v1","feature_names":["hotel_search_count"]}'::jsonb,
    '{"auuc":0.14,"qini":0.09}'::jsonb
);

UPDATE uplift_model_versions
SET lifecycle_status = 'validated',
    validation_result_json = '{"passed":true}'::jsonb,
    validated_at = clock_timestamp()
WHERE model_version_id = 'uplift_model_registry_b';

SELECT model_version_id
FROM activate_uplift_model_version(
    'uplift_model_registry_b',
    'second-reviewer@example.com'
);

DO $$
BEGIN
    IF (SELECT count(*) FROM uplift_model_versions
        WHERE lifecycle_status = 'active') <> 1
       OR NOT EXISTS (
            SELECT 1
            FROM uplift_model_versions
            WHERE model_version_id = 'uplift_model_registry_a'
              AND lifecycle_status = 'retired'
              AND NOT serving_eligible
              AND retired_at IS NOT NULL
       )
       OR NOT EXISTS (
            SELECT 1
            FROM uplift_model_versions
            WHERE model_version_id = 'uplift_model_registry_b'
              AND lifecycle_status = 'active'
              AND serving_eligible
       )
    THEN
        RAISE EXCEPTION 'active model replacement contract differs';
    END IF;
END
$$;

INSERT INTO uplift_model_versions (
    model_version_id,
    project_id,
    model_type,
    validation_scope,
    dataset_fingerprint,
    dataset_manifest_json,
    feature_contract_hash,
    outcome_contract_hash,
    training_code_version,
    validation_policy_version,
    split_policy_version,
    model_payload_json
) VALUES (
    'uplift_model_registry_external',
    'demo_project',
    'transformed_outcome_ridge',
    'external_pipeline_validation',
    repeat('e', 64),
    '{"dataset":"criteo_uplift"}'::jsonb,
    repeat('f', 64),
    repeat('1', 64),
    'uplift-training.v1',
    'uplift-validation.v1',
    'experiment-group-holdout.v1',
    '{"schema_version":"uplift-model-payload.v1"}'::jsonb
);

UPDATE uplift_model_versions
SET lifecycle_status = 'validated',
    validation_result_json = '{"passed":true}'::jsonb,
    validated_at = clock_timestamp()
WHERE model_version_id = 'uplift_model_registry_external';

SELECT pg_temp.expect_failure(
    $sql$SELECT activate_uplift_model_version(
        'uplift_model_registry_external',
        'external-reviewer@example.com'
    )$sql$,
    '23514'
);

INSERT INTO uplift_model_versions (
    model_version_id,
    project_id,
    model_type,
    validation_scope,
    dataset_fingerprint,
    dataset_manifest_json,
    feature_contract_hash,
    outcome_contract_hash,
    training_code_version,
    validation_policy_version,
    split_policy_version,
    model_payload_json
) VALUES (
    'uplift_model_registry_rejected',
    'demo_project',
    'transformed_outcome_ridge',
    'loopad_randomized_experiments',
    repeat('2', 64),
    '{}'::jsonb,
    repeat('3', 64),
    repeat('4', 64),
    'uplift-training.v1',
    'uplift-validation.v1',
    'experiment-time-holdout.v1',
    '{}'::jsonb
);

UPDATE uplift_model_versions
SET lifecycle_status = 'rejected',
    validation_result_json = '{"passed":false}'::jsonb
WHERE model_version_id = 'uplift_model_registry_rejected';

SELECT pg_temp.expect_failure(
    $sql$UPDATE uplift_model_versions
        SET lifecycle_status = 'active',
            serving_eligible = true,
            validated_at = now(),
            activated_at = now(),
            approved_by = 'reviewer',
            approved_at = now(),
            validation_result_json = '{"passed":true}'::jsonb
        WHERE model_version_id = 'uplift_model_registry_rejected'$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$UPDATE uplift_model_versions
        SET dataset_manifest_json = '{"changed":true}'::jsonb
        WHERE model_version_id = 'uplift_model_registry_external'$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO uplift_model_versions (
        model_version_id,
        project_id,
        model_type,
        validation_scope,
        dataset_fingerprint,
        dataset_manifest_json,
        feature_contract_hash,
        outcome_contract_hash,
        training_code_version,
        validation_policy_version,
        split_policy_version,
        model_payload_json
    ) VALUES (
        'uplift_model_registry_invalid_payload',
        'demo_project',
        'transformed_outcome_ridge',
        'loopad_randomized_experiments',
        repeat('5', 64),
        '{}'::jsonb,
        repeat('6', 64),
        repeat('7', 64),
        'uplift-training.v1',
        'uplift-validation.v1',
        'experiment-time-holdout.v1',
        '[]'::jsonb
    )$sql$,
    '23514'
);

ROLLBACK;
