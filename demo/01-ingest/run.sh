#!/usr/bin/env bash
# STAGE 01 -- Ingest / row identity (CONFIRMED in preflight/).
#
# Reuses preflight/'s Kafka + Kafka Connect Iceberg sink + REST catalog +
# DuckDB verification EXACTLY as proven there, just invoked through the
# root docker-compose.yml (which `include:`s preflight/docker-compose.yml
# unmodified) so it lives in the same Compose project as every other stage.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/lib.sh"

COUNT="${1:-300}"
# seconds between events: they "stream" in for the audience (300 x 0.25 s =
# 75 s) and Kafka Connect commits a handful at a time, so first-row-id visibly
# continues commit to commit. EVENT_INTERVAL=0 sends them all at once.
EVENT_INTERVAL="${EVENT_INTERVAL:-0.25}"

command -v jq >/dev/null 2>&1 || { fail "jq is required on the host (brew install jq)"; exit 1; }

banner "STAGE 01 -- Ingest / row identity"
check_iceberg_version
point "Row identity (_row_id) is inherited at commit time via manifest inheritance -- never materialized by the writer. Kafka Connect never sets _row_id; Iceberg assigns it when the snapshot commits."

mkdir -p "${ROOT_DIR}/out" "${ROOT_DIR}/preflight/out"

banner "1. Bringing up MinIO, the catalog (${CATALOG_SERVICES%% *}), Kafka, Kafka Connect"
# collector first (it brings Marquez up with it): Kafka Connect's commits
# emit lineage events from the first snapshot on
dc up -d --build openlineage-collector
# shellcheck disable=SC2086 -- CATALOG_SERVICES is a list of service names
dc up -d --build minio mc-init ${CATALOG_SERVICES} kafka kafka-connect
dc up -d --build lineage-dashboard
info "live dashboard: http://localhost:${DASHBOARD_PORT_HOST}"
info "lineage graph (Marquez): http://localhost:${MARQUEZ_WEB_PORT_HOST}"
[[ "${CATALOG_SERVICES}" == lakekeeper* ]] && info "catalog UI (Lakekeeper): http://localhost:${LAKEKEEPER_PORT_HOST}/ui"

banner "2. Waiting for services to be reachable"
wait_http "http://localhost:9000/minio/health/live" "MinIO"
info "waiting for the Iceberg REST catalog (${CATALOG_SERVICES%% *}) ..."
for _ in $(seq 1 60); do catalog_curl -o /dev/null "${CATALOG_URI_HOST}/v1/config?warehouse=${CATALOG_WAREHOUSE}" 2>/dev/null && break; sleep 2; done
catalog_curl -o /dev/null "${CATALOG_URI_HOST}/v1/config?warehouse=${CATALOG_WAREHOUSE}" || { fail "catalog not reachable"; exit 1; }
info "catalog is up"
wait_http "http://localhost:8083/connectors" "Kafka Connect"

banner "3. Bundled Iceberg version (printed at kafka-connect container startup)"
dc logs kafka-connect 2>/dev/null | grep -E "bundled Iceberg version|required minimum|RESULT:" || true

banner "4. Creating Kafka topic '${KAFKA_TOPIC}'"
dc exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --if-not-exists --topic "${KAFKA_TOPIC}" --partitions 1 --replication-factor 1
dc exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic "${KAFKA_TOPIC}"

banner "5. Creating V3 bronze.events explicitly (auto-create is OFF in the connector -- V2-by-default auto-create is exactly what row lineage can't survive)"
# spark-demo (Spark 4.0), whose "lake" catalog is the demo catalog (CATALOG_*
# in .env); preflight's Spark 3.5 image is baked against its own REST server
dc build -q spark-demo
dc run --rm spark-demo -f /work/sql/create_bronze_table.sql 2>&1 | tee "${ROOT_DIR}/out/01-create-table.log"

banner "6. Registering the Kafka Connect Iceberg sink"
# OAuth lines for catalogs that need them (Polaris); built here because
# ${VAR:+...} inside the heredoc would strip their quotes
CONNECT_AUTH=""
[[ -n "${CATALOG_CREDENTIAL:-}" ]] && CONNECT_AUTH=$'\n'"    \"iceberg.catalog.credential\": \"${CATALOG_CREDENTIAL}\","$'\n'"    \"iceberg.catalog.scope\": \"${CATALOG_SCOPE}\","
CONNECTOR_JSON=$(cat <<JSON
{
  "name": "iceberg-sink",
  "config": {
    "connector.class": "org.apache.iceberg.connect.IcebergSinkConnector",
    "tasks.max": "1",
    "topics": "${KAFKA_TOPIC}",
    "iceberg.tables": "${ICEBERG_NAMESPACE}.${ICEBERG_TABLE}",
    "iceberg.tables.auto-create-enabled": "false",
    "iceberg.tables.evolve-schema-enabled": "true",
    "iceberg.catalog.type": "rest",
    "iceberg.catalog.uri": "${CATALOG_URI}",
    "iceberg.catalog.warehouse": "${CATALOG_WAREHOUSE}",${CONNECT_AUTH}
    "iceberg.catalog.io-impl": "org.apache.iceberg.aws.s3.S3FileIO",
    "iceberg.catalog.s3.endpoint": "http://minio:9000",
    "iceberg.catalog.s3.path-style-access": "true",
    "iceberg.catalog.s3.access-key-id": "${MINIO_ROOT_USER}",
    "iceberg.catalog.s3.secret-access-key": "${MINIO_ROOT_PASSWORD}",
    "iceberg.catalog.client.region": "${AWS_REGION}",
    "iceberg.catalog.rest-metrics-reporting-enabled": "false",
    "iceberg.catalog.metrics-reporter-impl": "com.demo.lineage.OpenLineageMetricsReporter",
    "iceberg.control.commit.interval-ms": "2000",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false"
  }
}
JSON
)

EXISTING_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8083/connectors/iceberg-sink")
if [[ "${EXISTING_STATUS}" == "200" ]]; then
  info "connector 'iceberg-sink' already exists, updating its config"
  echo "${CONNECTOR_JSON}" | jq '.config' | curl -s -X PUT -H "Content-Type: application/json" \
    -d @- "http://localhost:8083/connectors/iceberg-sink/config" >/dev/null
else
  curl -sf -X POST -H "Content-Type: application/json" -d "${CONNECTOR_JSON}" \
    "http://localhost:8083/connectors" >/dev/null
fi

banner "7. Waiting for the connector task to reach RUNNING"
STATE="UNASSIGNED"
for _ in $(seq 1 30); do
  STATE=$(curl -s "http://localhost:8083/connectors/iceberg-sink/status" | jq -r '.tasks[0].state // "UNASSIGNED"')
  if [[ "${STATE}" == "RUNNING" ]]; then pass "connector task RUNNING"; break; fi
  if [[ "${STATE}" == "FAILED" ]]; then
    fail "connector task FAILED"; curl -s "http://localhost:8083/connectors/iceberg-sink/status" | jq .; exit 1
  fi
  sleep 2
done
[[ "${STATE}" == "RUNNING" ]] || { fail "connector did not reach RUNNING"; exit 1; }

banner "8. Streaming ${COUNT} synthetic events to '${KAFKA_TOPIC}', one every ${EVENT_INTERVAL}s (append-only)"
TMP_FILE=$(mktemp)
trap 'rm -f "${TMP_FILE}"' EXIT
python3 "${ROOT_DIR}/preflight/scripts/generate_events.py" "${COUNT}" > "${TMP_FILE}"
info "sample record:"
head -n 1 "${TMP_FILE}"
python3 -u -c '
import sys, time
delay = float(sys.argv[1])
for line in sys.stdin:
    sys.stdout.write(line); sys.stdout.flush()
    time.sleep(delay)' "${EVENT_INTERVAL}" < "${TMP_FILE}" \
  | dc exec -T kafka /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server localhost:9092 --topic "${KAFKA_TOPIC}"

# all produced: wait until every event is committed (Connect commits every 2 s)
for _ in $(seq 1 30); do
  committed=$(catalog_curl "$(catalog_table_url "${ICEBERG_NAMESPACE}" "${ICEBERG_TABLE}")" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"].get("next-row-id") or 0)' 2>/dev/null || echo 0)
  [[ "${committed}" -ge "${COUNT}" ]] && break
  sleep 2
done
info "${committed:-0} of ${COUNT} events committed"

banner "9. Verifying row lineage (DuckDB Checks A/B/C -- copy-pasteable slide material)"
# preflight's verify_duckdb.py checks, unchanged, run through
# scripts/verify_stage1.py (demo catalog lookup) in duckdb-demo, whose DuckDB
# extensions are baked in, so this works without internet at the venue
dc run --rm -e ICEBERG_NAMESPACE -e ICEBERG_TABLE \
  -v "${ROOT_DIR}/preflight/scripts:/work/preflight-scripts:ro" \
  duckdb-demo python3 /work/scripts/verify_stage1.py

point "Identity was inherited at commit -- Kafka Connect wrote plain Parquet rows; Iceberg's manifest writer assigned _row_id on commit. Nothing in the producer or the sink ever set it."
