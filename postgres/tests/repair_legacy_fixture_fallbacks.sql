-- Test-only repair for the legacy origin/main dummy fixture.
-- This file must not be used as a production migration or documented as an
-- automatic repair procedure. It deliberately leaves promotion_runs scope
-- columns untouched so the production backfill remains responsible for them.

BEGIN;

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
('exp_email_a1_fallback', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_email_reactivation', 'run_email_a1', 'analysis_email_a1', 'generation_email_a1', 'seg_existing_all', 'All existing hotel users', 'content_email_a1_mobile', 'email_a1_option_1', NULL, NULL, 'email', 1, 'goal_not_met', 'booking_conversion_rate', 0.05, 'all_segments', now() - interval '3 days', NULL),
('exp_onsite_a1_fallback', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'run_onsite_a1', 'analysis_onsite_a1', 'generation_onsite_a1', 'seg_existing_all', 'All existing hotel users', 'content_onsite_a1_near', 'onsite_a1_option_1', NULL, NULL, 'onsite_banner', 1, 'stopped', 'inflow_rate', 0.08, 'all_segments', now() - interval '2 days', now() - interval '2 hours'),
('exp_onsite_a2_fallback', 'demo_project', 'camp_expedia_hotel_demo', 'promo_expedia_onsite_last_minute', 'run_onsite_a2', 'analysis_onsite_a2', 'generation_onsite_a2', 'seg_existing_all', 'All existing hotel users', 'content_onsite_a2_near', 'onsite_a2_option_1', NULL, NULL, 'onsite_banner', 2, 'running', 'inflow_rate', 0.08, 'all_segments', now() - interval '1 hour', NULL),
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

COMMIT;
