#!/usr/bin/env bash
# V3 round-trip test: Lakekeeper vs the reference Iceberg REST catalog.
# Gate for switching the demo to Lakekeeper -- see compare_v3.py for what is
# checked. Needs the demo stack up (run demo/run-stage.sh 1 first); starts
# Lakekeeper and preflight's reference REST catalog itself.
#
# Spark catalogs: "ref" = reference catalog, "lk" = Lakekeeper (explicit, so
# this works whichever catalog the demo's "lake" points at; neither emits
# lineage events). Creates namespace rt in both (rt.customers, plus rt.events
# in Lakekeeper) and a connector iceberg-sink-lk-<run>. --cleanup drops them.
#
#   scripts/lakekeeper/v3_roundtrip.sh [--candidate lakekeeper|polaris] [--cleanup]
#
# --candidate picks the catalog under test (default lakekeeper). Polaris
# clients authenticate with OAuth client credentials (POLARIS_CLIENT_* in .env).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib.sh"

CLEANUP=""; CANDIDATE="lakekeeper"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) CLEANUP="--cleanup"; shift ;;
    --candidate) CANDIDATE="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "${CANDIDATE}" in
  lakekeeper)
    C_LABEL="Lakekeeper ${LAKEKEEPER_VERSION}"; C_URI=http://lakekeeper:8181/catalog
    LK_URI_HOST="http://localhost:${LAKEKEEPER_PORT_HOST}/catalog"; C_WH="${LAKEKEEPER_WAREHOUSE}"
    C_CRED=""; C_SCOPE=""; C_UP=(lakekeeper-bootstrap) ;;
  polaris)
    C_LABEL="Apache Polaris ${POLARIS_VERSION}"; C_URI=http://polaris:8181/api/catalog
    LK_URI_HOST="http://localhost:${POLARIS_PORT_HOST}/api/catalog"; C_WH="${POLARIS_CATALOG}"
    C_CRED="${POLARIS_CLIENT_ID}:${POLARIS_CLIENT_SECRET}"; C_SCOPE="PRINCIPAL_ROLE:ALL"; C_UP=(polaris-bootstrap) ;;
  *) echo "unknown candidate: ${CANDIDATE}" >&2; exit 1 ;;
esac
# curl against the candidate, with an OAuth token when it needs one
cand_curl() {
  if [[ -n "${C_CRED}" ]]; then
    local token
    token=$(curl -fsS -X POST "${LK_URI_HOST}/v1/oauth/tokens" \
      -d "grant_type=client_credentials&client_id=${C_CRED%%:*}&client_secret=${C_CRED#*:}&scope=${C_SCOPE}" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') || return 1
    curl -fsS -H "Authorization: Bearer ${token}" "$@"
  else
    curl -fsS "$@"
  fi
}
# Fresh connector + control topic per run: a re-created connector of the same
# name keeps its consumer offsets and would skip the existing topic data.
RUN_ID=$(date +%s)
LK_CONNECTOR="iceberg-sink-lk-${RUN_ID}"
LK_CONTROL_TOPIC="control-iceberg-lk-${RUN_ID}"

# Spark catalogs "ref" (reference REST server) and "lk" (Lakekeeper), both
# with static MinIO keys
LK_CONF=(
  --conf spark.sql.catalog.ref=org.apache.iceberg.spark.SparkCatalog
  --conf spark.sql.catalog.ref.type=rest
  --conf "spark.sql.catalog.ref.uri=${ICEBERG_REST_URI}"
  --conf "spark.sql.catalog.ref.warehouse=${ICEBERG_WAREHOUSE}"
  --conf spark.sql.catalog.ref.io-impl=org.apache.iceberg.aws.s3.S3FileIO
  --conf spark.sql.catalog.ref.s3.endpoint=http://minio:9000
  --conf spark.sql.catalog.ref.s3.path-style-access=true
  --conf "spark.sql.catalog.ref.s3.access-key-id=${MINIO_ROOT_USER}"
  --conf "spark.sql.catalog.ref.s3.secret-access-key=${MINIO_ROOT_PASSWORD}"
  --conf "spark.sql.catalog.ref.client.region=${AWS_REGION}"
  --conf spark.sql.catalog.lk=org.apache.iceberg.spark.SparkCatalog
  --conf spark.sql.catalog.lk.type=rest
  --conf "spark.sql.catalog.lk.uri=${C_URI}"
  --conf "spark.sql.catalog.lk.warehouse=${C_WH}"
  --conf spark.sql.catalog.lk.io-impl=org.apache.iceberg.aws.s3.S3FileIO
  --conf spark.sql.catalog.lk.s3.endpoint=http://minio:9000
  --conf spark.sql.catalog.lk.s3.path-style-access=true
  --conf "spark.sql.catalog.lk.s3.access-key-id=${MINIO_ROOT_USER}"
  --conf "spark.sql.catalog.lk.s3.secret-access-key=${MINIO_ROOT_PASSWORD}"
  --conf "spark.sql.catalog.lk.client.region=${AWS_REGION}"
)
if [[ -n "${C_CRED}" ]]; then
  LK_CONF+=(--conf "spark.sql.catalog.lk.credential=${C_CRED}" --conf "spark.sql.catalog.lk.scope=${C_SCOPE}")
fi

run_spark() {  # <label> <command...>: stop with the output if Spark fails
  local label="$1" out
  shift
  if ! out=$("$@" 2>&1); then
    echo "${out}" | grep -E "ERROR|Exception:" | grep -vE "^\s+at " | head -6 | cut -c1-400
    fail "${label}"
    exit 1
  fi
  echo "${out}" | grep -E "Added|Changed|Time taken" | tail -3 || true
}

spark_sql_file() {  # <catalog> <sql file with __C__ / __PURGE__ placeholders>
  local sql purge=""
  [[ "$1" == "ref" ]] && purge=PURGE
  sql=$(sed -e "s/__C__/$1/g" -e "s/__PURGE__/${purge}/g" "$2")
  run_spark "spark-sql on $1" dc run --rm spark-demo "${LK_CONF[@]}" -e "${sql}"
}

spark_submit() {  # <script> <args...>
  run_spark "spark-submit $*" dc run --rm --entrypoint /usr/local/bin/demo-spark-submit spark-demo "${LK_CONF[@]}" "$@"
}

lk_snapshots() {  # <namespace> <table>
  local prefix
  prefix=$(cand_curl "${LK_URI_HOST}/v1/config?warehouse=${C_WH}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["overrides"].get("prefix") or d["defaults"]["prefix"])')
  cand_curl "${LK_URI_HOST}/v1/${prefix}/namespaces/$1/tables/$2" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["metadata"].get("snapshots",[])))' 2>/dev/null || echo 0
}

wait_lk_snapshots() {  # <namespace> <table> <more than>
  for _ in $(seq 1 60); do
    [[ "$(lk_snapshots "$1" "$2")" -gt "$3" ]] && return 0
    sleep 2
  done
  fail "no new Lakekeeper snapshot on $1.$2"; return 1
}

banner "V3 round trip: ${C_LABEL} vs reference REST catalog"
dc build -q spark-demo duckdb-demo
dc up -d iceberg-rest
if [[ "${C_UP[0]}" == --profile ]]; then dc "${C_UP[@]}"; else dc up -d "${C_UP[@]}"; fi
wait_http "${ICEBERG_REST_URI_HOST}/v1/config" "reference REST catalog"
for _ in $(seq 1 60); do cand_curl -o /dev/null "${LK_URI_HOST}/v1/config?warehouse=${C_WH}" 2>/dev/null && break; sleep 2; done
cand_curl -o /dev/null "${LK_URI_HOST}/v1/config?warehouse=${C_WH}" || { fail "${C_LABEL} not reachable"; exit 1; }
info "${C_LABEL} is up"
wait_http "http://localhost:8083/connectors" "Kafka Connect"

for catalog in ref lk; do
  banner "1. Spark operations on ${catalog}.rt.customers"
  spark_sql_file "${catalog}" "${SCRIPT_DIR}/roundtrip_ops.sql"
  spark_submit /work/scripts/spark/add_column_with_default.py "${catalog}.rt.customers" channel STRING web
  spark_submit /work/scripts/spark/set_column_write_default.py "${catalog}.rt.customers" channel mobile
  spark_sql_file "${catalog}" "${SCRIPT_DIR}/roundtrip_variant.sql"
done

banner "2. Kafka Connect -> Lakekeeper rt.events"
spark_sql_file lk <(echo "DROP TABLE IF EXISTS __C__.rt.events;"; sed -e 's/CREATE NAMESPACE IF NOT EXISTS bronze;/CREATE NAMESPACE IF NOT EXISTS __C__.rt;/' \
  -e 's/bronze\.events/__C__.rt.events/g' -e '/^DESCRIBE/d' "${ROOT_DIR}/preflight/sql/create_bronze_table.sql")
dc exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --if-not-exists --topic "${LK_CONTROL_TOPIC}" --partitions 1 --replication-factor 1 >/dev/null
# remove connectors left by earlier runs
for old in $(curl -s http://localhost:8083/connectors | jq -r '.[] | select(startswith("iceberg-sink-lk"))'); do
  curl -s -X DELETE "http://localhost:8083/connectors/${old}" >/dev/null
done
# OAuth lines for the connector when the candidate needs them (built here:
# inside the heredoc, ${VAR:+...} would strip their quotes)
CONNECT_AUTH=""
[[ -n "${C_CRED}" ]] && CONNECT_AUTH=$'\n'"    \"iceberg.catalog.credential\": \"${C_CRED}\","$'\n'"    \"iceberg.catalog.scope\": \"${C_SCOPE}\","
curl -sf -X POST -H "Content-Type: application/json" "http://localhost:8083/connectors" -d @- >/dev/null <<JSON
{
  "name": "${LK_CONNECTOR}",
  "config": {
    "connector.class": "org.apache.iceberg.connect.IcebergSinkConnector",
    "tasks.max": "1",
    "topics": "${KAFKA_TOPIC}",
    "iceberg.tables": "rt.events",
    "iceberg.tables.auto-create-enabled": "false",
    "iceberg.tables.evolve-schema-enabled": "false",
    "iceberg.control.topic": "${LK_CONTROL_TOPIC}",
    "iceberg.catalog.type": "rest",
    "iceberg.catalog.uri": "${C_URI}",
    "iceberg.catalog.warehouse": "${C_WH}",${CONNECT_AUTH}
    "iceberg.catalog.io-impl": "org.apache.iceberg.aws.s3.S3FileIO",
    "iceberg.catalog.s3.endpoint": "http://minio:9000",
    "iceberg.catalog.s3.path-style-access": "true",
    "iceberg.catalog.s3.access-key-id": "${MINIO_ROOT_USER}",
    "iceberg.catalog.s3.secret-access-key": "${MINIO_ROOT_PASSWORD}",
    "iceberg.catalog.client.region": "${AWS_REGION}",
    "iceberg.control.commit.interval-ms": "2000",
    "consumer.override.auto.offset.reset": "earliest",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false"
  }
}
JSON
info "connector ${LK_CONNECTOR} registered; waiting for its first commit (existing topic data)"
wait_lk_snapshots rt events 0
info "producing 50 more events for a second commit"
python3 "${ROOT_DIR}/preflight/scripts/generate_events.py" 50 \
  | dc exec -T kafka /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic "${KAFKA_TOPIC}"
wait_lk_snapshots rt events 1

banner "3. Comparing"
set +e
dc run --rm -e ICEBERG_REST_URI -e CANDIDATE_URI="${C_URI}" -e CANDIDATE_WAREHOUSE="${C_WH}" \
  -e CANDIDATE_CREDENTIAL="${C_CRED}" -e CANDIDATE_SCOPE="${C_SCOPE}" -e CANDIDATE_LABEL="${C_LABEL}" -v "${SCRIPT_DIR}:/work/lakekeeper:ro" \
  duckdb-demo python3 /work/lakekeeper/compare_v3.py
RESULT=$?
set -e

if [[ "${CLEANUP}" == "--cleanup" ]]; then
  banner "Cleanup"
  curl -s -X DELETE "http://localhost:8083/connectors/${LK_CONNECTOR}" >/dev/null || true
  # Lakekeeper deletes dropped tables' files itself, so no PURGE there
  dc run --rm spark-demo "${LK_CONF[@]}" -e "
    DROP TABLE IF EXISTS ref.rt.customers PURGE; DROP NAMESPACE IF EXISTS ref.rt;
    DROP TABLE IF EXISTS lk.rt.customers; DROP TABLE IF EXISTS lk.rt.events;
    DROP NAMESPACE IF EXISTS lk.rt;" >/dev/null 2>&1 && info "dropped rt tables and connector"
fi
exit "${RESULT}"
