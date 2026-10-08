#!/usr/bin/env bash
# Recorded window: raw events on the Kafka topic, as the producer sent them
# (no _row_id). Waits for the broker and the topic, so it can open before
# Stage 01 starts the stack. Used by demo/record-demo.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/lib.sh" >/dev/null
bash "${SCRIPT_DIR}/header.sh" "Kafka topic '${KAFKA_TOPIC}' -- raw events as produced (no _row_id)"
until docker exec lineage-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
        --describe --topic "${KAFKA_TOPIC}" >/dev/null 2>&1; do
  sleep 2
done
exec docker exec -it lineage-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic "${KAFKA_TOPIC}"
