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
TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# the event takes the streaming path, like every other bronze row: Kafka ->
# Kafka Connect -> bronze.events. After stage 3 the table has "channel"; send
# it only then (otherwise the sink would evolve the table here)
EVENT_JSON="{\"event_id\": \"${EVENT_ID}\", \"customer_id\": ${CUSTOMER_ID}, \"amount\": ${AMOUNT}, \"ts\": \"${TS}\"}"
if catalog_curl "$(catalog_table_url bronze events)" 2>/dev/null \
    | python3 -c 'import json,sys; m=json.load(sys.stdin)["metadata"]; s=[x for x in m["schemas"] if x["schema-id"]==m["current-schema-id"]][0]; sys.exit(0 if any(f["name"]=="channel" for f in s["fields"]) else 1)'; then
  EVENT_JSON="${EVENT_JSON%\}}, \"channel\": \"web\"}"
fi

banner "1. A new event for customer_id=${CUSTOMER_ID} streams in: Kafka -> Kafka Connect -> bronze.events"
echo "${EVENT_JSON}"
echo "${EVENT_JSON}" | dc exec -T kafka /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic "${KAFKA_TOPIC}" >/dev/null 2>&1
LANDED=""
for _ in $(seq 1 30); do
  if dc run --rm duckdb-demo python3 /work/scripts/lineage_sql.py \
      "SELECT count(*) AS landed FROM bronze.events WHERE event_id = '${EVENT_ID}';" 2>/dev/null \
      | grep -qE "│ +1 +│"; then LANDED=1; break; fi
  sleep 2
done
if [[ -n "${LANDED}" ]]; then pass "Kafka Connect committed the event to bronze.events"; else fail "the event did not reach bronze.events within 60 s"; exit 1; fi

banner "2. MERGE the event from bronze.events into silver.customers"
# bronze -> silver, as in stage 2: the MERGE reads the event from bronze.events;
# OPENLINEAGE_INPUTS declares that read for the lineage graph
dc run --rm -e OPENLINEAGE_INPUTS="${OPENLINEAGE_DATASET_NAMESPACE}|bronze.events" spark-demo -e "
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

banner "3. GRAPH-LEVEL: the OpenLineage-shaped event this commit emitted (no row-level concept at all)"
LINEAGE_EVENT=$(python3 "${ROOT_DIR}/scripts/latest_lineage_event.py" "customers" | tee -a "${ROOT_DIR}/out/04-composable-lineage.log")
echo "${LINEAGE_EVENT}"
SEQUENCE_NUMBER=$(echo "${LINEAGE_EVENT}" | grep -oE 'SEQUENCE_NUMBER=[0-9]+' | cut -d= -f2)

if [[ -z "${SEQUENCE_NUMBER}" ]]; then
  fail "could not extract sequenceNumber from the captured lineage event"
  exit 1
fi
pass "captured sequenceNumber=${SEQUENCE_NUMBER} from the lineage graph event"

banner "4. ROW-LEVEL: drilling the graph event straight into rows via _last_updated_sequence_number = ${SEQUENCE_NUMBER}"
dc run --rm duckdb-demo python3 /work/scripts/read_row_lineage.py silver customers customer_id _last_updated_sequence_number "${SEQUENCE_NUMBER}" \
  2>&1 | tee -a "${ROOT_DIR}/out/04-composable-lineage.log"

banner "5. BACK TO THE SOURCE: silver row -> the bronze event that fed it -> the Kafka Connect commit -> the Kafka topic"
TRACE=$(dc run --rm duckdb-demo python3 /work/scripts/lineage_sql.py "
SELECT s._row_id, s._last_updated_sequence_number AS silver_seq, s.customer_id,
       b._row_id AS bronze_row_id, b._last_updated_sequence_number AS bronze_seq, b.event_id
FROM silver.customers s JOIN bronze.events b ON b.event_id = s.last_event_id
WHERE s.customer_id = ${CUSTOMER_ID};" 2>&1 | grep -v Container)
echo "${TRACE}" | tee -a "${ROOT_DIR}/out/04-composable-lineage.log"
BRONZE_SEQ=$(echo "${TRACE}" | grep "${EVENT_ID:0:8}" | awk -F'│' '{gsub(/ /,"",$6); print $6}')
if [[ -z "${BRONZE_SEQ}" ]]; then
  fail "silver.customers' row for ${CUSTOMER_ID} does not point at the new event"
  exit 1
fi
python3 "${ROOT_DIR}/scripts/lineage_event_for_seq.py" "bronze.events" "${BRONZE_SEQ}" \
  | grep -vE "^(JOB|INPUTS)=" | tee -a "${ROOT_DIR}/out/04-composable-lineage.log"
pass "silver row -> event ${EVENT_ID:0:8}... -> bronze.events sequenceNumber ${BRONZE_SEQ} -> Kafka Connect, from the Kafka topic"

point "OpenLineage told us WHICH commit happened (graph). Iceberg's _last_updated_sequence_number told us WHICH ROWS that commit touched (identity) -- and, one hop back, which Kafka Connect commit and which topic the input record came from. Neither tool knows the other's model -- sequenceNumber is the one key that bridges them. That join IS Composable Lineage."
