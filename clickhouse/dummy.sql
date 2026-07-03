-- =========================================================
-- Loop-Ad ClickHouse Dummy / Seed Data
-- =========================================================
--
-- Run schema.sql first, then dummy.sql.
--
-- This file includes:
--   1. demo-shop raw hotel journey events
--   2. Expedia-compatible hotel search rows
--   3. 64-dimensional user behavior vectors
--   4. sample validation errors
--
-- It refreshes only rows tagged as this dummy seed.
--
-- =========================================================

CREATE DATABASE IF NOT EXISTS loopad;
USE loopad;

SET mutations_sync = 1;

-- =========================================================
-- 0. Refresh previous dummy rows
-- =========================================================

ALTER TABLE raw_events
DELETE WHERE project_id = 'demo-shop'
  AND source = 'dummy.sql';

ALTER TABLE promotion_touch_events
DELETE WHERE project_id = 'demo-shop'
  AND source = 'dummy.sql';

ALTER TABLE booking_outcome_events
DELETE WHERE project_id = 'demo-shop'
  AND JSONExtractString(properties_json, 'seed_source') = 'clickhouse/dummy.sql';

ALTER TABLE expedia_hotel_events
DELETE WHERE date_time >= toDateTime('2026-07-01 00:00:00')
  AND user_id IN (1001, 1002, 1003, 1004, 1005, 1006);

ALTER TABLE user_behavior_vectors
DELETE WHERE project_id = 'demo-shop'
  AND source = 'dummy.sql';

ALTER TABLE event_validation_errors
DELETE WHERE ifNull(project_id, '') = 'demo-shop'
  AND JSONExtractString(payload_json, 'seed_source') = 'clickhouse/dummy.sql';

-- =========================================================
-- 1. Raw events
-- Materialized views populate promotion_touch_events and booking_outcome_events.
-- =========================================================

INSERT INTO raw_events
(
    project_id,
    write_key,
    schema_version,
    event_id,
    event_name,
    event_time,
    received_at,
    source,
    user_id,
    session_id,
    properties_json,
    validation_status
)
VALUES
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0001',
    'page_view',
    '2026-07-02 00:58:41.000',
    '2026-07-02 00:58:42.000',
    'dummy.sql',
    'user_family_001',
    'sess_family_001',
    '{"seed_source":"clickhouse/dummy.sql","page_path":"/hotels","device_type":"mobile","segment_id":"seg_family_trip"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0002',
    'hotel_search',
    '2026-07-02 01:00:13.000',
    '2026-07-02 01:00:14.000',
    'dummy.sql',
    'user_family_001',
    'sess_family_001',
    '{"seed_source":"clickhouse/dummy.sql","srch_destination_id":"8821","srch_adults_cnt":"2","srch_children_cnt":"2","srch_ci":"2026-07-12","srch_co":"2026-07-15","segment_id":"seg_family_trip"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0003',
    'hotel_detail_view',
    '2026-07-02 01:03:27.000',
    '2026-07-02 01:03:28.000',
    'dummy.sql',
    'user_family_001',
    'sess_family_001',
    '{"seed_source":"clickhouse/dummy.sql","hotel_id":"hotel_kr_1207","hotel_cluster":"41","hotel_market":"8821","price":"189000","breakfast_included":"1","free_cancellation":"1","room_type":"family_suite","segment_id":"seg_family_trip"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0004',
    'promotion_impression',
    '2026-07-02 01:04:03.000',
    '2026-07-02 01:04:04.000',
    'dummy.sql',
    'user_family_001',
    'sess_family_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"cmp_summer_family_2026","promotion_id":"promo_family_breakfast","promotion_run_id":"run_family_20260702","ad_experiment_id":"exp_family_banner_a","segment_id":"seg_family_trip","promotion_channel":"onsite_banner","content_id":"content_family_breakfast","content_option_id":"variant_a","placement_id":"hotel_detail_top","landing_url":"/promotions/family-breakfast","target_url":"/hotels/hotel_kr_1207"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0005',
    'promotion_click',
    '2026-07-02 01:04:22.000',
    '2026-07-02 01:04:23.000',
    'dummy.sql',
    'user_family_001',
    'sess_family_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"cmp_summer_family_2026","promotion_id":"promo_family_breakfast","promotion_run_id":"run_family_20260702","ad_experiment_id":"exp_family_banner_a","segment_id":"seg_family_trip","promotion_channel":"onsite_banner","content_id":"content_family_breakfast","content_option_id":"variant_a","redirect_id":"redir_family_001","placement_id":"hotel_detail_top","landing_url":"/promotions/family-breakfast","target_url":"/hotels/hotel_kr_1207"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0006',
    'campaign_landing',
    '2026-07-02 01:04:33.000',
    '2026-07-02 01:04:34.000',
    'dummy.sql',
    'user_family_001',
    'sess_family_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"cmp_summer_family_2026","promotion_id":"promo_family_breakfast","promotion_run_id":"run_family_20260702","ad_experiment_id":"exp_family_banner_a","segment_id":"seg_family_trip","promotion_channel":"onsite_banner","content_id":"content_family_breakfast","content_option_id":"variant_a","redirect_id":"redir_family_001","landing_url":"/promotions/family-breakfast","target_url":"/hotels/hotel_kr_1207"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0007',
    'booking_start',
    '2026-07-02 01:08:12.000',
    '2026-07-02 01:08:13.000',
    'dummy.sql',
    'user_family_001',
    'sess_family_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"cmp_summer_family_2026","promotion_id":"promo_family_breakfast","promotion_run_id":"run_family_20260702","ad_experiment_id":"exp_family_banner_a","segment_id":"seg_family_trip","content_id":"content_family_breakfast","content_option_id":"variant_a","booking_id":"booking_family_001","hotel_id":"hotel_kr_1207","hotel_cluster":"41","hotel_market":"8821","revenue":"567000","currency":"KRW"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0008',
    'booking_complete',
    '2026-07-02 01:11:54.000',
    '2026-07-02 01:11:55.000',
    'dummy.sql',
    'user_family_001',
    'sess_family_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"cmp_summer_family_2026","promotion_id":"promo_family_breakfast","promotion_run_id":"run_family_20260702","ad_experiment_id":"exp_family_banner_a","segment_id":"seg_family_trip","content_id":"content_family_breakfast","content_option_id":"variant_a","booking_id":"booking_family_001","hotel_id":"hotel_kr_1207","hotel_cluster":"41","hotel_market":"8821","revenue":"567000","currency":"KRW"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0009',
    'hotel_detail_view',
    '2026-07-02 02:15:02.000',
    '2026-07-02 02:15:03.000',
    'dummy.sql',
    'user_couple_001',
    'sess_couple_001',
    '{"seed_source":"clickhouse/dummy.sql","hotel_id":"hotel_jp_0802","hotel_cluster":"12","hotel_market":"4402","price":"241000","breakfast_included":"0","free_cancellation":"1","room_type":"deluxe_double","segment_id":"seg_couple_trip"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0010',
    'promotion_impression',
    '2026-07-02 02:16:44.000',
    '2026-07-02 02:16:45.000',
    'dummy.sql',
    'user_couple_001',
    'sess_couple_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"cmp_weekend_escape_2026","promotion_id":"promo_late_checkout","promotion_run_id":"run_couple_20260702","ad_experiment_id":"exp_couple_banner_b","segment_id":"seg_couple_trip","promotion_channel":"onsite_banner","content_id":"content_late_checkout","content_option_id":"variant_b","placement_id":"hotel_detail_middle","landing_url":"/promotions/late-checkout","target_url":"/hotels/hotel_jp_0802"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0011',
    'booking_start',
    '2026-07-02 02:22:10.000',
    '2026-07-02 02:22:11.000',
    'dummy.sql',
    'user_couple_001',
    'sess_couple_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"cmp_weekend_escape_2026","promotion_id":"promo_late_checkout","promotion_run_id":"run_couple_20260702","ad_experiment_id":"exp_couple_banner_b","segment_id":"seg_couple_trip","content_id":"content_late_checkout","content_option_id":"variant_b","booking_id":"booking_couple_001","hotel_id":"hotel_jp_0802","hotel_cluster":"12","hotel_market":"4402","revenue":"482000","currency":"KRW"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0012',
    'booking_cancel',
    '2026-07-02 02:26:39.000',
    '2026-07-02 02:26:40.000',
    'dummy.sql',
    'user_couple_001',
    'sess_couple_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"cmp_weekend_escape_2026","promotion_id":"promo_late_checkout","promotion_run_id":"run_couple_20260702","ad_experiment_id":"exp_couple_banner_b","segment_id":"seg_couple_trip","content_id":"content_late_checkout","content_option_id":"variant_b","booking_id":"booking_couple_001","hotel_id":"hotel_jp_0802","hotel_cluster":"12","hotel_market":"4402","revenue":"0","currency":"KRW","cancel_reason":"price_compare"}',
    'valid'
),
(
    'demo-shop',
    'wk_demo_local',
    'hotel_rec_promo.v1',
    'evt_demo_0013',
    'booking_complete',
    '2026-07-02 03:45:17.000',
    '2026-07-02 03:45:18.000',
    'dummy.sql',
    'user_organic_001',
    'sess_organic_001',
    '{"seed_source":"clickhouse/dummy.sql","campaign_id":"","promotion_id":"","promotion_run_id":"","ad_experiment_id":"","segment_id":"seg_existing_all","content_id":"","content_option_id":"","booking_id":"booking_organic_001","hotel_id":"hotel_th_2201","hotel_cluster":"7","hotel_market":"7104","revenue":"318000","currency":"KRW"}',
    'valid'
);

-- =========================================================
-- 2. Expedia-compatible search rows
-- =========================================================

INSERT INTO expedia_hotel_events
(
    date_time,
    site_name,
    posa_continent,
    user_location_country,
    user_location_region,
    user_location_city,
    orig_destination_distance,
    user_id,
    is_mobile,
    is_package,
    channel,
    srch_ci,
    srch_co,
    srch_adults_cnt,
    srch_children_cnt,
    srch_rm_cnt,
    srch_destination_id,
    srch_destination_type_id,
    hotel_continent,
    hotel_country,
    hotel_market,
    is_booking,
    cnt,
    hotel_cluster
)
VALUES
('2026-07-02 01:00:13', 2, 3, 66, 348, 48862, 14.2, 1001, 1, 1, 9, '2026-07-12', '2026-07-15', 2, 2, 1, 8821, 1, 3, 66, 8821, 1, 1, 41),
('2026-07-02 02:15:02', 2, 3, 66, 348, 48862, 721.4, 1002, 1, 0, 5, '2026-07-05', '2026-07-07', 2, 0, 1, 4402, 1, 3, 70, 4402, 0, 1, 12),
('2026-07-02 03:30:22', 2, 3, 66, 348, 48862, 3711.8, 1003, 0, 1, 2, '2026-07-20', '2026-07-24', 1, 0, 1, 7104, 1, 3, 106, 7104, 1, 1, 7),
('2026-07-02 05:48:11', 2, 3, 66, 348, 48862, 55.9, 1004, 1, 0, 4, '2026-07-03', '2026-07-04', 1, 0, 1, 8821, 1, 3, 66, 8821, 0, 1, 29),
('2026-07-02 08:10:05', 2, 3, 66, 348, 48862, NULL, 1005, 0, 0, 1, NULL, NULL, 2, 1, 1, 9901, 3, 3, 66, 9901, 0, 2, 33),
('2026-07-02 10:22:54', 2, 3, 66, 348, 48862, 129.6, 1006, 1, 1, 9, '2026-07-09', '2026-07-14', 2, 2, 2, 8821, 1, 3, 66, 8821, 1, 1, 41);

-- =========================================================
-- 3. User behavior vectors
-- =========================================================

INSERT INTO user_behavior_vectors
(
    project_id,
    user_id,
    vector_dim,
    vector_values,
    vector_version,
    source,
    window_start,
    window_end,
    updated_at
)
SELECT
    'demo-shop',
    user_id,
    64,
    arrayMap(i -> toFloat32(
        multiIf(
            profile = 'family', if(i % 4 IN (0, 1), 0.82, 0.18),
            profile = 'couple', if(i % 4 IN (1, 2), 0.74, 0.22),
            profile = 'organic', if(i % 4 = 3, 0.68, 0.31),
            0.25
        )
    ), range(64)),
    'hotel_rec_promo.v1',
    'dummy.sql',
    '2026-07-01 00:00:00.000',
    '2026-07-03 00:00:00.000',
    '2026-07-03 00:10:00.000'
FROM
(
    SELECT 'user_family_001' AS user_id, 'family' AS profile
    UNION ALL
    SELECT 'user_couple_001' AS user_id, 'couple' AS profile
    UNION ALL
    SELECT 'user_organic_001' AS user_id, 'organic' AS profile
);

-- =========================================================
-- 4. Validation errors
-- =========================================================

INSERT INTO event_validation_errors
(
    project_id,
    event_id,
    event_name,
    received_at,
    error_code,
    error_message,
    payload_json
)
VALUES
(
    'demo-shop',
    'evt_demo_bad_0001',
    'booking_complete',
    '2026-07-02 04:01:03.000',
    'missing_booking_id',
    'booking_complete requires properties.booking_id',
    '{"seed_source":"clickhouse/dummy.sql","project_id":"demo-shop","event_name":"booking_complete","properties":{"hotel_id":"hotel_kr_9999","revenue":"199000","currency":"KRW"}}'
),
(
    'demo-shop',
    'evt_demo_bad_0002',
    'hotel_detail_view',
    '2026-07-02 04:07:48.000',
    'invalid_price',
    'hotel_detail_view properties.price must be a number',
    '{"seed_source":"clickhouse/dummy.sql","project_id":"demo-shop","event_name":"hotel_detail_view","properties":{"hotel_id":"hotel_kr_1207","price":"free"}}'
);
