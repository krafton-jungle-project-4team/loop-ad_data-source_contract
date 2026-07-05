-- =========================================================
-- Loop-Ad PostgreSQL Dummy / Seed Data
-- =========================================================
--
-- This file is intentionally separated from schema.sql.
-- Run schema.sql first, then dummy.sql.
--
-- dummy.sql includes:
--   1. demo-shop project / campaign / promotion
--   2. segment preview, saved segment definitions, funnel setup
--   3. ChatKit session/action examples
--   4. Decision analysis, suggestions, vectors, target segments, generation output
--   5. promotion run, ad experiments, evaluations
--   6. active ad serving assignments, dispatch jobs, redirects
--   7. sample event validation errors
--
-- It refreshes only rows under project_id = 'demo-shop'.
--
-- =========================================================

BEGIN;

-- =========================================================
-- 0. Refresh previous demo-shop seed rows
-- Delete in FK dependency order.
-- =========================================================

DELETE FROM event_validation_errors
WHERE project_id = 'demo-shop';

DELETE FROM redirect_links
WHERE project_id = 'demo-shop';

DELETE FROM ad_dispatch_jobs
WHERE project_id = 'demo-shop';

DELETE FROM user_segment_assignments
WHERE project_id = 'demo-shop';

DELETE FROM promotion_evaluations
WHERE project_id = 'demo-shop';

DELETE FROM ad_experiments
WHERE project_id = 'demo-shop';

DELETE FROM promotion_target_segments
WHERE project_id = 'demo-shop';

DELETE FROM promotion_segment_suggestions
WHERE project_id = 'demo-shop';

DELETE FROM segment_vectors
WHERE project_id = 'demo-shop';

DELETE FROM promotion_runs
WHERE project_id = 'demo-shop';

DELETE FROM content_candidates
WHERE project_id = 'demo-shop';

DELETE FROM generation_runs
WHERE project_id = 'demo-shop';

DELETE FROM promotion_analyses
WHERE project_id = 'demo-shop';

DELETE FROM ai_action_runs
WHERE project_id = 'demo-shop';

DELETE FROM ai_chat_messages
WHERE chat_session_id IN (
    SELECT chat_session_id
    FROM ai_chat_sessions
    WHERE project_id = 'demo-shop'
);

DELETE FROM ai_chat_sessions
WHERE project_id = 'demo-shop';

DELETE FROM funnel_steps
WHERE funnel_id IN (
    SELECT funnel_id
    FROM funnel_definitions
    WHERE project_id = 'demo-shop'
);

DELETE FROM funnel_definitions
WHERE project_id = 'demo-shop';

DELETE FROM segment_definitions
WHERE project_id = 'demo-shop';

DELETE FROM segment_query_previews
WHERE project_id = 'demo-shop';

DELETE FROM promotions
WHERE project_id = 'demo-shop';

DELETE FROM campaigns
WHERE project_id = 'demo-shop';

DELETE FROM projects
WHERE project_id = 'demo-shop';

-- =========================================================
-- 1. Project / Campaign / Promotion
-- =========================================================

INSERT INTO projects (
    project_id,
    project_name,
    domain,
    write_key,
    industry,
    status,
    created_at,
    updated_at
)
VALUES (
    'demo-shop',
    'Demo Hotel Booking',
    'demo.loop-ad.local',
    'wk_demo_local',
    'hotel_booking',
    'active',
    TIMESTAMPTZ '2026-07-01 00:00:00+09',
    TIMESTAMPTZ '2026-07-01 00:00:00+09'
);

INSERT INTO campaigns (
    campaign_id,
    project_id,
    name,
    objective,
    target_audience,
    start_date,
    end_date,
    primary_metric,
    status,
    created_at,
    updated_at
)
VALUES (
    'cmp_summer_family_2026',
    'demo-shop',
    'Summer Family Hotel Boost',
    'Increase booking conversion for hotel detail visitors during summer travel demand.',
    'existing_users',
    DATE '2026-07-01',
    DATE '2026-08-31',
    'booking_conversion_rate',
    'active',
    TIMESTAMPTZ '2026-07-01 09:00:00+09',
    TIMESTAMPTZ '2026-07-03 09:00:00+09'
);

INSERT INTO promotions (
    promotion_id,
    project_id,
    campaign_id,
    channel,
    marketing_theme,
    target_audience,
    goal_metric,
    goal_target_value,
    goal_basis,
    min_sample_size,
    max_loop_count,
    message_brief,
    offer_type,
    landing_url,
    landing_type,
    budget_json,
    metadata_json,
    status,
    created_at,
    updated_at
)
VALUES (
    'promo_family_breakfast',
    'demo-shop',
    'cmp_summer_family_2026',
    'onsite_banner',
    'summer_family_trip',
    'existing_users',
    'booking_conversion_rate',
    0.085000,
    'promotion_average',
    100,
    3,
    'Promote breakfast-included family rooms to users comparing hotel detail pages.',
    'free_breakfast',
    '/promotions/family-breakfast',
    'hotel_detail_page',
    '{"daily_budget_krw": 500000, "max_cpa_krw": 28000}'::jsonb,
    '{"seed_source": "postgres/dummy.sql", "owner": "dashboard-demo"}'::jsonb,
    'running',
    TIMESTAMPTZ '2026-07-01 09:20:00+09',
    TIMESTAMPTZ '2026-07-03 10:10:00+09'
);

-- =========================================================
-- 2. Segment query previews / definitions
-- =========================================================

INSERT INTO segment_query_previews (
    query_preview_id,
    project_id,
    created_by,
    natural_language_query,
    generated_sql,
    query_params_json,
    base_time_from,
    base_time_to,
    sample_size,
    total_eligible_user_count,
    sample_ratio,
    sample_size_status,
    result_columns_json,
    result_preview_json,
    status,
    created_at
)
VALUES
(
    'preview_family_trip',
    'demo-shop',
    'operator-demo',
    'Users searching for rooms for at least two adults and one child within the next 14 days.',
    'SELECT user_id FROM hotel_marketing_profiles WHERE srch_children_cnt > 0 AND days_until_checkin BETWEEN 0 AND 14',
    '{"days_until_checkin_max": 14, "min_children": 1}'::jsonb,
    TIMESTAMPTZ '2026-07-01 00:00:00+09',
    TIMESTAMPTZ '2026-07-03 00:00:00+09',
    1840,
    92000,
    0.020000,
    'valid',
    '[{"name":"user_id","type":"string"},{"name":"hotel_cluster","type":"uint8"}]'::jsonb,
    '[{"user_id":"user_family_001","hotel_cluster":41},{"user_id":"user_family_002","hotel_cluster":41}]'::jsonb,
    'saved',
    TIMESTAMPTZ '2026-07-02 09:00:00+09'
),
(
    'preview_near_checkin',
    'demo-shop',
    'operator-demo',
    'Mobile users with check-in date within seven days who viewed hotel detail pages.',
    'SELECT user_id FROM hotel_marketing_profiles WHERE is_mobile = 1 AND days_until_checkin BETWEEN 0 AND 7',
    '{"days_until_checkin_max": 7, "device_type": "mobile"}'::jsonb,
    TIMESTAMPTZ '2026-07-01 00:00:00+09',
    TIMESTAMPTZ '2026-07-03 00:00:00+09',
    1265,
    92000,
    0.013750,
    'valid',
    '[{"name":"user_id","type":"string"},{"name":"days_until_checkin","type":"int32"}]'::jsonb,
    '[{"user_id":"user_mobile_001","days_until_checkin":2},{"user_id":"user_mobile_002","days_until_checkin":5}]'::jsonb,
    'saved',
    TIMESTAMPTZ '2026-07-02 09:10:00+09'
);

INSERT INTO segment_definitions (
    segment_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_name,
    source,
    query_preview_id,
    natural_language_query,
    generated_sql,
    rule_json,
    profile_json,
    sample_size,
    total_eligible_user_count,
    sample_ratio,
    status,
    created_at,
    updated_at
)
VALUES
(
    'seg_existing_all',
    'demo-shop',
    NULL,
    NULL,
    'All Existing Users',
    'system_default',
    NULL,
    'Fallback segment for every active user.',
    'SELECT user_id FROM users WHERE status = ''active''',
    '{"type":"default","matches":"all"}'::jsonb,
    '{"primary_segment":"seg_existing_all"}'::jsonb,
    92000,
    92000,
    1.000000,
    'active',
    TIMESTAMPTZ '2026-07-01 09:00:00+09',
    TIMESTAMPTZ '2026-07-01 09:00:00+09'
),
(
    'seg_family_trip',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'Family Trip Planners',
    'custom_chatkit',
    'preview_family_trip',
    'Users searching for rooms for at least two adults and one child within the next 14 days.',
    'SELECT user_id FROM hotel_marketing_profiles WHERE srch_children_cnt > 0 AND days_until_checkin BETWEEN 0 AND 14',
    '{"srch_children_cnt":{"gte":1},"days_until_checkin":{"between":[0,14]}}'::jsonb,
    '{"trip_type":"family","dominant_device":"mobile","top_hotel_cluster":41}'::jsonb,
    1840,
    92000,
    0.020000,
    'active',
    TIMESTAMPTZ '2026-07-02 09:05:00+09',
    TIMESTAMPTZ '2026-07-02 09:05:00+09'
),
(
    'seg_near_checkin_mobile',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'Near Check-in Mobile Users',
    'custom_chatkit',
    'preview_near_checkin',
    'Mobile users with check-in date within seven days who viewed hotel detail pages.',
    'SELECT user_id FROM hotel_marketing_profiles WHERE is_mobile = 1 AND days_until_checkin BETWEEN 0 AND 7',
    '{"is_mobile":1,"days_until_checkin":{"between":[0,7]}}'::jsonb,
    '{"trip_type":"last_minute","dominant_device":"mobile","price_sensitivity":"high"}'::jsonb,
    1265,
    92000,
    0.013750,
    'active',
    TIMESTAMPTZ '2026-07-02 09:15:00+09',
    TIMESTAMPTZ '2026-07-02 09:15:00+09'
);

-- =========================================================
-- 3. Funnel setup
-- =========================================================

INSERT INTO funnel_definitions (
    funnel_id,
    project_id,
    campaign_id,
    promotion_id,
    funnel_name,
    domain_type,
    channel,
    landing_type,
    status,
    created_at,
    updated_at
)
VALUES (
    'funnel_family_booking',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'Hotel Detail to Booking Complete',
    'hotel_booking',
    'onsite_banner',
    'hotel_detail_page',
    'active',
    TIMESTAMPTZ '2026-07-02 09:30:00+09',
    TIMESTAMPTZ '2026-07-02 09:30:00+09'
);

INSERT INTO funnel_steps (
    funnel_id,
    step_order,
    step_name,
    event_name,
    condition_json,
    created_at
)
VALUES
('funnel_family_booking', 1, 'Promotion Impression', 'promotion_impression', '{"channel":"onsite_banner"}'::jsonb, TIMESTAMPTZ '2026-07-02 09:30:00+09'),
('funnel_family_booking', 2, 'Promotion Click', 'promotion_click', '{"channel":"onsite_banner"}'::jsonb, TIMESTAMPTZ '2026-07-02 09:30:00+09'),
('funnel_family_booking', 3, 'Campaign Landing', 'campaign_landing', '{"landing_type":"hotel_detail_page"}'::jsonb, TIMESTAMPTZ '2026-07-02 09:30:00+09'),
('funnel_family_booking', 4, 'Booking Start', 'booking_start', '{}'::jsonb, TIMESTAMPTZ '2026-07-02 09:30:00+09'),
('funnel_family_booking', 5, 'Booking Complete', 'booking_complete', '{}'::jsonb, TIMESTAMPTZ '2026-07-02 09:30:00+09');

-- =========================================================
-- 4. ChatKit session / messages / action run
-- =========================================================

INSERT INTO ai_chat_sessions (
    chat_session_id,
    project_id,
    user_id,
    chatkit_thread_id,
    context_json,
    status,
    created_at,
    updated_at
)
VALUES (
    'chat_demo_family_segment',
    'demo-shop',
    'operator-demo',
    'thread_demo_family_segment',
    '{"campaign_id":"cmp_summer_family_2026","promotion_id":"promo_family_breakfast"}'::jsonb,
    'closed',
    TIMESTAMPTZ '2026-07-02 08:50:00+09',
    TIMESTAMPTZ '2026-07-02 09:20:00+09'
);

INSERT INTO ai_chat_messages (
    chat_session_id,
    role,
    content,
    metadata_json,
    created_at
)
VALUES
(
    'chat_demo_family_segment',
    'user',
    'Find hotel users likely to book family rooms soon.',
    '{"seed_source":"postgres/dummy.sql"}'::jsonb,
    TIMESTAMPTZ '2026-07-02 08:51:00+09'
),
(
    'chat_demo_family_segment',
    'assistant',
    'I found a family trip segment with valid sample size and saved it for this promotion.',
    '{"query_preview_id":"preview_family_trip","segment_id":"seg_family_trip"}'::jsonb,
    TIMESTAMPTZ '2026-07-02 08:53:00+09'
);

INSERT INTO ai_action_runs (
    action_run_id,
    chat_session_id,
    project_id,
    action_type,
    input_json,
    output_json,
    requires_confirmation,
    confirmed_at,
    status,
    created_at,
    updated_at
)
VALUES (
    'action_create_family_segment',
    'chat_demo_family_segment',
    'demo-shop',
    'create_segment_definition',
    '{"natural_language_query":"Users searching family rooms within 14 days"}'::jsonb,
    '{"query_preview_id":"preview_family_trip","segment_id":"seg_family_trip"}'::jsonb,
    true,
    TIMESTAMPTZ '2026-07-02 08:58:00+09',
    'completed',
    TIMESTAMPTZ '2026-07-02 08:55:00+09',
    TIMESTAMPTZ '2026-07-02 09:05:00+09'
);

-- =========================================================
-- 5. Decision analysis / suggestions / vectors / confirmed target segments
-- =========================================================

INSERT INTO promotion_analyses (
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    focus_segment_ids_json,
    operator_instruction,
    input_snapshot_json,
    profile_summary_json,
    output_json,
    status,
    created_at,
    updated_at
)
VALUES (
    'analysis_family_breakfast_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    '["seg_family_trip","seg_near_checkin_mobile"]'::jsonb,
    'Prioritize segments that are close to booking and likely to respond to breakfast value.',
    '{"window_start":"2026-07-01T00:00:00+09:00","window_end":"2026-07-03T00:00:00+09:00"}'::jsonb,
    '{"segments_analyzed":2,"dominant_signal":"hotel_detail_view_to_booking_start_drop"}'::jsonb,
    '{"recommended_segments":["seg_family_trip","seg_near_checkin_mobile"],"confidence":0.84}'::jsonb,
    'completed',
    TIMESTAMPTZ '2026-07-02 10:00:00+09',
    TIMESTAMPTZ '2026-07-02 10:07:00+09'
);

INSERT INTO segment_vectors (
    segment_vector_id,
    project_id,
    segment_id,
    promotion_id,
    promotion_run_id,
    analysis_id,
    vector_dim,
    vector_values,
    vector_version,
    source,
    created_at
)
SELECT
    v.segment_vector_id,
    'demo-shop',
    v.segment_id,
    'promo_family_breakfast',
    NULL,
    'analysis_family_breakfast_001',
    64,
    (
        SELECT jsonb_agg(
            CASE
                WHEN v.segment_id = 'seg_family_trip' AND gs.i % 4 IN (0, 1) THEN 0.82
                WHEN v.segment_id = 'seg_family_trip' THEN 0.18
                WHEN v.segment_id = 'seg_near_checkin_mobile' AND gs.i % 4 IN (1, 2) THEN 0.74
                WHEN v.segment_id = 'seg_near_checkin_mobile' THEN 0.22
                ELSE 0.25
            END
            ORDER BY gs.i
        )
        FROM generate_series(0, 63) AS gs(i)
    ),
    'hotel_rec_promo.v1',
    'fixture',
    TIMESTAMPTZ '2026-07-02 10:08:00+09'
FROM (
    VALUES
    ('vec_family_trip_001', 'seg_family_trip'),
    ('vec_near_checkin_001', 'seg_near_checkin_mobile')
) AS v(segment_vector_id, segment_id);

INSERT INTO promotion_segment_suggestions (
    suggestion_id,
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_id,
    suggested_rank,
    suggestion_source,
    status,
    score_json,
    reason_json,
    metadata_json,
    created_at,
    updated_at,
    decided_at
)
VALUES
(
    'sugg_family_breakfast_family_trip',
    'analysis_family_breakfast_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'seg_family_trip',
    1,
    'ai_ranked_existing',
    'confirmed',
    '{"fit_score":0.91,"sample_size":1840}'::jsonb,
    '{"summary":"Family planners match the breakfast-inclusive promotion and have enough sample size."}'::jsonb,
    '{"seed_source":"postgres/dummy.sql"}'::jsonb,
    TIMESTAMPTZ '2026-07-02 10:07:00+09',
    TIMESTAMPTZ '2026-07-02 10:09:00+09',
    TIMESTAMPTZ '2026-07-02 10:09:00+09'
),
(
    'sugg_family_breakfast_near_checkin',
    'analysis_family_breakfast_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'seg_near_checkin_mobile',
    2,
    'ai_ranked_existing',
    'confirmed',
    '{"fit_score":0.83,"sample_size":1265}'::jsonb,
    '{"summary":"Near check-in mobile users show urgency and high hotel-detail engagement."}'::jsonb,
    '{"seed_source":"postgres/dummy.sql"}'::jsonb,
    TIMESTAMPTZ '2026-07-02 10:07:00+09',
    TIMESTAMPTZ '2026-07-02 10:09:00+09',
    TIMESTAMPTZ '2026-07-02 10:09:00+09'
);

INSERT INTO promotion_target_segments (
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_id,
    segment_name,
    segment_vector_id,
    rule_json,
    profile_json,
    content_brief_json,
    data_evidence_json,
    estimated_size,
    priority,
    status,
    suggestion_id,
    confirmed_by,
    confirmed_at,
    created_at
)
VALUES
(
    'analysis_family_breakfast_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'seg_family_trip',
    'Family Trip Planners',
    'vec_family_trip_001',
    '{"srch_children_cnt":{"gte":1},"days_until_checkin":{"between":[0,14]}}'::jsonb,
    '{"trip_type":"family","top_hotel_cluster":41}'::jsonb,
    '{"angle":"free breakfast for children","tone":"warm and practical"}'::jsonb,
    '{"baseline_booking_conversion_rate":0.061,"detail_to_start_drop":0.42}'::jsonb,
    1840,
    'high',
    'running',
    'sugg_family_breakfast_family_trip',
    'operator-demo',
    TIMESTAMPTZ '2026-07-02 10:09:00+09',
    TIMESTAMPTZ '2026-07-02 10:09:00+09'
),
(
    'analysis_family_breakfast_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'seg_near_checkin_mobile',
    'Near Check-in Mobile Users',
    'vec_near_checkin_001',
    '{"is_mobile":1,"days_until_checkin":{"between":[0,7]}}'::jsonb,
    '{"trip_type":"last_minute","price_sensitivity":"high"}'::jsonb,
    '{"angle":"limited-time breakfast bundle","tone":"clear and urgent"}'::jsonb,
    '{"baseline_booking_conversion_rate":0.057,"detail_to_start_drop":0.39}'::jsonb,
    1265,
    'medium',
    'running',
    'sugg_family_breakfast_near_checkin',
    'operator-demo',
    TIMESTAMPTZ '2026-07-02 10:09:00+09',
    TIMESTAMPTZ '2026-07-02 10:09:00+09'
);

-- =========================================================
-- 6. Generation / content candidates
-- =========================================================

INSERT INTO generation_runs (
    generation_id,
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    content_option_count,
    operator_instruction,
    input_json,
    output_json,
    generation_report_json,
    status,
    created_at,
    updated_at
)
VALUES (
    'gen_family_breakfast_001',
    'analysis_family_breakfast_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    2,
    'Generate concise onsite banner copy for selected hotel booking segments.',
    '{"segments":["seg_family_trip","seg_near_checkin_mobile"],"channel":"onsite_banner"}'::jsonb,
    '{"content_ids":["content_family_breakfast_a","content_near_checkin_a"]}'::jsonb,
    '{"model":"seed","passed_brand_check":true,"passed_schema_check":true}'::jsonb,
    'completed',
    TIMESTAMPTZ '2026-07-02 10:12:00+09',
    TIMESTAMPTZ '2026-07-02 10:16:00+09'
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
    title,
    body,
    cta,
    image_prompt,
    landing_url,
    generation_prompt,
    reason_summary,
    data_evidence_json,
    message_strategy,
    metadata_json,
    status,
    created_at,
    updated_at
)
VALUES
(
    'content_family_breakfast_a',
    'variant_family_a',
    'gen_family_breakfast_001',
    'analysis_family_breakfast_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'seg_family_trip',
    'onsite_banner',
    'Breakfast included for the whole family',
    'Book a family room today and start the trip with breakfast covered.',
    'View family rooms',
    'bright hotel breakfast buffet with family-friendly room detail page banner',
    '/promotions/family-breakfast?segment=family',
    'Create onsite banner copy for family hotel shoppers.',
    'Families showed high detail views but lower booking starts; breakfast benefit reduces decision friction.',
    '{"detail_views":8420,"booking_starts":488,"conversion_gap":0.024}'::jsonb,
    'benefit_highlight',
    '{"seed_source":"postgres/dummy.sql","approved_by":"operator-demo"}'::jsonb,
    'active',
    TIMESTAMPTZ '2026-07-02 10:17:00+09',
    TIMESTAMPTZ '2026-07-02 10:20:00+09'
),
(
    'content_near_checkin_a',
    'variant_mobile_a',
    'gen_family_breakfast_001',
    'analysis_family_breakfast_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'seg_near_checkin_mobile',
    'onsite_banner',
    'Still need a room this week?',
    'Reserve now and get a breakfast bundle on selected stays.',
    'Book before check-in',
    'mobile hotel booking banner with clear limited-time breakfast bundle offer',
    '/promotions/family-breakfast?segment=near-checkin',
    'Create onsite banner copy for near check-in mobile users.',
    'Mobile users close to check-in respond better to immediate value and simple booking CTA.',
    '{"detail_views":5110,"booking_starts":292,"conversion_gap":0.019}'::jsonb,
    'urgency_plus_value',
    '{"seed_source":"postgres/dummy.sql","approved_by":"operator-demo"}'::jsonb,
    'active',
    TIMESTAMPTZ '2026-07-02 10:17:00+09',
    TIMESTAMPTZ '2026-07-02 10:20:00+09'
);

-- =========================================================
-- 7. Promotion run / ad experiments
-- =========================================================

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
    started_at,
    ended_at,
    created_at,
    updated_at
)
VALUES (
    'run_family_20260702',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'analysis_family_breakfast_001',
    'gen_family_breakfast_001',
    1,
    'running',
    '{"goal_metric":"booking_conversion_rate","goal_target_value":0.085,"goal_basis":"promotion_average"}'::jsonb,
    TIMESTAMPTZ '2026-07-02 11:00:00+09',
    NULL,
    TIMESTAMPTZ '2026-07-02 10:30:00+09',
    TIMESTAMPTZ '2026-07-03 10:00:00+09'
);

UPDATE segment_vectors
SET promotion_run_id = 'run_family_20260702'
WHERE project_id = 'demo-shop'
  AND promotion_id = 'promo_family_breakfast';

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
    goal_basis,
    started_at,
    ended_at,
    created_at,
    updated_at
)
VALUES
(
    'exp_family_banner_a',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    'analysis_family_breakfast_001',
    'gen_family_breakfast_001',
    'seg_family_trip',
    'Family Trip Planners',
    'content_family_breakfast_a',
    'variant_family_a',
    'onsite_banner',
    1,
    'running',
    'booking_conversion_rate',
    0.085000,
    'promotion_average',
    TIMESTAMPTZ '2026-07-02 11:00:00+09',
    NULL,
    TIMESTAMPTZ '2026-07-02 10:35:00+09',
    TIMESTAMPTZ '2026-07-03 10:00:00+09'
),
(
    'exp_near_checkin_banner_a',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    'analysis_family_breakfast_001',
    'gen_family_breakfast_001',
    'seg_near_checkin_mobile',
    'Near Check-in Mobile Users',
    'content_near_checkin_a',
    'variant_mobile_a',
    'onsite_banner',
    1,
    'approved',
    'booking_conversion_rate',
    0.085000,
    'promotion_average',
    TIMESTAMPTZ '2026-07-02 11:00:00+09',
    NULL,
    TIMESTAMPTZ '2026-07-02 10:35:00+09',
    TIMESTAMPTZ '2026-07-03 10:00:00+09'
);

-- =========================================================
-- 8. Evaluations
-- =========================================================

INSERT INTO promotion_evaluations (
    evaluation_id,
    project_id,
    campaign_id,
    promotion_id,
    promotion_run_id,
    ad_experiment_id,
    segment_id,
    content_id,
    content_option_id,
    metric,
    target_value,
    actual_value,
    numerator_count,
    denominator_count,
    sample_size,
    basis,
    status,
    feedback,
    next_loop_required,
    result_json,
    created_at
)
VALUES
(
    'eval_family_booking_conversion',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    'exp_family_banner_a',
    'seg_family_trip',
    'content_family_breakfast_a',
    'variant_family_a',
    'booking_conversion_rate',
    0.085000,
    0.091300,
    168,
    1840,
    1840,
    'promotion_average',
    'goal_met',
    'Family breakfast banner exceeded the booking conversion target.',
    false,
    '{"baseline":0.061,"lift":0.0303}'::jsonb,
    TIMESTAMPTZ '2026-07-03 09:00:00+09'
),
(
    'eval_near_checkin_booking_conversion',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    'exp_near_checkin_banner_a',
    'seg_near_checkin_mobile',
    'content_near_checkin_a',
    'variant_mobile_a',
    'booking_conversion_rate',
    0.085000,
    0.079800,
    101,
    1265,
    1265,
    'promotion_average',
    'goal_near',
    'Near check-in mobile segment is close to target but may need stronger urgency copy.',
    true,
    '{"baseline":0.057,"lift":0.0228}'::jsonb,
    TIMESTAMPTZ '2026-07-03 09:00:00+09'
),
(
    'eval_run_click_rate',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    NULL,
    NULL,
    NULL,
    NULL,
    'promotion_click_rate',
    0.045000,
    0.052000,
    161,
    3105,
    3105,
    'all_segments',
    'partial_goal_met',
    'Aggregate click rate is healthy while one conversion segment still needs another loop.',
    true,
    '{"promotion_impressions":3105,"promotion_clicks":161}'::jsonb,
    TIMESTAMPTZ '2026-07-03 09:05:00+09'
);

-- =========================================================
-- 9. Ad serving assignments / dispatch jobs / redirects
-- =========================================================

INSERT INTO user_segment_assignments (
    project_id,
    promotion_run_id,
    user_id,
    segment_id,
    ad_experiment_id,
    content_id,
    content_option_id,
    similarity_score,
    fallback,
    assignment_source,
    assigned_at,
    expires_at
)
VALUES
(
    'demo-shop',
    'run_family_20260702',
    'user_family_001',
    'seg_family_trip',
    'exp_family_banner_a',
    'content_family_breakfast_a',
    'variant_family_a',
    0.941200,
    false,
    'decision_batch',
    TIMESTAMPTZ '2026-07-02 11:05:00+09',
    TIMESTAMPTZ '2026-08-31 23:59:59+09'
),
(
    'demo-shop',
    'run_family_20260702',
    'user_mobile_001',
    'seg_near_checkin_mobile',
    'exp_near_checkin_banner_a',
    'content_near_checkin_a',
    'variant_mobile_a',
    0.887500,
    false,
    'decision_batch',
    TIMESTAMPTZ '2026-07-02 11:05:00+09',
    TIMESTAMPTZ '2026-08-31 23:59:59+09'
),
(
    'demo-shop',
    'run_family_20260702',
    'user_unknown_001',
    'seg_family_trip',
    'exp_family_banner_a',
    'content_family_breakfast_a',
    'variant_family_a',
    0.620000,
    true,
    'fallback',
    TIMESTAMPTZ '2026-07-02 11:05:00+09',
    TIMESTAMPTZ '2026-08-31 23:59:59+09'
);

INSERT INTO ad_dispatch_jobs (
    ad_dispatch_job_id,
    project_id,
    campaign_id,
    promotion_id,
    promotion_run_id,
    ad_experiment_id,
    channel,
    status,
    provider,
    target_count,
    sent_count,
    failed_count,
    created_at,
    started_at,
    completed_at,
    metadata_json
)
VALUES
(
    'dispatch_family_banner_20260702',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    'exp_family_banner_a',
    'onsite_banner',
    'running',
    'dashboard-onsite',
    1840,
    842,
    0,
    TIMESTAMPTZ '2026-07-02 11:00:00+09',
    TIMESTAMPTZ '2026-07-02 11:02:00+09',
    NULL,
    '{"placement_key":"hotel_detail_top","seed_source":"postgres/dummy.sql"}'::jsonb
),
(
    'dispatch_near_checkin_banner_20260702',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    'exp_near_checkin_banner_a',
    'onsite_banner',
    'scheduled',
    'dashboard-onsite',
    1265,
    0,
    0,
    TIMESTAMPTZ '2026-07-02 11:00:00+09',
    NULL,
    NULL,
    '{"placement_key":"hotel_detail_top","seed_source":"postgres/dummy.sql"}'::jsonb
);

INSERT INTO redirect_links (
    redirect_id,
    project_id,
    campaign_id,
    promotion_id,
    promotion_run_id,
    ad_experiment_id,
    user_id,
    segment_id,
    content_id,
    content_option_id,
    target_url,
    created_at,
    expires_at
)
VALUES
(
    'redir_family_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    'exp_family_banner_a',
    'user_family_001',
    'seg_family_trip',
    'content_family_breakfast_a',
    'variant_family_a',
    '/hotels/hotel_kr_1207?promo=family-breakfast',
    TIMESTAMPTZ '2026-07-02 11:06:00+09',
    TIMESTAMPTZ '2026-08-31 23:59:59+09'
),
(
    'redir_mobile_001',
    'demo-shop',
    'cmp_summer_family_2026',
    'promo_family_breakfast',
    'run_family_20260702',
    'exp_near_checkin_banner_a',
    'user_mobile_001',
    'seg_near_checkin_mobile',
    'content_near_checkin_a',
    'variant_mobile_a',
    '/hotels/search?promo=family-breakfast&checkin=soon',
    TIMESTAMPTZ '2026-07-02 11:06:00+09',
    TIMESTAMPTZ '2026-08-31 23:59:59+09'
);

-- =========================================================
-- 10. Event validation errors
-- =========================================================

INSERT INTO event_validation_errors (
    project_id,
    event_id,
    event_name,
    error_code,
    error_message,
    payload_json,
    created_at
)
VALUES
(
    'demo-shop',
    'evt_pg_bad_0001',
    'booking_complete',
    'missing_booking_id',
    'booking_complete requires properties.booking_id',
    '{"seed_source":"postgres/dummy.sql","event_name":"booking_complete","properties":{"hotel_id":"hotel_kr_1207","revenue":"567000","currency":"KRW"}}'::jsonb,
    TIMESTAMPTZ '2026-07-02 12:00:00+09'
),
(
    'demo-shop',
    'evt_pg_bad_0002',
    'promotion_click',
    'missing_promotion_run_id',
    'promotion_click requires properties.promotion_run_id',
    '{"seed_source":"postgres/dummy.sql","event_name":"promotion_click","properties":{"campaign_id":"cmp_summer_family_2026","promotion_id":"promo_family_breakfast"}}'::jsonb,
    TIMESTAMPTZ '2026-07-02 12:05:00+09'
);

COMMIT;
