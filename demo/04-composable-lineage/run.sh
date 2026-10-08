#!/usr/bin/env bash
# STAGE 04 -- Composable Lineage (correlation join / CLIMAX).
#
# Every commit spark-demo makes already carries a custom
# org.apache.iceberg.metrics.MetricsReporter (see docker/spark-demo) that
# POSTs an OpenLineage-shaped event to openlineage-collector. That event
# has NO row-level concept whatsoever -- it's graph-level: which table,
# which snapshot, which operation. The join back to actual rows happens on
# exactly ONE key: sequenceNumber == _last_updated_sequence_number. That
# join IS Composable Lineage: graph-level lineage from the tool, row-level
# identity from Iceberg, correlated without either system knowing about
# the other's model.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/lib.sh"

CUSTOMER_ID="${1:-9002}"

banner "STAGE 04 -- Composable Lineage: graph-level tooling + row-level identity, joined on one key"
check_iceberg_version

# spark-demo is a profile-gated `dc run` image, so `up --build` never rebuilds it;
# build explicitly so reporter changes always land (cached: seconds)
dc build -q spark-demo
dc up -d --build openlineage-collector lineage-dashboard
dc run --rm spark-demo -f /work/sql/create_silver_table.sql >/dev/null 2>&1 || true

EVENT_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
AMOUNT=$(python3 -c "import random; print(round(random.uniform(10, 500), 2))")
TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000")

# after stage 3 the sink has added "channel" to bronze.events, and Spark's
# INSERT must list every column: fill it in when the table has it
COLS="event_id, customer_id, amount, ts"; VALS="'${EVENT_ID}', ${CUSTOMER_ID}, ${AMOUNT}, TIMESTAMP '${TS}'"
if catalog_curl "$(catalog_table_url bronze events)" 2>/dev/null \
    | python3 -c 'import json,sys; m=json.load(sys.stdin)["metadata"]; s=[x for x in m["schemas"] if x["schema-id"]==m["current-schema-id"]][0]; sys.exit(0 if any(f["name"]=="channel" for f in s["fields"]) else 1)'; then
  COLS="${COLS}, channel"; VALS="${VALS}, 'web'"
fi

banner "1. A new event in bronze.events, MERGEd into silver.customers for customer_id=${CUSTOMER_ID}"
# bronze -> silver, as in stage 2: the MERGE reads the event from bronze.events;
# OPENLINEAGE_INPUTS declares that read for the lineage graph
dc run --rm -e OPENLINEAGE_INPUTS="${OPENLINEAGE_DATASET_NAMESPACE}|bronze.events" spark-demo -e "
INSERT INTO bronze.events (${COLS}) VALUES (${VALS});

MERGE INTO silver.customers t
USING (SELECT customer_id, amount, event_id, ts FROM bronze.events WHERE event_id = '${EVENT_ID}') s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET
  t.total_amount = t.total_amount + s.amount,
  t.last_event_id = s.event_id,
  t.updated_ts = s.ts
WHEN NOT MATCHED THEN INSERT (customer_id, total_amount, last_event_id, updated_ts)
VALUES (s.customer_id, s.amount, s.event_id, s.ts);
" 2>&1 | tee "${ROOT_DIR}/out/04-composable-lineage.log"

info "giving the async HTTP POST to openlineage-collector a moment to land ..."
sleep 3

banner "2. GRAPH-LEVEL: the OpenLineage-shaped event this commit emitted (no row-level concept at all)"
LINEAGE_EVENT=$(python3 "${ROOT_DIR}/scripts/latest_lineage_event.py" "customers" | tee -a "${ROOT_DIR}/out/04-composable-lineage.log")
echo "${LINEAGE_EVENT}"
SEQUENCE_NUMBER=$(echo "${LINEAGE_EVENT}" | grep -oE 'SEQUENCE_NUMBER=[0-9]+' | cut -d= -f2)

if [[ -z "${SEQUENCE_NUMBER}" ]]; then
  fail "could not extract sequenceNumber from the captured lineage event"
  exit 1
fi
pass "captured sequenceNumber=${SEQUENCE_NUMBER} from the lineage graph event"

banner "3. ROW-LEVEL: drilling the graph event straight into rows via _last_updated_sequence_number = ${SEQUENCE_NUMBER}"
dc run --rm duckdb-demo python3 /work/scripts/read_row_lineage.py silver customers customer_id _last_updated_sequence_number "${SEQUENCE_NUMBER}" \
  2>&1 | tee -a "${ROOT_DIR}/out/04-composable-lineage.log"

point "OpenLineage told us WHICH commit happened (graph). Iceberg's _last_updated_sequence_number told us WHICH ROWS that commit touched (identity). Neither tool knows the other's model -- sequenceNumber is the one key that bridges them. That join IS Composable Lineage."
