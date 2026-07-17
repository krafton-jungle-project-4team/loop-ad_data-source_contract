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
    IF EXISTS (
        SELECT 1
        FROM promotion_target_segments
        WHERE rule_json->>'audience_resolution_contract'
              IS DISTINCT FROM 'segment_audience.v1'
          AND (
              source_audience_snapshot_id IS NOT NULL
              OR audience_snapshot_id IS NOT NULL
          )
    ) THEN
        RAISE EXCEPTION 'legacy target snapshot bindings changed';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_runs
        WHERE audience_allocation_plan_id IS NOT NULL
           OR audience_allocation_plan_status IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'legacy run allocation bindings changed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'segment_audience_snapshots'::regclass
          AND attname = 'targetable'
          AND attgenerated = 's'
          AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION 'snapshot targetable generated column is missing';
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
)
VALUES (
    'allocation_generation_test',
    'demo_project',
    'hotel_behavior.v2',
    repeat('a', 64),
    '2026-06-01 00:00:00+00',
    '2026-07-01 00:00:00+00',
    '2026-07-01 00:00:00+00',
    3,
    3,
    0,
    'activated',
    true,
    now()
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
)
VALUES
(
    'allocation_vector_near',
    'demo_project',
    'seg_near_checkin',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    64,
    to_jsonb(ARRAY[1.0] || array_fill(0.0, ARRAY[63])),
    (ARRAY[1.0::real] || array_fill(0.0::real, ARRAY[63]))::vector,
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
    to_jsonb(ARRAY[0.0, 1.0] || array_fill(0.0, ARRAY[62])),
    (ARRAY[0.0::real, 1.0::real] || array_fill(0.0::real, ARRAY[62]))::vector,
    'hotel_behavior.v2',
    'behavior_query'
);

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
    metadata_json
)
VALUES
(
    'source_snapshot_near',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'seg_near_checkin',
    'allocation_vector_near',
    'allocation_generation_test',
    'segment_audience.v1',
    'hotel_behavior.v2',
    repeat('a', 64),
    'segment_audience.v1',
    repeat('b', 64),
    repeat('c', 64),
    'segment_behavior_query.v2',
    repeat('d', 64),
    'exact_cosine_rerank.v2',
    'audience_search.v2',
    'calibration.v1',
    repeat('e', 64),
    0.500000,
    '2026-07-01 00:00:00+00',
    '2026-06-01 00:00:00+00',
    '2026-07-01 00:00:00+00',
    3,
    2,
    2,
    1,
    'targetable',
    'exact',
    1.000000,
    1.000000,
    0.950000,
    repeat('f', 64),
    true,
    'completed',
    '{"candidate":"near"}'::jsonb
),
(
    'source_snapshot_family',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'seg_family_trip',
    'allocation_vector_family',
    'allocation_generation_test',
    'segment_audience.v1',
    'hotel_behavior.v2',
    repeat('a', 64),
    'segment_audience.v1',
    repeat('1', 64),
    repeat('2', 64),
    'segment_behavior_query.v2',
    repeat('3', 64),
    'exact_cosine_rerank.v2',
    'audience_search.v2',
    'calibration.v1',
    repeat('4', 64),
    0.500000,
    '2026-07-01 00:00:00+00',
    '2026-06-01 00:00:00+00',
    '2026-07-01 00:00:00+00',
    3,
    2,
    2,
    1,
    'targetable',
    'exact',
    1.000000,
    1.000000,
    0.950000,
    repeat('5', 64),
    true,
    'completed',
    '{"candidate":"family"}'::jsonb
);

INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    behavior_fit_score,
    retrieval_source,
    retrieval_rank
)
VALUES
    ('source_snapshot_near', 'allocation_user_overlap', 0.980000, 'exact', 1),
    ('source_snapshot_near', 'allocation_user_near', 0.900000, 'exact', 2),
    ('source_snapshot_family', 'allocation_user_overlap', 0.910000, 'exact', 1),
    ('source_snapshot_family', 'allocation_user_family', 0.880000, 'exact', 2);

DO $$
BEGIN
    IF (
        SELECT count(*)
        FROM segment_audience_members
        WHERE user_id = 'allocation_user_overlap'
          AND snapshot_id IN (
              'source_snapshot_near',
              'source_snapshot_family'
          )
    ) <> 2 THEN
        RAISE EXCEPTION 'source candidate overlap must remain allowed';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM segment_audience_snapshots
        WHERE snapshot_id IN (
            'source_snapshot_near',
            'source_snapshot_family'
        )
          AND (
              snapshot_role <> 'source_candidate'
              OR source_snapshot_id IS NOT NULL
              OR allocation_plan_id IS NOT NULL
          )
    ) THEN
        RAISE EXCEPTION 'source snapshot canonical role is invalid';
    END IF;
END
$$;

-- Current Decision V2 compatibility: before the allocation producer is
-- deployed, audience_snapshot_id can still point at the source snapshot and
-- the new source binding remains NULL.
UPDATE promotion_target_segments
SET rule_json = rule_json ||
        '{"audience_resolution_contract":"segment_audience.v1"}'::jsonb,
    audience_snapshot_id = 'source_snapshot_near'
WHERE analysis_id = 'analysis_sms_a1'
  AND segment_id = 'seg_near_checkin';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM promotion_target_segments
        WHERE analysis_id = 'analysis_sms_a1'
          AND segment_id = 'seg_near_checkin'
          AND source_audience_snapshot_id IS NULL
          AND audience_snapshot_id = 'source_snapshot_near'
    ) THEN
        RAISE EXCEPTION 'current Decision V2 target binding is incompatible';
    END IF;
END
$$;

INSERT INTO segment_audience_allocation_plans (
    allocation_plan_id,
    project_id,
    campaign_id,
    promotion_id,
    recommendation_analysis_id,
    selection_signature,
    allocation_policy_id,
    allocation_policy_version,
    allocation_policy_hash,
    status
)
VALUES (
    'allocation_plan_v1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'seg_family_trip|seg_near_checkin',
    'winner_take_best_normalized_fit',
    'allocation_policy.v1',
    repeat('6', 64),
    'draft'
);

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
    snapshot_role,
    source_snapshot_id,
    allocation_plan_id,
    allocation_policy_id,
    allocation_policy_version,
    allocation_policy_hash
)
VALUES
(
    'final_snapshot_near_v1',
    'analysis_sms_a1', 'demo_project', 'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin', 'seg_near_checkin',
    'allocation_vector_near', 'allocation_generation_test',
    'segment_audience.v1', 'hotel_behavior.v2', repeat('a', 64),
    'segment_audience.v1', repeat('b', 64), repeat('c', 64),
    'segment_behavior_query.v2', repeat('d', 64),
    'exact_cosine_rerank.v2', 'audience_search.v2', 'calibration.v1',
    repeat('e', 64), 0.500000,
    '2026-07-01 00:00:00+00', '2026-06-01 00:00:00+00',
    '2026-07-01 00:00:00+00', 3, 2, 2, 1, 'targetable', 'exact',
    1.000000, 1.000000, 0.950000, repeat('7', 64), true,
    'completed', '{"allocation_version":1}'::jsonb,
    'final_allocation', 'source_snapshot_near', 'allocation_plan_v1',
    'winner_take_best_normalized_fit', 'allocation_policy.v1', repeat('6', 64)
),
(
    'final_snapshot_family_v1',
    'analysis_sms_a1', 'demo_project', 'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin', 'seg_family_trip',
    'allocation_vector_family', 'allocation_generation_test',
    'segment_audience.v1', 'hotel_behavior.v2', repeat('a', 64),
    'segment_audience.v1', repeat('1', 64), repeat('2', 64),
    'segment_behavior_query.v2', repeat('3', 64),
    'exact_cosine_rerank.v2', 'audience_search.v2', 'calibration.v1',
    repeat('4', 64), 0.500000,
    '2026-07-01 00:00:00+00', '2026-06-01 00:00:00+00',
    '2026-07-01 00:00:00+00', 3, 2, 1, 1, 'targetable', 'exact',
    1.000000, 1.000000, 0.950000, repeat('8', 64), true,
    'completed', '{"allocation_version":1}'::jsonb,
    'final_allocation', 'source_snapshot_family', 'allocation_plan_v1',
    'winner_take_best_normalized_fit', 'allocation_policy.v1', repeat('6', 64)
);

UPDATE promotion_target_segments
SET rule_json = rule_json ||
        '{"audience_resolution_contract":"segment_audience.v1"}'::jsonb,
    source_audience_snapshot_id = CASE segment_id
        WHEN 'seg_near_checkin' THEN 'source_snapshot_near'
        WHEN 'seg_family_trip' THEN 'source_snapshot_family'
    END,
    audience_snapshot_id = CASE segment_id
        WHEN 'seg_near_checkin' THEN 'final_snapshot_near_v1'
        WHEN 'seg_family_trip' THEN 'final_snapshot_family_v1'
    END
WHERE analysis_id = 'analysis_sms_a1'
  AND segment_id IN ('seg_near_checkin', 'seg_family_trip');

SELECT pg_temp.expect_failure(
    $sql$UPDATE promotion_target_segments
         SET source_audience_snapshot_id = 'source_snapshot_family'
         WHERE analysis_id = 'analysis_sms_a1'
           AND segment_id = 'seg_near_checkin'$sql$,
    '23503'
);

INSERT INTO segment_audience_allocation_plan_targets (
    allocation_plan_id,
    target_segment_id,
    source_snapshot_id,
    final_snapshot_id,
    template_id,
    template_version,
    template_hash,
    allocation_priority,
    final_user_count,
    audience_status,
    targetable
)
SELECT
    'allocation_plan_v1',
    target.id,
    CASE target.segment_id
        WHEN 'seg_near_checkin' THEN 'source_snapshot_near'
        ELSE 'source_snapshot_family'
    END,
    CASE target.segment_id
        WHEN 'seg_near_checkin' THEN 'final_snapshot_near_v1'
        ELSE 'final_snapshot_family_v1'
    END,
    'hotel_behavior_allocation',
    'template.v1',
    repeat('9', 64),
    CASE target.segment_id WHEN 'seg_near_checkin' THEN 1 ELSE 2 END,
    CASE target.segment_id WHEN 'seg_near_checkin' THEN 2 ELSE 1 END,
    'targetable',
    true
FROM promotion_target_segments AS target
WHERE target.analysis_id = 'analysis_sms_a1'
  AND target.segment_id IN ('seg_near_checkin', 'seg_family_trip');

INSERT INTO segment_audience_allocation_members (
    allocation_plan_id,
    user_id,
    target_segment_id,
    source_snapshot_id,
    final_snapshot_id,
    behavior_fit_score,
    threshold,
    semantic_margin,
    normalized_fit,
    allocation_reason
)
SELECT
    'allocation_plan_v1',
    allocation.user_id,
    target.id,
    allocation.source_snapshot_id,
    allocation.final_snapshot_id,
    allocation.behavior_fit_score,
    0.500000,
    allocation.semantic_margin,
    allocation.normalized_fit,
    allocation.allocation_reason
FROM (
    VALUES
        (
            'seg_near_checkin', 'allocation_user_overlap',
            'source_snapshot_near', 'final_snapshot_near_v1',
            0.980000::numeric, 0.070000::numeric, 1.000000::numeric,
            'highest_normalized_fit'
        ),
        (
            'seg_near_checkin', 'allocation_user_near',
            'source_snapshot_near', 'final_snapshot_near_v1',
            0.900000::numeric, 0.400000::numeric, 0.900000::numeric,
            'single_source_match'
        ),
        (
            'seg_family_trip', 'allocation_user_family',
            'source_snapshot_family', 'final_snapshot_family_v1',
            0.880000::numeric, 0.380000::numeric, 0.880000::numeric,
            'single_source_match'
        )
) AS allocation(
    segment_id,
    user_id,
    source_snapshot_id,
    final_snapshot_id,
    behavior_fit_score,
    semantic_margin,
    normalized_fit,
    allocation_reason
)
JOIN promotion_target_segments AS target
  ON target.analysis_id = 'analysis_sms_a1'
 AND target.segment_id = allocation.segment_id;

-- Canonical final member materialization recipe. The final-member FK is
-- deferred so allocation rows and their final snapshot members can be written
-- atomically in either order inside the same transaction.
INSERT INTO segment_audience_members (
    snapshot_id,
    user_id,
    behavior_fit_score,
    retrieval_source,
    retrieval_rank
)
SELECT
    allocation.final_snapshot_id,
    allocation.user_id,
    allocation.behavior_fit_score,
    source_member.retrieval_source,
    source_member.retrieval_rank
FROM segment_audience_allocation_members AS allocation
JOIN segment_audience_members AS source_member
  ON source_member.snapshot_id = allocation.source_snapshot_id
 AND source_member.user_id = allocation.user_id
WHERE allocation.allocation_plan_id = 'allocation_plan_v1';

UPDATE segment_audience_allocation_plans
SET status = 'finalized', finalized_at = now()
WHERE allocation_plan_id = 'allocation_plan_v1';

DO $$
DECLARE
    invalid_target_count INT;
BEGIN
    SELECT count(*)
    INTO invalid_target_count
    FROM segment_audience_allocation_plan_targets AS plan_target
    JOIN segment_audience_allocation_plans AS plan
      ON plan.allocation_plan_id = plan_target.allocation_plan_id
    JOIN promotion_target_segments AS target
      ON target.id = plan_target.target_segment_id
    JOIN segment_audience_snapshots AS source_snapshot
      ON source_snapshot.snapshot_id = plan_target.source_snapshot_id
    JOIN segment_audience_snapshots AS final_snapshot
      ON final_snapshot.snapshot_id = plan_target.final_snapshot_id
    LEFT JOIN LATERAL (
        SELECT count(*) AS member_count
        FROM segment_audience_members AS member
        WHERE member.snapshot_id = plan_target.final_snapshot_id
    ) AS final_members ON true
    LEFT JOIN LATERAL (
        SELECT count(*) AS member_count
        FROM segment_audience_allocation_members AS member
        WHERE member.allocation_plan_id = plan_target.allocation_plan_id
          AND member.target_segment_id = plan_target.target_segment_id
    ) AS allocation_members ON true
    WHERE plan.allocation_plan_id = 'allocation_plan_v1'
      AND (
          plan.status <> 'finalized'
          OR target.source_audience_snapshot_id
             IS DISTINCT FROM plan_target.source_snapshot_id
          OR target.audience_snapshot_id
             IS DISTINCT FROM plan_target.final_snapshot_id
          OR target.rule_json->>'audience_resolution_contract'
             IS DISTINCT FROM 'segment_audience.v1'
          OR source_snapshot.snapshot_role <> 'source_candidate'
          OR final_snapshot.snapshot_role <> 'final_allocation'
          OR final_snapshot.source_snapshot_id
             IS DISTINCT FROM source_snapshot.snapshot_id
          OR final_snapshot.allocation_plan_id
             IS DISTINCT FROM plan.allocation_plan_id
          OR final_snapshot.final_user_count
             IS DISTINCT FROM plan_target.final_user_count
          OR final_snapshot.audience_status
             IS DISTINCT FROM plan_target.audience_status
          OR final_snapshot.targetable
             IS DISTINCT FROM plan_target.targetable
          OR final_members.member_count
             IS DISTINCT FROM plan_target.final_user_count::bigint
          OR allocation_members.member_count
             IS DISTINCT FROM final_members.member_count
      );

    IF invalid_target_count <> 0 THEN
        RAISE EXCEPTION '% allocation target validation rows failed',
            invalid_target_count;
    END IF;

    IF (
        SELECT count(*) - count(DISTINCT user_id)
        FROM segment_audience_allocation_members
        WHERE allocation_plan_id = 'allocation_plan_v1'
    ) <> 0 THEN
        RAISE EXCEPTION 'allocation plan contains duplicate users';
    END IF;
END
$$;

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO segment_audience_allocation_members (
        allocation_plan_id,
        user_id,
        target_segment_id,
        source_snapshot_id,
        final_snapshot_id,
        behavior_fit_score,
        threshold,
        semantic_margin,
        normalized_fit,
        allocation_reason
    )
    SELECT
        'allocation_plan_v1',
        'allocation_user_overlap',
        target.id,
        'source_snapshot_family',
        'final_snapshot_family_v1',
        0.910000,
        0.500000,
        0.010000,
        0.800000,
        'duplicate_overlap'
    FROM promotion_target_segments AS target
    WHERE target.analysis_id = 'analysis_sms_a1'
      AND target.segment_id = 'seg_family_trip'$sql$,
    '23505'
);

UPDATE segment_audience_allocation_plans
SET status = 'superseded', superseded_at = now()
WHERE allocation_plan_id = 'allocation_plan_v1';

INSERT INTO segment_audience_allocation_plans (
    allocation_plan_id,
    project_id,
    campaign_id,
    promotion_id,
    recommendation_analysis_id,
    selection_signature,
    allocation_policy_id,
    allocation_policy_version,
    allocation_policy_hash,
    status
)
VALUES (
    'allocation_plan_v2',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'seg_family_trip|seg_near_checkin',
    'winner_take_best_normalized_fit',
    'allocation_policy.v2',
    repeat('a', 64),
    'draft'
);

INSERT INTO segment_audience_snapshots (
    snapshot_id, analysis_id, project_id, campaign_id, promotion_id,
    segment_id, segment_vector_id, vector_generation_id, schema_version,
    vector_version, manifest_hash, audience_resolution_contract,
    segment_audience_spec_hash, query_vector_hash, query_compiler_version,
    query_compiler_hash, matcher_version, search_policy_version,
    calibration_version, calibration_hash, score_threshold, source_cutoff,
    window_start, window_end, eligible_user_count, behavior_match_count,
    final_user_count, min_sample_size, audience_status, selection_method,
    estimated_recall, recall_lower_bound, recall_target, input_fingerprint,
    meets_min_sample_size, status, metadata_json, snapshot_role,
    source_snapshot_id, allocation_plan_id, allocation_policy_id,
    allocation_policy_version, allocation_policy_hash
)
SELECT
    CASE source.segment_id
        WHEN 'seg_near_checkin' THEN 'final_snapshot_near_v2'
        ELSE 'final_snapshot_family_v2'
    END,
    source.analysis_id,
    source.project_id,
    source.campaign_id,
    source.promotion_id,
    source.segment_id,
    source.segment_vector_id,
    source.vector_generation_id,
    source.schema_version,
    source.vector_version,
    source.manifest_hash,
    source.audience_resolution_contract,
    source.segment_audience_spec_hash,
    source.query_vector_hash,
    source.query_compiler_version,
    source.query_compiler_hash,
    source.matcher_version,
    source.search_policy_version,
    source.calibration_version,
    source.calibration_hash,
    source.score_threshold,
    source.source_cutoff,
    source.window_start,
    source.window_end,
    source.eligible_user_count,
    source.behavior_match_count,
    CASE source.segment_id WHEN 'seg_near_checkin' THEN 2 ELSE 1 END,
    source.min_sample_size,
    'targetable',
    source.selection_method,
    source.estimated_recall,
    source.recall_lower_bound,
    source.recall_target,
    CASE source.segment_id
        WHEN 'seg_near_checkin' THEN repeat('b', 64)
        ELSE repeat('c', 64)
    END,
    true,
    'completed',
    '{"allocation_version":2}'::jsonb,
    'final_allocation',
    source.snapshot_id,
    'allocation_plan_v2',
    'winner_take_best_normalized_fit',
    'allocation_policy.v2',
    repeat('a', 64)
FROM segment_audience_snapshots AS source
WHERE source.snapshot_id IN (
    'source_snapshot_near',
    'source_snapshot_family'
);

UPDATE promotion_target_segments
SET audience_snapshot_id = CASE segment_id
        WHEN 'seg_near_checkin' THEN 'final_snapshot_near_v2'
        WHEN 'seg_family_trip' THEN 'final_snapshot_family_v2'
    END
WHERE analysis_id = 'analysis_sms_a1'
  AND segment_id IN ('seg_near_checkin', 'seg_family_trip');

INSERT INTO segment_audience_allocation_plan_targets (
    allocation_plan_id, target_segment_id, source_snapshot_id,
    final_snapshot_id, template_id, template_version, template_hash,
    allocation_priority, final_user_count, audience_status, targetable
)
SELECT
    'allocation_plan_v2',
    target.id,
    target.source_audience_snapshot_id,
    target.audience_snapshot_id,
    'hotel_behavior_allocation',
    'template.v2',
    repeat('d', 64),
    CASE target.segment_id WHEN 'seg_near_checkin' THEN 1 ELSE 2 END,
    CASE target.segment_id WHEN 'seg_near_checkin' THEN 2 ELSE 1 END,
    'targetable',
    true
FROM promotion_target_segments AS target
WHERE target.analysis_id = 'analysis_sms_a1'
  AND target.segment_id IN ('seg_near_checkin', 'seg_family_trip');

INSERT INTO segment_audience_allocation_members (
    allocation_plan_id, user_id, target_segment_id, source_snapshot_id,
    final_snapshot_id, behavior_fit_score, threshold, semantic_margin,
    normalized_fit, allocation_reason
)
SELECT
    'allocation_plan_v2',
    old_member.user_id,
    new_target.id,
    old_member.source_snapshot_id,
    CASE old_member.source_snapshot_id
        WHEN 'source_snapshot_near' THEN 'final_snapshot_near_v2'
        ELSE 'final_snapshot_family_v2'
    END,
    old_member.behavior_fit_score,
    old_member.threshold,
    old_member.semantic_margin,
    old_member.normalized_fit,
    'reallocated_before_run'
FROM segment_audience_allocation_members AS old_member
JOIN promotion_target_segments AS new_target
  ON new_target.analysis_id = 'analysis_sms_a1'
 AND new_target.source_audience_snapshot_id = old_member.source_snapshot_id
WHERE old_member.allocation_plan_id = 'allocation_plan_v1';

INSERT INTO segment_audience_members (
    snapshot_id, user_id, behavior_fit_score, retrieval_source, retrieval_rank
)
SELECT
    allocation.final_snapshot_id,
    allocation.user_id,
    allocation.behavior_fit_score,
    source_member.retrieval_source,
    source_member.retrieval_rank
FROM segment_audience_allocation_members AS allocation
JOIN segment_audience_members AS source_member
  ON source_member.snapshot_id = allocation.source_snapshot_id
 AND source_member.user_id = allocation.user_id
WHERE allocation.allocation_plan_id = 'allocation_plan_v2';

UPDATE segment_audience_allocation_plans
SET status = 'finalized', finalized_at = now()
WHERE allocation_plan_id = 'allocation_plan_v2';

DO $$
BEGIN
    IF (
        SELECT count(*)
        FROM segment_audience_allocation_members
        WHERE allocation_plan_id = 'allocation_plan_v1'
    ) <> 3 OR (
        SELECT count(*)
        FROM segment_audience_allocation_plan_targets
        WHERE allocation_plan_id = 'allocation_plan_v1'
    ) <> 2 THEN
        RAISE EXCEPTION 'superseded allocation plan was not preserved';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_target_segments
        WHERE analysis_id = 'analysis_sms_a1'
          AND (
              source_audience_snapshot_id IS NULL
              OR audience_snapshot_id NOT LIKE '%_v2'
          )
    ) THEN
        RAISE EXCEPTION 'replacement allocation plan did not rebind targets';
    END IF;
END
$$;

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO segment_audience_allocation_plans (
        allocation_plan_id, project_id, campaign_id, promotion_id,
        recommendation_analysis_id, selection_signature,
        allocation_policy_id, allocation_policy_version,
        allocation_policy_hash, status
    ) VALUES (
        'allocation_plan_concurrent', 'demo_project',
        'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin',
        'analysis_sms_a1', 'seg_near_checkin', 'policy', 'v1',
        repeat('e', 64), 'draft'
    )$sql$,
    '23505'
);

INSERT INTO segment_audience_allocation_previews (
    preview_id,
    recommendation_analysis_id,
    selection_signature,
    source_snapshot_set_hash,
    allocation_policy_version,
    allocation_policy_hash
)
SELECT
    'allocation_preview_' || preview_no,
    'analysis_sms_a1',
    selection_signature,
    repeat(preview_no::text, 64),
    'allocation_policy.v2',
    repeat('f', 64)
FROM (
    VALUES
        (1, 'seg_near_checkin'),
        (2, 'seg_family_trip'),
        (3, 'seg_mobile_user'),
        (4, 'seg_family_trip|seg_near_checkin'),
        (5, 'seg_mobile_user|seg_near_checkin'),
        (6, 'seg_family_trip|seg_mobile_user'),
        (7, 'seg_family_trip|seg_mobile_user|seg_near_checkin')
) AS combinations(preview_no, selection_signature);

INSERT INTO segment_audience_allocation_preview_targets (
    preview_id,
    segment_id,
    final_user_count,
    targetable,
    audience_status
)
VALUES
    ('allocation_preview_1', 'seg_near_checkin', 2, true, 'targetable'),
    ('allocation_preview_2', 'seg_family_trip', 2, true, 'targetable'),
    ('allocation_preview_3', 'seg_mobile_user', 1, true, 'targetable'),
    ('allocation_preview_4', 'seg_near_checkin', 2, true, 'targetable'),
    ('allocation_preview_4', 'seg_family_trip', 1, true, 'targetable'),
    ('allocation_preview_5', 'seg_near_checkin', 2, true, 'targetable'),
    ('allocation_preview_5', 'seg_mobile_user', 1, true, 'targetable'),
    ('allocation_preview_6', 'seg_family_trip', 2, true, 'targetable'),
    ('allocation_preview_6', 'seg_mobile_user', 1, true, 'targetable'),
    ('allocation_preview_7', 'seg_near_checkin', 2, true, 'targetable'),
    ('allocation_preview_7', 'seg_family_trip', 1, true, 'targetable'),
    ('allocation_preview_7', 'seg_mobile_user', 0, false, 'no_eligible_audience');

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO segment_audience_allocation_previews (
        preview_id, recommendation_analysis_id, selection_signature,
        source_snapshot_set_hash, allocation_policy_version,
        allocation_policy_hash
    ) VALUES (
        'allocation_preview_duplicate_active', 'analysis_sms_a1',
        'seg_near_checkin', repeat('0', 64), 'allocation_policy.v3',
        repeat('1', 64)
    )$sql$,
    '23505'
);

UPDATE segment_audience_allocation_previews
SET status = 'superseded'
WHERE preview_id = 'allocation_preview_1';

INSERT INTO segment_audience_allocation_previews (
    preview_id,
    recommendation_analysis_id,
    selection_signature,
    source_snapshot_set_hash,
    allocation_policy_version,
    allocation_policy_hash
)
VALUES (
    'allocation_preview_1_v2',
    'analysis_sms_a1',
    'seg_near_checkin',
    repeat('0', 64),
    'allocation_policy.v3',
    repeat('1', 64)
);

DO $$
BEGIN
    IF (
        SELECT count(*)
        FROM segment_audience_allocation_previews
        WHERE recommendation_analysis_id = 'analysis_sms_a1'
          AND status = 'active'
    ) <> 7 THEN
        RAISE EXCEPTION 'expected seven active selection previews';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM segment_audience_allocation_preview_targets AS preview_target
        JOIN segment_audience_allocation_previews AS preview
          ON preview.preview_id = preview_target.preview_id
        WHERE preview_target.targetable
              IS DISTINCT FROM (preview_target.final_user_count > 0)
    ) THEN
        RAISE EXCEPTION 'preview targetable/count contract mismatch';
    END IF;
END
$$;

SELECT pg_temp.expect_failure(
    $sql$INSERT INTO promotion_runs (
        promotion_run_id, project_id, campaign_id, promotion_id,
        analysis_id, generation_id, loop_count, status,
        goal_snapshot_json, segment_scope_json,
        segment_scope_fingerprint, audience_allocation_plan_id
    ) VALUES (
        'run_sms_allocation_test', 'demo_project',
        'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin',
        'analysis_sms_a1', 'generation_sms_a1', 2, 'planned',
        '{"goal_metric":"booking_conversion_rate","target":0.04}'::jsonb,
        '["seg_family_trip","seg_near_checkin"]'::jsonb,
        'ddb2d4e90789ba02f9868ab17bf57c27f98f7d22a8f327d1817cc962f81a7ed8',
        'allocation_plan_v2'
    )$sql$,
    '23503'
);

UPDATE segment_audience_allocation_plans
SET status = 'locked'
WHERE allocation_plan_id = 'allocation_plan_v2';

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
    segment_scope_fingerprint,
    audience_allocation_plan_id
)
VALUES (
    'run_sms_allocation_test',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'generation_sms_a1',
    2,
    'planned',
    '{"goal_metric":"booking_conversion_rate","target":0.04}'::jsonb,
    '["seg_family_trip","seg_near_checkin"]'::jsonb,
    'ddb2d4e90789ba02f9868ab17bf57c27f98f7d22a8f327d1817cc962f81a7ed8',
    'allocation_plan_v2'
);

UPDATE promotion_runs
SET status = 'running', started_at = now()
WHERE promotion_run_id = 'run_sms_allocation_test';

SELECT pg_temp.expect_failure(
    $sql$UPDATE segment_audience_allocation_members
         SET allocation_reason = 'mutated_after_lock'
         WHERE allocation_plan_id = 'allocation_plan_v2'
           AND user_id = 'allocation_user_overlap'$sql$,
    '55000'
);

SELECT pg_temp.expect_failure(
    $sql$DELETE FROM segment_audience_allocation_plan_targets
         WHERE allocation_plan_id = 'allocation_plan_v2'
           AND target_segment_id = (
               SELECT id
               FROM promotion_target_segments
               WHERE analysis_id = 'analysis_sms_a1'
                 AND segment_id = 'seg_family_trip'
           )$sql$,
    '55000'
);

SELECT pg_temp.expect_failure(
    $sql$UPDATE promotion_target_segments
         SET audience_snapshot_id = 'final_snapshot_near_v1'
         WHERE analysis_id = 'analysis_sms_a1'
           AND segment_id = 'seg_near_checkin'$sql$,
    '55000'
);

SELECT pg_temp.expect_failure(
    $sql$UPDATE segment_audience_allocation_plans
         SET status = 'superseded', superseded_at = now()
         WHERE allocation_plan_id = 'allocation_plan_v2'$sql$,
    '23503'
);

UPDATE user_behavior_vector_search_generations
SET status = 'superseded', is_active = false, updated_at = now()
WHERE vector_generation_id = 'allocation_generation_test';

DO $$
BEGIN
    IF (
        SELECT count(*)
        FROM segment_audience_allocation_members
        WHERE allocation_plan_id IN ('allocation_plan_v1', 'allocation_plan_v2')
    ) <> 6 THEN
        RAISE EXCEPTION 'allocation members were not preserved';
    END IF;

    IF (
        SELECT count(*)
        FROM segment_audience_snapshots
        WHERE allocation_plan_id IN ('allocation_plan_v1', 'allocation_plan_v2')
    ) <> 4 THEN
        RAISE EXCEPTION 'final allocation snapshots were not preserved';
    END IF;

    IF (
        SELECT count(*)
        FROM promotion_target_segments
        WHERE source_audience_snapshot_id IS NULL
          AND audience_snapshot_id IS NULL
    ) = 0 THEN
        RAISE EXCEPTION 'legacy nullable target path disappeared';
    END IF;
END
$$;

ROLLBACK;
