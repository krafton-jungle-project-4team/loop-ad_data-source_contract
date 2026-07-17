USE loopad;

SELECT throwIf(
    (
        SELECT count()
        FROM system.tables
        WHERE database = currentDatabase()
          AND name = 'promotion_audience_exclusion_projection'
          AND engine = 'ReplacingMergeTree'
    ) != 1,
    'exclusion projection must use versioned ReplacingMergeTree storage'
);

SELECT throwIf(
    (
        SELECT count()
        FROM system.tables
        WHERE database = currentDatabase()
          AND name = 'promotion_audience_exclusion_projection_status'
          AND engine = 'ReplacingMergeTree'
    ) != 1,
    'exclusion projection checkpoint table is missing'
);

INSERT INTO promotion_audience_exclusion_projection (
    project_id,
    campaign_id,
    promotion_id,
    user_id,
    state,
    exclusion_revision,
    updated_at
)
VALUES
    ('contract_project', 'campaign_a', 'promotion_a', 'reserved_user',
        'reserved', 1, toDateTime64('2026-07-17 00:00:01', 6, 'UTC')),
    ('contract_project', 'campaign_a', 'promotion_a', 'consumed_user',
        'reserved', 1, toDateTime64('2026-07-17 00:00:01', 6, 'UTC')),
    ('contract_project', 'campaign_a', 'promotion_a', 'consumed_user',
        'consumed', 2, toDateTime64('2026-07-17 00:00:02', 6, 'UTC')),
    ('contract_project', 'campaign_a', 'promotion_a', 'released_user',
        'reserved', 1, toDateTime64('2026-07-17 00:00:01', 6, 'UTC')),
    ('contract_project', 'campaign_a', 'promotion_a', 'released_user',
        'released', 2, toDateTime64('2026-07-17 00:00:02', 6, 'UTC')),
    ('contract_project', 'campaign_a', 'promotion_a', 'released_user',
        'reserved', 1, toDateTime64('2026-07-17 00:00:03', 6, 'UTC')),
    ('contract_project', 'campaign_b', 'promotion_b', 'reserved_user',
        'reserved', 1, toDateTime64('2026-07-17 00:00:01', 6, 'UTC'));

SELECT throwIf(
    (
        SELECT count()
        FROM promotion_audience_exclusion_active
        WHERE project_id = 'contract_project'
          AND promotion_id = 'promotion_a'
    ) != 2,
    'reserved and consumed users must be active exclusions'
);

SELECT throwIf(
    (
        SELECT count()
        FROM (
            SELECT
                project_id,
                promotion_id,
                user_id,
                argMax(
                    tuple(state, exclusion_revision),
                    tuple(exclusion_revision, updated_at)
                ) AS latest_state
            FROM promotion_audience_exclusion_projection
            WHERE project_id = 'contract_project'
              AND promotion_id = 'promotion_a'
              AND user_id = 'released_user'
            GROUP BY project_id, promotion_id, user_id
        )
        WHERE tupleElement(latest_state, 1) = 'released'
          AND tupleElement(latest_state, 2) = 2
    ) != 1,
    'latest state must be selected by exclusion revision, not insert order'
);

SELECT throwIf(
    (
        SELECT count()
        FROM (
            SELECT arrayJoin([
                'reserved_user',
                'consumed_user',
                'released_user',
                'new_user'
            ]) AS user_id
        ) AS candidates
        LEFT ANTI JOIN promotion_audience_exclusion_active AS excluded
          ON excluded.project_id = 'contract_project'
         AND excluded.promotion_id = 'promotion_a'
         AND excluded.user_id = candidates.user_id
    ) != 2,
    'hard-predicate anti-join must keep only released and unseen users'
);

SELECT throwIf(
    (
        SELECT count()
        FROM promotion_audience_exclusion_active
        WHERE project_id = 'contract_project'
          AND promotion_id = 'promotion_b'
          AND user_id = 'reserved_user'
    ) != 1,
    'the same user must be independently excludable in another promotion'
);

INSERT INTO promotion_audience_exclusion_projection_status (
    project_id,
    promotion_id,
    applied_revision,
    applied_at
)
VALUES (
    'contract_project',
    'promotion_a',
    2,
    toDateTime64('2026-07-17 00:00:02', 6, 'UTC')
);

SELECT throwIf(
    (
        SELECT argMax(
            applied_revision,
            tuple(applied_revision, applied_at)
        ) < 3
        FROM promotion_audience_exclusion_projection_status
        WHERE project_id = 'contract_project'
          AND promotion_id = 'promotion_a'
    ) != 1,
    'projection lag against PostgreSQL revision 3 was not detected'
);

INSERT INTO promotion_audience_exclusion_projection_status (
    project_id,
    promotion_id,
    applied_revision,
    applied_at
)
VALUES (
    'contract_project',
    'promotion_a',
    3,
    toDateTime64('2026-07-17 00:00:03', 6, 'UTC')
);

SELECT throwIf(
    (
        SELECT argMax(
            applied_revision,
            tuple(applied_revision, applied_at)
        ) < 3
        FROM promotion_audience_exclusion_projection_status
        WHERE project_id = 'contract_project'
          AND promotion_id = 'promotion_a'
    ) != 0,
    'projection checkpoint did not catch up to PostgreSQL revision 3'
);

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
    'redundant exclusion helper views must not exist'
);
