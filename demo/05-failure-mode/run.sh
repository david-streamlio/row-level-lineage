#!/usr/bin/env bash
# STAGE 05 -- Failure mode (closer).
#
# The user's spec preferred a LIVE Flink upsert (BaseEqualityDeltaWriter) as
# the failure-mode subject, with an explicit fallback allowance: "If too
# fragile live, produce a scripted reproducible before/after capture + spec
# paragraph as comment." Standing up a Flink JobManager/TaskManager +
# checkpointing + the Iceberg Flink connector, on top of everything else
# already in this stack, is a lot of extra live-demo surface area for a
# CLOSER stage whose entire point is a negative result -- so this uses that
# explicitly-permitted fallback: a deterministic, scripted DELETE+INSERT
# sequence against a V3 table that reproduces the OBSERVABLE EFFECT of an
# equality-delete-based upsert (Flink's BaseEqualityDeltaWriter deletes rows
# by equality condition, not by position, then inserts fresh rows -- Iceberg
# has no way to correlate the two). See README.md for the full spec
# paragraph and how to swap in real Flink later.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/lib.sh"

CUSTOMER_ID="${1:-9500}"

banner "STAGE 05 -- Failure mode: the most-deployed streaming UPSERT pattern produces no usable row lineage"
check_iceberg_version
point "Position-delete MERGE (Stage 02) carries _row_id forward. Equality-delete upsert (this stage) does NOT -- Iceberg has no way to know the inserted replacement IS the deleted row, so it allocates a fresh _row_id every single time."

# spark-demo is a profile-gated `dc run` image, so `up --build` never rebuilds it;
# build explicitly so reporter changes always land (cached: seconds). The
# collector (and Marquez with it) receives this stage's commit events.
dc build -q spark-demo
dc up -d --build openlineage-collector

banner "0. Creating the failure-mode tables"
dc run --rm spark-demo -f /work/sql/05_create_failure_tables.sql 2>&1 | tee "${ROOT_DIR}/out/05-failure-mode.log"
info "note: customers_v2_reference has NO _row_id column at all -- format-version 2 predates row lineage entirely. See DESCRIBE output above."

for round in 1 2 3; do
  EVENT_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
  AMOUNT=$(python3 -c "import random; print(round(random.uniform(10, 500), 2))")
  TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000")

  banner "Round ${round}/3 -- equality-delete upsert for customer_id=${CUSTOMER_ID} (DELETE by key, then INSERT fresh)"
  dc run --rm spark-demo -e "
DELETE FROM failure_demo.customers_equality_upsert WHERE customer_id = ${CUSTOMER_ID};
INSERT INTO failure_demo.customers_equality_upsert VALUES (${CUSTOMER_ID}, ${AMOUNT}, '${EVENT_ID}', TIMESTAMP '${TS}');
" 2>&1 | tee -a "${ROOT_DIR}/out/05-failure-mode.log"

  banner "Round ${round}/3 -- row-lineage state for customer_id=${CUSTOMER_ID} (watch _row_id CHURN every round)"
  dc run --rm duckdb-demo python3 /work/scripts/read_row_lineage.py failure_demo customers_equality_upsert customer_id customer_id "${CUSTOMER_ID}" \
    2>&1 | tee -a "${ROOT_DIR}/out/05-failure-mode.log"
done

point "Same customer_id, three updates, three DIFFERENT _row_id values. Contrast with Stage 02's constant _row_id under the same 3-update scenario: the delete/write PATH the engine chooses -- not the table format version -- decides whether row lineage survives an upsert. Equality-delete upsert, the default pattern for Flink/streaming CDC sinks, throws it away every time."
