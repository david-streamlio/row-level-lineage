#!/usr/bin/env python3
"""
Prints just enough of a table's metadata.json to prove a schema change was
metadata-only: snapshot count and total-data-files (from the current
snapshot's summary) must be UNCHANGED across an ALTER TABLE ADD COLUMN /
ALTER COLUMN SET DEFAULT, while schema-count/current-schema-id changes.

Iceberg does not create a new snapshot for a schema change at all -- this
prints straight from the catalog's metadata.json (via lineage_backend,
LINEAGE_BACKEND=local|aws), the same authoritative source used by
preflight/scripts/verify_duckdb.py.

Usage: table_stats.py <namespace> <table>
"""
import sys

from lineage_backend import get_backend


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    namespace, table = sys.argv[1], sys.argv[2]

    _, metadata = get_backend().load_table(namespace, table)

    snapshots = metadata.get("snapshots", [])
    current_snapshot_id = metadata.get("current-snapshot-id")
    current_snapshot = next((s for s in snapshots if s.get("snapshot-id") == current_snapshot_id), None)
    summary = current_snapshot.get("summary", {}) if current_snapshot else {}

    schemas = metadata.get("schemas", [])
    current_schema_id = metadata.get("current-schema-id")
    current_schema = next((s for s in schemas if s.get("schema-id") == current_schema_id), {})
    field_names = [f["name"] for f in current_schema.get("fields", [])]

    print(f"{namespace}.{table}")
    print(f"  snapshot count        : {len(snapshots)}")
    print(f"  total-data-files      : {summary.get('total-data-files', 'n/a')}")
    print(f"  total-records         : {summary.get('total-records', 'n/a')}")
    print(f"  schema count          : {len(schemas)}")
    print(f"  current-schema-id     : {current_schema_id}")
    print(f"  current columns       : {field_names}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
