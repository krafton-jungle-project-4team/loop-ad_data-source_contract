-- =========================================================
-- Loop-Ad ClickHouse Schema Contract v1.6
-- Owner: loop-ad_data-source_contract
-- Domain: hotel / accommodation booking
--
-- Purpose:
--   - raw event storage
--   - typed promotion touch / booking outcome events
--   - Expedia hotel sample data
--   - hotel profile views
--   - funnel/segment-query support views
--   - 64-dimensional user behavior vectors
-- =========================================================

-- =========================================================
-- 0. Raw Events
-- Collector/Kafka consumer stores original hotel_rec_promo.v1 envelope here.
-- =========================================================
CREATE TABLE IF NOT EXISTS raw_events
(
    project_id String,
    write_key String,
    schema_version LowCardinality(String),

    event_id String,
    event_name LowCardinality(String),
    event_time DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC') DEFAULT now64(3),

    source LowCardinality(String),
    user_id String,
    session_id Nullable(String),

    properties_json String,
    validation_status LowCardinality(String) DEFAULT 'valid',
    event_date Date MATERIALIZED toDate(event_time)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (project_id, event_name, event_time, user_id, event_id);

-- =========================================================
-- 1. Expedia Hotel Events
-- Kaggle Expedia Hotel Recommendations train.csv compatible table.
-- =========================================================
CREATE TABLE IF NOT EXISTS expedia_hotel_events
(
    date_time DateTime,

    site_name UInt16,
    posa_continent UInt8,
    user_location_country UInt16,
    user_location_region UInt16,
    user_location_city UInt32,
    orig_destination_distance Nullable(Float64),

    user_id UInt32,
    is_mobile UInt8,
    is_package UInt8,
    channel UInt16,

    srch_ci Nullable(Date),
    srch_co Nullable(Date),
    srch_adults_cnt UInt8,
    srch_children_cnt UInt8,
    srch_rm_cnt UInt8,
    srch_destination_id UInt32,
    srch_destination_type_id UInt8,

    hotel_continent UInt8,
    hotel_country UInt16,
    hotel_market UInt32,

    is_booking UInt8,
    cnt UInt32,
    hotel_cluster UInt8,

    event_date Date MATERIALIZED toDate(date_time)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, date_time, srch_destination_id, hotel_cluster);

-- =========================================================
-- 2. Hotel Marketing Profiles View
-- Expedia-derived behavioral profile used by Decision analysis/segment vectors.
-- =========================================================
CREATE VIEW IF NOT EXISTS hotel_marketing_profiles AS
SELECT
    date_time,
    toString(user_id) AS user_id,
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
    hotel_cluster,

    if(
        isNull(srch_ci) OR isNull(srch_co),
        CAST(NULL, 'Nullable(Int32)'),
        dateDiff('day', srch_ci, srch_co)
    ) AS stay_nights,

    if(
        isNull(srch_ci),
        CAST(NULL, 'Nullable(Int32)'),
        dateDiff('day', toDate(date_time), srch_ci)
    ) AS days_until_checkin,

    multiIf(
        is_mobile = 1, 'seg_mobile_user',
        srch_children_cnt > 0, 'seg_family_trip',
        srch_adults_cnt = 2 AND srch_children_cnt = 0 AND srch_rm_cnt = 1, 'seg_couple_trip',
        is_package = 1, 'seg_package_trip',
        (NOT isNull(srch_ci) AND NOT isNull(srch_co) AND dateDiff('day', srch_ci, srch_co) >= 4), 'seg_long_stay',
        (NOT isNull(srch_ci) AND dateDiff('day', toDate(date_time), srch_ci) BETWEEN 0 AND 7), 'seg_near_checkin',
        'seg_existing_all'
    ) AS primary_segment
FROM expedia_hotel_events;

-- =========================================================
-- 3. Promotion Touch Events
-- Typed events for promotion touch/inflow/CTR metrics.
-- Includes ad_experiment_id per v1.6.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_touch_events
(
    event_time DateTime64(3, 'UTC'),
    event_name LowCardinality(String),

    project_id String,
    campaign_id String,
    promotion_id String,
    promotion_run_id String,
    ad_experiment_id String,

    user_id String,
    session_id Nullable(String),
    segment_id String,

    channel LowCardinality(String),
    content_id String,
    content_option_id String,
    source LowCardinality(String),

    redirect_id Nullable(String),
    placement_id Nullable(String),
    landing_url Nullable(String),
    target_url Nullable(String),

    properties_json String,
    event_date Date MATERIALIZED toDate(event_time)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (
    project_id,
    campaign_id,
    promotion_id,
    promotion_run_id,
    ad_experiment_id,
    event_time,
    event_name,
    user_id
);

-- =========================================================
-- 4. Booking Outcome Events
-- Typed booking events. Promotion fields are nullable/empty for organic bookings,
-- but promotion evaluation uses only rows with promotion_run/ad_experiment ids.
-- =========================================================
CREATE TABLE IF NOT EXISTS booking_outcome_events
(
    event_time DateTime64(3, 'UTC'),
    event_name LowCardinality(String),

    project_id String,
    campaign_id Nullable(String),
    promotion_id Nullable(String),
    promotion_run_id Nullable(String),
    ad_experiment_id Nullable(String),

    user_id String,
    session_id Nullable(String),
    segment_id Nullable(String),

    content_id Nullable(String),
    content_option_id Nullable(String),

    booking_id String,
    booking_status LowCardinality(String),
    hotel_id Nullable(String),
    hotel_cluster Nullable(UInt8),
    hotel_market Nullable(UInt32),
    revenue Nullable(Float64),
    currency Nullable(String),

    properties_json String,
    event_date Date MATERIALIZED toDate(event_time)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (project_id, event_time, user_id, booking_id, event_name);

-- =========================================================
-- 5. User Behavior Vectors
-- 64-dimensional user vectors for Decision segment matching.
-- =========================================================
CREATE TABLE IF NOT EXISTS user_behavior_vectors
(
    project_id String,
    user_id String,
    vector_dim UInt16,
    vector_values Array(Float32),
    vector_version String,
    source LowCardinality(String),
    window_start DateTime64(3, 'UTC'),
    window_end DateTime64(3, 'UTC'),
    updated_at DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (project_id, user_id, vector_version);

-- =========================================================
-- 6. Event Validation Errors
-- Collector writes invalid payloads here or equivalent Postgres table.
-- =========================================================
CREATE TABLE IF NOT EXISTS event_validation_errors
(
    project_id Nullable(String),
    event_id Nullable(String),
    event_name Nullable(String),
    received_at DateTime64(3, 'UTC') DEFAULT now64(3),
    error_code LowCardinality(String),
    error_message String,
    payload_json String,
    event_date Date MATERIALIZED toDate(received_at)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, project_id, event_name, error_code);

-- =========================================================
-- 7. Hotel Detail Events View
-- Used by Dashboard segment SQL preview examples.
-- =========================================================
CREATE VIEW IF NOT EXISTS hotel_detail_events AS
SELECT
    event_time,
    project_id,
    user_id,
    session_id,
    nullIf(JSONExtractString(properties_json, 'hotel_id'), '') AS hotel_id,
    nullIf(JSONExtractString(properties_json, 'hotel_cluster'), '') AS hotel_cluster,
    nullIf(JSONExtractString(properties_json, 'hotel_market'), '') AS hotel_market,
    toFloat64OrNull(JSONExtractString(properties_json, 'price')) AS price,
    toUInt8OrNull(JSONExtractString(properties_json, 'breakfast_included')) AS breakfast_included,
    toUInt8OrNull(JSONExtractString(properties_json, 'free_cancellation')) AS free_cancellation,
    nullIf(JSONExtractString(properties_json, 'room_type'), '') AS room_type,
    properties_json
FROM raw_events
WHERE event_name = 'hotel_detail_view';

-- =========================================================
-- 8. Funnel Step Events View
-- Generic funnel event stream for Dashboard funnel page.
-- =========================================================
CREATE VIEW IF NOT EXISTS funnel_step_events AS
SELECT
    event_time,
    event_name,
    project_id,
    user_id,
    session_id,
    nullIf(JSONExtractString(properties_json, 'campaign_id'), '') AS campaign_id,
    nullIf(JSONExtractString(properties_json, 'promotion_id'), '') AS promotion_id,
    nullIf(JSONExtractString(properties_json, 'promotion_run_id'), '') AS promotion_run_id,
    nullIf(JSONExtractString(properties_json, 'ad_experiment_id'), '') AS ad_experiment_id,
    nullIf(JSONExtractString(properties_json, 'segment_id'), '') AS segment_id,
    nullIf(JSONExtractString(properties_json, 'hotel_id'), '') AS hotel_id,
    nullIf(JSONExtractString(properties_json, 'hotel_cluster'), '') AS hotel_cluster,
    nullIf(JSONExtractString(properties_json, 'page_path'), '') AS page_path,
    source,
    properties_json
FROM raw_events
WHERE event_name IN (
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
-- 9. Materialized View: Raw -> Promotion Touch Events
-- If the ingestion pipeline writes typed tables directly, this MV can be omitted.
-- =========================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_raw_to_promotion_touch_events
TO promotion_touch_events AS
SELECT
    event_time,
    event_name,
    project_id,
    JSONExtractString(properties_json, 'campaign_id') AS campaign_id,
    JSONExtractString(properties_json, 'promotion_id') AS promotion_id,
    JSONExtractString(properties_json, 'promotion_run_id') AS promotion_run_id,
    JSONExtractString(properties_json, 'ad_experiment_id') AS ad_experiment_id,
    user_id,
    session_id,
    JSONExtractString(properties_json, 'segment_id') AS segment_id,
    JSONExtractString(properties_json, 'promotion_channel') AS channel,
    JSONExtractString(properties_json, 'content_id') AS content_id,
    JSONExtractString(properties_json, 'content_option_id') AS content_option_id,
    source,
    nullIf(JSONExtractString(properties_json, 'redirect_id'), '') AS redirect_id,
    nullIf(JSONExtractString(properties_json, 'placement_id'), '') AS placement_id,
    nullIf(JSONExtractString(properties_json, 'landing_url'), '') AS landing_url,
    nullIf(JSONExtractString(properties_json, 'target_url'), '') AS target_url,
    properties_json
FROM raw_events
WHERE event_name IN (
    'promotion_impression',
    'promotion_click',
    'campaign_redirect_click',
    'campaign_landing'
)
  AND validation_status = 'valid';

-- =========================================================
-- 10. Materialized View: Raw -> Booking Outcome Events
-- Promotion evaluation uses booking rows with promotion_run_id/ad_experiment_id.
-- Organic booking rows may have null promotion fields.
-- =========================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_raw_to_booking_outcome_events
TO booking_outcome_events AS
SELECT
    event_time,
    event_name,
    project_id,
    nullIf(JSONExtractString(properties_json, 'campaign_id'), '') AS campaign_id,
    nullIf(JSONExtractString(properties_json, 'promotion_id'), '') AS promotion_id,
    nullIf(JSONExtractString(properties_json, 'promotion_run_id'), '') AS promotion_run_id,
    nullIf(JSONExtractString(properties_json, 'ad_experiment_id'), '') AS ad_experiment_id,
    user_id,
    session_id,
    nullIf(JSONExtractString(properties_json, 'segment_id'), '') AS segment_id,
    nullIf(JSONExtractString(properties_json, 'content_id'), '') AS content_id,
    nullIf(JSONExtractString(properties_json, 'content_option_id'), '') AS content_option_id,
    JSONExtractString(properties_json, 'booking_id') AS booking_id,
    multiIf(
        event_name = 'booking_start', 'started',
        event_name = 'booking_complete', 'completed',
        event_name = 'booking_cancel', 'cancelled',
        'unknown'
    ) AS booking_status,
    nullIf(JSONExtractString(properties_json, 'hotel_id'), '') AS hotel_id,
    toUInt8OrNull(JSONExtractString(properties_json, 'hotel_cluster')) AS hotel_cluster,
    toUInt32OrNull(JSONExtractString(properties_json, 'hotel_market')) AS hotel_market,
    toFloat64OrNull(JSONExtractString(properties_json, 'revenue')) AS revenue,
    nullIf(JSONExtractString(properties_json, 'currency'), '') AS currency,
    properties_json
FROM raw_events
WHERE event_name IN ('booking_start', 'booking_complete', 'booking_cancel')
  AND validation_status = 'valid';
