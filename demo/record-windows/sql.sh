#!/usr/bin/env bash
# Recorded window: a row-lineage query re-run every 2 s (scripts/lineage_sql.py
# --watch). demo/record-demo.sh writes each stage's query to the watched file,
# so the window never restarts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/lib.sh" >/dev/null
clear
exec docker compose --project-directory "${ROOT_DIR}" run --rm duckdb-demo \
  python3 /work/scripts/lineage_sql.py --watch 2 "/work/out/.record/sql-query.sql"
