#!/bin/sh
# One-shot Apache Polaris setup: create the "demo" catalog on MinIO.
# Idempotent: an existing catalog counts as success.
#
# Clients use their own static MinIO keys (stsUnavailable: no credential
# vending), exactly as with Lakekeeper and the reference REST catalog. All
# demo clients authenticate as the bootstrap principal (root), whose
# service_admin role gets catalog_admin on new catalogs.
set -eu
P=http://polaris:8181

TOKEN=$(curl -sf -X POST "$P/api/catalog/v1/oauth/tokens" \
  -d "grant_type=client_credentials&client_id=${POLARIS_CLIENT_ID}&client_secret=${POLARIS_CLIENT_SECRET}&scope=PRINCIPAL_ROLE:ALL" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "no token from Polaris"; exit 1; }

code=$(curl -s -o /tmp/out -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$P/api/management/v1/catalogs/${POLARIS_CATALOG}")
if [ "$code" = 200 ]; then echo "catalog ${POLARIS_CATALOG} already exists"; exit 0; fi

code=$(curl -s -o /tmp/out -w '%{http_code}' -X POST "$P/api/management/v1/catalogs" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data "{
    \"catalog\": {
      \"name\": \"${POLARIS_CATALOG}\",
      \"type\": \"INTERNAL\",
      \"readOnly\": false,
      \"properties\": { \"default-base-location\": \"s3://warehouse/polaris\" },
      \"storageConfigInfo\": {
        \"storageType\": \"S3\",
        \"allowedLocations\": [\"s3://warehouse/polaris\"],
        \"endpoint\": \"http://minio:9000\",
        \"endpointInternal\": \"http://minio:9000\",
        \"pathStyleAccess\": true,
        \"stsUnavailable\": true,
        \"region\": \"${AWS_REGION}\"
      }
    }
  }")
echo "create catalog: HTTP $code $(cat /tmp/out)"
case "$code" in 2*) exit 0 ;; *) exit 1 ;; esac
