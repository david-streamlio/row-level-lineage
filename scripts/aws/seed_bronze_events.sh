#!/usr/bin/env bash
# Append synthetic events to rll_bronze.events on AWS, so AWS mode has the
# same volume as the local Stage 01 ingest. Uses preflight's own event
# generator; writes BATCHES separate commits so first-row-id continuation is
# visible in the dashboard. Not idempotent: every run appends more rows.
#
#   AWS_PROFILE=your-profile scripts/aws/seed_bronze_events.sh [count] [batches]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COUNT="${1:-300}"
BATCHES="${2:-3}"
SQL_OUT="${ROOT_DIR}/out/aws-bronze-events.sql"   # ./out is mounted at /work/out

python3 "${ROOT_DIR}/preflight/scripts/generate_events.py" "${COUNT}" | python3 -c '
import json, sys
batches = int(sys.argv[1])
events = [json.loads(line) for line in sys.stdin if line.strip()]
size = -(-len(events) // batches)
for start in range(0, len(events), size):
    values = ",\n  ".join(
        "(\x27{event_id}\x27, {customer_id}, {amount:.2f}, TIMESTAMP \x27{ts}\x27)".format(
            event_id=e["event_id"], customer_id=e["customer_id"], amount=e["amount"],
            ts=e["ts"].replace("T", " ").rstrip("Z"))
        for e in events[start:start + size])
    print(f"INSERT INTO glue.rll_bronze.events (event_id, customer_id, amount, ts) VALUES\n  {values};\n")
print("SELECT count(*) AS total_rows FROM glue.rll_bronze.events;")
' "${BATCHES}" > "${SQL_OUT}"

exec "${ROOT_DIR}/scripts/aws/seed_glue_tables.sh" /work/out/aws-bronze-events.sql
