-- Named collection loopad_events_kafka -> loopad.events.
-- events_raw_kafka는 저장하지 않는 Kafka source table이고, events가 영구 저장 테이블이다.

CREATE DATABASE IF NOT EXISTS loopad;

USE loopad;

CREATE TABLE IF NOT EXISTS events
(
    project_id      String,
    event_id        String,
    user_id         String,
    session_id      String,
    event_time      DateTime64(3, 'UTC'),
    event_name      String,

    channel         String DEFAULT '',
    campaign_id     String DEFAULT '',

    age_group       String DEFAULT '',
    gender          String DEFAULT '',
    device          String DEFAULT '',

    category         String DEFAULT '',
    product_id       String DEFAULT '',
    inventory_status String DEFAULT '',

    price            Decimal(18, 2) DEFAULT 0,
    quantity         UInt32 DEFAULT 0,
    revenue          Decimal(18, 2) DEFAULT 0,

    coupon_id        String DEFAULT '',
    order_id         String DEFAULT '',

    experiment_id    String DEFAULT '',
    variant_id       String DEFAULT '',
    action_id        String DEFAULT '',
    mapping_id       String DEFAULT '',

    ad_id            String DEFAULT '',
    creative_id      String DEFAULT '',

    bandit_policy_id   String DEFAULT '',
    bandit_arm_id      String DEFAULT '',
    bandit_decision_id String DEFAULT '',

    reward_value       Float64 DEFAULT 0,
    properties_json    String DEFAULT '{}',
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (project_id, event_time, event_name);

CREATE TABLE IF NOT EXISTS events_raw_kafka
(
    project_id      String,
    event_id        String,
    user_id         String,
    session_id      String,
    event_time      String,
    event_name      String,

    channel         String,
    campaign_id     String,

    age_group       String,
    gender          String,
    device          String,

    category         String,
    product_id       String,
    inventory_status String,

    price            Decimal(18, 2),
    quantity         UInt32,
    revenue          Decimal(18, 2),

    coupon_id        String,
    order_id         String,

    experiment_id    String,
    variant_id       String,
    action_id        String,
    mapping_id       String,

    ad_id            String,
    creative_id      String,

    bandit_policy_id   String,
    bandit_arm_id      String,
    bandit_decision_id String,

    reward_value       Float64,
    properties_json    String
)
ENGINE = Kafka(loopad_events_kafka);

CREATE MATERIALIZED VIEW IF NOT EXISTS events_raw_kafka_to_events
TO events
AS
SELECT
    project_id,
    event_id,
    user_id,
    session_id,
    parseDateTime64BestEffort(event_time, 3, 'UTC') AS event_time,
    event_name,

    channel,
    campaign_id,

    age_group,
    gender,
    device,

    category,
    product_id,
    inventory_status,

    price,
    quantity,
    revenue,

    coupon_id,
    order_id,

    experiment_id,
    variant_id,
    action_id,
    mapping_id,

    ad_id,
    creative_id,

    bandit_policy_id,
    bandit_arm_id,
    bandit_decision_id,

    reward_value,
    properties_json
FROM events_raw_kafka;
