#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TRAIN_CSV="${TRAIN_CSV:-${SCRIPT_DIR}/train.csv}"
VECTOR_SQL="${VECTOR_SQL:-${SCRIPT_DIR}/build_user_behavior_vectors_from_expedia.sql}"
BUILD_USER_BEHAVIOR_VECTORS="${BUILD_USER_BEHAVIOR_VECTORS:-1}"

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_NATIVE_PORT="${CLICKHOUSE_NATIVE_PORT:-19000}"
CLICKHOUSE_DATABASE="${CLICKHOUSE_DATABASE:-loopad}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-loopad_app}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-loopad_local_password}"

if [[ ! -f "${TRAIN_CSV}" ]]; then
  cat >&2 <<EOF
train.csv not found: ${TRAIN_CSV}

Place Kaggle Expedia train.csv at:
  ${SCRIPT_DIR}/train.csv

Or pass a custom path:
  TRAIN_CSV=/path/to/train.csv bash clickhouse/load_train_csv.sh
EOF
  exit 1
fi

if command -v clickhouse-client >/dev/null 2>&1; then
  CLICKHOUSE_CLIENT=(clickhouse-client)
else
  if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<EOF
clickhouse-client is not installed and docker is not available.

Install clickhouse-client, or run this from the data-source-contract repo
with Docker Compose available.
EOF
    exit 1
  fi
  CLICKHOUSE_CLIENT=(
    docker compose
    --env-file "${REPO_ROOT}/environments/local.env"
    exec -T clickhouse
    clickhouse-client
  )
  CLICKHOUSE_HOST="localhost"
  CLICKHOUSE_NATIVE_PORT="9000"
fi

run_clickhouse() {
  "${CLICKHOUSE_CLIENT[@]}" \
    --host "${CLICKHOUSE_HOST}" \
    --port "${CLICKHOUSE_NATIVE_PORT}" \
    --user "${CLICKHOUSE_USER}" \
    --password "${CLICKHOUSE_PASSWORD}" \
    --database "${CLICKHOUSE_DATABASE}" \
    "$@"
}

echo "Loading ${TRAIN_CSV} into ${CLICKHOUSE_DATABASE}.expedia_hotel_events..."
run_clickhouse \
  --input_format_with_names_use_header 1 \
  --input_format_csv_empty_as_default 1 \
  --query "INSERT INTO expedia_hotel_events FORMAT CSVWithNames" \
  < "${TRAIN_CSV}"

echo "Loaded Expedia train.csv. Current event/user counts:"
run_clickhouse --query "
SELECT
    count() AS events,
    uniqExact(user_id) AS users
FROM expedia_hotel_events
"

if [[ "${BUILD_USER_BEHAVIOR_VECTORS}" == "1" ]]; then
  if [[ ! -f "${VECTOR_SQL}" ]]; then
    cat >&2 <<EOF
Vector build SQL not found: ${VECTOR_SQL}

Set BUILD_USER_BEHAVIOR_VECTORS=0 to skip vector generation.
EOF
    exit 1
  fi

  echo "Building user_behavior_vectors from expedia_hotel_events..."
  run_clickhouse --multiquery < "${VECTOR_SQL}"
else
  echo "Skipping user_behavior_vectors build because BUILD_USER_BEHAVIOR_VECTORS=${BUILD_USER_BEHAVIOR_VECTORS}."
fi

echo "Done."
