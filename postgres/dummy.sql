-- =========================================================
-- Loop-Ad PostgreSQL Dummy Data
-- Domain: hotel / accommodation booking
--
-- Purpose:
-- - Creates demo service hierarchy for local/ECS demo.
-- - Seeds Dashboard-facing manual next-loop fixture scenarios.
--
-- Created hierarchy:
--   project -> campaign -> promotions -> system_default segments -> funnels
--
-- Fixture scenarios:
-- - email: A1 serving while A2 content approval is pending
-- - onsite banner: A1 retired and lineage-backed A2 serving
-- - sms: rejected preparation and provenance-free insufficient_data exclusion
-- =========================================================

BEGIN;

-- =========================================================
-- 1. Project
-- =========================================================
INSERT INTO projects (
    project_id,
    project_name,
    domain,
    write_key,
    industry,
    status
)
VALUES (
    'demo_project',
    'LoopAd Expedia Hotel Demo',
    'demo.loopad.local',
    'demo_write_key_expedia',
    'hotel_booking',
    'active'
)
ON CONFLICT (project_id) DO UPDATE SET
    project_name = EXCLUDED.project_name,
    domain = EXCLUDED.domain,
    write_key = EXCLUDED.write_key,
    industry = EXCLUDED.industry,
    status = EXCLUDED.status,
    updated_at = now();

-- =========================================================
-- 2. Campaign
-- =========================================================
INSERT INTO campaigns (
    campaign_id,
    project_id,
    name,
    objective,
    target_audience,
    start_date,
    end_date,
    primary_metric,
    status
)
VALUES (
    'camp_expedia_hotel_demo',
    'demo_project',
    'Expedia Hotel Booking Demo Campaign',
    'Use Expedia hotel behavior data to demonstrate AI segment suggestion and promotion loop.',
    'existing_users',
    CURRENT_DATE,
    CURRENT_DATE + INTERVAL '30 days',
    'booking_conversion_rate',
    'active'
)
ON CONFLICT (campaign_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    name = EXCLUDED.name,
    objective = EXCLUDED.objective,
    target_audience = EXCLUDED.target_audience,
    start_date = EXCLUDED.start_date,
    end_date = EXCLUDED.end_date,
    primary_metric = EXCLUDED.primary_metric,
    status = EXCLUDED.status,
    updated_at = now();

-- =========================================================
-- 3. Promotions
-- =========================================================
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
    status
)
VALUES
(
    'promo_expedia_email_reactivation',
    'demo_project',
    'camp_expedia_hotel_demo',
    'email',
    'hotel_reactivation',
    'existing_users',
    'booking_conversion_rate',
    0.050000,
    'all_segments',
    100,
    3,
    'Reactivate users with high hotel booking propensity using personalized email content.',
    'limited_time_discount',
    'https://demo.loopad.local/hotels',
    'search_page',
    '{"currency": "KRW", "max_daily_budget": 500000}'::jsonb,
    '{"dataset": "kaggle_expedia_hotel_recommendations", "demo": true}'::jsonb,
    'analysis_ready'
),
(
    'promo_expedia_onsite_last_minute',
    'demo_project',
    'camp_expedia_hotel_demo',
    'onsite_banner',
    'last_minute_hotel',
    'existing_users',
    'inflow_rate',
    0.080000,
    'all_segments',
    100,
    3,
    'Show onsite banner to users with near check-in intent and strong hotel browsing behavior.',
    'last_minute_deal',
    'https://demo.loopad.local/hotels/last-minute',
    'hotel_detail_page',
    '{"currency": "KRW", "max_daily_budget": 700000}'::jsonb,
    '{"dataset": "kaggle_expedia_hotel_recommendations", "demo": true}'::jsonb,
    'analysis_ready'
),
(
    'promo_expedia_sms_near_checkin',
    'demo_project',
    'camp_expedia_hotel_demo',
    'sms',
    'near_checkin_reminder',
    'existing_users',
    'booking_conversion_rate',
    0.040000,
    'all_segments',
    100,
    3,
    'Send concise SMS offers to users with near check-in hotel search patterns.',
    'mobile_coupon',
    'https://demo.loopad.local/hotels/mobile-offer',
    'booking_resume',
    '{"currency": "KRW", "max_daily_budget": 300000}'::jsonb,
    '{"dataset": "kaggle_expedia_hotel_recommendations", "demo": true}'::jsonb,
    'analysis_ready'
)
ON CONFLICT (promotion_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    campaign_id = EXCLUDED.campaign_id,
    channel = EXCLUDED.channel,
    marketing_theme = EXCLUDED.marketing_theme,
    target_audience = EXCLUDED.target_audience,
    goal_metric = EXCLUDED.goal_metric,
    goal_target_value = EXCLUDED.goal_target_value,
    goal_basis = EXCLUDED.goal_basis,
    min_sample_size = EXCLUDED.min_sample_size,
    max_loop_count = EXCLUDED.max_loop_count,
    message_brief = EXCLUDED.message_brief,
    offer_type = EXCLUDED.offer_type,
    landing_url = EXCLUDED.landing_url,
    landing_type = EXCLUDED.landing_type,
    budget_json = EXCLUDED.budget_json,
    metadata_json = EXCLUDED.metadata_json,
    status = EXCLUDED.status,
    updated_at = now();

-- =========================================================
-- 4. System Default Segment Definitions
-- =========================================================
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
    status
)
VALUES
(
    'seg_existing_all',
    NULL,
    NULL,
    NULL,
    'All existing hotel users',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "all_existing_users"}'::jsonb,
    '{"description": "All users available in the hotel booking behavior dataset."}'::jsonb,
    0,
    0,
    0,
    'active'
),
(
    'seg_mobile_user',
    'demo_project',
    NULL,
    NULL,
    'Mobile hotel users',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "field_filter", "field": "is_mobile", "operator": "eq", "value": 1}'::jsonb,
    '{"description": "Users who frequently search hotels on mobile devices."}'::jsonb,
    0,
    0,
    0,
    'active'
),
(
    'seg_family_trip',
    'demo_project',
    NULL,
    NULL,
    'Family trip planners',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "field_filter", "field": "srch_children_cnt", "operator": "gt", "value": 0}'::jsonb,
    '{"description": "Users searching hotel stays with children."}'::jsonb,
    0,
    0,
    0,
    'active'
),
(
    'seg_package_trip',
    'demo_project',
    NULL,
    NULL,
    'Package trip users',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "field_filter", "field": "is_package", "operator": "eq", "value": 1}'::jsonb,
    '{"description": "Users who search hotel stays as part of package trips."}'::jsonb,
    0,
    0,
    0,
    'active'
),
(
    'seg_near_checkin',
    'demo_project',
    NULL,
    NULL,
    'Near check-in users',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "date_diff_filter", "field": "days_until_checkin", "operator": "between", "min": 0, "max": 7}'::jsonb,
    '{"description": "Users whose hotel check-in date is near."}'::jsonb,
    0,
    0,
    0,
    'active'
),
(
    'seg_long_stay',
    'demo_project',
    NULL,
    NULL,
    'Long stay hotel users',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "date_diff_filter", "field": "stay_nights", "operator": "gte", "value": 4}'::jsonb,
    '{"description": "Users searching longer hotel stays."}'::jsonb,
    0,
    0,
    0,
    'active'
),
(
    'seg_couple_trip',
    'demo_project',
    NULL,
    NULL,
    'Couple trip planners',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "field_filter", "conditions": [{"field": "srch_adults_cnt", "operator": "eq", "value": 2}, {"field": "srch_children_cnt", "operator": "eq", "value": 0}, {"field": "srch_rm_cnt", "operator": "eq", "value": 1}]}'::jsonb,
    '{"description": "Users searching two-person hotel stays."}'::jsonb,
    0,
    0,
    0,
    'active'
),
(
    'seg_repeat_hotel_no_booking',
    'demo_project',
    NULL,
    NULL,
    'Repeat hotel browsers without recent booking',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "behavior_filter", "conditions": [{"field": "hotel_search_count", "operator": "gte", "value": 2}, {"field": "recent_booking_count", "operator": "eq", "value": 0}]}'::jsonb,
    '{"description": "Users with repeated hotel browsing behavior and no recent completed booking."}'::jsonb,
    0,
    0,
    0,
    'active'
)
ON CONFLICT (segment_id) DO UPDATE SET
    project_id = CASE
        WHEN segment_definitions.segment_id = 'seg_existing_all' THEN NULL
        ELSE EXCLUDED.project_id
    END,
    campaign_id = EXCLUDED.campaign_id,
    promotion_id = EXCLUDED.promotion_id,
    segment_name = EXCLUDED.segment_name,
    source = EXCLUDED.source,
    query_preview_id = EXCLUDED.query_preview_id,
    natural_language_query = EXCLUDED.natural_language_query,
    generated_sql = EXCLUDED.generated_sql,
    rule_json = EXCLUDED.rule_json,
    profile_json = EXCLUDED.profile_json,
    sample_size = EXCLUDED.sample_size,
    total_eligible_user_count = EXCLUDED.total_eligible_user_count,
    sample_ratio = EXCLUDED.sample_ratio,
    status = EXCLUDED.status,
    updated_at = now();

-- =========================================================
-- 5. Funnel Definitions
-- Dashboard-owned setup data that can be used by funnel views/evaluation.
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
    status
)
VALUES
(
    'funnel_expedia_email_reactivation',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_email_reactivation',
    'Email hotel reactivation funnel',
    'hotel_booking',
    'email',
    'search_page',
    'active'
),
(
    'funnel_expedia_onsite_last_minute',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_onsite_last_minute',
    'Onsite last-minute hotel funnel',
    'hotel_booking',
    'onsite_banner',
    'hotel_detail_page',
    'active'
),
(
    'funnel_expedia_sms_near_checkin',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    'SMS near check-in hotel funnel',
    'hotel_booking',
    'sms',
    'booking_resume',
    'active'
)
ON CONFLICT (funnel_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    campaign_id = EXCLUDED.campaign_id,
    promotion_id = EXCLUDED.promotion_id,
    funnel_name = EXCLUDED.funnel_name,
    domain_type = EXCLUDED.domain_type,
    channel = EXCLUDED.channel,
    landing_type = EXCLUDED.landing_type,
    status = EXCLUDED.status,
    updated_at = now();

-- Re-seed funnel steps idempotently because the table has a generated primary key
-- and a unique constraint on (funnel_id, step_order).
INSERT INTO funnel_steps (
    funnel_id,
    step_order,
    step_name,
    event_name,
    condition_json
)
VALUES
('funnel_expedia_email_reactivation', 1, 'Promotion impression', 'promotion_impression', '{"channel": "email"}'::jsonb),
('funnel_expedia_email_reactivation', 2, 'Promotion click', 'promotion_click', '{"channel": "email"}'::jsonb),
('funnel_expedia_email_reactivation', 3, 'Campaign landing', 'campaign_landing', '{"landing_type": "search_page"}'::jsonb),
('funnel_expedia_email_reactivation', 4, 'Booking complete', 'booking_complete', '{}'::jsonb),

('funnel_expedia_onsite_last_minute', 1, 'Promotion impression', 'promotion_impression', '{"channel": "onsite_banner"}'::jsonb),
('funnel_expedia_onsite_last_minute', 2, 'Promotion click', 'promotion_click', '{"channel": "onsite_banner"}'::jsonb),
('funnel_expedia_onsite_last_minute', 3, 'Hotel detail view', 'hotel_detail_view', '{"landing_type": "hotel_detail_page"}'::jsonb),
('funnel_expedia_onsite_last_minute', 4, 'Booking complete', 'booking_complete', '{}'::jsonb),

('funnel_expedia_sms_near_checkin', 1, 'Promotion impression', 'promotion_impression', '{"channel": "sms"}'::jsonb),
('funnel_expedia_sms_near_checkin', 2, 'Promotion click', 'promotion_click', '{"channel": "sms"}'::jsonb),
('funnel_expedia_sms_near_checkin', 3, 'Booking resume', 'booking_start', '{"landing_type": "booking_resume"}'::jsonb),
('funnel_expedia_sms_near_checkin', 4, 'Booking complete', 'booking_complete', '{}'::jsonb)
ON CONFLICT (funnel_id, step_order) DO UPDATE SET
    step_name = EXCLUDED.step_name,
    event_name = EXCLUDED.event_name,
    condition_json = EXCLUDED.condition_json;

-- =========================================================
-- 6. Manual next-loop Dashboard fixtures
-- These rows are local-only examples for the three documented scenarios.
-- =========================================================

UPDATE promotions
SET status = CASE promotion_id
    WHEN 'promo_expedia_email_reactivation' THEN 'content_ready'
    WHEN 'promo_expedia_onsite_last_minute' THEN 'running'
    WHEN 'promo_expedia_sms_near_checkin' THEN 'goal_not_met'
    ELSE status
END,
updated_at = now()
WHERE promotion_id IN (
    'promo_expedia_email_reactivation',
    'promo_expedia_onsite_last_minute',
    'promo_expedia_sms_near_checkin'
);

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
    status
)
VALUES
(
    'analysis_email_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_email_reactivation',
    '["seg_mobile_user"]'::jsonb,
    'Create the first email loop for mobile hotel users.',
    '{"loop_count": 1}'::jsonb,
    '{"segment": "mobile hotel users"}'::jsonb,
    '{"result": "goal_not_met"}'::jsonb,
    'completed'
),
(
    'analysis_email_a2',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_email_reactivation',
    '["seg_mobile_user"]'::jsonb,
    'Prepare the next email loop after manual content approval.',
    '{"loop_count": 2, "source": "manual_next_loop"}'::jsonb,
    '{"segment": "mobile hotel users"}'::jsonb,
    '{"candidate_count": 3}'::jsonb,
    'completed'
),
(
    'analysis_onsite_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_onsite_last_minute',
    '["seg_near_checkin"]'::jsonb,
    'Create the first onsite loop for near check-in users.',
    '{"loop_count": 1}'::jsonb,
    '{"segment": "near check-in users"}'::jsonb,
    '{"result": "goal_not_met"}'::jsonb,
    'completed'
),
(
    'analysis_onsite_a2',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_onsite_last_minute',
    '["seg_near_checkin"]'::jsonb,
    'Prepare the activated onsite child loop.',
    '{"loop_count": 2, "source": "manual_next_loop"}'::jsonb,
    '{"segment": "near check-in users"}'::jsonb,
    '{"result": "activated"}'::jsonb,
    'completed'
),
(
    'analysis_sms_a1',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    '["seg_near_checkin", "seg_family_trip"]'::jsonb,
    'Create the first SMS loop for near check-in and family trip users.',
    '{"loop_count": 1}'::jsonb,
    '{"segments": ["near check-in users", "family trip planners"]}'::jsonb,
    '{"result": "goal_not_met"}'::jsonb,
    'completed'
),
(
    'analysis_sms_a2',
    'demo_project',
    'camp_expedia_hotel_demo',
    'promo_expedia_sms_near_checkin',
    '["seg_near_checkin"]'::jsonb,
    'Prepare an SMS next-loop candidate set that was rejected by the operator.',
    '{"loop_count": 2, "source": "manual_next_loop"}'::jsonb,
    '{"segment": "near check-in users"}'::jsonb,
    '{"result": "rejected"}'::jsonb,
    'completed'
)
ON CONFLICT (analysis_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    campaign_id = EXCLUDED.campaign_id,
    promotion_id = EXCLUDED.promotion_id,
    focus_segment_ids_json = EXCLUDED.focus_segment_ids_json,
    operator_instruction = EXCLUDED.operator_instruction,
    input_snapshot_json = EXCLUDED.input_snapshot_json,
    profile_summary_json = EXCLUDED.profile_summary_json,
    output_json = EXCLUDED.output_json,
    status = EXCLUDED.status,
    updated_at = now();

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
    priority,
    status,
    confirmed_by,
    confirmed_at
)
VALUES
('analysis_email_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'seg_mobile_user', 'Mobile hotel users', '{"type":"field_filter"}'::jsonb, '{"description":"Mobile hotel browsers"}'::jsonb, '{"channel":"email"}'::jsonb, '{"source":"fixture"}'::jsonb, 1200, 'high', 'running', 'fixture_operator', now() - interval '3 days'),
('analysis_email_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'seg_mobile_user', 'Mobile hotel users', '{"type":"field_filter"}'::jsonb, '{"description":"Mobile hotel browsers"}'::jsonb, '{"channel":"email"}'::jsonb, '{"source":"fixture"}'::jsonb, 1200, 'high', 'content_ready', NULL, NULL),
('analysis_onsite_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'seg_near_checkin', 'Near check-in users', '{"type":"date_diff_filter"}'::jsonb, '{"description":"Near check-in hotel browsers"}'::jsonb, '{"channel":"onsite_banner"}'::jsonb, '{"source":"fixture"}'::jsonb, 900, 'high', 'goal_not_met', 'fixture_operator', now() - interval '2 hours'),
('analysis_onsite_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'seg_near_checkin', 'Near check-in users', '{"type":"date_diff_filter"}'::jsonb, '{"description":"Near check-in hotel browsers"}'::jsonb, '{"channel":"onsite_banner"}'::jsonb, '{"source":"fixture"}'::jsonb, 900, 'high', 'running', 'fixture_operator', now() - interval '1 hour'),
('analysis_sms_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'seg_near_checkin', 'Near check-in users', '{"type":"date_diff_filter"}'::jsonb, '{"description":"Near check-in hotel browsers"}'::jsonb, '{"channel":"sms"}'::jsonb, '{"source":"fixture"}'::jsonb, 700, 'medium', 'goal_not_met', 'fixture_operator', now() - interval '1 day'),
('analysis_sms_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'seg_family_trip', 'Family trip planners', '{"type":"field_filter"}'::jsonb, '{"description":"Family hotel browsers"}'::jsonb, '{"channel":"sms"}'::jsonb, '{"source":"fixture"}'::jsonb, 500, 'medium', 'insufficient_data', NULL, NULL),
('analysis_sms_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'seg_near_checkin', 'Near check-in users', '{"type":"date_diff_filter"}'::jsonb, '{"description":"Near check-in hotel browsers"}'::jsonb, '{"channel":"sms"}'::jsonb, '{"source":"fixture"}'::jsonb, 700, 'medium', 'planned', NULL, NULL)
ON CONFLICT (analysis_id, segment_id) DO UPDATE SET
    segment_name = EXCLUDED.segment_name,
    rule_json = EXCLUDED.rule_json,
    profile_json = EXCLUDED.profile_json,
    content_brief_json = EXCLUDED.content_brief_json,
    data_evidence_json = EXCLUDED.data_evidence_json,
    estimated_size = EXCLUDED.estimated_size,
    priority = EXCLUDED.priority,
    status = EXCLUDED.status,
    confirmed_by = EXCLUDED.confirmed_by,
    confirmed_at = EXCLUDED.confirmed_at;

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
    started_at,
    finished_at,
    retry_count,
    next_retry_at,
    last_error_code,
    last_error_message,
    worker_id,
    lease_token,
    heartbeat_at,
    lease_expires_at,
    idempotency_key,
    request_fingerprint
)
VALUES
('generation_email_a1', 'analysis_email_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 1, 'Generate the first email candidate.', '{"schema_version":"generation.request.v1","project_id":"demo_project","campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_email_reactivation","analysis_id":"analysis_email_a1","channel":"email","loop_count":1,"brand_context":{"context_version":"v1","manifest_key":"brand-context/demo_project/manifests/v1/manifest.json"}}'::jsonb, '{"status":"completed"}'::jsonb, '{"fixture":true}'::jsonb, 'completed', now() - interval '3 days 10 minutes', now() - interval '3 days 5 minutes', 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'fixture:generation_email_a1', encode(digest(convert_to('generation_email_a1', 'UTF8'), 'sha256'), 'hex')),
('generation_email_a2', 'analysis_email_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 3, 'Generate three candidates for manual approval.', '{"schema_version":"generation.request.v1","project_id":"demo_project","campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_email_reactivation","analysis_id":"analysis_email_a2","channel":"email","loop_count":2,"brand_context":{"context_version":"v1","manifest_key":"brand-context/demo_project/manifests/v1/manifest.json"}}'::jsonb, '{"status":"completed"}'::jsonb, '{"fixture":true}'::jsonb, 'completed', now() - interval '6 hours', now() - interval '5 hours 50 minutes', 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'fixture:generation_email_a2', encode(digest(convert_to('generation_email_a2', 'UTF8'), 'sha256'), 'hex')),
('generation_onsite_a1', 'analysis_onsite_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 1, 'Generate the first onsite candidate.', '{"schema_version":"generation.request.v1","project_id":"demo_project","campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_onsite_last_minute","analysis_id":"analysis_onsite_a1","channel":"onsite_banner","loop_count":1,"brand_context":{"context_version":"v1","manifest_key":"brand-context/demo_project/manifests/v1/manifest.json"}}'::jsonb, '{"status":"completed"}'::jsonb, '{"fixture":true}'::jsonb, 'completed', now() - interval '2 days 10 minutes', now() - interval '2 days 5 minutes', 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'fixture:generation_onsite_a1', encode(digest(convert_to('generation_onsite_a1', 'UTF8'), 'sha256'), 'hex')),
('generation_onsite_a2', 'analysis_onsite_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 1, 'Generate the activated child candidate set.', '{"schema_version":"generation.request.v1","project_id":"demo_project","campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_onsite_last_minute","analysis_id":"analysis_onsite_a2","channel":"onsite_banner","loop_count":2,"brand_context":{"context_version":"v1","manifest_key":"brand-context/demo_project/manifests/v1/manifest.json"}}'::jsonb, '{"status":"completed"}'::jsonb, '{"fixture":true}'::jsonb, 'completed', now() - interval '1 hour 10 minutes', now() - interval '1 hour 5 minutes', 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'fixture:generation_onsite_a2', encode(digest(convert_to('generation_onsite_a2', 'UTF8'), 'sha256'), 'hex')),
('generation_sms_a1', 'analysis_sms_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 1, 'Generate the first SMS candidates.', '{"schema_version":"generation.request.v1","project_id":"demo_project","campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_sms_near_checkin","analysis_id":"analysis_sms_a1","channel":"sms","loop_count":1,"brand_context":{"context_version":"v1","manifest_key":"brand-context/demo_project/manifests/v1/manifest.json"}}'::jsonb, '{"status":"completed"}'::jsonb, '{"fixture":true}'::jsonb, 'completed', now() - interval '1 day 10 minutes', now() - interval '1 day 5 minutes', 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'fixture:generation_sms_a1', encode(digest(convert_to('generation_sms_a1', 'UTF8'), 'sha256'), 'hex')),
('generation_sms_a2', 'analysis_sms_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 2, 'Generate rejected next-loop candidates.', '{"schema_version":"generation.request.v1","project_id":"demo_project","campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_sms_near_checkin","analysis_id":"analysis_sms_a2","channel":"sms","loop_count":2,"brand_context":{"context_version":"v1","manifest_key":"brand-context/demo_project/manifests/v1/manifest.json"}}'::jsonb, '{"status":"completed"}'::jsonb, '{"fixture":true}'::jsonb, 'completed', now() - interval '30 minutes', now() - interval '25 minutes', 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'fixture:generation_sms_a2', encode(digest(convert_to('generation_sms_a2', 'UTF8'), 'sha256'), 'hex'))
ON CONFLICT (generation_id) DO UPDATE SET
    analysis_id = EXCLUDED.analysis_id,
    project_id = EXCLUDED.project_id,
    campaign_id = EXCLUDED.campaign_id,
    promotion_id = EXCLUDED.promotion_id,
    content_option_count = EXCLUDED.content_option_count,
    operator_instruction = EXCLUDED.operator_instruction,
    input_json = EXCLUDED.input_json,
    output_json = EXCLUDED.output_json,
    generation_report_json = EXCLUDED.generation_report_json,
    status = EXCLUDED.status,
    started_at = EXCLUDED.started_at,
    finished_at = EXCLUDED.finished_at,
    retry_count = EXCLUDED.retry_count,
    next_retry_at = EXCLUDED.next_retry_at,
    last_error_code = EXCLUDED.last_error_code,
    last_error_message = EXCLUDED.last_error_message,
    worker_id = EXCLUDED.worker_id,
    lease_token = EXCLUDED.lease_token,
    heartbeat_at = EXCLUDED.heartbeat_at,
    lease_expires_at = EXCLUDED.lease_expires_at,
    idempotency_key = EXCLUDED.idempotency_key,
    request_fingerprint = EXCLUDED.request_fingerprint,
    updated_at = now();

-- Complete the immutable request snapshot from the confirmed target rows and
-- versioned brand/model policies before deriving the request fingerprint.
UPDATE generation_runs AS gr
SET input_json = gr.input_json || jsonb_build_object(
        'content_option_count', gr.content_option_count,
        'operator_instruction', gr.operator_instruction,
        'placement', jsonb_strip_nulls(jsonb_build_object(
            'type', CASE promotion.channel
                WHEN 'email' THEN 'email_body'
                WHEN 'onsite_banner' THEN 'onsite_banner'
                WHEN 'sms' THEN 'sms_message'
            END,
            'slot_id', CASE promotion.channel
                WHEN 'onsite_banner' THEN 'C1_MAIN_TOP'
            END
        )),
        'offer', jsonb_build_object(
            'type', promotion.offer_type,
            'message_brief', promotion.message_brief
        ),
        'landing', jsonb_build_object(
            'url', promotion.landing_url,
            'type', promotion.landing_type
        ),
        'target_segments', COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'segment_id', pts.segment_id,
                        'content_brief', pts.content_brief_json,
                        'data_evidence', pts.data_evidence_json
                    )
                    ORDER BY pts.segment_id COLLATE "C"
                )
                FROM promotion_target_segments AS pts
                WHERE pts.analysis_id = gr.analysis_id
            ),
            '[]'::jsonb
        ),
        'brand_context', jsonb_build_object(
            'context_version', 'v1',
            'manifest_key',
                'brand-context/demo_project/manifests/v1/manifest.json',
            'manifest_sha256', encode(
                digest(
                    convert_to(
                        'brand-context/demo_project/manifests/v1/manifest.json:fixture-v1',
                        'UTF8'
                    ),
                    'sha256'
                ),
                'hex'
            ),
            'guide_version', 'v1',
            'asset_manifest_version', 'v1',
            'catalog_version', 'fixture-catalog-v1'
        ),
        'versions', jsonb_build_object(
            'content_spec', 'generation-v1',
            'embedding', 'text-embedding-3-large-1024-v1',
            'guardrail', 'generation-v1',
            'model', 'fixture-generation-model-v1',
            'prompt', 'generation-v1',
            'renderer', 'generation-v1',
            'retrieval_policy', 'exact-cosine-v1'
        )
    ),
    output_json = gr.output_json || jsonb_build_object(
        'status', 'completed',
        'retrieval_snapshot', jsonb_build_object(
            'query_version', 'fixture-query-v1',
            'retrieval_policy_version', 'exact-cosine-v1',
            'embedding_version', 'text-embedding-3-large-1024-v1',
            'documents', CASE
                WHEN promotion.channel = 'sms' THEN jsonb_build_array(
                    jsonb_build_object(
                        'document_id', 'rag_demo_brand_voice_v1_0',
                        'source_kind', 'brand_guide',
                        'source_id', 'brand-voice',
                        'source_version', 'v1',
                        'distance', 0.021
                    )
                )
                ELSE jsonb_build_array(
                    jsonb_build_object(
                        'document_id', 'rag_demo_brand_voice_v1_0',
                        'source_kind', 'brand_guide',
                        'source_id', 'brand-voice',
                        'source_version', 'v1',
                        'distance', 0.021
                    ),
                    jsonb_build_object(
                        'document_id', 'rag_demo_home_hero_v1_0',
                        'source_kind', 'brand_asset',
                        'source_id', 'home-hero',
                        'source_version', 'v1',
                        'distance', 0.034
                    )
                )
            END
        )
    ),
    created_at = LEAST(gr.created_at, gr.started_at - interval '1 minute')
FROM promotions AS promotion
WHERE gr.idempotency_key LIKE 'fixture:generation_%'
  AND promotion.promotion_id = gr.promotion_id;

UPDATE generation_runs
SET request_fingerprint = encode(
        digest(convert_to(input_json::text, 'UTF8'), 'sha256'),
        'hex'
    )
WHERE idempotency_key LIKE 'fixture:generation_%';

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
    subject,
    preheader,
    title,
    body,
    cta,
    message,
    landing_url,
    generation_prompt,
    reason_summary,
    data_evidence_json,
    message_strategy,
    metadata_json,
    status
)
VALUES
('content_email_a1_mobile', 'email_a1_option_1', 'generation_email_a1', 'analysis_email_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'seg_mobile_user', 'email', 'Your next hotel stay is waiting', 'A limited offer for your next trip', 'Find your next hotel stay', 'Personalized hotel deals based on your recent searches.', 'View hotels', NULL, NULL, 'hotel reactivation prompt', 'Baseline A1 content.', '{"fixture":true}'::jsonb, 'reactivation', '{"fixture":true}'::jsonb, 'active'),
('content_email_a2_mobile_1', 'email_a2_option_1', 'generation_email_a2', 'analysis_email_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'seg_mobile_user', 'email', 'A2 option 1: Save on your next stay', 'Manual approval candidate 1', 'Save on your next stay', 'A fresh offer for mobile hotel shoppers.', 'See offer', NULL, NULL, 'manual next-loop prompt', 'Candidate for operator approval.', '{"candidate":1}'::jsonb, 'discount', '{"fixture":true}'::jsonb, 'draft'),
('content_email_a2_mobile_2', 'email_a2_option_2', 'generation_email_a2', 'analysis_email_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'seg_mobile_user', 'email', 'A2 option 2: Plan your next escape', 'Manual approval candidate 2', 'Plan your next escape', 'Compare hotel options for your next trip.', 'Explore stays', NULL, NULL, 'manual next-loop prompt', 'Candidate for operator approval.', '{"candidate":2}'::jsonb, 'inspiration', '{"fixture":true}'::jsonb, 'draft'),
('content_email_a2_mobile_3', 'email_a2_option_3', 'generation_email_a2', 'analysis_email_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'seg_mobile_user', 'email', 'A2 option 3: Book with confidence', 'Manual approval candidate 3', 'Book with confidence', 'Use your recent hotel preferences to find a better stay.', 'Find a hotel', NULL, NULL, 'manual next-loop prompt', 'Candidate for operator approval.', '{"candidate":3}'::jsonb, 'confidence', '{"fixture":true}'::jsonb, 'draft'),
('content_onsite_a1_near', 'onsite_a1_option_1', 'generation_onsite_a1', 'analysis_onsite_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'seg_near_checkin', 'onsite_banner', NULL, NULL, 'Last-minute hotel deals', 'Complete your next hotel stay before check-in.', 'View deals', NULL, 'https://demo.loopad.local/hotels/last-minute', 'onsite baseline prompt', 'Baseline A1 content.', '{"fixture":true}'::jsonb, 'urgency', '{"fixture":true}'::jsonb, 'active'),
('content_onsite_a2_near', 'onsite_a2_option_1', 'generation_onsite_a2', 'analysis_onsite_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'seg_near_checkin', 'onsite_banner', NULL, NULL, 'Your next stay is ready', 'A2 content activated after approval.', 'Book now', NULL, 'https://demo.loopad.local/hotels/last-minute', 'activated child prompt', 'A2 canonical content.', '{"fixture":true}'::jsonb, 'urgency', '{"fixture":true}'::jsonb, 'active'),
('content_sms_a1_near', 'sms_a1_near_option_1', 'generation_sms_a1', 'analysis_sms_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'seg_near_checkin', 'sms', NULL, NULL, NULL, NULL, NULL, 'Hotel deal near your check-in date: view today''s offer.', 'https://demo.loopad.local/hotels/mobile-offer', 'sms baseline prompt', 'Baseline SMS content.', '{"fixture":true}'::jsonb, 'reminder', '{"fixture":true}'::jsonb, 'active'),
('content_sms_a1_family', 'sms_a1_family_option_1', 'generation_sms_a1', 'analysis_sms_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'seg_family_trip', 'sms', NULL, NULL, NULL, NULL, NULL, 'Family hotel options are ready for your next trip.', 'https://demo.loopad.local/hotels/mobile-offer', 'sms baseline prompt', 'Assignment-origin insufficient_data example.', '{"fixture":true}'::jsonb, 'family', '{"fixture":true}'::jsonb, 'active'),
('content_sms_a2_near_1', 'sms_a2_near_option_1', 'generation_sms_a2', 'analysis_sms_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'seg_near_checkin', 'sms', NULL, NULL, NULL, NULL, NULL, 'Rejected next-loop candidate.', 'https://demo.loopad.local/hotels/mobile-offer', 'sms next-loop prompt', 'Candidate from rejected preparation.', '{"fixture":true}'::jsonb, 'reminder', '{"fixture":true}'::jsonb, 'rejected'),
('content_sms_a2_near_2', 'sms_a2_near_option_2', 'generation_sms_a2', 'analysis_sms_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'seg_near_checkin', 'sms', NULL, NULL, NULL, NULL, NULL, 'Rejected alternative next-loop candidate.', 'https://demo.loopad.local/hotels/mobile-offer', 'sms next-loop prompt', 'Candidate from rejected preparation.', '{"fixture":true}'::jsonb, 'alternative', '{"fixture":true}'::jsonb, 'rejected')
ON CONFLICT (content_id) DO UPDATE SET
    content_option_id = EXCLUDED.content_option_id,
    generation_id = EXCLUDED.generation_id,
    analysis_id = EXCLUDED.analysis_id,
    project_id = EXCLUDED.project_id,
    campaign_id = EXCLUDED.campaign_id,
    promotion_id = EXCLUDED.promotion_id,
    segment_id = EXCLUDED.segment_id,
    channel = EXCLUDED.channel,
    subject = EXCLUDED.subject,
    preheader = EXCLUDED.preheader,
    title = EXCLUDED.title,
    body = EXCLUDED.body,
    cta = EXCLUDED.cta,
    message = EXCLUDED.message,
    landing_url = EXCLUDED.landing_url,
    generation_prompt = EXCLUDED.generation_prompt,
    reason_summary = EXCLUDED.reason_summary,
    data_evidence_json = EXCLUDED.data_evidence_json,
    message_strategy = EXCLUDED.message_strategy,
    metadata_json = EXCLUDED.metadata_json,
    status = EXCLUDED.status,
    updated_at = now();

-- Generation v1 readiness is independent from the approval lifecycle above.
-- Published fixture URLs omit CloudFront's `genai/` origin prefix while S3
-- storage keys retain it.
WITH generation_v1_candidate_fixture (
    content_id,
    image_prompt,
    image_url,
    creative_format,
    image_generation_status,
    artifact_status,
    artifact_storage_key,
    artifact_public_url,
    artifact_content_type
) AS (
    VALUES
    (
        'content_email_a1_mobile',
        'Inviting hotel stay hero with clear email copy space.',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_email_reactivation/generation_email_a1/content_email_a1_mobile/image.jpg',
        'email_html',
        'completed',
        'published',
        'genai/demo_project/promo_expedia_email_reactivation/generation_email_a1/content_email_a1_mobile/creative.email.html',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_email_reactivation/generation_email_a1/content_email_a1_mobile/creative.email.html',
        'text/html; charset=utf-8'
    ),
    (
        'content_email_a2_mobile_1',
        'Mobile hotel offer hero with calm travel mood and copy space.',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_1/image.jpg',
        'email_html',
        'completed',
        'published',
        'genai/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_1/creative.email.html',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_1/creative.email.html',
        'text/html; charset=utf-8'
    ),
    (
        'content_email_a2_mobile_2',
        'Hotel escape inspiration hero with destination imagery and copy space.',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_2/image.jpg',
        'email_html',
        'completed',
        'published',
        'genai/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_2/creative.email.html',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_2/creative.email.html',
        'text/html; charset=utf-8'
    ),
    (
        'content_email_a2_mobile_3',
        'Confident hotel booking hero with bright room and copy space.',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_3/image.jpg',
        'email_html',
        'completed',
        'published',
        'genai/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_3/creative.email.html',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_email_reactivation/generation_email_a2/content_email_a2_mobile_3/creative.email.html',
        'text/html; charset=utf-8'
    ),
    (
        'content_onsite_a1_near',
        'Last-minute hotel room banner with safe text area and no rendered text.',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_onsite_last_minute/generation_onsite_a1/content_onsite_a1_near/image.jpg',
        'banner_html',
        'completed',
        'published',
        'genai/demo_project/promo_expedia_onsite_last_minute/generation_onsite_a1/content_onsite_a1_near/creative.banner.html',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_onsite_last_minute/generation_onsite_a1/content_onsite_a1_near/creative.banner.html',
        'text/html; charset=utf-8'
    ),
    (
        'content_onsite_a2_near',
        'Ready-to-book hotel banner with safe text area and no rendered text.',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_onsite_last_minute/generation_onsite_a2/content_onsite_a2_near/image.jpg',
        'banner_html',
        'completed',
        'published',
        'genai/demo_project/promo_expedia_onsite_last_minute/generation_onsite_a2/content_onsite_a2_near/creative.banner.html',
        'https://gen-ai.asset.dev.loop-ad.org/demo_project/promo_expedia_onsite_last_minute/generation_onsite_a2/content_onsite_a2_near/creative.banner.html',
        'text/html; charset=utf-8'
    ),
    ('content_sms_a1_near', NULL, NULL, 'sms_text', 'not_required', 'not_required', NULL, NULL, NULL),
    ('content_sms_a1_family', NULL, NULL, 'sms_text', 'not_required', 'not_required', NULL, NULL, NULL),
    ('content_sms_a2_near_1', NULL, NULL, 'sms_text', 'not_required', 'not_required', NULL, NULL, NULL),
    ('content_sms_a2_near_2', NULL, NULL, 'sms_text', 'not_required', 'not_required', NULL, NULL, NULL)
)
UPDATE content_candidates AS cc
SET image_prompt = fixture.image_prompt,
    image_url = fixture.image_url,
    creative_format = fixture.creative_format,
    image_generation_status = fixture.image_generation_status,
    artifact_status = fixture.artifact_status,
    artifact_storage_key = fixture.artifact_storage_key,
    artifact_public_url = fixture.artifact_public_url,
    artifact_sha256 = CASE
        WHEN fixture.artifact_status = 'published'
        THEN encode(
            digest(
                convert_to(fixture.content_id || ':artifact:v1', 'UTF8'),
                'sha256'
            ),
            'hex'
        )
        ELSE NULL
    END,
    artifact_content_type = fixture.artifact_content_type,
    artifact_error_code = NULL,
    artifact_published_at = CASE
        WHEN fixture.artifact_status = 'published'
        THEN gr.finished_at - interval '1 minute'
        ELSE NULL
    END,
    metadata_json = COALESCE(cc.metadata_json, '{}'::jsonb)
        || jsonb_build_object(
            'creative', jsonb_build_object(
                'model', jsonb_build_object(
                    'provider', 'fixture',
                    'model_version', 'fixture-generation-model-v1',
                    'prompt_version', 'generation-v1'
                ),
                'lineage', jsonb_strip_nulls(jsonb_build_object(
                    'context_version', 'v1',
                    'retrieval_policy_version', 'exact-cosine-v1',
                    'document_ids', CASE
                        WHEN cc.channel = 'sms' THEN jsonb_build_array(
                            'rag_demo_brand_voice_v1_0'
                        )
                        ELSE jsonb_build_array(
                            'rag_demo_brand_voice_v1_0',
                            'rag_demo_home_hero_v1_0'
                        )
                    END,
                    'documents', CASE
                        WHEN cc.channel = 'sms' THEN jsonb_build_array(
                            jsonb_build_object(
                                'document_id',
                                    'rag_demo_brand_voice_v1_0',
                                'source_kind', 'brand_guide',
                                'source_id', 'brand-voice',
                                'source_version', 'v1',
                                'distance', 0.021
                            )
                        )
                        ELSE jsonb_build_array(
                            jsonb_build_object(
                                'document_id',
                                    'rag_demo_brand_voice_v1_0',
                                'source_kind', 'brand_guide',
                                'source_id', 'brand-voice',
                                'source_version', 'v1',
                                'distance', 0.021
                            ),
                            jsonb_build_object(
                                'document_id',
                                    'rag_demo_home_hero_v1_0',
                                'source_kind', 'brand_asset',
                                'source_id', 'home-hero',
                                'source_version', 'v1',
                                'distance', 0.034
                            )
                        )
                    END,
                    'selected_asset_id', CASE
                        WHEN cc.channel IN ('email', 'onsite_banner')
                        THEN 'home-hero'
                    END,
                    'provider_request_id',
                        'fixture:provider:' || fixture.content_id
                )),
                'image', jsonb_strip_nulls(jsonb_build_object(
                    'prompt', fixture.image_prompt,
                    'storage_key', CASE
                        WHEN fixture.image_url IS NOT NULL
                        THEN regexp_replace(
                            fixture.image_url,
                            '^https://gen-ai.asset.dev.loop-ad.org/',
                            'genai/'
                        )
                    END,
                    'public_url', fixture.image_url,
                    'sha256', CASE
                        WHEN fixture.image_url IS NOT NULL
                        THEN encode(
                            digest(
                                convert_to(
                                    fixture.content_id || ':image:v1',
                                    'UTF8'
                                ),
                                'sha256'
                            ),
                            'hex'
                        )
                    END,
                    'width', CASE
                        WHEN fixture.image_url IS NOT NULL THEN 1200
                    END,
                    'height', CASE cc.channel
                        WHEN 'email' THEN 630
                        WHEN 'onsite_banner' THEN 400
                    END,
                    'byte_size', CASE
                        WHEN fixture.image_url IS NOT NULL THEN 2048
                    END
                )),
                'artifact', jsonb_strip_nulls(jsonb_build_object(
                    'artifact_status', fixture.artifact_status,
                    'storage_key', fixture.artifact_storage_key,
                    'public_url', fixture.artifact_public_url,
                    'sha256', CASE
                        WHEN fixture.artifact_status = 'published'
                        THEN encode(
                            digest(
                                convert_to(
                                    fixture.content_id || ':artifact:v1',
                                    'UTF8'
                                ),
                                'sha256'
                            ),
                            'hex'
                        )
                    END,
                    'content_type', fixture.artifact_content_type,
                    'published_at', CASE
                        WHEN fixture.artifact_status = 'published'
                        THEN gr.finished_at - interval '1 minute'
                    END
                )),
                'guardrail', jsonb_build_object(
                    'version', 'generation-v1',
                    'status', 'passed'
                )
            )
        ),
    created_at = LEAST(
        cc.created_at,
        gr.started_at + interval '1 minute'
    ),
    updated_at = now()
FROM generation_v1_candidate_fixture AS fixture,
     generation_runs AS gr
WHERE cc.content_id = fixture.content_id
  AND gr.generation_id = cc.generation_id;

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
    started_at,
    ended_at
)
VALUES
('run_email_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'analysis_email_a1', 'generation_email_a1', 1, 'goal_not_met', '{"goal_metric":"booking_conversion_rate","target":0.05}'::jsonb, '["seg_mobile_user"]'::jsonb, '59c1fd8d7001d9f77e747d9cbac6c67bcf7b9f217bb884bf1844a9dc4a79c626', now() - interval '3 days', NULL),
('run_onsite_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'analysis_onsite_a1', 'generation_onsite_a1', 1, 'stopped', '{"goal_metric":"inflow_rate","target":0.08}'::jsonb, '["seg_near_checkin"]'::jsonb, '254dece18876fe5e844634faad372e1c614fc990c55041b6fa5d10865bbb623d', now() - interval '2 days', now() - interval '2 hours'),
('run_onsite_a2', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'analysis_onsite_a2', 'generation_onsite_a2', 2, 'running', '{"goal_metric":"inflow_rate","target":0.08}'::jsonb, '["seg_near_checkin"]'::jsonb, '254dece18876fe5e844634faad372e1c614fc990c55041b6fa5d10865bbb623d', now() - interval '1 hour', NULL),
('run_sms_a1', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'analysis_sms_a1', 'generation_sms_a1', 1, 'goal_not_met', '{"goal_metric":"booking_conversion_rate","target":0.04}'::jsonb, '["seg_family_trip","seg_near_checkin"]'::jsonb, 'ddb2d4e90789ba02f9868ab17bf57c27f98f7d22a8f327d1817cc962f81a7ed8', now() - interval '1 day', NULL)
ON CONFLICT (promotion_run_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    campaign_id = EXCLUDED.campaign_id,
    promotion_id = EXCLUDED.promotion_id,
    analysis_id = EXCLUDED.analysis_id,
    generation_id = EXCLUDED.generation_id,
    loop_count = EXCLUDED.loop_count,
    status = EXCLUDED.status,
    goal_snapshot_json = EXCLUDED.goal_snapshot_json,
    segment_scope_json = EXCLUDED.segment_scope_json,
    segment_scope_fingerprint = EXCLUDED.segment_scope_fingerprint,
    started_at = EXCLUDED.started_at,
    ended_at = EXCLUDED.ended_at,
    updated_at = now();

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
    parent_ad_experiment_id,
    source_evaluation_id,
    channel,
    loop_count,
    status,
    goal_metric,
    goal_target_value,
    goal_basis,
    started_at,
    ended_at
)
VALUES
('exp_email_a1_mobile', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'run_email_a1', 'analysis_email_a1', 'generation_email_a1', 'seg_mobile_user', 'Mobile hotel users', 'content_email_a1_mobile', 'email_a1_option_1', NULL, NULL, 'email', 1, 'goal_not_met', 'booking_conversion_rate', 0.05, 'all_segments', now() - interval '3 days', NULL),
('exp_email_a1_fallback', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'run_email_a1', 'analysis_email_a1', 'generation_email_a1', 'seg_existing_all', 'All existing hotel users', 'content_email_a1_mobile', 'email_a1_option_1', NULL, NULL, 'email', 1, 'goal_not_met', 'booking_conversion_rate', 0.05, 'all_segments', now() - interval '3 days', NULL),
('exp_onsite_a1_near', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'run_onsite_a1', 'analysis_onsite_a1', 'generation_onsite_a1', 'seg_near_checkin', 'Near check-in users', 'content_onsite_a1_near', 'onsite_a1_option_1', NULL, NULL, 'onsite_banner', 1, 'stopped', 'inflow_rate', 0.08, 'all_segments', now() - interval '2 days', now() - interval '2 hours'),
('exp_onsite_a1_fallback', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'run_onsite_a1', 'analysis_onsite_a1', 'generation_onsite_a1', 'seg_existing_all', 'All existing hotel users', 'content_onsite_a1_near', 'onsite_a1_option_1', NULL, NULL, 'onsite_banner', 1, 'stopped', 'inflow_rate', 0.08, 'all_segments', now() - interval '2 days', now() - interval '2 hours'),
('exp_onsite_a2_near', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'run_onsite_a2', 'analysis_onsite_a2', 'generation_onsite_a2', 'seg_near_checkin', 'Near check-in users', 'content_onsite_a2_near', 'onsite_a2_option_1', NULL, NULL, 'onsite_banner', 2, 'running', 'inflow_rate', 0.08, 'all_segments', now() - interval '1 hour', NULL),
('exp_onsite_a2_fallback', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'run_onsite_a2', 'analysis_onsite_a2', 'generation_onsite_a2', 'seg_existing_all', 'All existing hotel users', 'content_onsite_a2_near', 'onsite_a2_option_1', NULL, NULL, 'onsite_banner', 2, 'running', 'inflow_rate', 0.08, 'all_segments', now() - interval '1 hour', NULL),
('exp_sms_a1_near', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'run_sms_a1', 'analysis_sms_a1', 'generation_sms_a1', 'seg_near_checkin', 'Near check-in users', 'content_sms_a1_near', 'sms_a1_near_option_1', NULL, NULL, 'sms', 1, 'goal_not_met', 'booking_conversion_rate', 0.04, 'all_segments', now() - interval '1 day', NULL),
('exp_sms_a1_family', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'run_sms_a1', 'analysis_sms_a1', 'generation_sms_a1', 'seg_family_trip', 'Family trip planners', 'content_sms_a1_family', 'sms_a1_family_option_1', NULL, NULL, 'sms', 1, 'insufficient_data', 'booking_conversion_rate', 0.04, 'all_segments', NULL, NULL),
('exp_sms_a1_fallback', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'run_sms_a1', 'analysis_sms_a1', 'generation_sms_a1', 'seg_existing_all', 'All existing hotel users', 'content_sms_a1_near', 'sms_a1_near_option_1', NULL, NULL, 'sms', 1, 'goal_not_met', 'booking_conversion_rate', 0.04, 'all_segments', now() - interval '1 day', NULL)
ON CONFLICT (ad_experiment_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    campaign_id = EXCLUDED.campaign_id,
    promotion_id = EXCLUDED.promotion_id,
    promotion_run_id = EXCLUDED.promotion_run_id,
    analysis_id = EXCLUDED.analysis_id,
    generation_id = EXCLUDED.generation_id,
    segment_id = EXCLUDED.segment_id,
    segment_name = EXCLUDED.segment_name,
    content_id = EXCLUDED.content_id,
    content_option_id = EXCLUDED.content_option_id,
    parent_ad_experiment_id = EXCLUDED.parent_ad_experiment_id,
    source_evaluation_id = EXCLUDED.source_evaluation_id,
    channel = EXCLUDED.channel,
    loop_count = EXCLUDED.loop_count,
    status = EXCLUDED.status,
    goal_metric = EXCLUDED.goal_metric,
    goal_target_value = EXCLUDED.goal_target_value,
    goal_basis = EXCLUDED.goal_basis,
    started_at = EXCLUDED.started_at,
    ended_at = EXCLUDED.ended_at,
    updated_at = now();

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
('eval_email_a1_goal_not_met', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'run_email_a1', 'exp_email_a1_mobile', 'seg_mobile_user', 'content_email_a1_mobile', 'email_a1_option_1', 'booking_conversion_rate', 0.05, 0.021, 21, 1000, 1000, 'all_segments', 'goal_not_met', 'Baseline A1 did not meet the target.', true, '{"fixture":true}'::jsonb, now() - interval '2 days'),
('eval_email_a1_recheck_01_insufficient', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'run_email_a1', 'exp_email_a1_mobile', 'seg_mobile_user', 'content_email_a1_mobile', 'email_a1_option_1', 'booking_conversion_rate', 0.05, 0.010, 10, 1000, 1000, 'all_segments', 'insufficient_data', 'Re-evaluation with insufficient sample.', false, '{"fixture":true}'::jsonb, now() - interval '1 hour'),
('eval_email_a1_recheck_02_goal_met', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'run_email_a1', 'exp_email_a1_mobile', 'seg_mobile_user', 'content_email_a1_mobile', 'email_a1_option_1', 'booking_conversion_rate', 0.05, 0.051, 51, 1000, 1000, 'all_segments', 'goal_met', 'Tie-breaker row for the latest individual evaluation fixture.', false, '{"fixture":true}'::jsonb, now() - interval '1 hour'),
('eval_onsite_a1_goal_not_met', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'run_onsite_a1', 'exp_onsite_a1_near', 'seg_near_checkin', 'content_onsite_a1_near', 'onsite_a1_option_1', 'inflow_rate', 0.08, 0.031, 31, 1000, 1000, 'all_segments', 'goal_not_met', 'A1 was retired during the child cutover.', true, '{"fixture":true}'::jsonb, now() - interval '3 hours'),
('eval_sms_a1_near_goal_not_met', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'run_sms_a1', 'exp_sms_a1_near', 'seg_near_checkin', 'content_sms_a1_near', 'sms_a1_near_option_1', 'booking_conversion_rate', 0.04, 0.019, 19, 1000, 1000, 'all_segments', 'goal_not_met', 'The rejected preparation keeps the source A1 serving.', true, '{"fixture":true}'::jsonb, now() - interval '1 day'),
('eval_sms_a1_aggregate_insufficient', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_sms_near_checkin', 'run_sms_a1', NULL, NULL, NULL, NULL, 'booking_conversion_rate', 0.04, 0.0, 0, 0, 0, 'promotion_average', 'insufficient_data', 'Aggregate-only row must not prove individual serving provenance.', false, '{"fixture":true,"aggregate":true}'::jsonb, now() - interval '1 day')
ON CONFLICT (evaluation_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    campaign_id = EXCLUDED.campaign_id,
    promotion_id = EXCLUDED.promotion_id,
    promotion_run_id = EXCLUDED.promotion_run_id,
    ad_experiment_id = EXCLUDED.ad_experiment_id,
    segment_id = EXCLUDED.segment_id,
    content_id = EXCLUDED.content_id,
    content_option_id = EXCLUDED.content_option_id,
    metric = EXCLUDED.metric,
    target_value = EXCLUDED.target_value,
    actual_value = EXCLUDED.actual_value,
    numerator_count = EXCLUDED.numerator_count,
    denominator_count = EXCLUDED.denominator_count,
    sample_size = EXCLUDED.sample_size,
    basis = EXCLUDED.basis,
    status = EXCLUDED.status,
    feedback = EXCLUDED.feedback,
    next_loop_required = EXCLUDED.next_loop_required,
    result_json = EXCLUDED.result_json,
    created_at = EXCLUDED.created_at;

UPDATE ad_experiments
SET parent_ad_experiment_id = 'exp_onsite_a1_near',
    source_evaluation_id = 'eval_onsite_a1_goal_not_met',
    updated_at = now()
WHERE ad_experiment_id = 'exp_onsite_a2_near';

INSERT INTO next_loop_preparations (
    next_loop_preparation_id,
    source_promotion_run_id,
    analysis_id,
    generation_id,
    attempt_no,
    failed_segment_ids_json,
    failed_ad_experiment_ids_json,
    source_evaluation_ids_json,
    status,
    activated_promotion_run_id
)
VALUES
('prep_email_next_loop_01', 'run_email_a1', 'analysis_email_a2', 'generation_email_a2', 1, '["seg_mobile_user"]'::jsonb, '["exp_email_a1_mobile"]'::jsonb, '["eval_email_a1_goal_not_met"]'::jsonb, 'awaiting_content_approval', NULL),
('prep_onsite_next_loop_01', 'run_onsite_a1', 'analysis_onsite_a2', 'generation_onsite_a2', 1, '["seg_near_checkin"]'::jsonb, '["exp_onsite_a1_near"]'::jsonb, '["eval_onsite_a1_goal_not_met"]'::jsonb, 'activated', 'run_onsite_a2'),
('prep_sms_next_loop_01', 'run_sms_a1', 'analysis_sms_a2', 'generation_sms_a2', 1, '["seg_near_checkin"]'::jsonb, '["exp_sms_a1_near"]'::jsonb, '["eval_sms_a1_near_goal_not_met"]'::jsonb, 'rejected', NULL)
ON CONFLICT (next_loop_preparation_id) DO UPDATE SET
    source_promotion_run_id = EXCLUDED.source_promotion_run_id,
    analysis_id = EXCLUDED.analysis_id,
    generation_id = EXCLUDED.generation_id,
    attempt_no = EXCLUDED.attempt_no,
    failed_segment_ids_json = EXCLUDED.failed_segment_ids_json,
    failed_ad_experiment_ids_json = EXCLUDED.failed_ad_experiment_ids_json,
    source_evaluation_ids_json = EXCLUDED.source_evaluation_ids_json,
    status = EXCLUDED.status,
    activated_promotion_run_id = EXCLUDED.activated_promotion_run_id,
    updated_at = now();

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
    fallback_reason,
    assignment_source,
    assigned_at,
    expires_at
)
VALUES
('demo_project', 'run_email_a1', 'demo_user_email_awaiting', 'seg_mobile_user', 'exp_email_a1_mobile', 'content_email_a1_mobile', 'email_a1_option_1', 0.94, false, NULL, 'fixture', now() - interval '30 minutes', now() + interval '7 days'),
('demo_project', 'run_onsite_a1', 'demo_user_onsite_cutover', 'seg_near_checkin', 'exp_onsite_a1_near', 'content_onsite_a1_near', 'onsite_a1_option_1', 0.91, false, NULL, 'fixture', now() - interval '2 hours', now() + interval '7 days'),
('demo_project', 'run_onsite_a2', 'demo_user_onsite_cutover', 'seg_near_checkin', 'exp_onsite_a2_near', 'content_onsite_a2_near', 'onsite_a2_option_1', 0.95, false, NULL, 'fixture', now() - interval '30 minutes', now() + interval '7 days'),
('demo_project', 'run_onsite_a2', 'demo_user_onsite_fallback', 'seg_existing_all', 'exp_onsite_a2_fallback', 'content_onsite_a2_near', 'onsite_a2_option_1', NULL, true, 'below_threshold', 'fixture', now() - interval '5 minutes', now() + interval '7 days'),
('demo_project', 'run_sms_a1', 'demo_user_sms_rejected', 'seg_near_checkin', 'exp_sms_a1_near', 'content_sms_a1_near', 'sms_a1_near_option_1', 0.88, false, NULL, 'fixture', now() - interval '20 minutes', now() + interval '7 days'),
('demo_project', 'run_sms_a1', 'demo_user_sms_no_provenance', 'seg_family_trip', 'exp_sms_a1_family', 'content_sms_a1_family', 'sms_a1_family_option_1', 0.72, false, NULL, 'fixture', now() - interval '20 minutes', now() + interval '7 days')
ON CONFLICT (promotion_run_id, user_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    segment_id = EXCLUDED.segment_id,
    ad_experiment_id = EXCLUDED.ad_experiment_id,
    content_id = EXCLUDED.content_id,
    content_option_id = EXCLUDED.content_option_id,
    similarity_score = EXCLUDED.similarity_score,
    fallback = EXCLUDED.fallback,
    fallback_reason = EXCLUDED.fallback_reason,
    assignment_source = EXCLUDED.assignment_source,
    assigned_at = EXCLUDED.assigned_at,
    expires_at = EXCLUDED.expires_at;

INSERT INTO generation_rag.retrieval_documents (
    document_id,
    project_id,
    context_version,
    source_kind,
    source_id,
    source_version,
    chunk_index,
    s3_key,
    document_text,
    metadata_json,
    embedding,
    embedding_model,
    embedding_version,
    content_sha256,
    status
)
VALUES
(
    'rag_demo_home_hero_v1_0',
    'demo_project',
    'v1',
    'brand_asset',
    'home-hero',
    'v1',
    0,
    'brand-context/demo_project/assets/home-hero/v1/original.jpg',
    'StayLoop representative hotel hero asset.',
    '{"role":"hero","locale":"ko-KR","active":true,"license":"fixture"}'::jsonb,
    array_fill(0.001::real, ARRAY[1024])::vector(1024),
    'text-embedding-3-large',
    'text-embedding-3-large-1024-v1',
    encode(
        digest(convert_to('rag_demo_home_hero_v1_0', 'UTF8'), 'sha256'),
        'hex'
    ),
    'active'
),
(
    'rag_demo_brand_voice_v1_0',
    'demo_project',
    'v1',
    'brand_guide',
    'brand-voice',
    'v1',
    0,
    'brand-context/demo_project/guidelines/brand-voice/v1/content.md',
    'StayLoop uses calm, clear, and trustworthy travel language.',
    '{"required":true,"channels":["email","onsite_banner","sms"]}'::jsonb,
    array_fill(0.002::real, ARRAY[1024])::vector(1024),
    'text-embedding-3-large',
    'text-embedding-3-large-1024-v1',
    encode(
        digest(convert_to('rag_demo_brand_voice_v1_0', 'UTF8'), 'sha256'),
        'hex'
    ),
    'active'
)
ON CONFLICT (document_id) DO UPDATE SET
    project_id = EXCLUDED.project_id,
    context_version = EXCLUDED.context_version,
    source_kind = EXCLUDED.source_kind,
    source_id = EXCLUDED.source_id,
    source_version = EXCLUDED.source_version,
    chunk_index = EXCLUDED.chunk_index,
    s3_key = EXCLUDED.s3_key,
    document_text = EXCLUDED.document_text,
    metadata_json = EXCLUDED.metadata_json,
    embedding = EXCLUDED.embedding,
    embedding_model = EXCLUDED.embedding_model,
    embedding_version = EXCLUDED.embedding_version,
    content_sha256 = EXCLUDED.content_sha256,
    status = EXCLUDED.status,
    last_error_code = NULL,
    last_error_message = NULL,
    updated_at = now();

COMMIT;
