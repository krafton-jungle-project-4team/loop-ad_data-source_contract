USE loopad;

SELECT throwIf(
    (
        SELECT count()
        FROM system.tables
        WHERE database = currentDatabase()
          AND name = 'user_behavior_vectors'
          AND engine = 'ReplacingMergeTree'
    ) != 1,
    'existing user_behavior_vectors engine changed'
);

SELECT throwIf(
    (
        SELECT count()
        FROM system.tables
        WHERE database = currentDatabase()
          AND name = 'user_behavior_vector_revisions'
          AND engine = 'MergeTree'
    ) != 1,
    'revision table is missing or is not append-only MergeTree storage'
);

SELECT throwIf(
    (
        SELECT count()
        FROM system.tables
        WHERE database = currentDatabase()
          AND name = 'mv_user_behavior_vectors_to_revisions'
          AND engine = 'MaterializedView'
    ) != 1,
    'revision materialized view is missing'
);

SELECT throwIf(
    (
        SELECT count()
        FROM user_behavior_vector_revisions
        WHERE project_id = 'contract_project'
          AND user_id = 'legacy_user'
          AND vector_version = 'contract-v1'
    ) < 2,
    'repeated backfill did not preserve the visible legacy vector'
);

SELECT throwIf(
    (
        SELECT uniqExact(tuple(
            vector_dim,
            vector_values,
            CAST(source, 'String'),
            window_start,
            window_end,
            updated_at,
            vector_row_id
        ))
        FROM user_behavior_vector_revisions
        WHERE project_id = 'contract_project'
          AND user_id = 'legacy_user'
          AND vector_version = 'contract-v1'
    ) != 1,
    'repeated backfill changed the canonical legacy payload'
);

INSERT INTO user_behavior_vectors (
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
VALUES (
    'contract_project',
    'mv_user',
    3,
    [0.1, 0.2, 0.3],
    'contract-v1',
    'mv_fixture',
    toDateTime64('2026-07-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-07-02 00:00:00', 3, 'UTC'),
    toDateTime64('2026-07-03 00:00:00', 3, 'UTC')
);

SELECT throwIf(
    (
        SELECT count()
        FROM user_behavior_vector_revisions
        WHERE project_id = 'contract_project'
          AND user_id = 'mv_user'
          AND vector_version = 'contract-v1'
          AND match(vector_row_id, '^[0-9a-f]{64}$')
    ) != 1,
    'new source insert was not copied with a stable SHA-256 row ID'
);

INSERT INTO user_behavior_vectors (
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
VALUES
(
    'contract_project',
    'tie_user',
    3,
    [0.9, 0.1, 0.2],
    'contract-v1',
    'tie_source_a',
    toDateTime64('2026-07-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-07-02 00:00:00', 3, 'UTC'),
    toDateTime64('2026-07-05 00:00:00', 3, 'UTC')
),
(
    'contract_project',
    'tie_user',
    3,
    [0.1, 0.8, 0.3],
    'contract-v1',
    'tie_source_b',
    toDateTime64('2026-06-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-06-02 00:00:00', 3, 'UTC'),
    toDateTime64('2026-07-05 00:00:00', 3, 'UTC')
);

SELECT throwIf(
    (
        SELECT tupleElement(
            argMax(
                tuple(
                    vector_dim,
                    vector_values,
                    CAST(source, 'String'),
                    window_start,
                    window_end,
                    updated_at,
                    vector_row_id
                ),
                tuple(updated_at, vector_row_id)
            ),
            7
        )
        FROM user_behavior_vector_revisions
        WHERE project_id = 'contract_project'
          AND user_id = 'tie_user'
          AND vector_version = 'contract-v1'
    ) != (
        SELECT max(vector_row_id)
        FROM user_behavior_vector_revisions
        WHERE project_id = 'contract_project'
          AND user_id = 'tie_user'
          AND vector_version = 'contract-v1'
    ),
    'same-timestamp winner is not deterministic by vector_row_id'
);

WITH winner AS (
    SELECT argMax(
        tuple(
            vector_dim,
            vector_values,
            CAST(source, 'String'),
            window_start,
            window_end,
            updated_at,
            vector_row_id
        ),
        tuple(updated_at, vector_row_id)
    ) AS payload
    FROM user_behavior_vector_revisions
    WHERE project_id = 'contract_project'
      AND user_id = 'tie_user'
      AND vector_version = 'contract-v1'
)
SELECT throwIf(
    (
        SELECT count()
        FROM user_behavior_vector_revisions
        WHERE project_id = 'contract_project'
          AND user_id = 'tie_user'
          AND vector_version = 'contract-v1'
          AND tuple(
                vector_dim,
                vector_values,
                CAST(source, 'String'),
                window_start,
                window_end,
                updated_at,
                vector_row_id
              ) = (SELECT payload FROM winner)
    ) = 0,
    'canonical argMax mixed columns from different physical rows'
);

INSERT INTO user_behavior_vector_revisions VALUES
(
    'cutoff_project', 'cutoff_user', 2, [0.2, 0.4], 'cutoff-v1',
    'cutoff_source',
    toDateTime64('2025-12-01 00:00:00', 3, 'UTC'),
    toDateTime64('2025-12-31 00:00:00', 3, 'UTC'),
    toDateTime64('2026-01-01 00:00:00', 3, 'UTC'),
    repeat('1', 64),
    toDateTime64('2026-01-01 12:00:00', 6, 'UTC')
);

SELECT throwIf(
    (
        SELECT tupleElement(
            argMax(
                tuple(
                    vector_dim,
                    vector_values,
                    CAST(source, 'String'),
                    window_start,
                    window_end,
                    updated_at,
                    vector_row_id
                ),
                tuple(updated_at, vector_row_id)
            ),
            7
        )
        FROM user_behavior_vector_revisions
        WHERE project_id = 'cutoff_project'
          AND user_id = 'cutoff_user'
          AND vector_version = 'cutoff-v1'
          AND ingested_at < toDateTime64(
              '2026-01-15 00:00:00', 6, 'UTC'
          )
    ) != repeat('1', 64),
    'pre-cutoff baseline winner differs'
);

INSERT INTO user_behavior_vector_revisions VALUES
(
    'cutoff_project', 'cutoff_user', 2, [0.8, 0.6], 'cutoff-v1',
    'cutoff_source',
    toDateTime64('2026-01-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-01-31 00:00:00', 3, 'UTC'),
    toDateTime64('2026-02-01 00:00:00', 3, 'UTC'),
    repeat('2', 64),
    toDateTime64('2026-02-01 12:00:00', 6, 'UTC')
);

SELECT throwIf(
    (
        SELECT tupleElement(
            argMax(
                tuple(
                    vector_dim,
                    vector_values,
                    CAST(source, 'String'),
                    window_start,
                    window_end,
                    updated_at,
                    vector_row_id
                ),
                tuple(updated_at, vector_row_id)
            ),
            7
        )
        FROM user_behavior_vector_revisions
        WHERE project_id = 'cutoff_project'
          AND user_id = 'cutoff_user'
          AND vector_version = 'cutoff-v1'
          AND ingested_at < toDateTime64(
              '2026-01-15 00:00:00', 6, 'UTC'
          )
    ) != repeat('1', 64),
    'a post-cutoff insert changed the historical cutoff winner'
);

INSERT INTO user_behavior_vector_revisions VALUES
(
    'source_project', 'source_user', 2, [0.3, 0.7], 'source-v1',
    'source_a',
    toDateTime64('2026-01-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-01-10 00:00:00', 3, 'UTC'),
    toDateTime64('2026-01-10 00:00:00', 3, 'UTC'),
    repeat('3', 64),
    toDateTime64('2026-01-10 12:00:00', 6, 'UTC')
),
(
    'source_project', 'source_user', 2, [0.9, 0.1], 'source-v1',
    'source_b',
    toDateTime64('2026-02-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-02-10 00:00:00', 3, 'UTC'),
    toDateTime64('2026-02-10 00:00:00', 3, 'UTC'),
    repeat('4', 64),
    toDateTime64('2026-02-10 12:00:00', 6, 'UTC')
);

SELECT throwIf(
    (
        SELECT tupleElement(
            argMax(
                tuple(
                    vector_dim,
                    vector_values,
                    CAST(source, 'String'),
                    window_start,
                    window_end,
                    updated_at,
                    vector_row_id
                ),
                tuple(updated_at, vector_row_id)
            ),
            3
        )
        FROM user_behavior_vector_revisions
        WHERE project_id = 'source_project'
          AND user_id = 'source_user'
          AND vector_version = 'source-v1'
          AND source = 'source_a'
    ) != 'source_a',
    'source filter was not applied before canonical aggregation'
);

INSERT INTO user_behavior_vectors (
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
VALUES
(
    'list_project', 'list_a', 2, [0.1, 0.2], 'list-v1', 'list_source',
    toDateTime64('2026-03-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-03-02 00:00:00', 3, 'UTC'),
    toDateTime64('2026-03-03 00:00:00', 3, 'UTC')
),
(
    'list_project', 'list_b', 2, [0.3, 0.4], 'list-v1', 'list_source',
    toDateTime64('2026-03-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-03-02 00:00:00', 3, 'UTC'),
    toDateTime64('2026-03-03 00:00:00', 3, 'UTC')
);

WITH
explicit_users AS (
    SELECT
        project_id,
        user_id,
        vector_version,
        argMax(
            tuple(
                vector_dim,
                vector_values,
                CAST(source, 'String'),
                window_start,
                window_end,
                updated_at,
                vector_row_id
            ),
            tuple(updated_at, vector_row_id)
        ) AS payload
    FROM user_behavior_vector_revisions
    WHERE project_id = 'list_project'
      AND vector_version = 'list-v1'
      AND ingested_at < toDateTime64('2100-01-01 00:00:00', 6, 'UTC')
      AND user_id IN ('list_a', 'list_b')
    GROUP BY project_id, user_id, vector_version
),
project_keyset AS (
    SELECT
        project_id,
        user_id,
        vector_version,
        argMax(
            tuple(
                vector_dim,
                vector_values,
                CAST(source, 'String'),
                window_start,
                window_end,
                updated_at,
                vector_row_id
            ),
            tuple(updated_at, vector_row_id)
        ) AS payload
    FROM user_behavior_vector_revisions
    WHERE project_id = 'list_project'
      AND vector_version = 'list-v1'
      AND ingested_at < toDateTime64('2100-01-01 00:00:00', 6, 'UTC')
      AND tuple(user_id, vector_version) > tuple('', '')
      AND tuple(user_id, vector_version) <= tuple('list_b', 'list-v1')
    GROUP BY project_id, user_id, vector_version
)
SELECT throwIf(
    (SELECT arraySort(groupArray(tuple(
        project_id,
        user_id,
        vector_version,
        payload
    ))) FROM explicit_users)
    !=
    (SELECT arraySort(groupArray(tuple(
        project_id,
        user_id,
        vector_version,
        payload
    ))) FROM project_keyset),
    'explicit user list and project keyset latest-row semantics differ'
);
