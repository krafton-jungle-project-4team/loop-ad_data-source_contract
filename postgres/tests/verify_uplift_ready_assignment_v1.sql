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

CREATE OR REPLACE FUNCTION pg_temp.expect_deferred_failure(
    p_statement TEXT,
    p_constraint_name TEXT,
    p_expected_sqlstate TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    actual_sqlstate TEXT;
BEGIN
    BEGIN
        EXECUTE p_statement;
        EXECUTE format('SET CONSTRAINTS %I IMMEDIATE', p_constraint_name);
    EXCEPTION WHEN OTHERS THEN
        actual_sqlstate := SQLSTATE;
        EXECUTE format('SET CONSTRAINTS %I DEFERRED', p_constraint_name);
        IF actual_sqlstate <> p_expected_sqlstate THEN
            RAISE EXCEPTION
                'expected deferred SQLSTATE %, received % for: %',
                p_expected_sqlstate,
                actual_sqlstate,
                p_statement;
        END IF;
        RETURN;
    END;

    EXECUTE format('SET CONSTRAINTS %I DEFERRED', p_constraint_name);
    RAISE EXCEPTION 'statement unexpectedly passed deferred validation: %',
        p_statement;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.create_uplift_snapshot(
    p_snapshot_id VARCHAR(100),
    p_snapshot_kind VARCHAR(50),
    p_source_snapshot_id VARCHAR(100) DEFAULT NULL,
    p_allocation_plan_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO segment_audience_snapshots (
        snapshot_id,
        analysis_id,
        project_id,
        campaign_id,
        promotion_id,
        segment_id,
        segment_vector_id,
        vector_generation_id,
        schema_version,
        vector_version,
        manifest_hash,
        audience_resolution_contract,
        segment_audience_spec_hash,
        query_vector_hash,
        query_compiler_version,
        query_compiler_hash,
        matcher_version,
        search_policy_version,
        calibration_version,
        calibration_hash,
        score_threshold,
        source_cutoff,
        window_start,
        window_end,
        eligible_user_count,
        behavior_match_count,
        final_user_count,
        min_sample_size,
        audience_status,
        selection_method,
        estimated_recall,
        recall_lower_bound,
        recall_target,
        input_fingerprint,
        meets_min_sample_size,
        status,
        metadata_json,
        snapshot_kind,
        source_snapshot_id,
        allocation_plan_id
    ) VALUES (
        p_snapshot_id,
        'analysis_onsite_a2',
        'demo_project',
        'camp_expedia_hotel_demo',
        'promo_expedia_onsite_last_minute',
        'seg_near_checkin',
        'uplift_vector_near',
        'uplift_vector_generation',
        'segment_audience.v1',
        'hotel_behavior.v2',
        repeat('1', 64),
        'segment_audience.v1',
        encode(digest(convert_to(p_snapshot_id || ':spec', 'UTF8'), 'sha256'), 'hex'),
        encode(digest(convert_to(p_snapshot_id || ':query', 'UTF8'), 'sha256'), 'hex'),
        'segment_behavior_query.v2',
        encode(digest(convert_to(p_snapshot_id || ':compiler', 'UTF8'), 'sha256'), 'hex'),
        'exact_cosine_rerank.v2',
        'audience_search.v2',
        'calibration.v1',
        encode(digest(convert_to(p_snapshot_id || ':calibration', 'UTF8'), 'sha256'), 'hex'),
        0.500000,
        '2026-07-10 00:00:00+00',
        '2026-06-10 00:00:00+00',
        '2026-07-10 00:00:00+00',
        2,
        2,
        2,
        1,
        'targetable',
        'exact',
        1.000000,
        1.000000,
        0.950000,
        encode(digest(convert_to(p_snapshot_id || ':input', 'UTF8'), 'sha256'), 'hex'),
        true,
        'completed',
        '{"fixture":"uplift-ready-assignment.v1"}'::jsonb,
        p_snapshot_kind,
        p_source_snapshot_id,
        p_allocation_plan_id
    );
END
$$;

DO $$
DECLARE
    unit_validator TEXT;
BEGIN
    IF to_regclass('ad_experiment_units') IS NULL THEN
        RAISE EXCEPTION 'ad_experiment_units is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'ad_experiment_units'::regclass
          AND conname = 'uq_ad_experiment_units_run_user'
    ) OR NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'ad_experiment_units'::regclass
          AND conname = 'fk_ad_experiment_units_snapshot_member'
    ) OR NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'ad_experiment_units'::regclass
          AND conname = 'fk_ad_experiment_units_execution'
    ) THEN
        RAISE EXCEPTION 'ad experiment unit key contract differs';
    END IF;

    SELECT pg_get_functiondef(
        'assert_ad_experiment_unit(character varying)'::regprocedure
    ) INTO unit_validator;

    IF position('generation.window_end <= unit.assigned_at' IN unit_validator) = 0
       OR position(
            'generation.source_revision_cutoff <= unit.assigned_at'
            IN unit_validator
       ) = 0
       OR position('snapshot.source_cutoff <= unit.assigned_at' IN unit_validator) = 0
       OR position('execution.source_cutoff_at <= unit.assigned_at' IN unit_validator) = 0
       OR position('generation.source_cutoff_at' IN unit_validator) <> 0
    THEN
        RAISE EXCEPTION 'uplift unit time contract differs';
    END IF;
END
$$;

INSERT INTO user_behavior_vector_search_generations (
    vector_generation_id,
    project_id,
    vector_version,
    manifest_hash,
    window_start,
    window_end,
    source_revision_cutoff,
    expected_user_count,
    synced_user_count,
    invalid_user_count,
    status,
    is_active,
    activated_at
) VALUES (
    'uplift_vector_generation',
    'demo_project',
    'hotel_behavior.v2',
    repeat('2', 64),
    '2026-06-10 00:00:00+00',
    '2026-07-10 00:00:00+00',
    '2026-07-10 00:00:00+00',
    2,
    2,
    0,
    'activated',
    false,
    '2026-07-10 00:01:00+00'
);

INSERT INTO segment_vectors (
    segment_vector_id,
    project_id,
    segment_id,
    promotion_id,
    analysis_id,
    vector_dim,
    vector_values,
    embedding,
    vector_version,
    source
) VALUES (
    'uplift_vector_near',
    'demo_project',
    'seg_near_checkin',
    'promo_expedia_onsite_last_minute',
    'analysis_onsite_a2',
    64,
    to_jsonb(array_fill(0.0::REAL, ARRAY[64])),
    array_fill(0.0::REAL, ARRAY[64])::vector,
    'hotel_behavior.v2',
    'behavior_query'
);

SELECT pg_temp.create_uplift_snapshot(
    'uplift_source_snapshot',
    'source'
);

INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    behavior_fit_score,
    retrieval_source,
    retrieval_rank
) VALUES
    ('uplift_source_snapshot', 'uplift_treatment_user', 0.95, 'exact', 1),
    ('uplift_source_snapshot', 'uplift_control_user', 0.90, 'exact', 2);

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_onsite_last_minute'
);

INSERT INTO segment_audience_allocation_plans (
    allocation_plan_id,
    promotion_id,
    candidate_batch_analysis_id,
    target_analysis_id,
    selection_fingerprint,
    selected_segment_ids_json,
    exclusion_revision,
    allocation_policy_version,
    allocation_policy_hash
) VALUES (
    '55555555-5555-4555-8555-555555555555',
    'promo_expedia_onsite_last_minute',
    'analysis_onsite_a2',
    'analysis_onsite_a2',
    repeat('3', 64),
    '["seg_near_checkin"]'::jsonb,
    (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_onsite_last_minute'
    ),
    'lean-allocation.v1',
    repeat('4', 64)
);

SELECT pg_temp.create_uplift_snapshot(
    'uplift_final_snapshot',
    'final',
    'uplift_source_snapshot',
    '55555555-5555-4555-8555-555555555555'
);

INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    behavior_fit_score,
    retrieval_source,
    retrieval_rank
) VALUES
    ('uplift_final_snapshot', 'uplift_treatment_user', 0.95, 'exact', 1),
    ('uplift_final_snapshot', 'uplift_control_user', 0.90, 'exact', 2);

UPDATE promotion_target_segments
SET segment_vector_id = 'uplift_vector_near',
    audience_snapshot_id = 'uplift_final_snapshot',
    allocation_plan_id = '55555555-5555-4555-8555-555555555555',
    audience_reservation_state = 'reserved'
WHERE analysis_id = 'analysis_onsite_a2'
  AND segment_id = 'seg_near_checkin';

INSERT INTO promotion_audience_exclusion_members (
    project_id,
    promotion_id,
    user_id,
    target_analysis_id,
    segment_id,
    allocation_plan_id,
    final_snapshot_id,
    state,
    revision,
    reserved_at
) VALUES
(
    'demo_project',
    'promo_expedia_onsite_last_minute',
    'uplift_treatment_user',
    'analysis_onsite_a2',
    'seg_near_checkin',
    '55555555-5555-4555-8555-555555555555',
    'uplift_final_snapshot',
    'reserved',
    (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_onsite_last_minute'
    ),
    now()
),
(
    'demo_project',
    'promo_expedia_onsite_last_minute',
    'uplift_control_user',
    'analysis_onsite_a2',
    'seg_near_checkin',
    '55555555-5555-4555-8555-555555555555',
    'uplift_final_snapshot',
    'reserved',
    (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_onsite_last_minute'
    ),
    now()
);

INSERT INTO promotion_runs (
    promotion_run_id,
    project_id,
    campaign_id,
    promotion_id,
    analysis_id,
    generation_id,
    loop_count,
    status,
    goal_snapshot_json,
    segment_scope_json,
    segment_scope_fingerprint
) VALUES (
    'uplift_run_v1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_onsite_last_minute',
    'analysis_onsite_a2',
    'generation_onsite_a2',
    99,
    'planned',
    jsonb_build_object(
        'goal_metric', 'booking_conversion_rate',
        'target', 0.08,
        'outcome_spec', jsonb_build_object(
            'outcome_metric', 'booking_conversion_rate',
            'outcome_event_name', 'booking_complete',
            'outcome_filter', jsonb_build_object(
                'destination_ids', jsonb_build_array('jeju', 'okinawa')
            ),
            'outcome_definition_version', 'booking-outcome.v1',
            'uplift_training_eligible', true
        ),
        'outcome_spec_hash', repeat('5', 64)
    ),
    '["seg_near_checkin"]'::jsonb,
    encode(
        digest(convert_to('["seg_near_checkin"]', 'UTF8'), 'sha256'),
        'hex'
    )
);

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_onsite_last_minute'
);

UPDATE segment_audience_allocation_plans
SET status = 'locked',
    locked_at = now()
WHERE allocation_plan_id = '55555555-5555-4555-8555-555555555555';

UPDATE promotion_target_segments
SET audience_reservation_state = 'consumed'
WHERE analysis_id = 'analysis_onsite_a2'
  AND segment_id = 'seg_near_checkin';

UPDATE promotion_audience_exclusion_members
SET state = 'consumed',
    revision = (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_onsite_last_minute'
    ),
    consumed_at = now()
WHERE allocation_plan_id = '55555555-5555-4555-8555-555555555555';

INSERT INTO promotion_run_target_bindings (
    promotion_run_id,
    target_analysis_id,
    segment_id,
    allocation_plan_id,
    final_snapshot_id
) VALUES (
    'uplift_run_v1',
    'analysis_onsite_a2',
    'seg_near_checkin',
    '55555555-5555-4555-8555-555555555555',
    'uplift_final_snapshot'
);

INSERT INTO ad_experiments (
    ad_experiment_id,
    project_id,
    campaign_id,
    promotion_id,
    promotion_run_id,
    analysis_id,
    generation_id,
    segment_id,
    segment_name,
    content_id,
    content_option_id,
    channel,
    loop_count,
    status,
    goal_metric,
    goal_target_value,
    goal_basis
) VALUES (
    'uplift_ad_experiment_v1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_onsite_last_minute',
    'uplift_run_v1',
    'analysis_onsite_a2',
    'generation_onsite_a2',
    'seg_near_checkin',
    'Near check-in users',
    'content_onsite_a2_near',
    'onsite_a2_option_1',
    'onsite_banner',
    99,
    'planned',
    'booking_conversion_rate',
    0.08,
    'all_segments'
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
) VALUES (
    'uplift_assignment_execution_v1',
    'uplift_run_v1',
    repeat('6', 64),
    repeat('7', 64),
    'audience_snapshot',
    'assignment-v2',
    'hotel_behavior.v2',
    '2026-07-10 00:00:00+00',
    jsonb_build_object(
        'schema_version', 'segment-assignment-execution.v2',
        'experiment_design', jsonb_build_object(
            'mode', 'randomized_holdout',
            'requested_treatment_ratio', 0.5,
            'outcome_window_days', 30,
            'randomization_version', 'holdout.v1',
            'quota_policy_version', 'complete-randomization.v1',
            'randomization_salt_fingerprint', repeat('8', 64),
            'outcome_spec_hash', repeat('5', 64)
        ),
        'experiment_design_fingerprint', repeat('9', 64),
        'outcome_spec', (
            SELECT goal_snapshot_json->'outcome_spec'
            FROM promotion_runs
            WHERE promotion_run_id = 'uplift_run_v1'
        ),
        'audience_bindings', jsonb_build_array(
            jsonb_build_object(
                'segment_id', 'seg_near_checkin',
                'audience_snapshot_id', 'uplift_final_snapshot',
                'vector_generation_id', 'uplift_vector_generation'
            )
        ),
        'allocation_results', jsonb_build_array(
            jsonb_build_object(
                'ad_experiment_id', 'uplift_ad_experiment_v1',
                'unit_count', 2,
                'treatment_count', 1,
                'control_count', 1,
                'requested_treatment_ratio', 0.5,
                'actual_treatment_ratio', 0.5,
                'quota_policy_version', 'complete-randomization.v1'
            )
        )
    )
);

INSERT INTO ad_experiment_units (
    experiment_unit_id,
    project_id,
    promotion_run_id,
    ad_experiment_id,
    segment_id,
    audience_snapshot_id,
    vector_generation_id,
    segment_assignment_execution_id,
    user_id,
    arm,
    treatment_probability,
    assigned_at,
    outcome_window_start,
    outcome_window_end
) VALUES
(
    'uplift_unit_treatment',
    'demo_project',
    'uplift_run_v1',
    'uplift_ad_experiment_v1',
    'seg_near_checkin',
    'uplift_final_snapshot',
    'uplift_vector_generation',
    'uplift_assignment_execution_v1',
    'uplift_treatment_user',
    'treatment',
    0.5,
    '2026-07-15 00:00:00+00',
    '2026-07-15 00:00:00+00',
    '2026-08-14 00:00:00+00'
),
(
    'uplift_unit_control',
    'demo_project',
    'uplift_run_v1',
    'uplift_ad_experiment_v1',
    'seg_near_checkin',
    'uplift_final_snapshot',
    'uplift_vector_generation',
    'uplift_assignment_execution_v1',
    'uplift_control_user',
    'control',
    0.5,
    '2026-07-15 00:00:00+00',
    '2026-07-15 00:00:00+00',
    '2026-08-14 00:00:00+00'
);

INSERT INTO user_segment_assignments (
    project_id,
    promotion_run_id,
    user_id,
    segment_id,
    ad_experiment_id,
    content_id,
    content_option_id,
    fallback,
    assignment_source,
    assigned_at,
    expires_at,
    segment_assignment_execution_id
) VALUES (
    'demo_project',
    'uplift_run_v1',
    'uplift_treatment_user',
    'seg_near_checkin',
    'uplift_ad_experiment_v1',
    'content_onsite_a2_near',
    'onsite_a2_option_1',
    false,
    'analysis_snapshot',
    '2026-07-15 00:00:00+00',
    '2026-08-14 00:00:00+00',
    'uplift_assignment_execution_v1'
);

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    IF (SELECT count(*) FROM ad_experiment_units
        WHERE promotion_run_id = 'uplift_run_v1') <> 2
       OR (SELECT count(*) FROM ad_experiment_units
           WHERE promotion_run_id = 'uplift_run_v1'
             AND arm = 'treatment') <> 1
       OR (SELECT count(*) FROM ad_experiment_units
           WHERE promotion_run_id = 'uplift_run_v1'
             AND arm = 'control') <> 1
       OR (SELECT count(*) FROM user_segment_assignments
           WHERE promotion_run_id = 'uplift_run_v1') <> 1
    THEN
        RAISE EXCEPTION 'holdout population or serving subset differs';
    END IF;
END
$$;

UPDATE promotion_runs
SET status = 'approved'
WHERE promotion_run_id = 'uplift_run_v1';

SELECT pg_temp.expect_failure(
    $sql$UPDATE promotion_runs
         SET goal_snapshot_json = jsonb_set(
             goal_snapshot_json,
             '{outcome_spec,outcome_filter,destination_ids}',
             '["seoul"]'::jsonb
         )
         WHERE promotion_run_id = 'uplift_run_v1'$sql$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $sql$UPDATE promotion_runs
         SET goal_snapshot_json = jsonb_set(
             goal_snapshot_json,
             '{outcome_spec_hash}',
             to_jsonb(repeat('a', 64))
         )
         WHERE promotion_run_id = 'uplift_run_v1'$sql$,
    '23514'
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
SELECT
    'uplift_assignment_execution_same_design',
    promotion_run_id,
    repeat('a', 64),
    repeat('b', 64),
    matcher_strategy,
    matcher_version,
    vector_version,
    source_cutoff_at,
    input_manifest_json
FROM segment_assignment_executions
WHERE segment_assignment_execution_id = 'uplift_assignment_execution_v1';

SET CONSTRAINTS trg_validate_promotion_run_experiment_design IMMEDIATE;
SET CONSTRAINTS trg_validate_promotion_run_experiment_design DEFERRED;

SELECT pg_temp.expect_deferred_failure(
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
    )
    SELECT
        'uplift_assignment_execution_conflict',
        promotion_run_id,
        repeat('c', 64),
        repeat('d', 64),
        matcher_strategy,
        matcher_version,
        vector_version,
        source_cutoff_at,
        jsonb_set(
            jsonb_set(
                input_manifest_json,
                '{experiment_design,requested_treatment_ratio}',
                '0.6'::jsonb
            ),
            '{experiment_design_fingerprint}',
            to_jsonb(repeat('e', 64))
        )
    FROM segment_assignment_executions
    WHERE segment_assignment_execution_id =
        'uplift_assignment_execution_v1'$sql$,
    'trg_validate_promotion_run_experiment_design',
    '23514'
);

SELECT pg_temp.expect_deferred_failure(
    $sql$UPDATE ad_experiment_units
         SET assigned_at = '2026-07-09 00:00:00+00',
             outcome_window_start = '2026-07-09 00:00:00+00'
         WHERE experiment_unit_id = 'uplift_unit_control'$sql$,
    'trg_validate_ad_experiment_unit',
    '23514'
);

SELECT pg_temp.expect_deferred_failure(
    $sql$INSERT INTO user_segment_assignments (
        project_id,
        promotion_run_id,
        user_id,
        segment_id,
        ad_experiment_id,
        content_id,
        content_option_id,
        fallback,
        assignment_source,
        assigned_at,
        expires_at,
        segment_assignment_execution_id
    ) VALUES (
        'demo_project',
        'uplift_run_v1',
        'uplift_control_user',
        'seg_near_checkin',
        'uplift_ad_experiment_v1',
        'content_onsite_a2_near',
        'onsite_a2_option_1',
        false,
        'analysis_snapshot',
        '2026-07-15 00:00:00+00',
        '2026-08-14 00:00:00+00',
        'uplift_assignment_execution_v1'
    )$sql$,
    'trg_validate_uplift_ready_serving_assignment',
    '23514'
);

SELECT pg_temp.expect_deferred_failure(
    $sql$UPDATE user_segment_assignments
         SET segment_assignment_execution_id = NULL
         WHERE promotion_run_id = 'uplift_run_v1'
           AND user_id = 'uplift_treatment_user'$sql$,
    'trg_validate_uplift_ready_serving_assignment',
    '23514'
);

SELECT pg_temp.expect_deferred_failure(
    $sql$DELETE FROM user_segment_assignments
         WHERE promotion_run_id = 'uplift_run_v1'
           AND user_id = 'uplift_treatment_user'$sql$,
    'trg_validate_uplift_ready_serving_assignment',
    '23514'
);

ROLLBACK;
