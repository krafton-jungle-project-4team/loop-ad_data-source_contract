\set ON_ERROR_STOP on

BEGIN;

CREATE TABLE IF NOT EXISTS uplift_model_versions (
    model_version_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    model_type VARCHAR(100) NOT NULL,

    lifecycle_status VARCHAR(50) NOT NULL DEFAULT 'candidate',
    validation_scope VARCHAR(100) NOT NULL,
    serving_eligible BOOLEAN NOT NULL DEFAULT false,

    dataset_fingerprint CHAR(64) NOT NULL,
    dataset_manifest_json JSONB NOT NULL,
    feature_contract_hash CHAR(64) NOT NULL,
    outcome_contract_hash CHAR(64) NOT NULL,
    training_code_version VARCHAR(100) NOT NULL,
    validation_policy_version VARCHAR(100) NOT NULL,
    split_policy_version VARCHAR(100) NOT NULL,

    model_payload_json JSONB NOT NULL,
    metrics_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    validation_result_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    approved_by VARCHAR(100),
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    validated_at TIMESTAMPTZ,
    activated_at TIMESTAMPTZ,
    retired_at TIMESTAMPTZ,

    CONSTRAINT fk_uplift_model_versions_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_uplift_model_versions_identifiers
        CHECK (
            btrim(model_version_id) <> ''
            AND btrim(model_type) <> ''
            AND btrim(training_code_version) <> ''
            AND btrim(validation_policy_version) <> ''
            AND btrim(split_policy_version) <> ''
        ),

    CONSTRAINT chk_uplift_model_versions_lifecycle_status
        CHECK (
            lifecycle_status IN (
                'candidate',
                'validated',
                'active',
                'rejected',
                'retired'
            )
        ),

    CONSTRAINT chk_uplift_model_versions_validation_scope
        CHECK (
            validation_scope IN (
                'loopad_randomized_experiments',
                'external_pipeline_validation',
                'synthetic_pipeline_validation'
            )
        ),

    CONSTRAINT chk_uplift_model_versions_hashes
        CHECK (
            dataset_fingerprint ~ '^[0-9a-f]{64}$'
            AND feature_contract_hash ~ '^[0-9a-f]{64}$'
            AND outcome_contract_hash ~ '^[0-9a-f]{64}$'
        ),

    CONSTRAINT chk_uplift_model_versions_json_objects
        CHECK (
            jsonb_typeof(dataset_manifest_json) = 'object'
            AND jsonb_typeof(model_payload_json) = 'object'
            AND jsonb_typeof(metrics_json) = 'object'
            AND jsonb_typeof(validation_result_json) = 'object'
        ),

    CONSTRAINT chk_uplift_model_versions_approval_pair
        CHECK (
            (
                (approved_by IS NULL AND approved_at IS NULL)
                OR
                (
                    approved_by IS NOT NULL
                    AND btrim(approved_by) <> ''
                    AND approved_at IS NOT NULL
                )
            )
            AND (
                lifecycle_status IN ('active', 'retired')
                OR approved_by IS NULL
            )
        ),

    CONSTRAINT chk_uplift_model_versions_serving_state
        CHECK (
            (
                lifecycle_status = 'active'
                AND validation_scope = 'loopad_randomized_experiments'
                AND serving_eligible
                AND approved_by IS NOT NULL
                AND approved_at IS NOT NULL
                AND validated_at IS NOT NULL
                AND activated_at IS NOT NULL
                AND retired_at IS NULL
            )
            OR
            (
                lifecycle_status <> 'active'
                AND NOT serving_eligible
            )
        ),

    CONSTRAINT chk_uplift_model_versions_lifecycle_timestamps
        CHECK (
            (lifecycle_status NOT IN ('validated', 'active', 'retired')
                OR validated_at IS NOT NULL)
            AND (lifecycle_status <> 'retired' OR retired_at IS NOT NULL)
            AND (activated_at IS NULL OR validated_at IS NOT NULL)
            AND (retired_at IS NULL OR activated_at IS NOT NULL)
        ),

    CONSTRAINT chk_uplift_model_versions_validation_result
        CHECK (
            lifecycle_status NOT IN ('validated', 'active', 'retired')
            OR validation_result_json->>'passed' = 'true'
        ),

    CONSTRAINT uq_uplift_model_versions_dataset_code
        UNIQUE (
            project_id,
            model_type,
            dataset_fingerprint,
            training_code_version
        )
);

CREATE INDEX IF NOT EXISTS idx_uplift_model_versions_project_lifecycle
ON uplift_model_versions (
    project_id,
    model_type,
    lifecycle_status,
    created_at DESC
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_uplift_model_versions_active_contract
ON uplift_model_versions (
    project_id,
    model_type,
    feature_contract_hash,
    outcome_contract_hash
)
WHERE lifecycle_status = 'active';

CREATE OR REPLACE FUNCTION validate_uplift_model_version_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.lifecycle_status <> 'candidate' THEN
            RAISE EXCEPTION 'new uplift model versions must start as candidate'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    IF ROW(
        OLD.project_id,
        OLD.model_type,
        OLD.dataset_fingerprint,
        OLD.dataset_manifest_json,
        OLD.feature_contract_hash,
        OLD.outcome_contract_hash,
        OLD.training_code_version,
        OLD.validation_policy_version,
        OLD.split_policy_version,
        OLD.model_payload_json,
        OLD.metrics_json,
        OLD.validation_scope,
        OLD.created_at
    ) IS DISTINCT FROM ROW(
        NEW.project_id,
        NEW.model_type,
        NEW.dataset_fingerprint,
        NEW.dataset_manifest_json,
        NEW.feature_contract_hash,
        NEW.outcome_contract_hash,
        NEW.training_code_version,
        NEW.validation_policy_version,
        NEW.split_policy_version,
        NEW.model_payload_json,
        NEW.metrics_json,
        NEW.validation_scope,
        NEW.created_at
    ) THEN
        RAISE EXCEPTION 'uplift model training provenance is immutable'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.lifecycle_status = NEW.lifecycle_status THEN
        RETURN NEW;
    END IF;

    IF NOT (
        (OLD.lifecycle_status = 'candidate'
            AND NEW.lifecycle_status IN ('validated', 'rejected'))
        OR
        (OLD.lifecycle_status = 'validated'
            AND NEW.lifecycle_status IN ('active', 'rejected'))
        OR
        (OLD.lifecycle_status = 'active'
            AND NEW.lifecycle_status = 'retired')
    ) THEN
        RAISE EXCEPTION 'invalid uplift model lifecycle transition: % -> %',
            OLD.lifecycle_status,
            NEW.lifecycle_status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_validate_uplift_model_version_transition
ON uplift_model_versions;

CREATE TRIGGER trg_validate_uplift_model_version_transition
BEFORE INSERT OR UPDATE
ON uplift_model_versions
FOR EACH ROW
EXECUTE FUNCTION validate_uplift_model_version_transition();

CREATE OR REPLACE FUNCTION activate_uplift_model_version(
    p_model_version_id VARCHAR(100),
    p_approved_by VARCHAR(100)
)
RETURNS uplift_model_versions
LANGUAGE plpgsql
AS $$
DECLARE
    target uplift_model_versions%ROWTYPE;
BEGIN
    IF p_approved_by IS NULL OR btrim(p_approved_by) = '' THEN
        RAISE EXCEPTION 'uplift model activation requires an approver'
            USING ERRCODE = '23514';
    END IF;

    SELECT *
    INTO target
    FROM uplift_model_versions
    WHERE model_version_id = p_model_version_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'uplift model version does not exist: %',
            p_model_version_id
            USING ERRCODE = 'P0002';
    END IF;
    IF target.lifecycle_status <> 'validated' THEN
        RAISE EXCEPTION 'only validated uplift models can be activated'
            USING ERRCODE = '23514';
    END IF;
    IF target.validation_scope <> 'loopad_randomized_experiments' THEN
        RAISE EXCEPTION 'external or synthetic validation cannot activate serving'
            USING ERRCODE = '23514';
    END IF;
    IF target.validation_result_json->>'passed' IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'uplift model validation policy did not pass'
            USING ERRCODE = '23514';
    END IF;

    PERFORM 1
    FROM uplift_model_versions
    WHERE project_id = target.project_id
      AND model_type = target.model_type
      AND feature_contract_hash = target.feature_contract_hash
      AND outcome_contract_hash = target.outcome_contract_hash
      AND lifecycle_status = 'active'
    FOR UPDATE;

    UPDATE uplift_model_versions
    SET lifecycle_status = 'retired',
        serving_eligible = false,
        retired_at = clock_timestamp()
    WHERE project_id = target.project_id
      AND model_type = target.model_type
      AND feature_contract_hash = target.feature_contract_hash
      AND outcome_contract_hash = target.outcome_contract_hash
      AND lifecycle_status = 'active';

    UPDATE uplift_model_versions
    SET lifecycle_status = 'active',
        serving_eligible = true,
        approved_by = btrim(p_approved_by),
        approved_at = clock_timestamp(),
        activated_at = clock_timestamp(),
        retired_at = NULL
    WHERE model_version_id = p_model_version_id
    RETURNING * INTO target;

    RETURN target;
END
$$;

COMMIT;
