BEGIN;

ALTER TABLE segment_assignment_executions
    ADD COLUMN IF NOT EXISTS uplift_assignment_status VARCHAR(20),
    ADD COLUMN IF NOT EXISTS uplift_finalized_at TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'segment_assignment_executions'::regclass
          AND conname = 'chk_segment_assignment_executions_uplift_status'
    ) THEN
        ALTER TABLE segment_assignment_executions
            ADD CONSTRAINT chk_segment_assignment_executions_uplift_status
            CHECK (
                (
                    input_manifest_json->>'schema_version' =
                        'segment-assignment-execution.v2'
                    AND uplift_assignment_status IN ('preparing', 'finalized')
                    AND (
                        (
                            uplift_assignment_status = 'preparing'
                            AND uplift_finalized_at IS NULL
                        )
                        OR (
                            uplift_assignment_status = 'finalized'
                            AND uplift_finalized_at IS NOT NULL
                        )
                    )
                )
                OR (
                    input_manifest_json->>'schema_version' IS DISTINCT FROM
                        'segment-assignment-execution.v2'
                    AND uplift_assignment_status IS NULL
                    AND uplift_finalized_at IS NULL
                )
            );
    END IF;
END
$$;

-- =========================================================
-- Uplift-ready assignment v1
-- Keeps experiment design on the assignment execution while
-- recording one immutable treatment/control result per user.
-- =========================================================
CREATE TABLE IF NOT EXISTS ad_experiment_units (
    experiment_unit_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    promotion_run_id VARCHAR(100) NOT NULL,
    ad_experiment_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    audience_snapshot_id VARCHAR(100) NOT NULL,
    vector_generation_id VARCHAR(100) NOT NULL,
    segment_assignment_execution_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    arm VARCHAR(20) NOT NULL,
    treatment_probability NUMERIC(12, 9) NOT NULL,
    assigned_at TIMESTAMPTZ NOT NULL,
    outcome_window_start TIMESTAMPTZ NOT NULL,
    outcome_window_end TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_ad_experiment_units_project
        FOREIGN KEY (project_id)
        REFERENCES projects (project_id),

    CONSTRAINT fk_ad_experiment_units_run
        FOREIGN KEY (promotion_run_id)
        REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_ad_experiment_units_experiment
        FOREIGN KEY (ad_experiment_id)
        REFERENCES ad_experiments (ad_experiment_id),

    CONSTRAINT fk_ad_experiment_units_segment
        FOREIGN KEY (segment_id)
        REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_ad_experiment_units_snapshot
        FOREIGN KEY (audience_snapshot_id)
        REFERENCES segment_audience_snapshots (snapshot_id),

    CONSTRAINT fk_ad_experiment_units_vector_generation
        FOREIGN KEY (vector_generation_id)
        REFERENCES user_behavior_vector_search_generations (
            vector_generation_id
        ),

    CONSTRAINT fk_ad_experiment_units_execution
        FOREIGN KEY (
            promotion_run_id,
            segment_assignment_execution_id
        )
        REFERENCES segment_assignment_executions (
            promotion_run_id,
            segment_assignment_execution_id
        )
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,

    CONSTRAINT fk_ad_experiment_units_snapshot_member
        FOREIGN KEY (audience_snapshot_id, user_id)
        REFERENCES segment_audience_members (snapshot_id, user_id),

    CONSTRAINT chk_ad_experiment_units_identifiers
        CHECK (
            btrim(experiment_unit_id) <> ''
            AND btrim(project_id) <> ''
            AND btrim(promotion_run_id) <> ''
            AND btrim(ad_experiment_id) <> ''
            AND btrim(segment_id) <> ''
            AND btrim(audience_snapshot_id) <> ''
            AND btrim(vector_generation_id) <> ''
            AND btrim(segment_assignment_execution_id) <> ''
            AND btrim(user_id) <> ''
        ),

    CONSTRAINT chk_ad_experiment_units_arm
        CHECK (arm IN ('treatment', 'control')),

    CONSTRAINT chk_ad_experiment_units_treatment_probability
        CHECK (
            treatment_probability > 0
            AND treatment_probability <= 1
        ),

    CONSTRAINT chk_ad_experiment_units_outcome_window
        CHECK (
            assigned_at = outcome_window_start
            AND outcome_window_start < outcome_window_end
        ),

    CONSTRAINT uq_ad_experiment_units_run_user
        UNIQUE (promotion_run_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_ad_experiment_units_execution_arm
ON ad_experiment_units (segment_assignment_execution_id, arm);

CREATE INDEX IF NOT EXISTS idx_ad_experiment_units_run_arm
ON ad_experiment_units (promotion_run_id, arm);

CREATE INDEX IF NOT EXISTS idx_ad_experiment_units_experiment_arm_user
ON ad_experiment_units (ad_experiment_id, arm, user_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiment_units_snapshot_user
ON ad_experiment_units (audience_snapshot_id, user_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiment_units_generation_user
ON ad_experiment_units (vector_generation_id, user_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiment_units_project_outcome_end
ON ad_experiment_units (project_id, outcome_window_end);

CREATE OR REPLACE FUNCTION prevent_promotion_run_outcome_spec_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.goal_snapshot_json->'outcome_spec'
           IS DISTINCT FROM NEW.goal_snapshot_json->'outcome_spec'
       OR OLD.goal_snapshot_json->>'outcome_spec_hash'
           IS DISTINCT FROM NEW.goal_snapshot_json->>'outcome_spec_hash'
       OR OLD.goal_snapshot_json->'outcome_spec'->>'outcome_definition_version'
           IS DISTINCT FROM
          NEW.goal_snapshot_json->'outcome_spec'->>'outcome_definition_version'
    THEN
        RAISE EXCEPTION 'promotion run outcome spec is immutable'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_promotion_run_outcome_spec_immutable
ON promotion_runs;

CREATE TRIGGER trg_promotion_run_outcome_spec_immutable
BEFORE UPDATE
ON promotion_runs
FOR EACH ROW EXECUTE FUNCTION prevent_promotion_run_outcome_spec_mutation();

CREATE OR REPLACE FUNCTION assert_promotion_run_experiment_design(
    p_promotion_run_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    run_goal_snapshot JSONB;
    execution_row RECORD;
    design JSONB;
    normalized_design JSONB;
    first_design JSONB;
    first_design_fingerprint TEXT;
    requested_ratio NUMERIC;
    outcome_window_days NUMERIC;
    mode TEXT;
    salt_fingerprint TEXT;
BEGIN
    SELECT goal_snapshot_json
    INTO run_goal_snapshot
    FROM promotion_runs
    WHERE promotion_run_id = p_promotion_run_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    FOR execution_row IN
        SELECT
            segment_assignment_execution_id,
            input_manifest_json
        FROM segment_assignment_executions
        WHERE promotion_run_id = p_promotion_run_id
          AND input_manifest_json->>'schema_version' =
              'segment-assignment-execution.v2'
        ORDER BY segment_assignment_execution_id
    LOOP
        design := execution_row.input_manifest_json->'experiment_design';

        IF jsonb_typeof(design) IS DISTINCT FROM 'object'
           OR NOT COALESCE(
                execution_row.input_manifest_json
                    ->>'experiment_design_fingerprint'
                    ~ '^[0-9a-f]{64}$',
                false
           )
           OR jsonb_typeof(execution_row.input_manifest_json->'outcome_spec')
                IS DISTINCT FROM 'object'
           OR jsonb_typeof(execution_row.input_manifest_json->'audience_bindings')
                IS DISTINCT FROM 'array'
           OR jsonb_typeof(execution_row.input_manifest_json->'allocation_results')
                IS DISTINCT FROM 'array'
           OR jsonb_typeof(design->'requested_treatment_ratio')
                IS DISTINCT FROM 'number'
           OR jsonb_typeof(design->'outcome_window_days')
                IS DISTINCT FROM 'number'
           OR design->>'randomization_version' IS NULL
           OR btrim(design->>'randomization_version') = ''
           OR design->>'quota_policy_version' IS NULL
           OR btrim(design->>'quota_policy_version') = ''
           OR NOT COALESCE(
                design->>'outcome_spec_hash' ~ '^[0-9a-f]{64}$',
                false
           )
        THEN
            RAISE EXCEPTION
                'invalid uplift-ready experiment design manifest: %',
                execution_row.segment_assignment_execution_id
                USING ERRCODE = '23514';
        END IF;

        mode := design->>'mode';
        requested_ratio := (design->>'requested_treatment_ratio')::NUMERIC;
        outcome_window_days := (design->>'outcome_window_days')::NUMERIC;
        salt_fingerprint := design->>'randomization_salt_fingerprint';

        IF mode IS NULL
           OR mode NOT IN ('all_treatment', 'randomized_holdout')
           OR outcome_window_days <= 0
           OR outcome_window_days <> trunc(outcome_window_days)
           OR (
                mode = 'all_treatment'
                AND requested_ratio <> 1
           )
           OR (
                mode = 'randomized_holdout'
                AND (
                    requested_ratio <= 0
                    OR requested_ratio >= 1
                    OR NOT COALESCE(
                        salt_fingerprint ~ '^[0-9a-f]{64}$',
                        false
                    )
                )
           )
           OR (
                mode = 'all_treatment'
                AND salt_fingerprint IS NOT NULL
                AND salt_fingerprint !~ '^[0-9a-f]{64}$'
           )
        THEN
            RAISE EXCEPTION
                'invalid uplift-ready experiment design values: %',
                execution_row.segment_assignment_execution_id
                USING ERRCODE = '23514';
        END IF;

        IF jsonb_typeof(run_goal_snapshot->'outcome_spec')
                IS DISTINCT FROM 'object'
           OR NOT COALESCE(
                run_goal_snapshot->>'outcome_spec_hash'
                    ~ '^[0-9a-f]{64}$',
                false
           )
           OR execution_row.input_manifest_json->'outcome_spec'
                IS DISTINCT FROM run_goal_snapshot->'outcome_spec'
           OR design->>'outcome_spec_hash'
                IS DISTINCT FROM run_goal_snapshot->>'outcome_spec_hash'
        THEN
            RAISE EXCEPTION
                'assignment execution outcome spec differs from promotion run: %',
                execution_row.segment_assignment_execution_id
                USING ERRCODE = '23514';
        END IF;

        normalized_design := jsonb_build_object(
            'mode', mode,
            'requested_treatment_ratio', requested_ratio,
            'outcome_window_days', outcome_window_days,
            'randomization_version', design->>'randomization_version',
            'quota_policy_version', design->>'quota_policy_version',
            'randomization_salt_fingerprint',
                COALESCE(to_jsonb(salt_fingerprint), 'null'::jsonb),
            'outcome_spec_hash', design->>'outcome_spec_hash'
        );

        IF first_design IS NULL THEN
            first_design := normalized_design;
            first_design_fingerprint :=
                execution_row.input_manifest_json->>'experiment_design_fingerprint';
        ELSIF normalized_design IS DISTINCT FROM first_design
              OR execution_row.input_manifest_json->>'experiment_design_fingerprint'
                    IS DISTINCT FROM first_design_fingerprint
        THEN
            RAISE EXCEPTION
                'promotion run contains conflicting experiment designs: %',
                p_promotion_run_id
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION validate_promotion_run_experiment_design_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM assert_promotion_run_experiment_design(OLD.promotion_run_id);
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE')
       AND (
            TG_OP = 'INSERT'
            OR NEW.promotion_run_id IS DISTINCT FROM OLD.promotion_run_id
            OR NEW.input_manifest_json IS DISTINCT FROM OLD.input_manifest_json
       )
    THEN
        PERFORM assert_promotion_run_experiment_design(NEW.promotion_run_id);
    END IF;

    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS trg_validate_promotion_run_experiment_design
ON segment_assignment_executions;

CREATE CONSTRAINT TRIGGER trg_validate_promotion_run_experiment_design
AFTER INSERT OR UPDATE OR DELETE
ON segment_assignment_executions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION validate_promotion_run_experiment_design_trigger();

CREATE OR REPLACE FUNCTION assert_uplift_assignment_execution(
    p_segment_assignment_execution_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    execution_row segment_assignment_executions%ROWTYPE;
BEGIN
    SELECT *
    INTO execution_row
    FROM segment_assignment_executions
    WHERE segment_assignment_execution_id =
        p_segment_assignment_execution_id
    FOR UPDATE;

    IF NOT FOUND
       OR execution_row.input_manifest_json->>'schema_version'
            IS DISTINCT FROM 'segment-assignment-execution.v2'
    THEN
        RAISE EXCEPTION 'uplift-ready assignment execution does not exist: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    IF jsonb_typeof(
        execution_row.input_manifest_json->'allocation_results'
    ) IS DISTINCT FROM 'array'
       OR jsonb_typeof(
            execution_row.input_manifest_json->'audience_bindings'
       ) IS DISTINCT FROM 'array'
    THEN
        RAISE EXCEPTION 'uplift-ready assignment manifest is incomplete: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    PERFORM assert_promotion_run_experiment_design(
        execution_row.promotion_run_id
    );

    -- Validate identity, frozen feature time, and final snapshot bindings once
    -- for the complete execution instead of once per inserted user row.
    IF EXISTS (
        SELECT 1
        FROM ad_experiment_units AS unit
        JOIN promotion_runs AS run
          ON run.promotion_run_id = unit.promotion_run_id
        JOIN ad_experiments AS experiment
          ON experiment.ad_experiment_id = unit.ad_experiment_id
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = unit.audience_snapshot_id
        JOIN segment_audience_members AS member
          ON member.snapshot_id = unit.audience_snapshot_id
         AND member.user_id = unit.user_id
        JOIN user_behavior_vector_search_generations AS generation
          ON generation.vector_generation_id = unit.vector_generation_id
        JOIN segment_assignment_executions AS execution
          ON execution.promotion_run_id = unit.promotion_run_id
         AND execution.segment_assignment_execution_id =
             unit.segment_assignment_execution_id
        JOIN promotion_run_target_bindings AS binding
          ON binding.promotion_run_id = unit.promotion_run_id
         AND binding.segment_id = unit.segment_id
         AND binding.final_snapshot_id = unit.audience_snapshot_id
        WHERE unit.segment_assignment_execution_id =
                p_segment_assignment_execution_id
          AND NOT (
              unit.project_id = run.project_id
              AND experiment.project_id = unit.project_id
              AND experiment.promotion_run_id = unit.promotion_run_id
              AND experiment.segment_id = unit.segment_id
              AND snapshot.project_id = unit.project_id
              AND snapshot.segment_id = unit.segment_id
              AND snapshot.snapshot_kind = 'final'
              AND snapshot.vector_generation_id = unit.vector_generation_id
              AND generation.project_id = unit.project_id
              AND generation.vector_version = snapshot.vector_version
              AND execution.vector_version = generation.vector_version
              AND execution.input_manifest_json->>'schema_version' =
                  'segment-assignment-execution.v2'
              AND generation.window_end <= unit.assigned_at
              AND generation.source_revision_cutoff <= unit.assigned_at
              AND snapshot.source_cutoff <= unit.assigned_at
              AND execution.source_cutoff_at <= unit.assigned_at
              AND unit.outcome_window_start = unit.assigned_at
              AND unit.outcome_window_start < unit.outcome_window_end
          )
    ) THEN
        RAISE EXCEPTION
            'ad experiment unit identity, snapshot, or time contract mismatch: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        (
            SELECT
                binding.segment_id,
                binding.final_snapshot_id,
                member.user_id
            FROM promotion_run_target_bindings AS binding
            JOIN segment_audience_members AS member
              ON member.snapshot_id = binding.final_snapshot_id
            WHERE binding.promotion_run_id = execution_row.promotion_run_id
            EXCEPT
            SELECT
                unit.segment_id,
                unit.audience_snapshot_id,
                unit.user_id
            FROM ad_experiment_units AS unit
            WHERE unit.segment_assignment_execution_id =
                p_segment_assignment_execution_id
        )
    ) OR EXISTS (
        (
            SELECT
                unit.segment_id,
                unit.audience_snapshot_id,
                unit.user_id
            FROM ad_experiment_units AS unit
            WHERE unit.segment_assignment_execution_id =
                p_segment_assignment_execution_id
            EXCEPT
            SELECT
                binding.segment_id,
                binding.final_snapshot_id,
                member.user_id
            FROM promotion_run_target_bindings AS binding
            JOIN segment_audience_members AS member
              ON member.snapshot_id = binding.final_snapshot_id
            WHERE binding.promotion_run_id = execution_row.promotion_run_id
        )
    ) THEN
        RAISE EXCEPTION 'experiment units must equal the final audience: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        (
            SELECT
                unit.user_id,
                unit.segment_id,
                unit.ad_experiment_id,
                unit.assigned_at
            FROM ad_experiment_units AS unit
            WHERE unit.segment_assignment_execution_id =
                    p_segment_assignment_execution_id
              AND unit.arm = 'treatment'
            EXCEPT
            SELECT
                assignment.user_id,
                assignment.segment_id,
                assignment.ad_experiment_id,
                assignment.assigned_at
            FROM user_segment_assignments AS assignment
            WHERE assignment.segment_assignment_execution_id =
                p_segment_assignment_execution_id
        )
    ) OR EXISTS (
        (
            SELECT
                assignment.user_id,
                assignment.segment_id,
                assignment.ad_experiment_id,
                assignment.assigned_at
            FROM user_segment_assignments AS assignment
            WHERE assignment.segment_assignment_execution_id =
                p_segment_assignment_execution_id
            EXCEPT
            SELECT
                unit.user_id,
                unit.segment_id,
                unit.ad_experiment_id,
                unit.assigned_at
            FROM ad_experiment_units AS unit
            WHERE unit.segment_assignment_execution_id =
                    p_segment_assignment_execution_id
              AND unit.arm = 'treatment'
        )
    ) THEN
        RAISE EXCEPTION 'treatment units and serving assignments differ: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        WITH manifest_results AS (
            SELECT *
            FROM jsonb_to_recordset(
                execution_row.input_manifest_json->'allocation_results'
            ) AS result(
                ad_experiment_id TEXT,
                segment_id TEXT,
                audience_snapshot_id TEXT,
                unit_count INTEGER,
                treatment_count INTEGER,
                control_count INTEGER,
                actual_treatment_ratio NUMERIC
            )
        )
        SELECT 1
        FROM manifest_results
        WHERE ad_experiment_id IS NULL
           OR segment_id IS NULL
           OR audience_snapshot_id IS NULL
           OR unit_count IS NULL
           OR treatment_count IS NULL
           OR control_count IS NULL
           OR actual_treatment_ratio IS NULL
           OR unit_count < 0
           OR treatment_count < 0
           OR control_count < 0
           OR treatment_count + control_count <> unit_count
           OR actual_treatment_ratio < 0
           OR actual_treatment_ratio > 1
    ) OR EXISTS (
        WITH manifest_results AS (
            SELECT *
            FROM jsonb_to_recordset(
                execution_row.input_manifest_json->'allocation_results'
            ) AS result(ad_experiment_id TEXT)
        )
        SELECT 1
        FROM manifest_results
        GROUP BY ad_experiment_id
        HAVING count(*) <> 1
    ) THEN
        RAISE EXCEPTION 'assignment allocation manifest is invalid: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        WITH manifest_results AS (
            SELECT *
            FROM jsonb_to_recordset(
                execution_row.input_manifest_json->'allocation_results'
            ) AS result(
                ad_experiment_id TEXT,
                segment_id TEXT,
                audience_snapshot_id TEXT,
                unit_count INTEGER,
                treatment_count INTEGER,
                control_count INTEGER,
                actual_treatment_ratio NUMERIC
            )
        ), actual_results AS (
            SELECT
                unit.ad_experiment_id,
                unit.segment_id,
                unit.audience_snapshot_id,
                count(*)::INTEGER AS unit_count,
                count(*) FILTER (WHERE unit.arm = 'treatment')::INTEGER
                    AS treatment_count,
                count(*) FILTER (WHERE unit.arm = 'control')::INTEGER
                    AS control_count
            FROM ad_experiment_units AS unit
            WHERE unit.segment_assignment_execution_id =
                p_segment_assignment_execution_id
            GROUP BY
                unit.ad_experiment_id,
                unit.segment_id,
                unit.audience_snapshot_id
        )
        SELECT 1
        FROM manifest_results AS manifest
        LEFT JOIN actual_results AS actual
          ON actual.ad_experiment_id = manifest.ad_experiment_id
         AND actual.segment_id = manifest.segment_id
         AND actual.audience_snapshot_id = manifest.audience_snapshot_id
        WHERE manifest.unit_count <> COALESCE(actual.unit_count, 0)
           OR manifest.treatment_count <>
                COALESCE(actual.treatment_count, 0)
           OR manifest.control_count <> COALESCE(actual.control_count, 0)
           OR round(manifest.actual_treatment_ratio, 9) <>
                CASE
                    WHEN manifest.unit_count = 0 THEN 0::NUMERIC
                    ELSE round(
                        manifest.treatment_count::NUMERIC /
                        manifest.unit_count::NUMERIC,
                        9
                    )
                END
    ) OR EXISTS (
        WITH manifest_results AS (
            SELECT *
            FROM jsonb_to_recordset(
                execution_row.input_manifest_json->'allocation_results'
            ) AS result(
                ad_experiment_id TEXT,
                segment_id TEXT,
                audience_snapshot_id TEXT
            )
        )
        SELECT 1
        FROM ad_experiment_units AS unit
        LEFT JOIN manifest_results AS manifest
          ON manifest.ad_experiment_id = unit.ad_experiment_id
         AND manifest.segment_id = unit.segment_id
         AND manifest.audience_snapshot_id = unit.audience_snapshot_id
        WHERE unit.segment_assignment_execution_id =
                p_segment_assignment_execution_id
          AND manifest.ad_experiment_id IS NULL
    ) THEN
        RAISE EXCEPTION 'manifest quota differs from experiment units: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        WITH manifest_results AS (
            SELECT *
            FROM jsonb_to_recordset(
                execution_row.input_manifest_json->'allocation_results'
            ) AS result(
                ad_experiment_id TEXT,
                segment_id TEXT,
                audience_snapshot_id TEXT,
                actual_treatment_ratio NUMERIC
            )
        )
        SELECT 1
        FROM ad_experiment_units AS unit
        JOIN manifest_results AS manifest
          ON manifest.ad_experiment_id = unit.ad_experiment_id
         AND manifest.segment_id = unit.segment_id
         AND manifest.audience_snapshot_id = unit.audience_snapshot_id
        WHERE unit.segment_assignment_execution_id =
                p_segment_assignment_execution_id
          AND unit.treatment_probability <>
                round(manifest.actual_treatment_ratio, 9)
    ) THEN
        RAISE EXCEPTION 'unit treatment probability differs from quota: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        WITH manifest_results AS (
            SELECT *
            FROM jsonb_to_recordset(
                execution_row.input_manifest_json->'allocation_results'
            ) AS result(
                ad_experiment_id TEXT,
                segment_id TEXT,
                audience_snapshot_id TEXT,
                unit_count INTEGER
            )
        ), manifest_bindings AS (
            SELECT *
            FROM jsonb_to_recordset(
                execution_row.input_manifest_json->'audience_bindings'
            ) AS binding(
                ad_experiment_id TEXT,
                segment_id TEXT,
                audience_snapshot_id TEXT,
                vector_generation_id TEXT,
                member_count INTEGER
            )
        )
        SELECT 1
        FROM manifest_results AS result
        LEFT JOIN manifest_bindings AS binding
          ON binding.ad_experiment_id = result.ad_experiment_id
         AND binding.segment_id = result.segment_id
         AND binding.audience_snapshot_id = result.audience_snapshot_id
        WHERE binding.ad_experiment_id IS NULL
           OR binding.vector_generation_id IS NULL
           OR binding.member_count IS DISTINCT FROM result.unit_count
    ) OR EXISTS (
        WITH manifest_bindings AS (
            SELECT *
            FROM jsonb_to_recordset(
                execution_row.input_manifest_json->'audience_bindings'
            ) AS binding(
                ad_experiment_id TEXT,
                segment_id TEXT,
                audience_snapshot_id TEXT,
                vector_generation_id TEXT
            )
        )
        SELECT 1
        FROM ad_experiment_units AS unit
        JOIN manifest_bindings AS binding
          ON binding.ad_experiment_id = unit.ad_experiment_id
         AND binding.segment_id = unit.segment_id
         AND binding.audience_snapshot_id = unit.audience_snapshot_id
        WHERE unit.segment_assignment_execution_id =
                p_segment_assignment_execution_id
          AND binding.vector_generation_id <> unit.vector_generation_id
    ) THEN
        RAISE EXCEPTION 'manifest audience binding differs from units: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION finalize_uplift_assignment_execution(
    p_segment_assignment_execution_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    current_status TEXT;
BEGIN
    SELECT uplift_assignment_status
    INTO current_status
    FROM segment_assignment_executions
    WHERE segment_assignment_execution_id =
        p_segment_assignment_execution_id
      AND input_manifest_json->>'schema_version' =
        'segment-assignment-execution.v2'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'uplift-ready assignment execution does not exist: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    IF current_status = 'finalized' THEN
        RETURN;
    END IF;

    IF current_status IS DISTINCT FROM 'preparing' THEN
        RAISE EXCEPTION 'uplift-ready assignment execution is not preparing: %',
            p_segment_assignment_execution_id
            USING ERRCODE = '23514';
    END IF;

    PERFORM assert_uplift_assignment_execution(
        p_segment_assignment_execution_id
    );

    UPDATE segment_assignment_executions
    SET uplift_assignment_status = 'finalized',
        uplift_finalized_at = clock_timestamp()
    WHERE segment_assignment_execution_id =
        p_segment_assignment_execution_id;
END
$$;

CREATE OR REPLACE FUNCTION prevent_ad_experiment_unit_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF EXISTS (
            SELECT 1
            FROM segment_assignment_executions
            WHERE segment_assignment_execution_id =
                    NEW.segment_assignment_execution_id
              AND input_manifest_json->>'schema_version' =
                    'segment-assignment-execution.v2'
              AND uplift_assignment_status = 'finalized'
        ) THEN
            RAISE EXCEPTION 'finalized ad experiment units are immutable'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'ad experiment units are immutable'
        USING ERRCODE = '23514';
END
$$;

DROP TRIGGER IF EXISTS trg_validate_ad_experiment_unit
ON ad_experiment_units;

DROP TRIGGER IF EXISTS trg_ad_experiment_unit_immutable
ON ad_experiment_units;

CREATE TRIGGER trg_ad_experiment_unit_immutable
BEFORE INSERT OR UPDATE OR DELETE
ON ad_experiment_units
FOR EACH ROW EXECUTE FUNCTION prevent_ad_experiment_unit_mutation();

CREATE OR REPLACE FUNCTION prevent_finalized_uplift_execution_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.input_manifest_json->>'schema_version' =
            'segment-assignment-execution.v2'
       AND OLD.uplift_assignment_status = 'finalized'
    THEN
        RAISE EXCEPTION 'finalized uplift assignment execution is immutable'
            USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_finalized_uplift_execution_immutable
ON segment_assignment_executions;

CREATE TRIGGER trg_finalized_uplift_execution_immutable
BEFORE UPDATE OR DELETE
ON segment_assignment_executions
FOR EACH ROW
EXECUTE FUNCTION prevent_finalized_uplift_execution_mutation();

CREATE OR REPLACE FUNCTION prevent_finalized_uplift_serving_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    old_execution_id VARCHAR(100);
    new_execution_id VARCHAR(100);
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        old_execution_id := OLD.segment_assignment_execution_id;
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        new_execution_id := NEW.segment_assignment_execution_id;
    END IF;

    IF (old_execution_id IS NOT NULL OR new_execution_id IS NOT NULL)
       AND EXISTS (
            SELECT 1
            FROM segment_assignment_executions
            WHERE segment_assignment_execution_id IN (
                    old_execution_id,
                    new_execution_id
                  )
              AND input_manifest_json->>'schema_version' =
                  'segment-assignment-execution.v2'
              AND uplift_assignment_status = 'finalized'
       )
    THEN
        RAISE EXCEPTION 'finalized uplift serving assignments are immutable'
            USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_validate_uplift_ready_serving_assignment
ON user_segment_assignments;

DROP TRIGGER IF EXISTS trg_finalized_uplift_serving_immutable
ON user_segment_assignments;

CREATE TRIGGER trg_finalized_uplift_serving_immutable
BEFORE INSERT OR UPDATE OR DELETE
ON user_segment_assignments
FOR EACH ROW
EXECUTE FUNCTION prevent_finalized_uplift_serving_mutation();

COMMIT;
