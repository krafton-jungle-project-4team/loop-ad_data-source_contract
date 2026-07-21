BEGIN;

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

CREATE OR REPLACE FUNCTION assert_uplift_ready_assignment_population(
    p_promotion_run_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM segment_assignment_executions
        WHERE promotion_run_id = p_promotion_run_id
          AND input_manifest_json->>'schema_version' =
              'segment-assignment-execution.v2'
    ) THEN
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_run_target_bindings AS binding
        JOIN segment_audience_members AS member
          ON member.snapshot_id = binding.final_snapshot_id
        LEFT JOIN ad_experiment_units AS unit
          ON unit.promotion_run_id = binding.promotion_run_id
         AND unit.segment_id = binding.segment_id
         AND unit.audience_snapshot_id = binding.final_snapshot_id
         AND unit.user_id = member.user_id
        WHERE binding.promotion_run_id = p_promotion_run_id
          AND unit.experiment_unit_id IS NULL
    ) OR EXISTS (
        SELECT 1
        FROM ad_experiment_units AS unit
        LEFT JOIN promotion_run_target_bindings AS binding
          ON binding.promotion_run_id = unit.promotion_run_id
         AND binding.segment_id = unit.segment_id
         AND binding.final_snapshot_id = unit.audience_snapshot_id
        LEFT JOIN segment_audience_members AS member
          ON member.snapshot_id = unit.audience_snapshot_id
         AND member.user_id = unit.user_id
        WHERE unit.promotion_run_id = p_promotion_run_id
          AND (
              binding.promotion_run_id IS NULL
              OR member.user_id IS NULL
          )
    ) THEN
        RAISE EXCEPTION
            'experiment units must equal the final audience: %',
            p_promotion_run_id
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM ad_experiment_units AS unit
        LEFT JOIN user_segment_assignments AS assignment
          ON assignment.promotion_run_id = unit.promotion_run_id
         AND assignment.user_id = unit.user_id
        WHERE unit.promotion_run_id = p_promotion_run_id
          AND (
              (
                  unit.arm = 'control'
                  AND assignment.id IS NOT NULL
              )
              OR (
                  unit.arm = 'treatment'
                  AND (
                      assignment.id IS NULL
                      OR assignment.segment_id <> unit.segment_id
                      OR assignment.ad_experiment_id <>
                          unit.ad_experiment_id
                      OR assignment.segment_assignment_execution_id
                          IS DISTINCT FROM
                          unit.segment_assignment_execution_id
                      OR assignment.assigned_at <> unit.assigned_at
                  )
              )
          )
    ) OR EXISTS (
        SELECT 1
        FROM user_segment_assignments AS assignment
        JOIN segment_assignment_executions AS execution
          ON execution.promotion_run_id = assignment.promotion_run_id
         AND execution.segment_assignment_execution_id =
             assignment.segment_assignment_execution_id
        LEFT JOIN ad_experiment_units AS unit
          ON unit.promotion_run_id = assignment.promotion_run_id
         AND unit.user_id = assignment.user_id
         AND unit.arm = 'treatment'
        WHERE assignment.promotion_run_id = p_promotion_run_id
          AND execution.input_manifest_json->>'schema_version' =
              'segment-assignment-execution.v2'
          AND (
              unit.experiment_unit_id IS NULL
              OR unit.segment_id <> assignment.segment_id
              OR unit.ad_experiment_id <> assignment.ad_experiment_id
              OR unit.segment_assignment_execution_id <>
                  assignment.segment_assignment_execution_id
              OR unit.assigned_at <> assignment.assigned_at
          )
    ) THEN
        RAISE EXCEPTION
            'treatment units and serving assignments differ: %',
            p_promotion_run_id
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION validate_promotion_run_experiment_design_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM assert_promotion_run_experiment_design(OLD.promotion_run_id);
        PERFORM assert_uplift_ready_assignment_population(OLD.promotion_run_id);
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE')
       AND (
            TG_OP = 'INSERT'
            OR NEW.promotion_run_id IS DISTINCT FROM OLD.promotion_run_id
            OR NEW.input_manifest_json IS DISTINCT FROM OLD.input_manifest_json
       )
    THEN
        PERFORM assert_promotion_run_experiment_design(NEW.promotion_run_id);
        PERFORM assert_uplift_ready_assignment_population(NEW.promotion_run_id);
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

CREATE OR REPLACE FUNCTION assert_ad_experiment_unit(
    p_experiment_unit_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
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
        WHERE unit.experiment_unit_id = p_experiment_unit_id
          AND unit.project_id = run.project_id
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
    ) THEN
        IF EXISTS (
            SELECT 1
            FROM ad_experiment_units
            WHERE experiment_unit_id = p_experiment_unit_id
        ) THEN
            RAISE EXCEPTION
                'ad experiment unit identity, snapshot, or time contract mismatch: %',
                p_experiment_unit_id
                USING ERRCODE = '23514';
        END IF;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION validate_ad_experiment_unit_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM assert_ad_experiment_unit(OLD.experiment_unit_id);
        PERFORM assert_uplift_ready_assignment_population(
            OLD.promotion_run_id
        );
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM assert_ad_experiment_unit(NEW.experiment_unit_id);
        PERFORM assert_uplift_ready_assignment_population(
            NEW.promotion_run_id
        );
    END IF;

    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS trg_validate_ad_experiment_unit
ON ad_experiment_units;

CREATE CONSTRAINT TRIGGER trg_validate_ad_experiment_unit
AFTER INSERT OR UPDATE OR DELETE
ON ad_experiment_units
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_ad_experiment_unit_trigger();

CREATE OR REPLACE FUNCTION validate_uplift_ready_serving_assignment_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM assert_uplift_ready_assignment_population(
            OLD.promotion_run_id
        );
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM assert_uplift_ready_assignment_population(
            NEW.promotion_run_id
        );
    END IF;

    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS trg_validate_uplift_ready_serving_assignment
ON user_segment_assignments;

CREATE CONSTRAINT TRIGGER trg_validate_uplift_ready_serving_assignment
AFTER INSERT OR UPDATE OR DELETE
ON user_segment_assignments
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION validate_uplift_ready_serving_assignment_trigger();

COMMIT;
