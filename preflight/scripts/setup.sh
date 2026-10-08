#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

command -v jq >/dev/null 2>&1 || { fail "jq is required on the host (brew install jq)"; exit 1; }

mkdir -p "${ROOT_DIR}/out"

banner "1. Bringing up infrastructure (MinIO, REST catalog, Kafka, Kafka Connect)"
dc up -d --build minio mc-init iceberg-rest kafka kafka-connect

banner "2. Waiting for services to be reachable"
wait_http "http://localhost:9000/minio/health/live" "MinIO"
wait_http "${ICEBERG_REST_URI_HOST}/v1/config" "Iceberg REST catalog"
wait_http "http://localhost:8083/connectors" "Kafka Connect"

banner "3. Bundled Iceberg version (printed at kafka-connect container startup)"
dc logs kafka-connect 2>/dev/null | grep -E "bundled Iceberg version|required minimum|RESULT:" || true

banner "4. Creating Kafka topic '${KAFKA_TOPIC}'"
dc exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --if-not-exists --topic "${KAFKA_TOPIC}" --partitions 1 --replication-factor 1
dc exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic "${KAFKA_TOPIC}"

banner "5. Creating V3 bronze.events explicitly via Spark SQL (auto-create is OFF in the connector)"
dc run --rm spark -f /work/sql/create_bronze_table.sql 2>&1 | tee "${ROOT_DIR}/out/create_table.log"
info "full format-version verification happens in scripts/verify.sh (Check A) against the REST catalog's own metadata JSON"

banner "6. Registering Kafka Connect Iceberg sink (iceberg.tables.auto-create-enabled=false)"
CONNECTOR_JSON=$(cat <<JSON
{
  "name": "iceberg-sink",
  "config": {
    "connector.class": "org.apache.iceberg.connect.IcebergSinkConnector",
    "tasks.max": "1",
    "topics": "${KAFKA_TOPIC}",
    "iceberg.tables": "${ICEBERG_NAMESPACE}.${ICEBERG_TABLE}",
    "iceberg.tables.auto-create-enabled": "false",
    "iceberg.tables.evolve-schema-enabled": "false",
    "iceberg.catalog.type": "rest",
    "iceberg.catalog.uri": "${ICEBERG_REST_URI}",
    "iceberg.catalog.warehouse": "${ICEBERG_WAREHOUSE}",
    "iceberg.catalog.io-impl": "org.apache.iceberg.aws.s3.S3FileIO",
    "iceberg.catalog.s3.endpoint": "http://minio:9000",
    "iceberg.catalog.s3.path-style-access": "true",
    "iceberg.catalog.s3.access-key-id": "${MINIO_ROOT_USER}",
    "iceberg.catalog.s3.secret-access-key": "${MINIO_ROOT_PASSWORD}",
    "iceberg.catalog.client.region": "${AWS_REGION}",
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
  if [[ "${STATE}" == "RUNNING" ]]; then
    pass "connector task RUNNING"
    break
  fi
  if [[ "${STATE}" == "FAILED" ]]; then
    fail "connector task FAILED -- full status below"
    curl -s "http://localhost:8083/connectors/iceberg-sink/status" | jq .
    exit 1
  fi
  sleep 2
done

if [[ "${STATE}" != "RUNNING" ]]; then
  fail "connector task did not reach RUNNING in time (last state: ${STATE})"
  curl -s "http://localhost:8083/connectors/iceberg-sink/status" | jq .
  exit 1
fi

curl -s "http://localhost:8083/connectors/iceberg-sink/status" | jq .

banner "Setup complete"
