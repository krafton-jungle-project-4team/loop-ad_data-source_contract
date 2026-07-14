#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTED_BASE_REF="${BASE_REF:-origin/main}"
BASE_REF="${REQUESTED_BASE_REF}"
EXECUTION_BASE_REF="${EXECUTION_BASE_REF:-ca4f456f40255ec758937a8c84ea7f5566cc9d0a}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
CONTAINER_NAME="loop-ad-contract-test-$$"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="loop-ad-contract-test"
FRESH_DB="fresh_contract"
LEGACY_DB="legacy_contract"
EXECUTION_BASE_DB="execution_base_contract"

cleanup() {
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

log() {
    printf '[postgres-contract] %s\n' "$*"
}

resolve_legacy_base_ref() {
    local requested_ref="$1"
    local candidate_ref

    if ! git -C "${ROOT_DIR}" grep -q --fixed-strings \
        'segment_scope_json' "${requested_ref}" -- postgres/schema.sql; then
        printf '%s\n' "${requested_ref}"
        return 0
    fi

    while IFS= read -r candidate_ref; do
        if git -C "${ROOT_DIR}" cat-file -e \
            "${candidate_ref}:postgres/schema.sql" 2>/dev/null \
            && ! git -C "${ROOT_DIR}" grep -q --fixed-strings \
                'segment_scope_json' "${candidate_ref}" -- postgres/schema.sql; then
            printf '%s\n' "${candidate_ref}"
            return 0
        fi
    done < <(git -C "${ROOT_DIR}" rev-list --first-parent "${requested_ref}")

    printf 'could not resolve a pre-scope legacy schema from %s\n' \
        "${requested_ref}" >&2
    return 1
}

psql_file() {
    local database="$1"
    local file="$2"

    docker exec -i "${CONTAINER_NAME}" \
        psql -X -v ON_ERROR_STOP=1 \
        -U "${POSTGRES_USER}" -d "${database}" < "${file}"
}

psql_git_file() {
    local database="$1"
    local git_path="$2"

    git -C "${ROOT_DIR}" show "${BASE_REF}:${git_path}" \
        | docker exec -i "${CONTAINER_NAME}" \
            psql -X -v ON_ERROR_STOP=1 \
            -U "${POSTGRES_USER}" -d "${database}"
}

psql_git_file_at() {
    local database="$1"
    local git_ref="$2"
    local git_path="$3"

    git -C "${ROOT_DIR}" show "${git_ref}:${git_path}" \
        | docker exec -i "${CONTAINER_NAME}" \
            psql -X -v ON_ERROR_STOP=1 \
            -U "${POSTGRES_USER}" -d "${database}"
}

psql_query() {
    local database="$1"
    local query="$2"

    docker exec "${CONTAINER_NAME}" \
        psql -X -v ON_ERROR_STOP=1 -At -F $'\t' \
        -U "${POSTGRES_USER}" -d "${database}" -c "${query}"
}

assert_query() {
    local database="$1"
    local query="$2"
    local expected="$3"
    local actual

    actual="$(psql_query "${database}" "${query}")"
    if [[ "${actual}" != "${expected}" ]]; then
        printf 'query assertion failed\ndatabase: %s\nexpected: %s\nactual: %s\n' \
            "${database}" "${expected}" "${actual}" >&2
        return 1
    fi
}

git -C "${ROOT_DIR}" rev-parse --verify "${REQUESTED_BASE_REF}" >/dev/null
git -C "${ROOT_DIR}" rev-parse --verify "${EXECUTION_BASE_REF}" >/dev/null
BASE_REF="$(resolve_legacy_base_ref "${REQUESTED_BASE_REF}")"
if [[ "${BASE_REF}" != "${REQUESTED_BASE_REF}" ]]; then
    log "resolved legacy migration base ${REQUESTED_BASE_REF} -> ${BASE_REF}"
fi

log "starting isolated PostgreSQL (${POSTGRES_IMAGE})"
docker run --detach --rm \
    --name "${CONTAINER_NAME}" \
    -e "POSTGRES_USER=${POSTGRES_USER}" \
    -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB=postgres \
    "${POSTGRES_IMAGE}" >/dev/null

postgres_ready=false
for _ in $(seq 1 30); do
    if docker exec "${CONTAINER_NAME}" \
        sh -c 'test "$(cat /proc/1/comm)" = postgres' >/dev/null 2>&1 \
        && docker exec "${CONTAINER_NAME}" \
            pg_isready -U "${POSTGRES_USER}" -d postgres >/dev/null 2>&1; then
        postgres_ready=true
        break
    fi
    sleep 1
done

if [[ "${postgres_ready}" != true ]]; then
    printf 'isolated PostgreSQL did not become ready\n' >&2
    exit 1
fi

docker exec "${CONTAINER_NAME}" \
    createdb -U "${POSTGRES_USER}" "${FRESH_DB}"
docker exec "${CONTAINER_NAME}" \
    createdb -U "${POSTGRES_USER}" "${LEGACY_DB}"
docker exec "${CONTAINER_NAME}" \
    createdb -U "${POSTGRES_USER}" "${EXECUTION_BASE_DB}"

log 'verifying fresh schema and rerunnable dummy data'
psql_file "${FRESH_DB}" "${ROOT_DIR}/postgres/schema.sql"

assert_query "${FRESH_DB}" "
SELECT (
    project_id IS NULL
    AND campaign_id IS NULL
    AND promotion_id IS NULL
    AND query_preview_id IS NULL
    AND source = 'system_default'
    AND status = 'active'
)::int
FROM segment_definitions
WHERE segment_id = 'seg_existing_all';
" '1'

if psql_query "${FRESH_DB}" "
INSERT INTO segment_definitions (
    segment_id,
    project_id,
    segment_name,
    source
)
VALUES (
    'seg_invalid_global',
    NULL,
    'Invalid global segment',
    'system_default'
);
" >/dev/null 2>&1; then
    printf 'non-fallback segment unexpectedly accepted a null project_id\n' >&2
    exit 1
fi

psql_file "${FRESH_DB}" "${ROOT_DIR}/postgres/dummy.sql"
psql_file "${FRESH_DB}" "${ROOT_DIR}/postgres/dummy.sql"

assert_query "${FRESH_DB}" "
SELECT (project_id IS NULL)::int
FROM segment_definitions
WHERE segment_id = 'seg_existing_all';
" '1'

psql_file \
    "${FRESH_DB}" \
    "${ROOT_DIR}/postgres/tests/verify_promotion_run_segment_scope.sql"

psql_file \
    "${FRESH_DB}" \
    "${ROOT_DIR}/postgres/tests/verify_segment_assignment_execution_provenance.sql"

log "verifying legacy migration from ${BASE_REF}"
psql_git_file "${LEGACY_DB}" postgres/schema.sql
psql_git_file "${LEGACY_DB}" postgres/dummy.sql

for _ in 1 2; do
    psql_file \
        "${LEGACY_DB}" \
        "${ROOT_DIR}/postgres/expand_promotion_run_segment_scope.sql"
done

assert_query "${LEGACY_DB}" "
SELECT (
    project_id IS NULL
    AND campaign_id IS NULL
    AND promotion_id IS NULL
    AND query_preview_id IS NULL
    AND source = 'system_default'
)::int
FROM segment_definitions
WHERE segment_id = 'seg_existing_all';
" '1'

if psql_query "${LEGACY_DB}" "
UPDATE segment_definitions
SET project_id = 'demo_project'
WHERE segment_id = 'seg_existing_all';
" >/dev/null 2>&1; then
    printf 'global fallback unexpectedly accepted project ownership\n' >&2
    exit 1
fi

log 'confirming finalize-before-backfill failure and transaction rollback'
if psql_file \
    "${LEGACY_DB}" \
    "${ROOT_DIR}/postgres/finalize_promotion_run_segment_scope.sql"; then
    printf 'finalize unexpectedly succeeded before backfill\n' >&2
    exit 1
fi

assert_query "${LEGACY_DB}" "
SELECT (
    (SELECT count(*) = 2
     FROM pg_attribute
     WHERE attrelid = 'promotion_runs'::regclass
       AND attname IN (
           'segment_scope_json',
           'segment_scope_fingerprint'
       )
       AND NOT attnotnull)
    AND EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'uq_promotion_runs_loop'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'uq_promotion_runs_segment_scope'
    )
)::int;
" '1'

log 'confirming fallback-missing backfill failure and transaction rollback'
backfill_failure_output=''
if backfill_failure_output="$(psql_file \
    "${LEGACY_DB}" \
    "${ROOT_DIR}/postgres/backfill_promotion_run_segment_scope.sql" 2>&1)"; then
    printf 'backfill unexpectedly succeeded without fallback experiments\n' >&2
    exit 1
fi
printf '%s\n' "${backfill_failure_output}"

if [[ "${backfill_failure_output}" != *'[fallback_experiment_count]'* \
      || "${backfill_failure_output}" != *'promotion_run_id=run_email_a1'* ]]; then
    printf 'backfill failure did not identify fallback damage and a run ID\n' >&2
    exit 1
fi

assert_query "${LEGACY_DB}" "
SELECT (
    NOT EXISTS (
        SELECT 1
        FROM promotion_runs
        WHERE segment_scope_json IS NOT NULL
           OR segment_scope_fingerprint IS NOT NULL
    )
    AND EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'uq_promotion_runs_loop'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'uq_promotion_runs_segment_scope'
    )
)::int;
" '1'

log 'applying the test-only legacy fallback repair twice'
for _ in 1 2; do
    psql_file \
        "${LEGACY_DB}" \
        "${ROOT_DIR}/postgres/tests/repair_legacy_fixture_fallbacks.sql"
done

for _ in 1 2; do
    psql_file \
        "${LEGACY_DB}" \
        "${ROOT_DIR}/postgres/backfill_promotion_run_segment_scope.sql"
done

assert_query "${LEGACY_DB}" "
SELECT count(*)
FROM promotion_runs
WHERE segment_scope_json IS NULL
   OR segment_scope_fingerprint IS NULL;
" '0'

for _ in 1 2; do
    psql_file \
        "${LEGACY_DB}" \
        "${ROOT_DIR}/postgres/finalize_promotion_run_segment_scope.sql"
done

psql_file \
    "${LEGACY_DB}" \
    "${ROOT_DIR}/postgres/tests/verify_promotion_run_segment_scope.sql"

log "verifying assignment execution expand from ${EXECUTION_BASE_REF}"
psql_git_file_at \
    "${EXECUTION_BASE_DB}" \
    "${EXECUTION_BASE_REF}" \
    postgres/schema.sql
psql_git_file_at \
    "${EXECUTION_BASE_DB}" \
    "${EXECUTION_BASE_REF}" \
    postgres/dummy.sql

serving_view_before="$(psql_query "${EXECUTION_BASE_DB}" "
SELECT pg_get_viewdef('active_ad_serving_assignments'::regclass, true);
")"
serving_rows_before="$(psql_query "${EXECUTION_BASE_DB}" "
SELECT md5(COALESCE(string_agg(
    to_jsonb(serving_row)::text,
    E'\\n' ORDER BY
        project_id,
        promotion_run_id,
        user_id,
        ad_experiment_id
), ''))
FROM active_ad_serving_assignments AS serving_row;
")"

for _ in 1 2; do
    psql_file \
        "${EXECUTION_BASE_DB}" \
        "${ROOT_DIR}/postgres/expand_segment_assignment_execution_provenance.sql"
done

log 'confirming single-column execution FK repair'
psql_query "${EXECUTION_BASE_DB}" "
ALTER TABLE user_segment_assignments
    DROP CONSTRAINT fk_user_segment_assignments_execution;
ALTER TABLE user_segment_assignments
    ADD CONSTRAINT fk_user_segment_assignments_execution
    FOREIGN KEY (segment_assignment_execution_id)
    REFERENCES segment_assignment_executions (
        segment_assignment_execution_id
    )
    ON UPDATE NO ACTION
    ON DELETE NO ACTION;
" >/dev/null

assert_query "${EXECUTION_BASE_DB}" "
SELECT (array_length(conkey, 1) = 1)::int
FROM pg_constraint
WHERE conrelid = 'user_segment_assignments'::regclass
  AND conname = 'fk_user_segment_assignments_execution';
" '1'

psql_query "${EXECUTION_BASE_DB}" "
BEGIN;
INSERT INTO segment_assignment_executions (
    segment_assignment_execution_id,
    promotion_run_id,
    request_fingerprint,
    input_fingerprint,
    matcher_strategy,
    matcher_version,
    vector_version,
    source_cutoff_at,
    input_manifest_json
) VALUES (
    'single_fk_vulnerability_probe',
    'run_onsite_a2',
    repeat('9', 64),
    repeat('8', 64),
    'exact_probe',
    'probe-v1',
    'fixture-v1',
    now(),
    '{}'::jsonb
);
UPDATE user_segment_assignments
SET segment_assignment_execution_id = 'single_fk_vulnerability_probe'
WHERE promotion_run_id = 'run_email_a1'
  AND user_id = 'demo_user_email_awaiting';
ROLLBACK;
" >/dev/null

psql_file \
    "${EXECUTION_BASE_DB}" \
    "${ROOT_DIR}/postgres/expand_segment_assignment_execution_provenance.sql"

assert_query "${EXECUTION_BASE_DB}" "
SELECT (
    contype = 'f'
    AND confrelid = 'segment_assignment_executions'::regclass
    AND conkey = ARRAY[
        (
            SELECT attnum::SMALLINT
            FROM pg_attribute
            WHERE attrelid = 'user_segment_assignments'::regclass
              AND attname = 'promotion_run_id'
        ),
        (
            SELECT attnum::SMALLINT
            FROM pg_attribute
            WHERE attrelid = 'user_segment_assignments'::regclass
              AND attname = 'segment_assignment_execution_id'
        )
    ]::SMALLINT[]
    AND confkey = ARRAY[
        (
            SELECT attnum::SMALLINT
            FROM pg_attribute
            WHERE attrelid = 'segment_assignment_executions'::regclass
              AND attname = 'promotion_run_id'
        ),
        (
            SELECT attnum::SMALLINT
            FROM pg_attribute
            WHERE attrelid = 'segment_assignment_executions'::regclass
              AND attname = 'segment_assignment_execution_id'
        )
    ]::SMALLINT[]
)::int
FROM pg_constraint
WHERE conrelid = 'user_segment_assignments'::regclass
  AND conname = 'fk_user_segment_assignments_execution';
" '1'

assert_query "${EXECUTION_BASE_DB}" "
SELECT count(*)
FROM user_segment_assignments
WHERE segment_assignment_execution_id IS NOT NULL;
" '0'

serving_view_after="$(psql_query "${EXECUTION_BASE_DB}" "
SELECT pg_get_viewdef('active_ad_serving_assignments'::regclass, true);
")"
serving_rows_after="$(psql_query "${EXECUTION_BASE_DB}" "
SELECT md5(COALESCE(string_agg(
    to_jsonb(serving_row)::text,
    E'\\n' ORDER BY
        project_id,
        promotion_run_id,
        user_id,
        ad_experiment_id
), ''))
FROM active_ad_serving_assignments AS serving_row;
")"

if [[ "${serving_view_before}" != "${serving_view_after}" \
      || "${serving_rows_before}" != "${serving_rows_after}" ]]; then
    printf 'active serving definition or rows changed after provenance expand\n' \
        >&2
    exit 1
fi

psql_file \
    "${EXECUTION_BASE_DB}" \
    "${ROOT_DIR}/postgres/tests/verify_segment_assignment_execution_provenance.sql"

log 'comparing fresh and migrated scope contract metadata'
snapshot_query="
WITH contract_metadata AS (
    SELECT
        'column|' || attname || '|' ||
        format_type(atttypid, atttypmod) || '|' || attnotnull AS item
    FROM pg_attribute
    WHERE attrelid = 'promotion_runs'::regclass
      AND attnum > 0
      AND NOT attisdropped
      AND attname IN (
          'segment_scope_json',
          'segment_scope_fingerprint'
      )

    UNION ALL

    SELECT
        'constraint|' || conname || '|' || pg_get_constraintdef(oid) AS item
    FROM pg_constraint
    WHERE conrelid = 'promotion_runs'::regclass
      AND conname IN (
          'chk_promotion_runs_segment_scope',
          'uq_promotion_runs_segment_scope'
      )

    UNION ALL

    SELECT
        'index|' || indexname || '|' || indexdef AS item
    FROM pg_indexes
    WHERE schemaname = current_schema()
      AND tablename = 'promotion_runs'
      AND indexname = 'idx_promotion_runs_promotion_loop'

    UNION ALL

    SELECT
        'function|' || md5(
            prosrc || '|' || provolatile::text || '|' ||
            proisstrict::text || '|' || proparallel::text
        ) AS item
    FROM pg_proc
    WHERE oid = 'is_valid_promotion_run_segment_scope(jsonb,text)'::regprocedure
)
SELECT string_agg(item, E'\n' ORDER BY item)
FROM contract_metadata;
"

fresh_snapshot="$(psql_query "${FRESH_DB}" "${snapshot_query}")"
legacy_snapshot="$(psql_query "${LEGACY_DB}" "${snapshot_query}")"
if [[ "${fresh_snapshot}" != "${legacy_snapshot}" ]]; then
    printf 'fresh and migrated contract metadata differ\nfresh:\n%s\nmigrated:\n%s\n' \
        "${fresh_snapshot}" "${legacy_snapshot}" >&2
    exit 1
fi

log 'comparing fresh and migrated assignment execution metadata'
execution_snapshot_query="
WITH contract_metadata AS (
    SELECT
        'column|' || classes.relname || '|' || attributes.attnum || '|' ||
        attributes.attname || '|' ||
        format_type(attributes.atttypid, attributes.atttypmod) || '|' ||
        attributes.attnotnull || '|' ||
        COALESCE(pg_get_expr(defaults.adbin, defaults.adrelid), '') AS item
    FROM pg_class AS classes
    JOIN pg_attribute AS attributes
      ON attributes.attrelid = classes.oid
    LEFT JOIN pg_attrdef AS defaults
      ON defaults.adrelid = classes.oid
     AND defaults.adnum = attributes.attnum
    WHERE (
        classes.relname = 'segment_assignment_executions'
        OR (
            classes.relname = 'user_segment_assignments'
            AND attributes.attname = 'segment_assignment_execution_id'
        )
    )
      AND attributes.attnum > 0
      AND NOT attributes.attisdropped

    UNION ALL

    SELECT
        'constraint|' || classes.relname || '|' || constraints.conname || '|' ||
        pg_get_constraintdef(constraints.oid) AS item
    FROM pg_constraint AS constraints
    JOIN pg_class AS classes
      ON classes.oid = constraints.conrelid
    WHERE classes.relname = 'segment_assignment_executions'
       OR constraints.conname = 'fk_user_segment_assignments_execution'

    UNION ALL

    SELECT
        'index|' || tablename || '|' || indexname || '|' || indexdef AS item
    FROM pg_indexes
    WHERE schemaname = current_schema()
      AND (
          tablename = 'segment_assignment_executions'
          OR indexname = 'idx_user_segment_assignments_execution_id'
      )
)
SELECT string_agg(item, E'\\n' ORDER BY item)
FROM contract_metadata;
"

fresh_execution_snapshot="$(psql_query \
    "${FRESH_DB}" \
    "${execution_snapshot_query}")"
migrated_execution_snapshot="$(psql_query \
    "${EXECUTION_BASE_DB}" \
    "${execution_snapshot_query}")"
if [[ "${fresh_execution_snapshot}" != "${migrated_execution_snapshot}" ]]; then
    printf 'fresh and migrated assignment execution metadata differ\n' >&2
    printf 'fresh:\n%s\nmigrated:\n%s\n' \
        "${fresh_execution_snapshot}" \
        "${migrated_execution_snapshot}" >&2
    exit 1
fi

log 'checking Python and PostgreSQL compact JSON SHA-256 fingerprints'
python_fingerprint="$(python3 -c '
import hashlib
import json
scope = ["seg_family_trip", "seg_near_checkin"]
payload = json.dumps(scope, ensure_ascii=False, separators=(",", ":"))
print(hashlib.sha256(payload.encode("utf-8")).hexdigest())
')"
postgres_fingerprint="$(psql_query "${FRESH_DB}" "
SELECT encode(
    digest(
        convert_to(
            '[\"seg_family_trip\",\"seg_near_checkin\"]',
            'UTF8'
        ),
        'sha256'
    ),
    'hex'
);
")"
if [[ "${python_fingerprint}" != "${postgres_fingerprint}" ]]; then
    printf 'Python/PostgreSQL fingerprint mismatch: %s != %s\n' \
        "${python_fingerprint}" "${postgres_fingerprint}" >&2
    exit 1
fi

dummy_row_count=0
while IFS=$'\t' read -r promotion_run_id scope_json fingerprint; do
    computed_fingerprint="$(python3 -c '
import hashlib
import json
import sys
payload = json.dumps(
    json.loads(sys.argv[1]),
    ensure_ascii=False,
    separators=(",", ":"),
)
print(hashlib.sha256(payload.encode("utf-8")).hexdigest())
' "${scope_json}")"
    if [[ "${computed_fingerprint}" != "${fingerprint}" ]]; then
        printf 'dummy fingerprint mismatch for %s: %s != %s\n' \
            "${promotion_run_id}" "${computed_fingerprint}" "${fingerprint}" >&2
        exit 1
    fi
    dummy_row_count=$((dummy_row_count + 1))
done < <(psql_query "${FRESH_DB}" "
SELECT
    promotion_run_id,
    segment_scope_json::text,
    segment_scope_fingerprint
FROM promotion_runs
ORDER BY promotion_run_id;
")

if [[ "${dummy_row_count}" -eq 0 ]]; then
    printf 'no dummy promotion_runs were checked\n' >&2
    exit 1
fi

fallback_experiment_count="$(psql_query "${FRESH_DB}" "
SELECT count(*)
FROM ad_experiments
WHERE segment_id = 'seg_existing_all';
")"
if [[ "${fallback_experiment_count}" -lt 4 \
      || "${fallback_experiment_count}" -ne "${dummy_row_count}" ]]; then
    printf 'fallback experiment count mismatch: runs=%s fallbacks=%s\n' \
        "${dummy_row_count}" "${fallback_experiment_count}" >&2
    exit 1
fi

active_fallback_assignment_count="$(psql_query "${FRESH_DB}" "
SELECT count(*)
FROM active_ad_serving_assignments
WHERE fallback = true;
")"
if [[ "${active_fallback_assignment_count}" -ne 1 ]]; then
    printf 'active fallback assignment count mismatch: %s\n' \
        "${active_fallback_assignment_count}" >&2
    exit 1
fi

log 'final promotion_runs contract state'
psql_query "${LEGACY_DB}" "
SELECT
    attname || ':not_null=' || attnotnull
FROM pg_attribute
WHERE attrelid = 'promotion_runs'::regclass
  AND attname IN (
      'segment_scope_json',
      'segment_scope_fingerprint'
  )
UNION ALL
SELECT
    conname || ':' || pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'promotion_runs'::regclass
  AND conname IN (
      'chk_promotion_runs_segment_scope',
      'uq_promotion_runs_segment_scope'
  )
ORDER BY 1;
"

log "all checks passed (${dummy_row_count} dummy promotion_runs, ${fallback_experiment_count} fallback experiments, ${active_fallback_assignment_count} active fallback assignments verified)"
