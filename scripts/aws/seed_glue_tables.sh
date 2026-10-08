#!/usr/bin/env bash
# Seed the AWS backend (S3 + Glue) with the demo's three tables by running
# sql/aws/seed_glue_tables.sql through the existing spark-demo image.
#
# spark-demo's built-in `lake` catalog points at the local REST catalog; this
# adds a second catalog, `glue`, on the command line (GlueCatalog + S3FileIO),
# with the same Composable Lineage MetricsReporter so its commits show up in
# the dashboard's event feed too.
#
# Credentials: temporary keys exported from your AWS CLI profile for this one
# run, passed as environment variables -- never written to disk or .env.
#
#   aws sso login --profile your-profile
#   AWS_PROFILE=your-profile scripts/aws/seed_glue_tables.sh [sql file]
#
# The optional argument is a SQL file path inside the container (default
# /work/sql/aws/seed_glue_tables.sql); seed_bronze_events.sh uses it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib.sh"

if [[ "${LINEAGE_OFFLINE_RESOLVED}" == 1 ]]; then
  fail "offline: the AWS seed needs internet (S3 + Glue). The local demo doesn't -- LINEAGE_BACKEND=local."
  exit 1
fi

: "${LINEAGE_S3_BUCKET:?set LINEAGE_S3_BUCKET in .env}"
REGION="${LINEAGE_AWS_REGION:?set LINEAGE_AWS_REGION in .env}"
SQL_FILE="${1:-/work/sql/aws/seed_glue_tables.sql}"

# Loads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN into
# this shell only.
eval "$(aws configure export-credentials --format env)"

banner "Running ${SQL_FILE} against Glue (s3://${LINEAGE_S3_BUCKET}/, ${REGION})"
dc up -d --build openlineage-collector
dc run --rm \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION="${REGION}" \
  spark-demo \
  --conf spark.sql.catalog.glue=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.glue.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog \
  --conf "spark.sql.catalog.glue.warehouse=s3://${LINEAGE_S3_BUCKET}/" \
  --conf spark.sql.catalog.glue.io-impl=org.apache.iceberg.aws.s3.S3FileIO \
  --conf "spark.sql.catalog.glue.client.region=${REGION}" \
  --conf spark.sql.catalog.glue.metrics-reporter-impl=com.demo.lineage.OpenLineageMetricsReporter \
  -f "${SQL_FILE}"
