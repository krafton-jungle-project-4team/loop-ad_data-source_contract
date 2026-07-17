#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${CLICKHOUSE_BASE_REF:-ca4f456f40255ec758937a8c84ea7f5566cc9d0a}"
CLICKHOUSE_IMAGE="${CLICKHOUSE_IMAGE:-clickhouse/clickhouse-server:26.3.13.31}"
FRESH_CONTAINER="loop-ad-clickhouse-fresh-$$"
MIGRATED_CONTAINER="loop-ad-clickhouse-migrated-$$"

cleanup() {
    docker rm -f "${FRESH_CONTAINER}" "${MIGRATED_CONTAINER}" \
        >/dev/null 2>&1 || true
}

trap cleanup EXIT

log() {
    printf '[clickhouse-contract] %s\n' "$*"
}

start_clickhouse() {
    local container_name="$1"
    local clickhouse_ready=false

    docker run --detach --rm \
        --name "${container_name}" \
        "${CLICKHOUSE_IMAGE}" >/dev/null

    for _ in $(seq 1 60); do
        if docker exec "${container_name}" \
            clickhouse-client --query 'SELECT 1' >/dev/null 2>&1; then
            clickhouse_ready=true
            break
        fi
        sleep 1
    done

    if [[ "${clickhouse_ready}" != true ]]; then
        printf 'ClickHouse did not become ready: %s\n' \
            "${container_name}" >&2
        return 1
    fi
}

clickhouse_file() {
    local container_name="$1"
    local file="$2"

    docker exec -i "${container_name}" \
        clickhouse-client --multiquery < "${file}"
}

clickhouse_git_file() {
    local container_name="$1"
    local git_path="$2"

    git -C "${ROOT_DIR}" show "${BASE_REF}:${git_path}" \
        | docker exec -i "${container_name}" \
            clickhouse-client --multiquery
}

clickhouse_query() {
    local container_name="$1"
    local query="$2"

    docker exec "${container_name}" \
        clickhouse-client --query "${query}"
}

seed_legacy_vector() {
    local container_name="$1"

    clickhouse_query "${container_name}" "
        INSERT INTO loopad.user_behavior_vectors (
            project_id,
            user_id,
            vector_dim,
            vector_values,
            vector_version,
            source,
            window_start,
            window_end,
            updated_at
        ) VALUES (
            'contract_project',
            'legacy_user',
            3,
            [0.1, 0.2, 0.3],
            'contract-v1',
            'legacy_fixture',
            toDateTime64('2026-06-01 00:00:00', 3, 'UTC'),
            toDateTime64('2026-06-30 00:00:00', 3, 'UTC'),
            toDateTime64('2026-07-01 00:00:00', 3, 'UTC')
        );
    "
}

git -C "${ROOT_DIR}" rev-parse --verify "${BASE_REF}" >/dev/null

log "starting isolated ClickHouse containers (${CLICKHOUSE_IMAGE})"
start_clickhouse "${FRESH_CONTAINER}"
start_clickhouse "${MIGRATED_CONTAINER}"

log 'verifying fresh schema, backfill replay, and canonical latest rows'
clickhouse_file \
    "${FRESH_CONTAINER}" \
    "${ROOT_DIR}/clickhouse/schema.sql"
seed_legacy_vector "${FRESH_CONTAINER}"
for _ in 1 2; do
    clickhouse_file \
        "${FRESH_CONTAINER}" \
        "${ROOT_DIR}/clickhouse/backfill_user_behavior_vector_revisions.sql"
done
clickhouse_file \
    "${FRESH_CONTAINER}" \
    "${ROOT_DIR}/clickhouse/tests/verify_user_behavior_vector_revisions.sql"
clickhouse_file \
    "${FRESH_CONTAINER}" \
    "${ROOT_DIR}/clickhouse/tests/verify_promotion_audience_exclusions.sql"

if clickhouse_query "${FRESH_CONTAINER}" "
    INSERT INTO loopad.promotion_audience_exclusion_projection (
        project_id,
        campaign_id,
        promotion_id,
        user_id,
        state,
        exclusion_revision,
        updated_at
    ) VALUES (
        'contract_project',
        'campaign_a',
        'promotion_a',
        'invalid_state_user',
        'unknown',
        4,
        now64(6, 'UTC')
    );
" >/dev/null 2>&1; then
    printf 'invalid ClickHouse exclusion state was accepted\n' >&2
    exit 1
fi

log "verifying additive expansion from ${BASE_REF}"
clickhouse_git_file "${MIGRATED_CONTAINER}" clickhouse/schema.sql
source_ddl_before="$(clickhouse_query "${MIGRATED_CONTAINER}" \
    'SHOW CREATE TABLE loopad.user_behavior_vectors')"
seed_legacy_vector "${MIGRATED_CONTAINER}"
source_rows_before="$(clickhouse_query "${MIGRATED_CONTAINER}" "
    SELECT tuple(
        project_id,
        user_id,
        vector_dim,
        vector_values,
        vector_version,
        CAST(source, 'String'),
        window_start,
        window_end,
        updated_at
    )
    FROM loopad.user_behavior_vectors FINAL
    ORDER BY project_id, user_id, vector_version;
")"

for _ in 1 2; do
    clickhouse_file \
        "${MIGRATED_CONTAINER}" \
        "${ROOT_DIR}/clickhouse/expand_user_behavior_vector_revisions.sql"
done
for _ in 1 2; do
    clickhouse_file \
        "${MIGRATED_CONTAINER}" \
        "${ROOT_DIR}/clickhouse/expand_promotion_audience_exclusions.sql"
done

clickhouse_query "${MIGRATED_CONTAINER}" "
    CREATE VIEW loopad.promotion_audience_exclusion_current AS
    SELECT 1 AS unsupported_draft_marker;
" >/dev/null

if clickhouse_file \
    "${MIGRATED_CONTAINER}" \
    "${ROOT_DIR}/clickhouse/expand_promotion_audience_exclusions.sql"; then
    printf 'ClickHouse exclusion migration accepted obsolete helper views\n' >&2
    exit 1
fi

clickhouse_query "${MIGRATED_CONTAINER}" \
    'DROP VIEW loopad.promotion_audience_exclusion_current;' >/dev/null

for _ in 1 2; do
    clickhouse_file \
        "${MIGRATED_CONTAINER}" \
        "${ROOT_DIR}/clickhouse/backfill_user_behavior_vector_revisions.sql"
done

source_ddl_after="$(clickhouse_query "${MIGRATED_CONTAINER}" \
    'SHOW CREATE TABLE loopad.user_behavior_vectors')"
source_rows_after="$(clickhouse_query "${MIGRATED_CONTAINER}" "
    SELECT tuple(
        project_id,
        user_id,
        vector_dim,
        vector_values,
        vector_version,
        CAST(source, 'String'),
        window_start,
        window_end,
        updated_at
    )
    FROM loopad.user_behavior_vectors FINAL
    ORDER BY project_id, user_id, vector_version;
")"

if [[ "${source_ddl_before}" != "${source_ddl_after}" \
      || "${source_rows_before}" != "${source_rows_after}" ]]; then
    printf 'existing user_behavior_vectors contract changed during expand\n' \
        >&2
    exit 1
fi

clickhouse_file \
    "${MIGRATED_CONTAINER}" \
    "${ROOT_DIR}/clickhouse/tests/verify_user_behavior_vector_revisions.sql"
clickhouse_file \
    "${MIGRATED_CONTAINER}" \
    "${ROOT_DIR}/clickhouse/tests/verify_promotion_audience_exclusions.sql"

fresh_revision_ddl="$(clickhouse_query "${FRESH_CONTAINER}" \
    'SHOW CREATE TABLE loopad.user_behavior_vector_revisions')"
migrated_revision_ddl="$(clickhouse_query "${MIGRATED_CONTAINER}" \
    'SHOW CREATE TABLE loopad.user_behavior_vector_revisions')"
fresh_mv_ddl="$(clickhouse_query "${FRESH_CONTAINER}" \
    'SHOW CREATE TABLE loopad.mv_user_behavior_vectors_to_revisions')"
migrated_mv_ddl="$(clickhouse_query "${MIGRATED_CONTAINER}" \
    'SHOW CREATE TABLE loopad.mv_user_behavior_vectors_to_revisions')"

if [[ "${fresh_revision_ddl}" != "${migrated_revision_ddl}" \
      || "${fresh_mv_ddl}" != "${migrated_mv_ddl}" ]]; then
    printf 'fresh and migrated vector revision metadata differ\n' >&2
    exit 1
fi

for relation_name in \
    promotion_audience_exclusion_projection \
    promotion_audience_exclusion_projection_status \
    promotion_audience_exclusion_active; do
    fresh_exclusion_ddl="$(clickhouse_query "${FRESH_CONTAINER}" \
        "SHOW CREATE TABLE loopad.${relation_name}")"
    migrated_exclusion_ddl="$(clickhouse_query "${MIGRATED_CONTAINER}" \
        "SHOW CREATE TABLE loopad.${relation_name}")"

    if [[ "${fresh_exclusion_ddl}" != "${migrated_exclusion_ddl}" ]]; then
        printf 'fresh and migrated exclusion metadata differ: %s\n' \
            "${relation_name}" >&2
        exit 1
    fi
done

for container_name in "${FRESH_CONTAINER}" "${MIGRATED_CONTAINER}"; do
    obsolete_helper_count="$(clickhouse_query "${container_name}" "
        SELECT count()
        FROM system.tables
        WHERE database = 'loopad'
          AND name IN (
              'promotion_audience_exclusion_current',
              'promotion_audience_exclusion_projection_status_current'
          );
    ")"
    if [[ "${obsolete_helper_count}" != '0' ]]; then
        printf 'obsolete exclusion helper views remain in %s\n' \
            "${container_name}" >&2
        exit 1
    fi
done

log 'all ClickHouse vector revision and exclusion checks passed'
