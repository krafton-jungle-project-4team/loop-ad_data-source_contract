CREATE DATABASE IF NOT EXISTS loopad;
USE loopad;

CREATE TABLE IF NOT EXISTS user_behavior_vector_revisions
(
    project_id String,
    user_id String,
    vector_dim UInt16,
    vector_values Array(Float32),
    vector_version String,
    source LowCardinality(String),
    window_start DateTime64(3, 'UTC'),
    window_end DateTime64(3, 'UTC'),
    updated_at DateTime64(3, 'UTC'),
    vector_row_id String,
    ingested_at DateTime64(6, 'UTC')
)
ENGINE = MergeTree
ORDER BY (
    project_id,
    user_id,
    vector_version,
    ingested_at,
    updated_at,
    vector_row_id
);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_user_behavior_vectors_to_revisions
TO user_behavior_vector_revisions AS
SELECT
    project_id,
    user_id,
    vector_dim,
    vector_values,
    vector_version,
    source,
    window_start,
    window_end,
    updated_at,
    lower(hex(SHA256(toJSONString(tuple(
        project_id,
        user_id,
        vector_version,
        toUnixTimestamp64Milli(updated_at),
        vector_dim,
        vector_values,
        CAST(source, 'String'),
        toUnixTimestamp64Milli(window_start),
        toUnixTimestamp64Milli(window_end)
    ))))) AS vector_row_id,
    now64(6, 'UTC') AS ingested_at
FROM user_behavior_vectors;
