#!/usr/bin/env bash
# Live-demo query window: interactive DuckDB SQL over every catalog table,
# with _row_id / _last_updated_sequence_number as the first columns. Views
# always read the current snapshot. See scripts/lineage_sql.py.
#
#   demo/sql.sh                                  # interactive prompt
#   demo/sql.sh "SELECT * FROM silver.customers WHERE customer_id = 9001;"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../scripts/lib.sh"

dc run --rm duckdb-demo python3 /work/scripts/lineage_sql.py "$@"
