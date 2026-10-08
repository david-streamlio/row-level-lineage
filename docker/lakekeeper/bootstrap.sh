#!/bin/sh
# One-shot Lakekeeper setup: accept the terms (bootstrap) and create the
# "demo" warehouse on MinIO. Idempotent: an already-bootstrapped server and
# an existing warehouse both count as success.
#
# No STS and no remote signing (Lakekeeper's default is on): clients use
# their own static MinIO keys, exactly as with the reference REST catalog,
# and S3 traffic doesn't depend on Lakekeeper signing each request.
#
# Storage layout: readable folders in MinIO (lakekeeper/bronze/events-<uuid>/)
# instead of bare UUIDs.
#
# Lakekeeper deletes a dropped table's files itself, so use plain DROP TABLE;
# Spark's DROP TABLE ... PURGE then races it and fails on missing files.
set -eu
LK=http://lakekeeper:8181

code=$(curl -s -o /tmp/out -w '%{http_code}' -X POST "$LK/management/v1/bootstrap" \
  -H 'Content-Type: application/json' --data '{"accept-terms-of-use": true}')
echo "bootstrap: HTTP $code $(cat /tmp/out)"

# an existing warehouse answers 400 "storage profile overlaps", so check first
if curl -sf -o /dev/null "$LK/catalog/v1/config?warehouse=${LAKEKEEPER_WAREHOUSE}"; then
  echo "warehouse ${LAKEKEEPER_WAREHOUSE} already exists"
  exit 0
fi

body=$(cat <<JSON
{
  "warehouse-name": "${LAKEKEEPER_WAREHOUSE}",
  "storage-profile": {
    "type": "s3",
    "bucket": "warehouse",
    "key-prefix": "lakekeeper",
    "endpoint": "http://minio:9000",
    "region": "${AWS_REGION}",
    "path-style-access": true,
    "flavor": "s3-compat",
    "sts-enabled": false,
    "remote-signing-enabled": false,
    "storage-layout": {"type": "full-hierarchy", "namespace": "{name}", "tabular": "{name}-{uuid}"}
  },
  "storage-credential": {
    "type": "s3",
    "credential-type": "access-key",
    "aws-access-key-id": "${MINIO_ROOT_USER}",
    "aws-secret-access-key": "${MINIO_ROOT_PASSWORD}"
  }
}
JSON
)
code=$(curl -s -o /tmp/out -w '%{http_code}' -X POST "$LK/management/v1/warehouse" \
  -H 'Content-Type: application/json' --data "$body")
echo "warehouse: HTTP $code $(cat /tmp/out)"
case "$code" in
  2*) exit 0 ;;
  *) exit 1 ;;
esac
