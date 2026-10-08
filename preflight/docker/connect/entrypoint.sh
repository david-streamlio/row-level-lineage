#!/usr/bin/env bash
set -euo pipefail

echo "=================================================================="
echo " Iceberg Kafka Connect sink -- bundled Iceberg version check"
echo "=================================================================="
check_iceberg_version.sh
echo "=================================================================="
echo ""

exec "${KAFKA_HOME}/bin/connect-distributed.sh" "${KAFKA_HOME}/config/connect-distributed.properties"
