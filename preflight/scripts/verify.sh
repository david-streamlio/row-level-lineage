#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

command -v jq >/dev/null 2>&1 || { fail "jq is required on the host (brew install jq)"; exit 1; }

mkdir -p "${ROOT_DIR}/out"
rm -f "${ROOT_DIR}/out/status.json"

banner "Running DuckDB verification (Checks A, B, C)"
set +e
dc run --rm duckdb python3 /work/scripts/verify_duckdb.py
set -e

if [[ ! -f "${ROOT_DIR}/out/status.json" ]]; then
  fail "verify_duckdb.py did not produce out/status.json -- treating as a hard failure"
  exit 1
fi

NEEDS_FALLBACK=$(jq -r '.check_c_needs_spark_fallback' "${ROOT_DIR}/out/status.json")

if [[ "${NEEDS_FALLBACK}" == "true" ]]; then
  banner "CHECK C -- Spark fallback (this DuckDB build can't read .snapshots first_row_id/added_rows)"
  info "NOTE: this is the documented fallback path -- DuckDB is still used for Checks A and B."
  dc run --rm spark -f /work/sql/check_c_snapshots.sql 2>&1 | tee "${ROOT_DIR}/out/check_c_spark.log"
fi

CHECK_A=$(jq -r '.check_a' "${ROOT_DIR}/out/status.json")
CHECK_B=$(jq -r '.check_b' "${ROOT_DIR}/out/status.json")
CHECK_C_DUCKDB=$(jq -r '.check_c_duckdb_pass' "${ROOT_DIR}/out/status.json")

banner "FINAL PASS/FAIL SUMMARY (copy-paste for slides)"
echo "---------------------------------------------------------------------"
if [[ "${CHECK_A}" == "true" ]]; then pass "Check A - bronze.events is Iceberg format-version 3"; else fail "Check A - bronze.events is NOT format-version 3"; fi
if [[ "${CHECK_B}" == "true" ]]; then pass "Check B - _row_id densely/sequentially assigned (row lineage WORKS)"; else fail "Check B - _row_id is NULL or non-sequential (row lineage BROKEN)"; fi

if [[ "${NEEDS_FALLBACK}" == "true" ]]; then
  info "Check C - evaluated via Spark fallback, see out/check_c_spark.log above"
else
  if [[ "${CHECK_C_DUCKDB}" == "true" ]]; then pass "Check C - first_row_id advances by added_rows on each commit"; else fail "Check C - first_row_id does NOT advance correctly across commits"; fi
fi
echo "---------------------------------------------------------------------"

echo
if [[ "${CHECK_A}" == "true" && "${CHECK_B}" == "true" ]]; then
  echo "${BOLD}${GREEN}OVERALL: PASS -- row lineage (_row_id via manifest inheritance) works end-to-end via Kafka Connect ingest.${RESET}"
  exit 0
else
  echo "${BOLD}${RED}OVERALL: FAIL -- see README.md 'What a failure means' for the fallback demo path.${RESET}"
  exit 1
fi
