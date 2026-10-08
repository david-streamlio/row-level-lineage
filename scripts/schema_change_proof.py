#!/usr/bin/env python3
"""
Stage 03's proof that schema changes are metadata-only WHILE Kafka Connect
keeps ingesting. Snapshot and file counts do move here (every Connect commit
is a snapshot), so instead of "counts unchanged" this lists every snapshot
committed since a baseline and checks:

  - every one is an append, by Kafka Connect or by Stage 03's own Spark
    INSERTs -- none comes from a schema change (Iceberg never creates a
    snapshot for one)
  - no data file was deleted or rewritten
  - the schema count went up by the expected number of changes

Reads the catalog's metadata via lineage_backend.

Usage: schema_change_proof.py <namespace> <table> <baseline_sequence_number> <baseline_schema_count> [expected_schema_changes]
       schema_change_proof.py <namespace> <table> --baseline   (prints "<sequence> <schemas>")
"""
import sys

from lineage_backend import get_backend


def writer(summary: dict) -> str:
    if "kafka.connect.commit-id" in summary or "kafka.connect.task-id" in summary:
        return "Kafka Connect"
    return (summary.get("engine-name") or "?").capitalize()


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    namespace, table = sys.argv[1], sys.argv[2]
    _, metadata = get_backend().load_table(namespace, table)
    schema_count = len(metadata.get("schemas", []))
    if sys.argv[3] == "--baseline":
        print(f"{metadata.get('last-sequence-number', 0)} {schema_count}")
        return 0

    since, schemas_before = int(sys.argv[3]), int(sys.argv[4])
    expected = int(sys.argv[5]) if len(sys.argv) > 5 else None
    new = sorted((s for s in metadata.get("snapshots", []) if s["sequence-number"] > since),
                 key=lambda s: s["sequence-number"])

    print(f"{namespace}.{table}: snapshots committed after sequence number {since}")
    print(f"  {'seq':>4}  {'writer':<13} {'operation':<9} {'added rows':>10} {'added files':>11} {'deleted files':>13}")
    for s in new:
        summary = s.get("summary", {})
        print(f"  {s['sequence-number']:>4}  {writer(summary):<13} {summary.get('operation', '?'):<9} "
              f"{summary.get('added-records', '0'):>10} {summary.get('added-data-files', '0'):>11} "
              f"{summary.get('deleted-data-files', '0'):>13}")
    by_writer = {}
    for s in new:
        by_writer[writer(s.get("summary", {}))] = by_writer.get(writer(s.get("summary", {})), 0) + 1
    print(f"  schemas: {schemas_before} -> {schema_count}; snapshots by writer: "
          + (", ".join(f"{w} {n}" for w, n in sorted(by_writer.items())) or "none"))

    ok = True
    not_appends = [s for s in new if s.get("summary", {}).get("operation") != "append"]
    deleted = [s for s in new if int(s.get("summary", {}).get("deleted-data-files", 0)) > 0]
    unknown = [s for s in new if writer(s.get("summary", {})) not in ("Kafka Connect", "Spark")]
    for label, bad in (("every new snapshot is an append", not_appends),
                       ("no data file deleted or rewritten", deleted),
                       ("every new snapshot is a Kafka Connect or Spark write", unknown)):
        print(f"{'PASS' if not bad else 'FAIL'}: {label}")
        ok &= not bad
    if expected is not None:
        grew = schema_count - schemas_before == expected
        print(f"{'PASS' if grew else 'FAIL'}: schema count +{expected} with no snapshot of its own")
        ok &= grew
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
