#!/usr/bin/env bash
# Shared helpers sourced by every demo/ stage script. Mirrors
# preflight/scripts/lib.sh but rooted at the repo root (root docker-compose.yml
# + root .env), since `include:` resolves compose variables against the
# top-level .env, not preflight/.env.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

# LINEAGE_OFFLINE set on the command line wins over .env
_lineage_offline_cli="${LINEAGE_OFFLINE:-}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
[[ -n "${_lineage_offline_cli}" ]] && LINEAGE_OFFLINE="${_lineage_offline_cli}"

BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")

banner() { echo; echo "${BOLD}${CYAN}=======================================================================${RESET}"; echo "${BOLD}${CYAN}  $*${RESET}"; echo "${BOLD}${CYAN}=======================================================================${RESET}"; }
point()  { echo; echo "${BOLD}POINT:${RESET} $*"; echo; }
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

# Offline mode, for working without internet. LINEAGE_OFFLINE in .env:
# auto (default) probes Docker Hub once (3 s), 1 forces offline, 0 online.
# Offline, `dc build` is skipped and `--build` is dropped from `dc up`, so the
# stages run on the images already built (see scripts/offline-prep.sh).
# Bind-mounted code (scripts/, sql/, dashboard/) still changes live; edits to
# the reporter or the collector need an image rebuild once back online.
# Resolved once and exported, so nested scripts don't probe again.
if [[ -z "${LINEAGE_OFFLINE_RESOLVED:-}" ]]; then
  case "${LINEAGE_OFFLINE:-auto}" in
    1|true|yes) LINEAGE_OFFLINE_RESOLVED=1 ;;
    0|false|no) LINEAGE_OFFLINE_RESOLVED=0 ;;
    *)
      # any HTTP answer (Docker Hub says 401) means online
      if curl -s -o /dev/null --max-time 3 https://registry-1.docker.io/v2/; then
        LINEAGE_OFFLINE_RESOLVED=0
      else
        LINEAGE_OFFLINE_RESOLVED=1
      fi ;;
  esac
  export LINEAGE_OFFLINE_RESOLVED
  if [[ "${LINEAGE_OFFLINE_RESOLVED}" == 1 ]]; then
    echo "${YELLOW}--${RESET} offline mode: image builds skipped, using the images already built"
  fi
fi

dc() {
  if [[ "${LINEAGE_OFFLINE_RESOLVED}" == 1 ]]; then
    # find the compose subcommand (skipping global flags and their values)
    local arg subcommand="" skip=0 args=()
    for arg in "$@"; do
      if [[ "${skip}" == 1 ]]; then skip=0
      elif [[ -z "${subcommand}" && "${arg}" == --profile ]]; then skip=1
      elif [[ -z "${subcommand}" && "${arg}" != -* ]]; then subcommand="${arg}"
      fi
      [[ "${arg}" == --build ]] || args+=("${arg}")
    done
    if [[ "${subcommand}" == build ]]; then
      info "offline: skipped 'docker compose $*'"
      return 0
    fi
    set -- "${args[@]}"
  fi
  docker compose --project-directory "${ROOT_DIR}" "$@"
}

# catalog_table_url <namespace> <table>: the demo catalog's LoadTable URL as
# seen from the host. Lakekeeper puts the warehouse id in the path
# (/v1/{prefix}/...), read from /v1/config; the reference server has none.
# catalog_curl <curl args...>: curl against the demo catalog, with an OAuth
# token when CATALOG_CREDENTIAL is set (Apache Polaris)
catalog_curl() {
  if [[ -n "${CATALOG_CREDENTIAL:-}" ]]; then
    local token
    token=$(curl -fsS -X POST "${CATALOG_URI_HOST}/v1/oauth/tokens" \
      -d "grant_type=client_credentials&client_id=${CATALOG_CREDENTIAL%%:*}&client_secret=${CATALOG_CREDENTIAL#*:}&scope=${CATALOG_SCOPE}" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' 2>/dev/null) || return 1
    curl -fsS -H "Authorization: Bearer ${token}" "$@"
  else
    curl -fsS "$@"
  fi
}

catalog_table_url() {
  local prefix
  prefix=$(catalog_curl "${CATALOG_URI_HOST}/v1/config?warehouse=${CATALOG_WAREHOUSE}" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("overrides",{}).get("prefix") or d.get("defaults",{}).get("prefix") or "")' 2>/dev/null || true)
  echo "${CATALOG_URI_HOST}/v1${prefix:+/${prefix}}/namespaces/$1/tables/$2"
}

# wait_for_snapshot <namespace> <table> [tries]
# See preflight/scripts/lib.sh for why this polls instead of sleeping.
wait_for_snapshot() {
  local namespace="$1" table="$2" tries="${3:-60}"
  local url
  url=$(catalog_table_url "${namespace}" "${table}")
  info "waiting for a commit against ${namespace}.${table} ..."
  local prev_count
  prev_count="${4:-0}"
  for ((i = 1; i <= tries; i++)); do
    local count
    count=$(catalog_curl "${url}" 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("metadata",{}).get("snapshots",[])))' 2>/dev/null || echo 0)
    if [[ "${count}" -gt "${prev_count}" ]]; then
      info "${namespace}.${table} now has ${count} snapshot(s) committed"
      return 0
    fi
    sleep 2
  done
  fail "no new snapshot on ${namespace}.${table} after $((tries * 2))s"
  return 1
}

snapshot_count() {
  local namespace="$1" table="$2"
  catalog_curl "$(catalog_table_url "${namespace}" "${table}")" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("metadata",{}).get("snapshots",[])))' 2>/dev/null || echo 0
}

check_iceberg_version() {
  info "Iceberg version pinned for this demo: ${ICEBERG_VERSION} (minimum required: ${ICEBERG_MIN_VERSION})"
}
