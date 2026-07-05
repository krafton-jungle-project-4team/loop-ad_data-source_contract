-- =========================================================
-- Loop-Ad PostgreSQL Dummy Data
-- Domain: hotel / accommodation booking
--
-- Purpose:
-- - Creates demo service hierarchy for local/ECS demo.
-- - Keeps result tables empty so each service API can create its own rows.
--
-- Created hierarchy:
--   project -> campaign -> promotions -> system_default segments -> funnels
--
-- Not inserted here:
-- - promotion_analyses
-- - promotion_segment_suggestions
-- - promotion_target_segments
-- - generation_runs / content_candidates
-- - promotion_runs / ad_experiments
-- - user_segment_assignments
-- - promotion_evaluations
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
    'demo_project',
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
    project_id = EXCLUDED.project_id,
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

COMMIT;
