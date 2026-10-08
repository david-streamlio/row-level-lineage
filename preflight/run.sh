#!/usr/bin/env bash
# One-shot preflight: bring the stack up, create the V3 table, register the
# sink, produce events, and print the PASS/FAIL verification summary.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

./scripts/setup.sh
./scripts/produce.sh 300
./scripts/verify.sh
