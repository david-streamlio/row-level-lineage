#!/usr/bin/env bash
# Shared helpers sourced by every script in this directory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")

banner() { echo; echo "${BOLD}== $* ==${RESET}"; }
pass()   { echo "${GREEN}PASS${RESET}: $*"; }
fail()   { echo "${RED}FAIL${RESET}: $*"; }
info()   { echo "${YELLOW}--${RESET} $*"; }

# wait_http <url> <label> [tries]
wait_http() {
  local url="$1" label="$2" tries="${3:-60}"
  info "waiting for ${label} (${url}) ..."
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS -o /dev/null "${url}"; then
      info "${label} is up"
      return 0
    fi
    sleep 2
  done
  fail "${label} did not become ready at ${url} after $((tries * 2))s"
  return 1
}

dc() {
  docker compose --project-directory "${ROOT_DIR}" "$@"
}

# wait_for_snapshot <tries>
# Polls the REST catalog's LoadTableResult for bronze.events until it reports
# at least one snapshot. A fixed sleep after producing is unreliable: the
# Iceberg Kafka Connect sink's control topic has to be auto-created and its
# commit coordinator elected before the first commit.interval-ms timer even
# starts, which routinely takes 30-45s cold -- much longer than the commit
# interval itself suggests.
wait_for_snapshot() {
  local tries="${1:-60}"
  local url="${ICEBERG_REST_URI_HOST}/v1/namespaces/${ICEBERG_NAMESPACE}/tables/${ICEBERG_TABLE}"
  info "waiting for the sink to commit at least one Iceberg snapshot ..."
  for ((i = 1; i <= tries; i++)); do
    local count
    count=$(curl -fsS "${url}" 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("metadata",{}).get("snapshots",[])))' 2>/dev/null || echo 0)
    if [[ "${count}" -gt 0 ]]; then
      info "table has ${count} snapshot(s) committed"
      return 0
    fi
    sleep 2
  done
  fail "no Iceberg snapshot appeared after $((tries * 2))s -- check 'docker compose logs kafka-connect'"
  return 1
}
