#!/usr/bin/env bash
# Dispatcher for the staged conference demo. Run any stage in isolation,
# deterministically, or reset/tear down the whole stack.
#
#   demo/run-stage.sh 1        # Ingest / row identity
#   demo/run-stage.sh 2        # Mutation with deletion vectors
#   demo/run-stage.sh 3        # Schema evolution (metadata-only)
#   demo/run-stage.sh 4        # Composable Lineage (correlation join)
#   demo/run-stage.sh 5        # Failure mode (closer)
#   demo/run-stage.sh reset    # Stop and remove all containers/volumes
#   demo/run-stage.sh teardown # Alias for reset
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib.sh"

STAGE="${1:-}"
shift || true

case "${STAGE}" in
  1) exec bash "${SCRIPT_DIR}/01-ingest/run.sh" "$@" ;;
  2) exec bash "${SCRIPT_DIR}/02-mutation/run.sh" "$@" ;;
  3) exec bash "${SCRIPT_DIR}/03-schema-evolution/run.sh" "$@" ;;
  4) exec bash "${SCRIPT_DIR}/04-composable-lineage/run.sh" "$@" ;;
  5) exec bash "${SCRIPT_DIR}/05-failure-mode/run.sh" "$@" ;;
  reset|teardown)
    banner "Tearing down the demo stack (containers, networks, volumes)"
    dc down -v --remove-orphans
    rm -rf "${ROOT_DIR}/out" "${ROOT_DIR}/preflight/out"
    mkdir -p "${ROOT_DIR}/out/openlineage" "${ROOT_DIR}/preflight/out"
    pass "reset complete -- next 'run-stage.sh 1' starts from a clean state"
    ;;
  *)
    echo "Usage: $0 <1|2|3|4|5|reset|teardown>"
    echo
    echo "  1  Ingest / row identity"
    echo "  2  Mutation with deletion vectors"
    echo "  3  Schema evolution (metadata-only)"
    echo "  4  Composable Lineage (correlation join)"
    echo "  5  Failure mode (closer)"
    echo "  reset / teardown  Stop everything and wipe state"
    exit 1
    ;;
esac
