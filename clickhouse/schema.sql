-- clickhouse/schema.sql
-- Loop Ad MVP ClickHouse schema
--
-- 기준:
-- 1. Browser SDK가 Event Collector로 보내는 flat payload를 그대로 수용한다.
-- 2. ClickHouse는 사용자 행동 로그와 reward 계산의 원천 이벤트 저장소다.
-- 3. SDK가 보내지 않는 ingested_at/event_date는 ClickHouse에서 생성한다.
-- 4. alpha/beta 같은 bandit 상태값은 PostgreSQL에 두고,
--    ClickHouse에는 어떤 decision/arm/action에서 발생한 이벤트인지 추적 가능한 id만 남긴다.

-- =========================================================
-- 1. Raw Events
-- =========================================================

CREATE TABLE IF NOT EXISTS events
(
    -- -----------------------------------------------------
    -- Required identifiers
    -- SDK가 항상 보내는 필수 식별자
    -- -----------------------------------------------------
    project_id      LowCardinality(String),
    event_id        String,
    user_id         String,
    session_id      String,

    -- SDK는 ISO string으로 보내고,
    -- Event Collector가 DateTime64(3, 'UTC')로 변환해서 insert한다.
    event_time      DateTime64(3, 'UTC'),

    -- page_view, product_view, add_to_cart, checkout_start,
    -- purchase, ad_impression, ad_click, coupon_issued, coupon_used 등
    event_name      LowCardinality(String),

    -- -----------------------------------------------------
    -- Segment / attribution context
    -- SDK EventContext와 1:1 매핑
    -- -----------------------------------------------------
    channel         LowCardinality(String) DEFAULT '',
    campaign_id     String DEFAULT '',

    age_group       LowCardinality(String) DEFAULT '',
    gender          LowCardinality(String) DEFAULT '',
    device          LowCardinality(String) DEFAULT '',

    -- -----------------------------------------------------
    -- Product / commerce context
    -- -----------------------------------------------------
    category         LowCardinality(String) DEFAULT '',
    product_id       String DEFAULT '',
    inventory_status LowCardinality(String) DEFAULT '',

    price            Decimal(18, 2) DEFAULT 0,
    quantity         UInt32 DEFAULT 0,
    revenue          Decimal(18, 2) DEFAULT 0,

    coupon_id        String DEFAULT '',
    order_id         String DEFAULT '',

    -- -----------------------------------------------------
    -- Experiment / action / ad tracking
    -- -----------------------------------------------------
    experiment_id    String DEFAULT '',
    variant_id       LowCardinality(String) DEFAULT '',
    action_id        String DEFAULT '',
    mapping_id       String DEFAULT '',

    ad_id            String DEFAULT '',
    creative_id      String DEFAULT '',

    -- -----------------------------------------------------
    -- Bandit tracking
    -- PostgreSQL bandit 상태와 연결하기 위한 식별자
    -- -----------------------------------------------------
    bandit_policy_id   String DEFAULT '',
    bandit_arm_id      String DEFAULT '',
    bandit_decision_id String DEFAULT '',

    -- 구매, 클릭, 퍼널 진행 등 reward worker가 사용할 수 있는 값
    reward_value       Float64 DEFAULT 0,

    -- -----------------------------------------------------
    -- Flexible properties
    -- SDK가 JSON.stringify 해서 보내는 추가 속성
    -- 예: page.url, page.path, sdk.version, element metadata 등
    -- -----------------------------------------------------
    properties_json    String DEFAULT '{}',

    -- -----------------------------------------------------
    -- Internal columns
    -- SDK가 보내지 않는다.
    -- -----------------------------------------------------
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),

    -- 대시보드에서 한국 시간 기준 일자 집계를 쉽게 하기 위한 materialized column
    event_date Date MATERIALIZED toDate(toTimeZone(event_time, 'Asia/Seoul')),

    -- -----------------------------------------------------
    -- Data skipping indexes
    -- -----------------------------------------------------
    INDEX idx_event_id           event_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_user_id            user_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_session_id         session_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_product_id         product_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_campaign_id        campaign_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_experiment_id      experiment_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_action_id          action_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_mapping_id         mapping_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_ad_id              ad_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_creative_id        creative_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_bandit_policy_id   bandit_policy_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_bandit_arm_id      bandit_arm_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_bandit_decision_id bandit_decision_id TYPE bloom_filter(0.01) GRANULARITY 4
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