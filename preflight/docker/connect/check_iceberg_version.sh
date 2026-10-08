#!/usr/bin/env bash
# Inspects the iceberg-core jar actually sitting in the plugin path and fails
# LOUDLY if its bundled Iceberg version is older than the minimum required
# for correct row-lineage (_row_id) semantics.
#
# Apache Iceberg does not publish a shaded "iceberg-kafka-connect-runtime"
# jar to Maven Central for the donated connector, so the plugin directory
# here (/opt/kafka/plugins/iceberg-kafka-connect/) holds the connector jar
# plus its full unshaded dependency tree, resolved via Maven at image build
# time (see docker/connect/pom.xml). Iceberg's published jars carry no
# embedded pom.properties/manifest version metadata, so the jar's own
# filename (as laid down by `mvn dependency:copy-dependencies`, which always
# names copies `<artifactId>-<version>.jar`) is the version signal -- and
# also the thing worth checking, since it confirms Maven's dependency
# mediation didn't silently pull in an older iceberg-core than the one we
# asked for transitively (e.g. via parquet-hadoop -> hadoop-* -> iceberg).
#
# Why this matters: Iceberg < 1.10.0 silently REASSIGNS _row_id on compaction
# instead of preserving it via manifest inheritance. A harness that "passes"
# on an older jar would be reporting a false positive for the demo.
set -euo pipefail

MIN_VERSION="${ICEBERG_MIN_VERSION:-1.10.0}"
PLUGIN_DIR="/opt/kafka/plugins/iceberg-kafka-connect"

JAR="$(ls "${PLUGIN_DIR}"/iceberg-core-*.jar 2>/dev/null | head -n1 || true)"

if [[ -z "${JAR}" || ! -f "${JAR}" ]]; then
  echo "FATAL: iceberg-core jar not found in ${PLUGIN_DIR}" >&2
  exit 1
fi

BUNDLED_VERSION="$(basename "${JAR}" .jar | sed -E 's/^iceberg-core-//')"

if [[ -z "${BUNDLED_VERSION}" ]]; then
  echo "FATAL: could not parse a version out of jar filename $(basename "${JAR}")." >&2
  exit 1
fi

version_ge() {
  # true (0) if $1 >= $2, using natural version sort
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

echo "jar                      : $(basename "${JAR}")"
echo "bundled Iceberg version  : ${BUNDLED_VERSION}"
echo "required minimum         : ${MIN_VERSION}  (row lineage / _row_id manifest inheritance)"

if version_ge "${BUNDLED_VERSION}" "${MIN_VERSION}"; then
  echo "RESULT: OK -- ${BUNDLED_VERSION} >= ${MIN_VERSION}"
else
  echo ""
  echo "########################################################################"
  echo "# FATAL: bundled Iceberg version ${BUNDLED_VERSION} is OLDER than ${MIN_VERSION}."
  echo "#"
  echo "# Iceberg < 1.10.0 silently REASSIGNS _row_id on compaction instead of"
  echo "# preserving it via manifest inheritance. Any row-lineage result produced"
  echo "# by this harness on that version would be a false positive and is not"
  echo "# valid evidence for the demo. Refusing to start Kafka Connect."
  echo "#"
  echo "# Fix: bump ICEBERG_VERSION in .env to >= 1.10.0 (this repo defaults to"
  echo "# 1.11.0) and rebuild: docker compose build kafka-connect"
  echo "########################################################################"
  exit 1
fi
