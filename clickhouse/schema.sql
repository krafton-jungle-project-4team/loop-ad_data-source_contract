-- clickhouse/schema.sql
-- Loop-Ad hotel_rec_promo.v1 ClickHouse schema.
--
-- ClickHouse stores the source event stream and derived analytical views for
-- hotel reservation promotion funnels, segment preview queries, and ad
-- experiment evaluation.

-- =========================================================
-- 1. Raw Events
-- Event Collector inserts the validated hotel_rec_promo.v1 envelope here.
-- Promotion attribution values are kept in properties_json.
-- =========================================================

CREATE TABLE IF NOT EXISTS raw_events
(
    project_id      LowCardinality(String),
    schema_version  LowCardinality(String) DEFAULT 'hotel_rec_promo.v1',
    event_id        String,
    event_name      LowCardinality(String),
    event_time      DateTime64(3, 'UTC'),
    source          LowCardinality(String) DEFAULT 'browser_sdk',
    user_id         String,
    session_id      String,
    properties_json String DEFAULT '{}',

    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    event_date  Date MATERIALIZED toDate(toTimeZone(event_time, 'Asia/Seoul')),

    INDEX idx_event_id            event_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_user_id             user_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_session_id          session_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_campaign_id         JSONExtractString(properties_json, 'campaign_id') TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_promotion_id        JSONExtractString(properties_json, 'promotion_id') TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_promotion_run_id    JSONExtractString(properties_json, 'promotion_run_id') TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_ad_experiment_id    JSONExtractString(properties_json, 'ad_experiment_id') TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_segment_id          JSONExtractString(properties_json, 'segment_id') TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_hotel_id            JSONExtractString(properties_json, 'hotel_id') TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_hotel_cluster       JSONExtractString(properties_json, 'hotel_cluster') TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY
(
    project_id,
    event_date,
    event_name,
    session_id,
    user_id,
    event_time
);

-- =========================================================
-- 2. Expedia / Hotel Domain Events
-- Typed hotel behavior view over raw events.
-- =========================================================

CREATE VIEW IF NOT EXISTS expedia_hotel_events AS
SELECT
    event_time,
    event_date,
    project_id,
    user_id,
    session_id,
    event_name,
    JSONExtractString(properties_json, 'hotel_id') AS hotel_id,
    JSONExtractString(properties_json, 'hotel_cluster') AS hotel_cluster,
    JSONExtractString(properties_json, 'hotel_market') AS hotel_market,
    JSONExtractString(properties_json, 'hotel_city') AS hotel_city,
    JSONExtractString(properties_json, 'hotel_country') AS hotel_country,
    JSONExtractString(properties_json, 'checkin_date') AS checkin_date,
    JSONExtractString(properties_json, 'checkout_date') AS checkout_date,
    toUInt16OrZero(JSONExtractString(properties_json, 'adult_count')) AS adult_count,
    toUInt16OrZero(JSONExtractString(properties_json, 'child_count')) AS child_count,
    toDecimal64OrZero(JSONExtractString(properties_json, 'room_price'), 2) AS room_price,
    JSONExtractString(properties_json, 'currency') AS currency,
    properties_json
FROM raw_events
WHERE event_name IN
(
    'hotel_search',
    'hotel_click',
    'hotel_detail_view',
    'booking_start',
    'booking_complete',
    'booking_cancel'
);

-- =========================================================
-- 3. Hotel Marketing Profiles
-- User-level aggregates used by dashboards and segment preview queries.
-- =========================================================

CREATE VIEW IF NOT EXISTS hotel_marketing_profiles AS
SELECT
    project_id,
    user_id,
    min(event_time) AS first_seen_at,
    max(event_time) AS last_seen_at,
    countIf(event_name = 'hotel_search') AS hotel_search_count,
    countIf(event_name = 'hotel_click') AS hotel_click_count,
    countIf(event_name = 'hotel_detail_view') AS hotel_detail_view_count,
    countIf(event_name = 'booking_start') AS booking_start_count,
    countIf(event_name = 'booking_complete') AS booking_complete_count,
    countIf(event_name = 'booking_cancel') AS booking_cancel_count,
    uniqExactIf(JSONExtractString(properties_json, 'hotel_cluster'), event_name = 'hotel_detail_view') AS viewed_hotel_cluster_count,
    argMaxIf(JSONExtractString(properties_json, 'hotel_cluster'), event_time, event_name = 'hotel_detail_view') AS last_viewed_hotel_cluster,
    argMaxIf(JSONExtractString(properties_json, 'hotel_market'), event_time, event_name = 'hotel_detail_view') AS last_viewed_hotel_market,
    argMaxIf(JSONExtractString(properties_json, 'device'), event_time, JSONExtractString(properties_json, 'device') != '') AS last_device
FROM raw_events
GROUP BY
    project_id,
    user_id;

-- =========================================================
-- 4. Promotion Touch Events
-- Query source for inflow_rate, click rate, and promotion funnels.
-- =========================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS promotion_touch_events
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY
(
    project_id,
    campaign_id,
    promotion_id,
    promotion_run_id,
    ad_experiment_id,
    event_time,
    event_name,
    user_id
)
AS
SELECT
    event_time,
    event_date,
    project_id,
    user_id,
    session_id,
    event_name,
    JSONExtractString(properties_json, 'campaign_id') AS campaign_id,
    JSONExtractString(properties_json, 'promotion_id') AS promotion_id,
    JSONExtractString(properties_json, 'promotion_run_id') AS promotion_run_id,
    JSONExtractString(properties_json, 'ad_experiment_id') AS ad_experiment_id,
    JSONExtractString(properties_json, 'promotion_channel') AS promotion_channel,
    JSONExtractString(properties_json, 'segment_id') AS segment_id,
    JSONExtractString(properties_json, 'content_id') AS content_id,
    JSONExtractString(properties_json, 'content_option_id') AS content_option_id,
    JSONExtractString(properties_json, 'placement_id') AS placement_id,
    JSONExtractString(properties_json, 'landing_type') AS landing_type,
    properties_json
FROM raw_events
WHERE event_name IN
(
    'promotion_impression',
    'promotion_click',
    'campaign_redirect_click',
    'campaign_landing'
);

-- =========================================================
-- 5. Booking Outcome Events
-- Query source for booking_conversion_rate and booking funnels.
-- =========================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS booking_outcome_events
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY
(
    project_id,
    promotion_run_id,
    event_time,
    event_name,
    user_id
)
AS
SELECT
    event_time,
    event_date,
    project_id,
    user_id,
    session_id,
    event_name,
    JSONExtractString(properties_json, 'campaign_id') AS campaign_id,
    JSONExtractString(properties_json, 'promotion_id') AS promotion_id,
    JSONExtractString(properties_json, 'promotion_run_id') AS promotion_run_id,
    nullIf(JSONExtractString(properties_json, 'ad_experiment_id'), '') AS ad_experiment_id,
    JSONExtractString(properties_json, 'segment_id') AS segment_id,
    JSONExtractString(properties_json, 'booking_id') AS booking_id,
    JSONExtractString(properties_json, 'hotel_id') AS hotel_id,
    JSONExtractString(properties_json, 'hotel_cluster') AS hotel_cluster,
    JSONExtractString(properties_json, 'hotel_market') AS hotel_market,
    JSONExtractString(properties_json, 'checkin_date') AS checkin_date,
    JSONExtractString(properties_json, 'checkout_date') AS checkout_date,
    toDecimal64OrZero(JSONExtractString(properties_json, 'booking_value'), 2) AS booking_value,
    JSONExtractString(properties_json, 'currency') AS currency,
    properties_json
FROM raw_events
WHERE event_name IN
(
    'booking_start',
    'booking_complete',
    'booking_cancel'
);

-- =========================================================
-- 6. Hotel Detail Events
-- Contract view used by segment SQL preview examples.
-- =========================================================

CREATE VIEW IF NOT EXISTS hotel_detail_events AS
SELECT
    event_time,
    event_date,
    project_id,
    user_id,
    session_id,
    JSONExtractString(properties_json, 'hotel_id') AS hotel_id,
    JSONExtractString(properties_json, 'hotel_cluster') AS hotel_cluster,
    JSONExtractString(properties_json, 'hotel_market') AS hotel_market,
    JSONExtractString(properties_json, 'hotel_city') AS hotel_city,
    JSONExtractString(properties_json, 'hotel_country') AS hotel_country,
    properties_json
FROM raw_events
WHERE event_name = 'hotel_detail_view';

-- =========================================================
-- 7. Funnel Step Events
-- Common hotel and promotion funnel event projection.
-- =========================================================

CREATE VIEW IF NOT EXISTS funnel_step_events AS
SELECT
    event_time,
    event_date,
    project_id,
    user_id,
    session_id,
    event_name,
    JSONExtractString(properties_json, 'campaign_id') AS campaign_id,
    JSONExtractString(properties_json, 'promotion_id') AS promotion_id,
    JSONExtractString(properties_json, 'promotion_run_id') AS promotion_run_id,
    JSONExtractString(properties_json, 'ad_experiment_id') AS ad_experiment_id,
    JSONExtractString(properties_json, 'promotion_channel') AS promotion_channel,
    JSONExtractString(properties_json, 'segment_id') AS segment_id,
    multiIf(
        event_name = 'page_view', 1,
        event_name = 'campaign_redirect_click', 1,
        event_name = 'promotion_impression', 1,
        event_name = 'campaign_landing', 2,
        event_name = 'promotion_click', 2,
        event_name = 'hotel_search', 3,
        event_name = 'hotel_click', 4,
        event_name = 'hotel_detail_view', 5,
        event_name = 'booking_start', 6,
        event_name = 'booking_complete', 7,
        event_name = 'booking_cancel', 8,
        0
    ) AS step_order,
    multiIf(
        event_name IN ('campaign_redirect_click', 'campaign_landing'), 'email_sms_promotion',
        event_name IN ('promotion_impression', 'promotion_click'), 'onsite_banner_promotion',
        'hotel_booking'
    ) AS funnel_type,
    properties_json
FROM raw_events
WHERE event_name IN
(
    'page_view',
    'promotion_impression',
    'promotion_click',
    'campaign_redirect_click',
    'campaign_landing',
    'hotel_search',
    'hotel_click',
    'hotel_detail_view',
    'booking_start',
    'booking_complete',
    'booking_cancel'
);

-- =========================================================
-- 8. User Behavior Vectors
-- Decision writes or refreshes derived vectors used for segment matching.
-- =========================================================

CREATE TABLE IF NOT EXISTS user_behavior_vectors
(
    project_id        LowCardinality(String),
    user_id           String,
    vector_version    String,
    dimensions        UInt16 DEFAULT 64,
    vector_json       String DEFAULT '[]',
    top_features_json String DEFAULT '[]',
    source_window_start DateTime64(3, 'UTC'),
    source_window_end   DateTime64(3, 'UTC'),
    updated_at       DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    updated_date     Date MATERIALIZED toDate(toTimeZone(updated_at, 'Asia/Seoul')),

    INDEX idx_user_behavior_user user_id TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = ReplacingMergeTree(updated_at)
PARTITION BY toYYYYMM(updated_date)
ORDER BY
(
    project_id,
    vector_version,
    user_id
);

-- =========================================================
-- 9. Event Validation Errors
-- Collector validation failures for operational analysis.
-- =========================================================

CREATE TABLE IF NOT EXISTS event_validation_errors
(
    error_id       String,
    project_id     LowCardinality(String) DEFAULT '',
    schema_version LowCardinality(String) DEFAULT '',
    event_id       String DEFAULT '',
    event_name     LowCardinality(String) DEFAULT '',
    source         LowCardinality(String) DEFAULT '',
    error_code     LowCardinality(String),
    error_message  String,
    payload_json   String DEFAULT '{}',
    created_at     DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    error_date     Date MATERIALIZED toDate(toTimeZone(created_at, 'Asia/Seoul')),

    INDEX idx_validation_event_id event_id TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(error_date)
ORDER BY
(
    project_id,
    error_date,
    event_name,
    error_code,
    created_at
);
