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
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        actual_sqlstate := SQLSTATE;
        SET CONSTRAINTS ALL DEFERRED;
        IF actual_sqlstate <> p_expected_sqlstate THEN
            RAISE EXCEPTION
                'expected deferred SQLSTATE %, received % for: %',
                p_expected_sqlstate,
                actual_sqlstate,
                p_statement;
        END IF;
        RETURN;
    END;

    SET CONSTRAINTS ALL DEFERRED;
    RAISE EXCEPTION 'statement unexpectedly passed deferred validation: %',
        p_statement;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.create_audience_snapshot(
    p_snapshot_id VARCHAR(100),
    p_analysis_id VARCHAR(100),
    p_segment_id VARCHAR(100),
    p_segment_vector_id VARCHAR(100),
    p_final_user_count INT,
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
        p_analysis_id,
        'demo_project',
        'camp_expedia_hotel_demo',
        'promo_expedia_sms_near_checkin',
        p_segment_id,
        p_segment_vector_id,
        'allocation_generation_test',
        'segment_audience.v1',
        'hotel_behavior.v2',
        repeat('a', 64),
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
        '2026-07-01 00:00:00+00',
        '2026-06-01 00:00:00+00',
        '2026-07-01 00:00:00+00',
        20,
        20,
        p_final_user_count,
        1,
        CASE WHEN p_final_user_count > 0
            THEN 'targetable'
            ELSE 'no_eligible_audience'
        END,
        'exact',
        1.000000,
        1.000000,
        0.950000,
        encode(digest(convert_to(p_snapshot_id || ':input', 'UTF8'), 'sha256'), 'hex'),
        p_final_user_count > 0,
        'completed',
        jsonb_build_object('fixture', 'lean_allocation_contract'),
        p_snapshot_kind,
        p_source_snapshot_id,
        p_allocation_plan_id
    );
END
$$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM promotion_target_segments
        WHERE allocation_plan_id IS NOT NULL
           OR audience_reservation_state IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'legacy target allocation fields changed';
    END IF;

    IF EXISTS (SELECT 1 FROM promotion_run_target_bindings) THEN
        RAISE EXCEPTION 'legacy runs unexpectedly gained target bindings';
    END IF;

    IF EXISTS (SELECT 1 FROM promotion_audience_exclusion_members)
       OR EXISTS (SELECT 1 FROM promotion_audience_exclusion_state) THEN
        RAISE EXCEPTION 'legacy rows unexpectedly gained exclusions';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_class
        WHERE relname IN (
            'segment_audience_allocation_plan_segments',
            'segment_audience_allocation_members',
            'segment_audience_allocation_previews',
            'segment_audience_allocation_preview_targets',
            'promotion_audience_exclusion_revisions',
            'promotion_audience_exclusion_events',
            'promotion_run_target_audience_bindings'
        )
          AND relkind IN ('r', 'p', 'v', 'm')
    ) THEN
        RAISE EXCEPTION 'an obsolete allocation draft relation still exists';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name IN (
              'segment_audience_snapshots',
              'promotion_target_segments'
          )
          AND column_name IN (
              'snapshot_role',
              'source_audience_snapshot_id',
              'allocation_policy_id',
              'allocation_policy_version',
              'allocation_policy_hash',
              'promotion_exclusion_revision',
              'promotion_exclusion_hash',
              'targetable'
          )
    ) THEN
        RAISE EXCEPTION 'an obsolete allocation draft column still exists';
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
    'allocation_generation_test',
    'demo_project',
    'hotel_behavior.v2',
    repeat('a', 64),
    '2026-06-01 00:00:00+00',
    '2026-07-01 00:00:00+00',
    '2026-07-01 00:00:00+00',
    20,
    20,
    0,
    'activated',
    true,
    now()
);

INSERT INTO campaigns (
    campaign_id,
    project_id,
    name,
    status
) VALUES (
    'allocation_scope_mismatch_campaign',
    'demo_project',
    'Allocation scope mismatch probe',
    'draft'
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
) VALUES
(
    'allocation_vector_near',
    'demo_project',
    'seg_near_checkin',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    64,
    to_jsonb(array_fill(0.0::REAL, ARRAY[64])),
    array_fill(0.0::REAL, ARRAY[64])::vector,
    'hotel_behavior.v2',
    'behavior_query'
),
(
    'allocation_vector_family',
    'demo_project',
    'seg_family_trip',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    64,
    to_jsonb(array_fill(0.0::REAL, ARRAY[64])),
    array_fill(0.0::REAL, ARRAY[64])::vector,
    'hotel_behavior.v2',
    'behavior_query'
);

SELECT pg_temp.create_audience_snapshot(
    'allocation_source_near',
    'analysis_sms_a1',
    'seg_near_checkin',
    'allocation_vector_near',
    2,
    'source'
);
SELECT pg_temp.create_audience_snapshot(
    'allocation_source_family',
    'analysis_sms_a1',
    'seg_family_trip',
    'allocation_vector_family',
    2,
    'source'
);

INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    behavior_fit_score,
    retrieval_source,
    retrieval_rank
) VALUES
('allocation_source_near', 'source_overlap_user', 0.95, 'exact', 1),
('allocation_source_near', 'source_near_user', 0.90, 'ann', 2),
('allocation_source_family', 'source_overlap_user', 0.93, 'exact', 1),
('allocation_source_family', 'source_family_user', 0.88, 'ann', 2);

-- Confirmation P1: two overlapping sources become two disjoint final sets.
SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_sms_near_checkin'
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
    '11111111-1111-4111-8111-111111111111',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'analysis_sms_a1',
    repeat('1', 64),
    '["seg_family_trip","seg_near_checkin"]'::jsonb,
    (SELECT revision FROM promotion_audience_exclusion_state
     WHERE promotion_id = 'promo_expedia_sms_near_checkin'),
    'lean-allocation.v1',
    repeat('a', 64)
);

SELECT pg_temp.create_audience_snapshot(
    'allocation_final_p1_near',
    'analysis_sms_a1',
    'seg_near_checkin',
    'allocation_vector_near',
    1,
    'final',
    'allocation_source_near',
    '11111111-1111-4111-8111-111111111111'
);
SELECT pg_temp.create_audience_snapshot(
    'allocation_final_p1_family',
    'analysis_sms_a1',
    'seg_family_trip',
    'allocation_vector_family',
    1,
    'final',
    'allocation_source_family',
    '11111111-1111-4111-8111-111111111111'
);

INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    behavior_fit_score,
    retrieval_source,
    retrieval_rank
) VALUES
('allocation_final_p1_near', 'p1_near_user', 0.95, 'exact', 1),
('allocation_final_p1_family', 'p1_family_user', 0.92, 'ann', 1);

SELECT pg_temp.expect_failure(
    $statement$
    WITH changed AS (
        UPDATE segment_audience_members
        SET user_id = 'p1_near_user'
        WHERE snapshot_id = 'allocation_final_p1_family'
        RETURNING 1
    )
    SELECT assert_final_audience_snapshot('allocation_final_p1_family')
    FROM changed
    $statement$,
    '23505'
);

SELECT pg_temp.expect_failure(
    $statement$
    WITH added AS (
        INSERT INTO segment_audience_members (
            snapshot_id,
            user_id,
            retrieval_source
        ) VALUES (
            'allocation_final_p1_family',
            'p1_extra_user',
            'exact'
        )
        RETURNING 1
    )
    SELECT assert_final_audience_snapshot('allocation_final_p1_family')
    FROM added
    $statement$,
    '23514'
);

UPDATE promotion_target_segments
SET audience_snapshot_id = CASE segment_id
        WHEN 'seg_near_checkin' THEN 'allocation_final_p1_near'
        WHEN 'seg_family_trip' THEN 'allocation_final_p1_family'
    END,
    allocation_plan_id = '11111111-1111-4111-8111-111111111111',
    audience_reservation_state = 'reserved'
WHERE analysis_id = 'analysis_sms_a1'
  AND segment_id IN ('seg_near_checkin', 'seg_family_trip');

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
    'promo_expedia_sms_near_checkin',
    'p1_near_user',
    'analysis_sms_a1',
    'seg_near_checkin',
    '11111111-1111-4111-8111-111111111111',
    'allocation_final_p1_near',
    'reserved',
    (SELECT revision FROM promotion_audience_exclusion_state
     WHERE promotion_id = 'promo_expedia_sms_near_checkin'),
    now()
),
(
    'demo_project',
    'promo_expedia_sms_near_checkin',
    'p1_family_user',
    'analysis_sms_a1',
    'seg_family_trip',
    '11111111-1111-4111-8111-111111111111',
    'allocation_final_p1_family',
    'reserved',
    (SELECT revision FROM promotion_audience_exclusion_state
     WHERE promotion_id = 'promo_expedia_sms_near_checkin'),
    now()
);

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM segment_audience_members AS near_member
        JOIN segment_audience_members AS family_member
          ON family_member.user_id = near_member.user_id
        WHERE near_member.snapshot_id = 'allocation_source_near'
          AND family_member.snapshot_id = 'allocation_source_family'
    ) THEN
        RAISE EXCEPTION 'source snapshots should allow overlap';
    END IF;

    IF EXISTS (
        SELECT member.user_id
        FROM segment_audience_snapshots AS snapshot
        JOIN segment_audience_members AS member
          ON member.snapshot_id = snapshot.snapshot_id
        WHERE snapshot.allocation_plan_id =
            '11111111-1111-4111-8111-111111111111'
        GROUP BY member.user_id
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'P1 final snapshots overlap';
    END IF;
END
$$;

SELECT pg_temp.expect_deferred_failure(
    $statement$
    UPDATE promotion_target_segments
    SET campaign_id = 'allocation_scope_mismatch_campaign'
    WHERE analysis_id = 'analysis_sms_a1'
      AND segment_id = 'seg_near_checkin'
    $statement$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $statement$
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
        '11111111-1111-4111-8111-111111111119',
        'promo_expedia_sms_near_checkin',
        'analysis_sms_a1',
        'analysis_sms_a1',
        repeat('1', 64),
        '["seg_family_trip","seg_near_checkin"]'::jsonb,
        1,
        'lean-allocation.v1',
        repeat('a', 64)
    )
    $statement$,
    '23505'
);

SELECT pg_temp.expect_failure(
    $statement$
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
        '11111111-1111-4111-8111-111111111118',
        'promo_expedia_sms_near_checkin',
        'analysis_sms_a1',
        'analysis_sms_a1',
        repeat('8', 64),
        '["seg_near_checkin","seg_family_trip"]'::jsonb,
        1,
        'lean-allocation.v1',
        repeat('a', 64)
    )
    $statement$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $statement$
    INSERT INTO segment_audience_members (
        snapshot_id,
        user_id,
        retrieval_source
    ) VALUES (
        'allocation_final_p1_near',
        'late_mutation_user',
        'exact'
    )
    $statement$,
    '55000'
);

-- Bind only A. B must remain reserved and unbound.
INSERT INTO promotion_runs (
    promotion_run_id,
    project_id,
    campaign_id,
    promotion_id,
    analysis_id,
    generation_id,
    loop_count,
    status,
    segment_scope_json,
    segment_scope_fingerprint
) VALUES (
    'allocation_run_p1_near',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'generation_sms_a1',
    41,
    'planned',
    '["seg_near_checkin"]'::jsonb,
    encode(digest(convert_to('["seg_near_checkin"]', 'UTF8'), 'sha256'), 'hex')
);

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_sms_near_checkin'
);

UPDATE segment_audience_allocation_plans
SET status = 'locked',
    locked_at = now()
WHERE allocation_plan_id = '11111111-1111-4111-8111-111111111111';

UPDATE promotion_target_segments
SET audience_reservation_state = 'consumed'
WHERE analysis_id = 'analysis_sms_a1'
  AND segment_id = 'seg_near_checkin';

UPDATE promotion_audience_exclusion_members
SET state = 'consumed',
    revision = (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_sms_near_checkin'
    ),
    consumed_at = now()
WHERE allocation_plan_id = '11111111-1111-4111-8111-111111111111'
  AND segment_id = 'seg_near_checkin';

INSERT INTO promotion_run_target_bindings (
    promotion_run_id,
    target_analysis_id,
    segment_id,
    allocation_plan_id,
    final_snapshot_id
) VALUES (
    'allocation_run_p1_near',
    'analysis_sms_a1',
    'seg_near_checkin',
    '11111111-1111-4111-8111-111111111111',
    'allocation_final_p1_near'
);

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM promotion_run_target_bindings
        WHERE target_analysis_id = 'analysis_sms_a1'
          AND segment_id = 'seg_family_trip'
    ) OR NOT EXISTS (
        SELECT 1
        FROM promotion_target_segments
        WHERE analysis_id = 'analysis_sms_a1'
          AND segment_id = 'seg_family_trip'
          AND audience_reservation_state = 'reserved'
    ) THEN
        RAISE EXCEPTION 'binding A unexpectedly auto-bound B';
    END IF;
END
$$;

-- A locked plan may bind its still-reserved B target into a later run.
INSERT INTO promotion_runs (
    promotion_run_id,
    project_id,
    campaign_id,
    promotion_id,
    analysis_id,
    generation_id,
    loop_count,
    status,
    segment_scope_json,
    segment_scope_fingerprint
) VALUES (
    'allocation_run_p1_family',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'generation_sms_a1',
    42,
    'planned',
    '["seg_family_trip"]'::jsonb,
    encode(digest(convert_to('["seg_family_trip"]', 'UTF8'), 'sha256'), 'hex')
);

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_sms_near_checkin'
);

UPDATE promotion_target_segments
SET audience_reservation_state = 'consumed'
WHERE analysis_id = 'analysis_sms_a1'
  AND segment_id = 'seg_family_trip';

UPDATE promotion_audience_exclusion_members
SET state = 'consumed',
    revision = (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_sms_near_checkin'
    ),
    consumed_at = now()
WHERE allocation_plan_id = '11111111-1111-4111-8111-111111111111'
  AND segment_id = 'seg_family_trip';

INSERT INTO promotion_run_target_bindings (
    promotion_run_id,
    target_analysis_id,
    segment_id,
    allocation_plan_id,
    final_snapshot_id
) VALUES (
    'allocation_run_p1_family',
    'analysis_sms_a1',
    'seg_family_trip',
    '11111111-1111-4111-8111-111111111111',
    'allocation_final_p1_family'
);

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

SELECT pg_temp.expect_failure(
    $statement$
    INSERT INTO promotion_run_target_bindings (
        promotion_run_id,
        target_analysis_id,
        segment_id,
        allocation_plan_id,
        final_snapshot_id
    ) VALUES (
        'run_sms_a1',
        'analysis_sms_a1',
        'seg_near_checkin',
        '11111111-1111-4111-8111-111111111111',
        'allocation_final_p1_near'
    )
    $statement$,
    '23505'
);

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE segment_audience_allocation_plans
    SET status = 'released',
        locked_at = NULL,
        released_at = now()
    WHERE allocation_plan_id = '11111111-1111-4111-8111-111111111111'
    $statement$,
    '55000'
);

SELECT pg_temp.expect_failure(
    $statement$
    WITH next_revision AS (
        SELECT advance_promotion_audience_exclusion_revision(
            'promo_expedia_sms_near_checkin'
        ) AS revision
    )
    UPDATE promotion_audience_exclusion_members
    SET state = 'released',
        revision = (SELECT revision FROM next_revision),
        consumed_at = NULL,
        released_at = now()
    WHERE user_id = 'p1_near_user'
    $statement$,
    '55000'
);

-- Confirmation P2 proves two explicit targets may bind to one run.
INSERT INTO promotion_target_segments (
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_id,
    segment_name,
    rule_json,
    profile_json,
    content_brief_json,
    data_evidence_json,
    estimated_size,
    status
) VALUES (
    'analysis_sms_a2',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'seg_family_trip',
    'Family trip planners',
    '{}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    1,
    'planned'
);

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_sms_near_checkin'
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
    '22222222-2222-4222-8222-222222222222',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'analysis_sms_a2',
    repeat('2', 64),
    '["seg_family_trip","seg_near_checkin"]'::jsonb,
    (SELECT revision FROM promotion_audience_exclusion_state
     WHERE promotion_id = 'promo_expedia_sms_near_checkin'),
    'lean-allocation.v1',
    repeat('b', 64)
);

SELECT pg_temp.create_audience_snapshot(
    'allocation_final_p2_near',
    'analysis_sms_a2',
    'seg_near_checkin',
    'allocation_vector_near',
    1,
    'final',
    'allocation_source_near',
    '22222222-2222-4222-8222-222222222222'
);
SELECT pg_temp.create_audience_snapshot(
    'allocation_final_p2_family',
    'analysis_sms_a2',
    'seg_family_trip',
    'allocation_vector_family',
    1,
    'final',
    'allocation_source_family',
    '22222222-2222-4222-8222-222222222222'
);

INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    behavior_fit_score,
    retrieval_source,
    retrieval_rank
) VALUES
('allocation_final_p2_near', 'p2_near_user', 0.91, 'exact', 1),
('allocation_final_p2_family', 'p2_family_user', 0.89, 'ann', 1);

UPDATE promotion_target_segments
SET audience_snapshot_id = CASE segment_id
        WHEN 'seg_near_checkin' THEN 'allocation_final_p2_near'
        WHEN 'seg_family_trip' THEN 'allocation_final_p2_family'
    END,
    allocation_plan_id = '22222222-2222-4222-8222-222222222222',
    audience_reservation_state = 'reserved'
WHERE analysis_id = 'analysis_sms_a2'
  AND segment_id IN ('seg_near_checkin', 'seg_family_trip');

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
('demo_project', 'promo_expedia_sms_near_checkin', 'p2_near_user',
 'analysis_sms_a2', 'seg_near_checkin',
 '22222222-2222-4222-8222-222222222222', 'allocation_final_p2_near',
 'reserved', (SELECT revision FROM promotion_audience_exclusion_state
              WHERE promotion_id = 'promo_expedia_sms_near_checkin'), now()),
('demo_project', 'promo_expedia_sms_near_checkin', 'p2_family_user',
 'analysis_sms_a2', 'seg_family_trip',
 '22222222-2222-4222-8222-222222222222', 'allocation_final_p2_family',
 'reserved', (SELECT revision FROM promotion_audience_exclusion_state
              WHERE promotion_id = 'promo_expedia_sms_near_checkin'), now());

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

SELECT pg_temp.expect_deferred_failure(
    $statement$
    DO $probe$
    BEGIN
        INSERT INTO promotion_runs (
            promotion_run_id,
            project_id,
            campaign_id,
            promotion_id,
            analysis_id,
            generation_id,
            loop_count,
            status,
            segment_scope_json,
            segment_scope_fingerprint
        ) VALUES (
            'allocation_wrong_analysis_run',
            'demo_project',
            'camp_expedia_hotel_demo',
            'promo_expedia_sms_near_checkin',
            'analysis_sms_a1',
            'generation_sms_a1',
            43,
            'planned',
            '["seg_near_checkin"]'::jsonb,
            encode(digest(convert_to('["seg_near_checkin"]', 'UTF8'), 'sha256'), 'hex')
        );

        INSERT INTO promotion_run_target_bindings (
            promotion_run_id,
            target_analysis_id,
            segment_id,
            allocation_plan_id,
            final_snapshot_id
        ) VALUES (
            'allocation_wrong_analysis_run',
            'analysis_sms_a2',
            'seg_near_checkin',
            '22222222-2222-4222-8222-222222222222',
            'allocation_final_p2_near'
        );
    END
    $probe$
    $statement$,
    '23514'
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
    segment_scope_json,
    segment_scope_fingerprint
) VALUES (
    'allocation_run_p2_multi',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a2',
    'generation_sms_a2',
    44,
    'planned',
    '["seg_family_trip","seg_near_checkin"]'::jsonb,
    encode(digest(convert_to(
        '["seg_family_trip","seg_near_checkin"]',
        'UTF8'
    ), 'sha256'), 'hex')
);

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_sms_near_checkin'
);

UPDATE segment_audience_allocation_plans
SET status = 'locked',
    locked_at = now()
WHERE allocation_plan_id = '22222222-2222-4222-8222-222222222222';

UPDATE promotion_target_segments
SET audience_reservation_state = 'consumed'
WHERE analysis_id = 'analysis_sms_a2'
  AND segment_id IN ('seg_near_checkin', 'seg_family_trip');

UPDATE promotion_audience_exclusion_members
SET state = 'consumed',
    revision = (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_sms_near_checkin'
    ),
    consumed_at = now()
WHERE allocation_plan_id = '22222222-2222-4222-8222-222222222222';

INSERT INTO promotion_run_target_bindings (
    promotion_run_id,
    target_analysis_id,
    segment_id,
    allocation_plan_id,
    final_snapshot_id
) VALUES
('allocation_run_p2_multi', 'analysis_sms_a2', 'seg_near_checkin',
 '22222222-2222-4222-8222-222222222222', 'allocation_final_p2_near'),
('allocation_run_p2_multi', 'analysis_sms_a2', 'seg_family_trip',
 '22222222-2222-4222-8222-222222222222', 'allocation_final_p2_family');

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    IF (SELECT count(*) FROM promotion_run_target_bindings
        WHERE promotion_run_id = 'allocation_run_p2_multi') <> 2 THEN
        RAISE EXCEPTION 'explicit multi-target run did not retain both bindings';
    END IF;
END
$$;

-- Confirmation P3 is released as a whole before any run binding.
INSERT INTO promotion_analyses (
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    focus_segment_ids_json,
    input_snapshot_json,
    profile_summary_json,
    output_json,
    status
) VALUES (
    'allocation_analysis_release',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    '["seg_family_trip","seg_near_checkin"]'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    'completed'
);

INSERT INTO promotion_target_segments (
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_id,
    segment_name,
    rule_json,
    profile_json,
    content_brief_json,
    data_evidence_json,
    estimated_size,
    status
) VALUES
('allocation_analysis_release', 'demo_project', 'camp_expedia_hotel_demo',
 'promo_expedia_sms_near_checkin', 'seg_near_checkin', 'Near check-in users',
 '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, 1, 'planned'),
('allocation_analysis_release', 'demo_project', 'camp_expedia_hotel_demo',
 'promo_expedia_sms_near_checkin', 'seg_family_trip', 'Family trip planners',
 '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, 1, 'planned');

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_sms_near_checkin'
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
    '33333333-3333-4333-8333-333333333333',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'allocation_analysis_release',
    repeat('3', 64),
    '["seg_family_trip","seg_near_checkin"]'::jsonb,
    (SELECT revision FROM promotion_audience_exclusion_state
     WHERE promotion_id = 'promo_expedia_sms_near_checkin'),
    'lean-allocation.v1',
    repeat('c', 64)
);

SELECT pg_temp.create_audience_snapshot(
    'allocation_final_p3_near', 'allocation_analysis_release',
    'seg_near_checkin', 'allocation_vector_near', 1, 'final',
    'allocation_source_near', '33333333-3333-4333-8333-333333333333'
);
SELECT pg_temp.create_audience_snapshot(
    'allocation_final_p3_family', 'allocation_analysis_release',
    'seg_family_trip', 'allocation_vector_family', 1, 'final',
    'allocation_source_family', '33333333-3333-4333-8333-333333333333'
);

INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    retrieval_source,
    retrieval_rank
) VALUES
('allocation_final_p3_near', 'released_reusable_user', 'exact', 1),
('allocation_final_p3_family', 'released_family_user', 'exact', 1);

UPDATE promotion_target_segments
SET audience_snapshot_id = CASE segment_id
        WHEN 'seg_near_checkin' THEN 'allocation_final_p3_near'
        WHEN 'seg_family_trip' THEN 'allocation_final_p3_family'
    END,
    allocation_plan_id = '33333333-3333-4333-8333-333333333333',
    audience_reservation_state = 'reserved'
WHERE analysis_id = 'allocation_analysis_release';

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
('demo_project', 'promo_expedia_sms_near_checkin', 'released_reusable_user',
 'allocation_analysis_release', 'seg_near_checkin',
 '33333333-3333-4333-8333-333333333333', 'allocation_final_p3_near',
 'reserved', (SELECT revision FROM promotion_audience_exclusion_state
              WHERE promotion_id = 'promo_expedia_sms_near_checkin'), now()),
('demo_project', 'promo_expedia_sms_near_checkin', 'released_family_user',
 'allocation_analysis_release', 'seg_family_trip',
 '33333333-3333-4333-8333-333333333333', 'allocation_final_p3_family',
 'reserved', (SELECT revision FROM promotion_audience_exclusion_state
              WHERE promotion_id = 'promo_expedia_sms_near_checkin'), now());

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

SELECT pg_temp.expect_deferred_failure(
    $statement$
    UPDATE promotion_target_segments
    SET audience_reservation_state = 'released'
    WHERE analysis_id = 'allocation_analysis_release'
      AND segment_id = 'seg_near_checkin'
    $statement$,
    '23514'
);

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_sms_near_checkin'
);

UPDATE promotion_target_segments
SET audience_reservation_state = 'released'
WHERE analysis_id = 'allocation_analysis_release';

UPDATE promotion_audience_exclusion_members
SET state = 'released',
    revision = (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_sms_near_checkin'
    ),
    released_at = now()
WHERE allocation_plan_id = '33333333-3333-4333-8333-333333333333';

UPDATE segment_audience_allocation_plans
SET status = 'released',
    released_at = now()
WHERE allocation_plan_id = '33333333-3333-4333-8333-333333333333';

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

-- A released user can be rebound by a new confirmation action.
INSERT INTO promotion_analyses (
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    focus_segment_ids_json,
    input_snapshot_json,
    profile_summary_json,
    output_json,
    status
) VALUES (
    'allocation_analysis_reuse',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    '["seg_near_checkin"]'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    'completed'
);

INSERT INTO promotion_target_segments (
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_id,
    segment_name,
    rule_json,
    profile_json,
    content_brief_json,
    data_evidence_json,
    estimated_size,
    status
) VALUES (
    'allocation_analysis_reuse',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'seg_near_checkin',
    'Near check-in users',
    '{}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    1,
    'planned'
);

SELECT advance_promotion_audience_exclusion_revision(
    'promo_expedia_sms_near_checkin'
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
    '44444444-4444-4444-8444-444444444444',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'allocation_analysis_reuse',
    repeat('4', 64),
    '["seg_near_checkin"]'::jsonb,
    (SELECT revision FROM promotion_audience_exclusion_state
     WHERE promotion_id = 'promo_expedia_sms_near_checkin'),
    'lean-allocation.v1',
    repeat('d', 64)
);

SELECT pg_temp.create_audience_snapshot(
    'allocation_final_p4_near', 'allocation_analysis_reuse',
    'seg_near_checkin', 'allocation_vector_near', 1, 'final',
    'allocation_source_near', '44444444-4444-4444-8444-444444444444'
);

INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    retrieval_source,
    retrieval_rank
) VALUES (
    'allocation_final_p4_near',
    'released_reusable_user',
    'exact',
    1
);

UPDATE promotion_target_segments
SET audience_snapshot_id = 'allocation_final_p4_near',
    allocation_plan_id = '44444444-4444-4444-8444-444444444444',
    audience_reservation_state = 'reserved'
WHERE analysis_id = 'allocation_analysis_reuse'
  AND segment_id = 'seg_near_checkin';

UPDATE promotion_audience_exclusion_members
SET target_analysis_id = 'allocation_analysis_reuse',
    segment_id = 'seg_near_checkin',
    allocation_plan_id = '44444444-4444-4444-8444-444444444444',
    final_snapshot_id = 'allocation_final_p4_near',
    state = 'reserved',
    revision = (
        SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_sms_near_checkin'
    ),
    reserved_at = now(),
    consumed_at = NULL,
    released_at = NULL
WHERE project_id = 'demo_project'
  AND promotion_id = 'promo_expedia_sms_near_checkin'
  AND user_id = 'released_reusable_user';

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM promotion_audience_exclusion_members
        WHERE project_id = 'demo_project'
          AND promotion_id = 'promo_expedia_sms_near_checkin'
          AND user_id = 'released_reusable_user'
          AND allocation_plan_id =
              '44444444-4444-4444-8444-444444444444'
          AND state = 'reserved'
    ) THEN
        RAISE EXCEPTION 'released user was not reusable';
    END IF;

    IF (SELECT revision
        FROM promotion_audience_exclusion_state
        WHERE promotion_id = 'promo_expedia_sms_near_checkin') <> 8 THEN
        RAISE EXCEPTION 'promotion exclusion revision is not monotonic';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_target_segments
        WHERE analysis_id NOT LIKE 'allocation_analysis_%'
          AND analysis_id NOT IN ('analysis_sms_a1', 'analysis_sms_a2')
          AND (allocation_plan_id IS NOT NULL
               OR audience_reservation_state IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'unrelated legacy targets changed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_run_target_bindings'::regclass
          AND conname = 'uq_promotion_run_target_bindings_target'
    ) OR EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_run_target_bindings'::regclass
          AND contype = 'u'
          AND pg_get_constraintdef(oid) = 'UNIQUE (promotion_run_id)'
    ) THEN
        RAISE EXCEPTION 'run binding uniqueness contract is incorrect';
    END IF;

    PERFORM assert_segment_audience_allocation_plan(
        '33333333-3333-4333-8333-333333333333'
    );
END
$$;

ROLLBACK;
