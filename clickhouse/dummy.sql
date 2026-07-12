-- =========================================================
-- Loop-Ad ClickHouse local fixture
-- Domain: hotel / accommodation booking
--
-- Purpose:
-- - Provides Dashboard-facing promotion funnel and booking events.
-- - Reuses the PostgreSQL manual next-loop fixture identifiers.
-- - Inserts raw events so the schema Materialized Views create typed rows.
--
-- This file is mounted only by docker-compose.local-fixture.yml and is
-- intended for a fresh local fixture volume.
-- =========================================================

USE loopad;

-- =========================================================
-- 1. Raw promotion and booking events
-- =========================================================
INSERT INTO raw_events (
    project_id,
    write_key,
    schema_version,
    event_id,
    event_name,
    event_time,
    source,
    user_id,
    session_id,
    properties_json,
    validation_status
)
VALUES
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_email_01',
    'promotion_impression',
    toDateTime64('2026-07-12 12:00:00', 3, 'UTC'),
    'fixture',
    'demo_user_email_awaiting',
    'session_email_awaiting',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_email_reactivation","promotion_run_id":"run_email_a1","ad_experiment_id":"exp_email_a1_mobile","segment_id":"seg_mobile_user","promotion_channel":"email","content_id":"content_email_a1_mobile","content_option_id":"email_a1_option_1","landing_url":"https://demo.loopad.local/hotels","page":{"url":"https://demo.loopad.local/hotels","previous_url":"https://demo.loopad.local/"}}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_email_02',
    'promotion_click',
    toDateTime64('2026-07-12 12:01:00', 3, 'UTC'),
    'fixture',
    'demo_user_email_awaiting',
    'session_email_awaiting',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_email_reactivation","promotion_run_id":"run_email_a1","ad_experiment_id":"exp_email_a1_mobile","segment_id":"seg_mobile_user","promotion_channel":"email","content_id":"content_email_a1_mobile","content_option_id":"email_a1_option_1","landing_url":"https://demo.loopad.local/hotels","target_url":"https://demo.loopad.local/hotels","page":{"url":"https://demo.loopad.local/hotels","previous_url":"https://demo.loopad.local/"}}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_email_03',
    'campaign_landing',
    toDateTime64('2026-07-12 12:02:00', 3, 'UTC'),
    'fixture',
    'demo_user_email_awaiting',
    'session_email_awaiting',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_email_reactivation","promotion_run_id":"run_email_a1","ad_experiment_id":"exp_email_a1_mobile","segment_id":"seg_mobile_user","promotion_channel":"email","content_id":"content_email_a1_mobile","content_option_id":"email_a1_option_1","landing_url":"https://demo.loopad.local/hotels","page":{"url":"https://demo.loopad.local/hotels","previous_url":"https://demo.loopad.local/email"},"page_path":"/hotels"}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_email_04',
    'booking_start',
    toDateTime64('2026-07-12 12:04:00', 3, 'UTC'),
    'fixture',
    'demo_user_email_awaiting',
    'session_email_awaiting',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_email_reactivation","promotion_run_id":"run_email_a1","ad_experiment_id":"exp_email_a1_mobile","segment_id":"seg_mobile_user","content_id":"content_email_a1_mobile","content_option_id":"email_a1_option_1","booking_id":"booking_fixture_email_001","hotel_id":"hotel_101","hotel_cluster":"11","hotel_market":"101","revenue":"180000","currency":"KRW"}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_onsite_01',
    'promotion_impression',
    toDateTime64('2026-07-12 13:00:00', 3, 'UTC'),
    'fixture',
    'demo_user_onsite_cutover',
    'session_onsite_cutover',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_onsite_last_minute","promotion_run_id":"run_onsite_a2","ad_experiment_id":"exp_onsite_a2_near","segment_id":"seg_near_checkin","promotion_channel":"onsite_banner","content_id":"content_onsite_a2_near","content_option_id":"onsite_a2_option_1","landing_url":"https://demo.loopad.local/hotels/last-minute","page":{"url":"https://demo.loopad.local/hotels/last-minute","previous_url":"https://demo.loopad.local/"}}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_onsite_02',
    'promotion_click',
    toDateTime64('2026-07-12 13:01:00', 3, 'UTC'),
    'fixture',
    'demo_user_onsite_cutover',
    'session_onsite_cutover',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_onsite_last_minute","promotion_run_id":"run_onsite_a2","ad_experiment_id":"exp_onsite_a2_near","segment_id":"seg_near_checkin","promotion_channel":"onsite_banner","content_id":"content_onsite_a2_near","content_option_id":"onsite_a2_option_1","target_url":"https://demo.loopad.local/hotels/last-minute","page":{"url":"https://demo.loopad.local/hotels/last-minute","previous_url":"https://demo.loopad.local/"}}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_onsite_03',
    'hotel_detail_view',
    toDateTime64('2026-07-12 13:02:00', 3, 'UTC'),
    'fixture',
    'demo_user_onsite_cutover',
    'session_onsite_cutover',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_onsite_last_minute","promotion_run_id":"run_onsite_a2","ad_experiment_id":"exp_onsite_a2_near","segment_id":"seg_near_checkin","content_id":"content_onsite_a2_near","content_option_id":"onsite_a2_option_1","hotel_id":"hotel_101","hotel_cluster":"11","hotel_market":"101","price":"210000","breakfast_included":"1","free_cancellation":"1","room_type":"deluxe","page_path":"/hotels/last-minute"}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_onsite_04',
    'booking_start',
    toDateTime64('2026-07-12 13:03:00', 3, 'UTC'),
    'fixture',
    'demo_user_onsite_cutover',
    'session_onsite_cutover',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_onsite_last_minute","promotion_run_id":"run_onsite_a2","ad_experiment_id":"exp_onsite_a2_near","segment_id":"seg_near_checkin","content_id":"content_onsite_a2_near","content_option_id":"onsite_a2_option_1","booking_id":"booking_fixture_onsite_001","hotel_id":"hotel_101","hotel_cluster":"11","hotel_market":"101","revenue":"210000","currency":"KRW"}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_onsite_05',
    'booking_complete',
    toDateTime64('2026-07-12 13:05:00', 3, 'UTC'),
    'fixture',
    'demo_user_onsite_cutover',
    'session_onsite_cutover',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_onsite_last_minute","promotion_run_id":"run_onsite_a2","ad_experiment_id":"exp_onsite_a2_near","segment_id":"seg_near_checkin","content_id":"content_onsite_a2_near","content_option_id":"onsite_a2_option_1","booking_id":"booking_fixture_onsite_001","hotel_id":"hotel_101","hotel_cluster":"11","hotel_market":"101","revenue":"210000","currency":"KRW"}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_sms_01',
    'promotion_impression',
    toDateTime64('2026-07-12 14:00:00', 3, 'UTC'),
    'fixture',
    'demo_user_sms_rejected',
    'session_sms_rejected',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_sms_near_checkin","promotion_run_id":"run_sms_a1","ad_experiment_id":"exp_sms_a1_near","segment_id":"seg_near_checkin","promotion_channel":"sms","content_id":"content_sms_a1_near","content_option_id":"sms_a1_near_option_1","landing_url":"https://demo.loopad.local/hotels/mobile-offer","page":{"url":"https://demo.loopad.local/hotels/mobile-offer","previous_url":"https://demo.loopad.local/"}}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_sms_02',
    'promotion_click',
    toDateTime64('2026-07-12 14:01:00', 3, 'UTC'),
    'fixture',
    'demo_user_sms_rejected',
    'session_sms_rejected',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_sms_near_checkin","promotion_run_id":"run_sms_a1","ad_experiment_id":"exp_sms_a1_near","segment_id":"seg_near_checkin","promotion_channel":"sms","content_id":"content_sms_a1_near","content_option_id":"sms_a1_near_option_1","target_url":"https://demo.loopad.local/hotels/mobile-offer","page":{"url":"https://demo.loopad.local/hotels/mobile-offer","previous_url":"https://demo.loopad.local/"}}',
    'valid'
),
(
    'demo_project',
    'demo_write_key_expedia',
    'hotel_rec_promo.v1',
    'evt_fixture_sms_03',
    'booking_cancel',
    toDateTime64('2026-07-12 14:03:00', 3, 'UTC'),
    'fixture',
    'demo_user_sms_rejected',
    'session_sms_rejected',
    '{"campaign_id":"camp_expedia_hotel_demo","promotion_id":"promo_expedia_sms_near_checkin","promotion_run_id":"run_sms_a1","ad_experiment_id":"exp_sms_a1_near","segment_id":"seg_near_checkin","content_id":"content_sms_a1_near","content_option_id":"sms_a1_near_option_1","booking_id":"booking_fixture_sms_001","hotel_id":"hotel_202","hotel_cluster":"22","hotel_market":"202","revenue":"0","currency":"KRW"}',
    'valid'
);

-- =========================================================
-- 2. User behavior vectors
-- =========================================================
INSERT INTO user_behavior_vectors (
    project_id,
    user_id,
    vector_dim,
    vector_values,
    vector_version,
    source,
    window_start,
    window_end
)
VALUES
('demo_project', 'demo_user_email_awaiting', 64, arrayMap(x -> toFloat32(x) / 100.0, range(64)), 'fixture-v1', 'fixture', toDateTime64('2026-07-01 00:00:00', 3, 'UTC'), toDateTime64('2026-07-12 23:59:59', 3, 'UTC')),
('demo_project', 'demo_user_onsite_cutover', 64, arrayMap(x -> toFloat32(x + 1) / 100.0, range(64)), 'fixture-v1', 'fixture', toDateTime64('2026-07-01 00:00:00', 3, 'UTC'), toDateTime64('2026-07-12 23:59:59', 3, 'UTC')),
('demo_project', 'demo_user_sms_rejected', 64, arrayMap(x -> toFloat32(x + 2) / 100.0, range(64)), 'fixture-v1', 'fixture', toDateTime64('2026-07-01 00:00:00', 3, 'UTC'), toDateTime64('2026-07-12 23:59:59', 3, 'UTC')),
('demo_project', 'demo_user_sms_no_provenance', 64, arrayMap(x -> toFloat32(x + 3) / 100.0, range(64)), 'fixture-v1', 'fixture', toDateTime64('2026-07-01 00:00:00', 3, 'UTC'), toDateTime64('2026-07-12 23:59:59', 3, 'UTC'));
