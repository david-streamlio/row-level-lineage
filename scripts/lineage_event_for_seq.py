#!/usr/bin/env python3
"""
Runs on the HOST (not in a container) -- reads the collector's JSONL log
directly off disk via the bind-mounted ./out/openlineage volume.

Finds the OpenLineage event for one Iceberg commit: the event whose
iceberg_commit.tableName contains the given substring and whose
sequenceNumber matches. Prints the job that made the commit and the datasets
it read (for Kafka Connect: the Kafka topic) -- Stage 04's last hop, from a
bronze row's _last_updated_sequence_number back to the stream.

Usage: lineage_event_for_seq.py <table_substring> <sequence_number>
"""
import json
import sys
from pathlib import Path

LOG_FILE = Path(__file__).resolve().parent.parent / "out" / "openlineage" / "events.jsonl"


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    table_substring, sequence_number = sys.argv[1], int(sys.argv[2])

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
            commit = event.get("run", {}).get("facets", {}).get("iceberg_commit", {})
            if table_substring in commit.get("tableName", "") and commit.get("sequenceNumber") == sequence_number:
                match = event

    if match is None:
        print(f"FAIL: no lineage event for '{table_substring}' at sequenceNumber {sequence_number}", file=sys.stderr)
        return 1

    commit = match["run"]["facets"]["iceberg_commit"]
    job = match["job"]
    inputs = ", ".join(f"{d['namespace']}/{d['name']}" for d in match.get("inputs", [])) or "(none)"
    print(f"lineage event: sequenceNumber={commit['sequenceNumber']}  {commit['operation']}  {commit['tableName']}")
    print(f"  job:   {job['namespace']}/{job['name']}")
    print(f"  input: {inputs}")
    print(f"\nJOB={job['namespace']}/{job['name']}")
    print(f"INPUTS={inputs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
