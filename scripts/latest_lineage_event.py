#!/usr/bin/env python3
"""
Runs on the HOST (not in a container) -- reads the collector's JSONL log
directly off disk via the bind-mounted ./out/openlineage volume.

Finds the most recent OpenLineage-shaped event whose iceberg_commit.tableName
contains the given substring, prints it pretty-printed (a live-demo moment),
and prints the bare sequenceNumber on the last line so callers can capture it
with `tail -n1` / command substitution.

Usage: latest_lineage_event.py <table_substring>
"""
import json
import sys
from pathlib import Path

LOG_FILE = Path(__file__).resolve().parent.parent / "out" / "openlineage" / "events.jsonl"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    table_substring = sys.argv[1]

    if not LOG_FILE.exists():
        print(f"FAIL: {LOG_FILE} does not exist yet -- has any commit happened?", file=sys.stderr)
        return 1

    match = None
    with open(LOG_FILE) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            table_name = event.get("run", {}).get("facets", {}).get("iceberg_commit", {}).get("tableName", "")
            if table_substring in table_name:
                match = event

    if match is None:
        print(f"FAIL: no lineage event found for a table matching '{table_substring}'", file=sys.stderr)
        return 1

    print(json.dumps(match, indent=2))
    seq = match["run"]["facets"]["iceberg_commit"]["sequenceNumber"]
    print(f"\nSEQUENCE_NUMBER={seq}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
