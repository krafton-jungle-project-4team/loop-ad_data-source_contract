USE loopad;

INSERT INTO user_behavior_vector_revisions (
    project_id,
    user_id,
    vector_dim,
    vector_values,
    vector_version,
    source,
    window_start,
    window_end,
    updated_at,
    vector_row_id,
    ingested_at
)
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
FROM user_behavior_vectors FINAL;
