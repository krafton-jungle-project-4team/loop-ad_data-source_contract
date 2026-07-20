#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/environments/dashboard.env}"

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

python3 "${ROOT_DIR}/scripts/seed_demo_historical_campaign.py" \
  --target local \
  --apply

printf 'dedicated historical campaign fixture seeded and verified\n'
