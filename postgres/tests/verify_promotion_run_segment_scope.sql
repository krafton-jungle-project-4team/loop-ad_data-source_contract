\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
    invalid_run_count BIGINT;
    scope_mismatch_count BIGINT;
    broken_lineage_count BIGINT;
BEGIN
    IF to_regprocedure(
        'is_valid_promotion_run_segment_scope(jsonb,text)'
    ) IS NULL THEN
        RAISE EXCEPTION 'scope validator function is missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'promotion_runs'::regclass
          AND attname IN (
              'segment_scope_json',
              'segment_scope_fingerprint'
          )
          AND NOT attnotnull
    ) THEN
        RAISE EXCEPTION 'scope columns must be NOT NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'chk_promotion_runs_segment_scope'
          AND contype = 'c'
          AND convalidated
    ) THEN
        RAISE EXCEPTION 'canonical scope CHECK constraint is missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname IN (
              'uq_promotion_runs_loop',
              'chk_promotion_runs_segment_scope_json',
              'chk_promotion_runs_segment_scope_fingerprint'
          )
    ) THEN
        RAISE EXCEPTION 'obsolete promotion_runs constraints remain';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'uq_promotion_runs_segment_scope'
          AND contype = 'u'
    ) THEN
        RAISE EXCEPTION 'full composite scope unique constraint is missing';
    END IF;

    SELECT count(*)
    INTO invalid_run_count
    FROM promotion_runs
    WHERE segment_scope_json IS NULL
       OR segment_scope_fingerprint IS NULL
       OR NOT is_valid_promotion_run_segment_scope(
            segment_scope_json,
            segment_scope_fingerprint
       );

    IF invalid_run_count <> 0 THEN
        RAISE EXCEPTION '% fixture promotion_runs have invalid scopes',
            invalid_run_count;
    END IF;

    WITH expected_scopes AS (
        SELECT
            pr.promotion_run_id,
            (
                SELECT jsonb_agg(
                    normalized.segment_id
                    ORDER BY normalized.segment_id COLLATE "C"
                )
                FROM (
                    SELECT DISTINCT ae.segment_id
                    FROM ad_experiments AS ae
                    WHERE ae.promotion_run_id = pr.promotion_run_id
                      AND ae.segment_id <> 'seg_existing_all'
                ) AS normalized
            ) AS segment_scope_json
        FROM promotion_runs AS pr
    )
    SELECT count(*)
    INTO scope_mismatch_count
    FROM promotion_runs AS pr
    JOIN expected_scopes AS expected
      USING (promotion_run_id)
    WHERE pr.segment_scope_json IS DISTINCT FROM expected.segment_scope_json;

    IF scope_mismatch_count <> 0 THEN
        RAISE EXCEPTION
            '% fixture scopes differ from non-fallback experiments',
            scope_mismatch_count;
    END IF;

    SELECT count(*)
    INTO broken_lineage_count
    FROM ad_experiments AS child
    LEFT JOIN ad_experiments AS parent
      ON parent.ad_experiment_id = child.parent_ad_experiment_id
    LEFT JOIN promotion_evaluations AS source_evaluation
      ON source_evaluation.evaluation_id = child.source_evaluation_id
    WHERE child.parent_ad_experiment_id IS NOT NULL
      AND (
          parent.ad_experiment_id IS NULL
          OR source_evaluation.evaluation_id IS NULL
          OR source_evaluation.ad_experiment_id
             IS DISTINCT FROM parent.ad_experiment_id
          OR source_evaluation.promotion_run_id
             IS DISTINCT FROM parent.promotion_run_id
      );

    IF broken_lineage_count <> 0 THEN
        RAISE EXCEPTION '% child experiment lineage rows are broken',
            broken_lineage_count;
    END IF;

    SELECT count(*)
    INTO broken_lineage_count
    FROM next_loop_preparations AS preparation
    CROSS JOIN LATERAL jsonb_array_elements_text(
        preparation.failed_segment_ids_json
    ) AS failed_segment(segment_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM ad_experiments AS source_experiment
        WHERE source_experiment.promotion_run_id =
              preparation.source_promotion_run_id
          AND source_experiment.segment_id = failed_segment.segment_id
          AND source_experiment.segment_id <> 'seg_existing_all'
    );

    IF broken_lineage_count <> 0 THEN
        RAISE EXCEPTION '% next-loop segment references are broken',
            broken_lineage_count;
    END IF;

    SELECT count(*)
    INTO broken_lineage_count
    FROM next_loop_preparations AS preparation
    CROSS JOIN LATERAL jsonb_array_elements_text(
        preparation.failed_ad_experiment_ids_json
    ) AS failed_experiment(ad_experiment_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM ad_experiments AS source_experiment
        WHERE source_experiment.promotion_run_id =
              preparation.source_promotion_run_id
          AND source_experiment.ad_experiment_id =
              failed_experiment.ad_experiment_id
    );

    IF broken_lineage_count <> 0 THEN
        RAISE EXCEPTION '% next-loop experiment references are broken',
            broken_lineage_count;
    END IF;

    SELECT count(*)
    INTO broken_lineage_count
    FROM next_loop_preparations AS preparation
    CROSS JOIN LATERAL jsonb_array_elements_text(
        preparation.source_evaluation_ids_json
    ) AS source_evaluation(evaluation_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM promotion_evaluations AS evaluation
        WHERE evaluation.promotion_run_id =
              preparation.source_promotion_run_id
          AND evaluation.evaluation_id = source_evaluation.evaluation_id
    );

    IF broken_lineage_count <> 0 THEN
        RAISE EXCEPTION '% next-loop evaluation references are broken',
            broken_lineage_count;
    END IF;
END
$$;

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
)
VALUES
(
    'test_scope_run_a',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'generation_sms_a1',
    9,
    'planned',
    '["seg_family_trip"]'::jsonb,
    '368e152e586ec2cf917821779f3fbd33976c8dbc855eeb25aa6d245a5c255001'
),
(
    'test_scope_run_b',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'analysis_sms_a1',
    'generation_sms_a1',
    9,
    'planned',
    '["seg_near_checkin"]'::jsonb,
    '254dece18876fe5e844634faad372e1c614fc990c55041b6fa5d10865bbb623d'
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
    status
)
VALUES (
    'test_content_scope_fallback',
    'test_scope_fallback_option',
    'generation_sms_a1',
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'seg_existing_all',
    'sms',
    'Fallback fixture used only by the rollback test.',
    'active'
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
)
VALUES
(
    'test_scope_exp_a',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'test_scope_run_a',
    'analysis_sms_a1',
    'generation_sms_a1',
    'seg_family_trip',
    'Family trip planners',
    'content_sms_a1_family',
    'sms_a1_family_option_1',
    'sms',
    9,
    'planned',
    'booking_conversion_rate',
    0.04,
    'all_segments'
),
(
    'test_scope_exp_a_fallback',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'test_scope_run_a',
    'analysis_sms_a1',
    'generation_sms_a1',
    'seg_existing_all',
    'All existing hotel users',
    'test_content_scope_fallback',
    'test_scope_fallback_option',
    'sms',
    9,
    'planned',
    'booking_conversion_rate',
    0.04,
    'all_segments'
),
(
    'test_scope_exp_b',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'test_scope_run_b',
    'analysis_sms_a1',
    'generation_sms_a1',
    'seg_near_checkin',
    'Near check-in users',
    'content_sms_a1_near',
    'sms_a1_near_option_1',
    'sms',
    9,
    'planned',
    'booking_conversion_rate',
    0.04,
    'all_segments'
);

DO $$
DECLARE
    run_count BIGINT;
    run_id_count BIGINT;
    fingerprint_count BIGINT;
    scope_mismatch_count BIGINT;
BEGIN
    SELECT
        count(*),
        count(DISTINCT promotion_run_id),
        count(DISTINCT segment_scope_fingerprint)
    INTO run_count, run_id_count, fingerprint_count
    FROM promotion_runs
    WHERE project_id = 'demo_project'
      AND promotion_id = 'promo_expedia_sms_near_checkin'
      AND analysis_id = 'analysis_sms_a1'
      AND generation_id = 'generation_sms_a1'
      AND loop_count = 9;

    IF run_count <> 2 OR run_id_count <> 2 OR fingerprint_count <> 2 THEN
        RAISE EXCEPTION
            'different scopes did not create two distinct full-identity runs';
    END IF;

    WITH expected_scopes AS (
        SELECT
            pr.promotion_run_id,
            (
                SELECT jsonb_agg(
                    normalized.segment_id
                    ORDER BY normalized.segment_id COLLATE "C"
                )
                FROM (
                    SELECT DISTINCT ae.segment_id
                    FROM ad_experiments AS ae
                    WHERE ae.promotion_run_id = pr.promotion_run_id
                      AND ae.segment_id <> 'seg_existing_all'
                ) AS normalized
            ) AS segment_scope_json
        FROM promotion_runs AS pr
        WHERE pr.promotion_run_id IN (
            'test_scope_run_a',
            'test_scope_run_b'
        )
    )
    SELECT count(*)
    INTO scope_mismatch_count
    FROM promotion_runs AS pr
    JOIN expected_scopes AS expected
      USING (promotion_run_id)
    WHERE pr.segment_scope_json IS DISTINCT FROM expected.segment_scope_json;

    IF scope_mismatch_count <> 0 THEN
        RAISE EXCEPTION
            'test run scope includes fallback or misses a non-fallback experiment';
    END IF;

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
        )
        VALUES (
            'test_scope_run_duplicate',
            'demo_project',
            'camp_expedia_hotel_demo',
            'promo_expedia_sms_near_checkin',
            'analysis_sms_a1',
            'generation_sms_a1',
            9,
            'planned',
            '["seg_family_trip"]'::jsonb,
            '368e152e586ec2cf917821779f3fbd33976c8dbc855eeb25aa6d245a5c255001'
        );
        RAISE EXCEPTION 'identical full composite scope was accepted';
    EXCEPTION
        WHEN unique_violation THEN NULL;
    END;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.expect_scope_check_violation(
    p_promotion_run_id TEXT,
    p_segment_scope_json JSONB,
    p_segment_scope_fingerprint TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
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
        )
        VALUES (
            p_promotion_run_id,
            'demo_project',
            'camp_expedia_hotel_demo',
            'promo_expedia_sms_near_checkin',
            'analysis_sms_a1',
            'generation_sms_a1',
            10,
            'planned',
            p_segment_scope_json,
            p_segment_scope_fingerprint
        );
        RAISE EXCEPTION '% was accepted', p_promotion_run_id;
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_unsorted',
    '["seg_near_checkin","seg_family_trip"]'::jsonb,
    'ddb2d4e90789ba02f9868ab17bf57c27f98f7d22a8f327d1817cc962f81a7ed8'
);
SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_duplicate',
    '["seg_family_trip","seg_family_trip"]'::jsonb,
    repeat('0', 64)
);
SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_fallback',
    '["seg_existing_all"]'::jsonb,
    '5f7995a2e727f3918739964a4b76844dd994bba80fa63aad8f0223b669094c2a'
);
SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_empty_id',
    '[""]'::jsonb,
    repeat('0', 64)
);
SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_whitespace',
    '[" seg_family_trip"]'::jsonb,
    repeat('0', 64)
);
SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_non_string',
    '[1]'::jsonb,
    repeat('0', 64)
);
SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_empty_array',
    '[]'::jsonb,
    repeat('0', 64)
);
SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_root_type',
    '{"segment_id":"seg_family_trip"}'::jsonb,
    repeat('0', 64)
);
SELECT pg_temp.expect_scope_check_violation(
    'test_scope_bad_fingerprint',
    '["seg_family_trip"]'::jsonb,
    repeat('0', 64)
);

ROLLBACK;
