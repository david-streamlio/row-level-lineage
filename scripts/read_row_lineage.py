#!/usr/bin/env python3
"""
Generic row-lineage reader, shared by demo Stages 02/04/05.

Reads _row_id / _last_updated_sequence_number for a table straight from the
catalog's own metadata.json (authoritative source of truth -- see
preflight/scripts/verify_duckdb.py's Check C comment for why neither
DuckDB's iceberg_snapshots() nor Spark's .snapshots view are used instead)
plus DuckDB's iceberg_scan() pointed at that exact metadata.json path.
Catalog + S3 access come from lineage_backend (LINEAGE_BACKEND=local|aws).

Usage:
  read_row_lineage.py <namespace> <table> <id_column> [where_column] [where_value]

Example:
  read_row_lineage.py silver customers customer_id customer_id 9001
"""
import sys

from lineage_backend import get_backend


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2

    namespace, table, id_column = sys.argv[1], sys.argv[2], sys.argv[3]
    where_column = sys.argv[4] if len(sys.argv) > 4 else None
    where_value = sys.argv[5] if len(sys.argv) > 5 else None

    backend = get_backend()
    metadata_location, metadata = backend.load_table(namespace, table)
    format_version = metadata.get("format-version")

    con = backend.duckdb_connect()

    where_clause = ""
    if where_column and where_value is not None:
        try:
            float(where_value)
            where_clause = f"WHERE {where_column} = {where_value}"
        except ValueError:
            where_clause = f"WHERE {where_column} = '{where_value}'"

    query = (
        f"SELECT _row_id, _last_updated_sequence_number, {id_column} "
        f"FROM iceberg_scan('{metadata_location}') {where_clause} "
        f"ORDER BY {id_column};"
    )

    print(f"\n{namespace}.{table}  (format-version={format_version})")
    print(f"query: {query}\n")
    rows = con.execute(query).fetchall()

    print(f"{'_row_id':>12}  {'_last_updated_sequence_number':>30}  {id_column}")
    print("-" * 70)
    for r in rows:
        print(f"{str(r[0]):>12}  {str(r[1]):>30}  {r[2]}")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
