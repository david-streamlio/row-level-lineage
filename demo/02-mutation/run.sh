#!/usr/bin/env bash
# STAGE 02 -- Mutation with deletion vectors.
#
# Spark MERGE bronze -> silver.customers (merge-on-read). We update the SAME
# customer_id across 3 separate commits and read _row_id/_last_updated_
# sequence_number after each one. Point: identity survives mutation ONLY on
# the deletion-vector (position-delete) path -- Iceberg explicitly carries
# the old row's _row_id forward when an engine updates it via position
# deletes. Stage 05 shows the opposite case (equality-delete upsert).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/lib.sh"

CUSTOMER_ID="${1:-9001}"

banner "STAGE 02 -- Mutation with deletion vectors"
check_iceberg_version
point "silver.customers uses write.*.mode=merge-on-read. When Spark's MERGE updates an existing row via a position delete, Iceberg copies _row_id and only advances _last_updated_sequence_number -- the row's identity survives the mutation."

banner "0. Bringing up the demo Spark image (Iceberg ${ICEBERG_VERSION} + Composable Lineage reporter) and the OpenLineage collector"
# spark-demo is a profile-gated `dc run` image, so `up --build` never rebuilds it;
# build explicitly so reporter changes always land (cached: seconds)
dc build -q spark-demo
dc up -d --build openlineage-collector lineage-dashboard

banner "1. Creating V3 silver.customers (merge-on-read) if it doesn't exist"
dc run --rm spark-demo -f /work/sql/create_silver_table.sql 2>&1 | tee "${ROOT_DIR}/out/02-create-silver.log"

for round in 1 2 3; do
  EVENT_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
  AMOUNT=$(python3 -c "import random; print(round(random.uniform(10, 500), 2))")
  TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000")

  banner "Round ${round}/3 -- new event for customer_id=${CUSTOMER_ID} (event_id=${EVENT_ID}, amount=${AMOUNT})"

  # bronze -> silver: the event lands in bronze.events, then the MERGE reads it
  # from there. OPENLINEAGE_INPUTS declares that read for the lineage graph
  # (the commit-level reporter can't see reads; the bronze INSERT's own commit
  # skips it, since a commit never lists its own table as an input).
  dc run --rm -e OPENLINEAGE_INPUTS="${OPENLINEAGE_DATASET_NAMESPACE}|bronze.events" spark-demo -e "
INSERT INTO bronze.events (event_id, customer_id, amount, ts) VALUES ('${EVENT_ID}', ${CUSTOMER_ID}, ${AMOUNT}, TIMESTAMP '${TS}');

MERGE INTO silver.customers t
USING (SELECT customer_id, amount, event_id, ts FROM bronze.events WHERE event_id = '${EVENT_ID}') s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET
  t.total_amount = t.total_amount + s.amount,
  t.last_event_id = s.event_id,
  t.updated_ts = s.ts
WHEN NOT MATCHED THEN INSERT (customer_id, total_amount, last_event_id, updated_ts)
VALUES (s.customer_id, s.amount, s.event_id, s.ts);
" 2>&1 | tee -a "${ROOT_DIR}/out/02-mutation.log"

  banner "Round ${round}/3 -- row-lineage state for customer_id=${CUSTOMER_ID} (watch _row_id: constant; _last_updated_sequence_number: advancing)"
  dc run --rm duckdb-demo python3 /work/scripts/read_row_lineage.py silver customers customer_id customer_id "${CUSTOMER_ID}" \
    2>&1 | tee -a "${ROOT_DIR}/out/02-mutation.log"
done

point "Across 3 separate commits, _row_id for customer_id=${CUSTOMER_ID} never changed -- only _last_updated_sequence_number advanced. That constant value IS the durable row identity, and it survived real mutation, not just append."
