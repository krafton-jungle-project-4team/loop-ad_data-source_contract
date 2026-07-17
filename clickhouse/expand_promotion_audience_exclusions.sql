CREATE DATABASE IF NOT EXISTS loopad;
USE loopad;

SELECT throwIf(
    (
        SELECT count()
        FROM system.tables
        WHERE database = currentDatabase()
          AND name IN (
              'promotion_audience_exclusion_current',
              'promotion_audience_exclusion_projection_status_current'
          )
    ) != 0,
    'unsupported pre-release exclusion helper views detected; rebuild the V2 baseline database'
);

-- PostgreSQL publishes each ledger state with its exclusion revision, then
-- advances the checkpoint only after all rows for that revision are visible.
CREATE TABLE IF NOT EXISTS promotion_audience_exclusion_projection
(
    project_id String,
    campaign_id String,
    promotion_id String,
    user_id String,
    state LowCardinality(String),
    exclusion_revision UInt64,
    updated_at DateTime64(6, 'UTC'),

    CONSTRAINT chk_promotion_audience_exclusion_projection_state
        CHECK state IN ('reserved', 'consumed', 'released')
)
ENGINE = ReplacingMergeTree(exclusion_revision)
ORDER BY (project_id, promotion_id, user_id);

CREATE TABLE IF NOT EXISTS promotion_audience_exclusion_projection_status
(
    project_id String,
    promotion_id String,
    applied_revision UInt64,
    applied_at DateTime64(6, 'UTC')
)
ENGINE = ReplacingMergeTree(applied_revision)
ORDER BY (project_id, promotion_id);

CREATE VIEW IF NOT EXISTS promotion_audience_exclusion_active AS
SELECT
    project_id,
    tupleElement(latest_state, 1) AS campaign_id,
    promotion_id,
    user_id,
    tupleElement(latest_state, 2) AS state,
    tupleElement(latest_state, 3) AS exclusion_revision,
    tupleElement(latest_state, 4) AS updated_at
FROM (
    SELECT
        project_id,
        promotion_id,
        user_id,
        argMax(
            tuple(campaign_id, state, exclusion_revision, updated_at),
            tuple(exclusion_revision, updated_at)
        ) AS latest_state
    FROM promotion_audience_exclusion_projection
    GROUP BY
        project_id,
        promotion_id,
        user_id
)
WHERE tupleElement(latest_state, 2) IN ('reserved', 'consumed');

SELECT throwIf(
    (
        SELECT count()
        FROM system.tables
        WHERE database = currentDatabase()
          AND name IN (
              'promotion_audience_exclusion_projection',
              'promotion_audience_exclusion_projection_status',
              'promotion_audience_exclusion_active'
          )
    ) != 3,
    'promotion audience exclusion projection contract is incomplete'
);
