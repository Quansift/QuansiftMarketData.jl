#!/bin/bash
set -euo pipefail

REPO_DIR="${TIINGO_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${TIINGO_ENV_FILE:-$REPO_DIR/.env.staging}"

cd "$REPO_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

mkdir -p "$REPO_DIR/data" "$REPO_DIR/.duckdb_temp" "$REPO_DIR/logs"

if [[ "${TIINGO_API_KEY:-}" == "replace_me_with_real_tiingo_api_key" || -z "${TIINGO_API_KEY:-}" ]]; then
  echo "Set TIINGO_API_KEY in $ENV_FILE before running the staging smoke test." >&2
  exit 1
fi

if [[ "${TIINGO_SMOKE_EXPORT_POSTGRES:-false}" == "true" && "${TIINGO_PG_CONNECTION:-}" == "postgresql://user:password@host:5432/database?sslmode=require" ]]; then
  echo "Set TIINGO_PG_CONNECTION in $ENV_FILE before enabling PostgreSQL export." >&2
  exit 1
fi

exec julia --project="$REPO_DIR" "$REPO_DIR/scripts/staging_smoke_test.jl"
