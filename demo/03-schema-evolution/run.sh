#!/usr/bin/env bash
# STAGE 03 -- Schema evolution at the source: a new field arrives mid-stream.
#
# Events stream into Kafka; about 20 s in, the producer starts sending a new
# field ("channel") without warning, as when an upstream team ships one. The
# Kafka Connect Iceberg sink (iceberg.tables.evolve-schema-enabled, set in
# Stage 01) adds the column to bronze.events by itself -- metadata only, no
# data file rewritten, nothing stopped or restarted, no operator. Proven with
# scripts/schema_change_proof.py: every snapshot since the baseline is a Kafka
# Connect append, no file was deleted, the schema count went up by one.
#
# Rows written before the change read NULL for the new column (the sink adds it
# as optional, with no default); the new events carry their value.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/lib.sh"

RATE="${1:-5}"            # events per second
FIELD_AFTER="${2:-20}"    # seconds until the producer starts sending the new field
AFTER_EVOLVE=15           # keep streaming this long after the table evolved

banner "STAGE 03 -- Schema evolution at the source: a new field arrives mid-stream"
check_iceberg_version
point "The producer adds a field without warning. The Kafka Connect sink evolves the Iceberg table by itself -- a metadata-only schema change, no rewrite, no restart, no operator -- while the stream keeps flowing."

# spark-demo is a profile-gated `dc run` image, so `up --build` never rebuilds it;
# build explicitly so reporter changes always land (cached: seconds)
dc build -q spark-demo
dc up -d --build openlineage-collector lineage-dashboard

LOG="${ROOT_DIR}/out/03-schema-evolution.log"
STREAM_FILE="${ROOT_DIR}/out/03-streamed-events.jsonl"
STOP_FILE="${ROOT_DIR}/out/.stop-stream"
FIELD_FILE="${ROOT_DIR}/out/.field-added"

schema_count() {
  catalog_curl "$(catalog_table_url bronze events)" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["metadata"]["schemas"]))' 2>/dev/null || echo 0
}

banner "0. Baseline, then stream ${RATE} events/s into '${KAFKA_TOPIC}' -- still the original 4 fields"
dc run --rm duckdb-demo python3 /work/scripts/table_stats.py bronze events 2>&1 | tee "${LOG}"
read -r BASE_SEQ BASE_SCHEMAS < <(dc run --rm duckdb-demo python3 /work/scripts/schema_change_proof.py bronze events --baseline 2>/dev/null | tail -1)
info "baseline: sequence number ${BASE_SEQ}, ${BASE_SCHEMAS} schema(s)"
rm -f "${STOP_FILE}" "${FIELD_FILE}"
python3 -u "${ROOT_DIR}/scripts/stream_events.py" --rate "${RATE}" --stop-file "${STOP_FILE}" \
    --add-field-after "${FIELD_AFTER}" --marker-file "${FIELD_FILE}" \
  | tee "${STREAM_FILE}" \
  | dc exec -T kafka /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
      --topic "${KAFKA_TOPIC}" >/dev/null 2>&1 &
STREAM_PID=$!
trap 'touch "${STOP_FILE}"' EXIT
info "streaming (watch the Kafka window); Kafka Connect commits every 2 s"

banner "1. Without warning, the producer starts sending a new field: \"channel\""
for _ in $(seq 1 60); do [[ -f "${FIELD_FILE}" ]] && break; sleep 1; done
info "events now carry \"channel\" -- nobody changed the table"
EVOLVED=""
for _ in $(seq 1 60); do
  if [[ "$(schema_count)" -gt "${BASE_SCHEMAS}" ]]; then EVOLVED=1; break; fi
  sleep 2
done
if [[ -n "${EVOLVED}" ]]; then
  pass "the Kafka Connect sink evolved bronze.events by itself: ${BASE_SCHEMAS} -> $(schema_count) schemas"
else
  fail "bronze.events did not evolve within 120 s"
fi
sleep "${AFTER_EVOLVE}"

banner "2. Stop the stream; every event landed, nothing was rewritten or restarted"
touch "${STOP_FILE}"
wait "${STREAM_PID}" 2>/dev/null || true
STREAMED=$(wc -l < "${STREAM_FILE}" | tr -d ' ')
info "streamed ${STREAMED} events during this stage; waiting for Kafka Connect's last commit"
LANDED=0
for _ in $(seq 1 30); do
  LANDED=$(dc run --rm duckdb-demo python3 /work/scripts/lineage_sql.py \
    "SELECT count(*) AS landed FROM read_json_auto('/work/out/03-streamed-events.jsonl') s JOIN bronze.events e USING (event_id);" 2>/dev/null \
    | grep -oE "│ +[0-9]+ +│" | tr -dc '0-9')
  [[ "${LANDED:-0}" -ge "${STREAMED}" ]] && break
  sleep 2
done
TASK_STATE=$(curl -s "http://localhost:8083/connectors/iceberg-sink/status" | jq -r '.tasks[0].state')
dc run --rm duckdb-demo python3 /work/scripts/schema_change_proof.py bronze events \
  "${BASE_SEQ}" "${BASE_SCHEMAS}" 1 2>&1 | grep -v Container | tee -a "${LOG}"
if [[ "${LANDED}" == "${STREAMED}" ]]; then pass "all ${STREAMED} streamed events are in bronze.events"; else fail "${LANDED}/${STREAMED} streamed events landed"; fi
if [[ "${TASK_STATE}" == "RUNNING" ]]; then pass "Kafka Connect task still RUNNING -- never restarted"; else fail "Kafka Connect task is ${TASK_STATE}"; fi

banner "3. Before and after the field appeared"
dc run --rm duckdb-demo python3 /work/scripts/lineage_sql.py "
SELECT CASE WHEN channel IS NULL THEN 'before the new field (NULL)' ELSE 'after: ' || channel END AS rows_written,
       count(*) AS rows
FROM bronze.events GROUP BY ALL ORDER BY 1;" 2>&1 | grep -v Container | tee -a "${LOG}"
point "The source changed its schema without warning and the pipeline kept going: the sink evolved the Iceberg table itself (metadata only, zero rewritten files), nothing stopped or restarted, and every event landed. Rows from before the change read NULL for the new column."
