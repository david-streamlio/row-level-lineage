#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

COUNT="${1:-300}"

banner "Producing ${COUNT} synthetic events to topic '${KAFKA_TOPIC}' (append-only)"

TMP_FILE=$(mktemp)
trap 'rm -f "${TMP_FILE}"' EXIT

python3 "${SCRIPT_DIR}/generate_events.py" "${COUNT}" > "${TMP_FILE}"

info "sample record:"
head -n 1 "${TMP_FILE}"

dc exec -T kafka /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic "${KAFKA_TOPIC}" < "${TMP_FILE}"

wait_for_snapshot 90

pass "produced ${COUNT} records to '${KAFKA_TOPIC}' and confirmed a snapshot committed"
