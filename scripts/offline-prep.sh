#!/usr/bin/env bash
# Get the demo ready to run without internet, then check that it is.
#
#   scripts/offline-prep.sh          # ONLINE: build + pull everything, then check
#   scripts/offline-prep.sh --check  # works OFFLINE: verify only, change nothing
#
# What "ready" means:
#   - every image the stack runs is present locally (nothing pulls at runtime)
#   - every base image the builds start FROM is present, so `--build` /
#     `dc build` still work offline (the Dockerfiles keep network steps in
#     layers that only re-run when versions or pom.xml change)
#   - DuckDB's extensions load with no network in the images that read tables
#   - host tools are installed, and LINEAGE_BACKEND=local (no AWS)
#   - the MinIO images are backed up: the pinned quay.io/minio tags can no
#     longer be pulled (HTTP 401 as of 2026-10-07), so if Docker's image cache
#     is ever cleared, `docker load -i` the backup instead
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

MODE="${1:-prep}"
BACKUP_DIR="${LINEAGE_IMAGE_BACKUP:-${HOME}/.cache/row-level-lineage}"
FAILED=0
ok()  { pass "$*"; }
bad() { fail "$*"; FAILED=1; }

if [[ "${MODE}" != "--check" ]]; then
  banner "1. Building every image (needs internet the first time; cached after)"
  dc --profile tools build
  banner "2. Pulling pre-built images that aren't local yet"
  dc --profile tools pull --ignore-buildable --policy missing
  banner "3. Backing up the MinIO images to ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"
  docker save -o "${BACKUP_DIR}/minio-images.tar" "${MINIO_IMAGE}" "${MC_IMAGE}"
  info "restore with: docker load -i ${BACKUP_DIR}/minio-images.tar"
fi

banner "Images the stack runs"
while read -r image; do
  if docker image inspect "${image}" >/dev/null 2>&1; then ok "${image}"; else bad "missing: ${image}"; fi
done < <(dc --profile tools config --images | sort -u)

banner "Base images the builds start FROM (for offline rebuilds)"
while read -r image; do
  if docker image inspect "${image}" >/dev/null 2>&1; then
    ok "${image}"
  elif [[ "${MODE}" != "--check" ]] && docker pull -q "${image}" >/dev/null; then
    ok "${image} (pulled)"
  else
    bad "missing: ${image}"
  fi
done < <(grep -h "^FROM" "${ROOT_DIR}"/docker/*/Dockerfile "${ROOT_DIR}"/docker/*/*/Dockerfile \
           "${ROOT_DIR}"/dashboard/Dockerfile "${ROOT_DIR}"/preflight/docker/*/Dockerfile 2>/dev/null \
         | awk '{print $2}' | sort -u)

banner "DuckDB extensions load with no network"
for image in lineage-duckdb-demo:local lineage-dashboard:local; do
  if docker run --rm --network none --entrypoint python3 "${image}" -c \
      "import duckdb; c = duckdb.connect(); c.execute('LOAD httpfs; LOAD avro; LOAD iceberg; LOAD aws')" \
      >/dev/null 2>&1; then
    ok "${image}"
  else
    bad "${image}: DuckDB extensions not baked in (rebuild it online)"
  fi
done

banner "MinIO image backup"
if [[ -s "${BACKUP_DIR}/minio-images.tar" ]]; then
  ok "${BACKUP_DIR}/minio-images.tar"
else
  bad "no backup at ${BACKUP_DIR}/minio-images.tar (run without --check while the images are local)"
fi

banner "Host tools and backend"
for tool in docker jq python3 curl; do
  if command -v "${tool}" >/dev/null 2>&1; then ok "${tool}"; else bad "missing host tool: ${tool}"; fi
done
if [[ "${LINEAGE_BACKEND:-local}" == "local" ]]; then
  ok "LINEAGE_BACKEND=local (MinIO + local catalog, no AWS)"
else
  bad "LINEAGE_BACKEND=${LINEAGE_BACKEND} -- set it to local in .env to work without AWS"
fi

echo
if [[ "${FAILED}" == 0 ]]; then
  pass "ready to work offline"
else
  fail "not ready -- fix the items above while online"
fi
exit "${FAILED}"
