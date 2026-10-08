#!/usr/bin/env python3
"""
Runs inside the `duckdb` compose service (no docker access from here).

Checks A and B are decided here. Check C is attempted here via DuckDB's
iceberg_snapshots() table function; if this DuckDB build can't expose
first_row_id/added_rows, we write check_c_needs_spark_fallback=true to
out/status.json and scripts/verify.sh runs the Spark fallback query.
"""
import json
import os
import sys
import urllib.request

import duckdb

NAMESPACE = os.environ["ICEBERG_NAMESPACE"]
TABLE = os.environ["ICEBERG_TABLE"]
REST_URI = os.environ["ICEBERG_REST_URI"]
MINIO_ENDPOINT = os.environ["MINIO_ENDPOINT"]
MINIO_USER = os.environ["MINIO_ROOT_USER"]
MINIO_PASSWORD = os.environ["MINIO_ROOT_PASSWORD"]
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

OUT_DIR = "/work/out"


def hr(title: str) -> None:
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def fetch_table_json() -> dict:
    url = f"{REST_URI}/v1/namespaces/{NAMESPACE}/tables/{TABLE}"
    with urllib.request.urlopen(url, timeout=15) as resp:
        return json.loads(resp.read())


def main() -> int:
    results = {}

    hr("Harness tooling")
    print(f"duckdb python module version : {duckdb.__version__}")
    print(f"iceberg namespace.table       : {NAMESPACE}.{TABLE}")
    print(f"iceberg REST catalog          : {REST_URI}")

    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute("INSTALL iceberg; LOAD iceberg;")
    con.execute(
        f"""
        CREATE SECRET minio_s3 (
            TYPE S3,
            KEY_ID '{MINIO_USER}',
            SECRET '{MINIO_PASSWORD}',
            ENDPOINT '{MINIO_ENDPOINT}',
            URL_STYLE 'path',
            USE_SSL false,
            REGION '{AWS_REGION}'
        );
        """
    )

    # ------------------------------------------------------------------
    # CHECK A -- format version survived table creation?
    # Authoritative source: the REST catalog's own LoadTableResult JSON.
    # ------------------------------------------------------------------
    hr("CHECK A -- did the table survive as Iceberg format-version 3?")
    table_json = fetch_table_json()
    metadata = table_json["metadata"]
    metadata_location = table_json["metadata-location"]
    format_version = metadata.get("format-version")

    print(f"metadata-location : {metadata_location}")
    print(f"format-version    : {format_version}")

    metadata_log = metadata.get("metadata-log", [])
    print(f"metadata-log entries ({len(metadata_log)}):")
    for entry in metadata_log:
        print(f"  {entry}")

    check_a_pass = format_version == 3
    results["check_a"] = check_a_pass
    print("\n" + ("PASS" if check_a_pass else "FAIL") + f": format-version = {format_version} (required: 3)")

    table_root = metadata_location.rsplit("/metadata/", 1)[0]
    print(f"\n(table root, used by iceberg_scan()/iceberg_snapshots() below): {table_root}")

    # ------------------------------------------------------------------
    # Optional: attach the REST catalog directly for `bronze.events`-style
    # SQL. Best UX when it works; NOT required for correctness of the
    # checks below, which always have a table-function fallback that reads
    # straight off the table root in S3.
    # ------------------------------------------------------------------
    qualified_name = None
    try:
        con.execute(f"ATTACH '' AS {NAMESPACE} (TYPE ICEBERG, ENDPOINT '{REST_URI}');")
        rows = con.execute(
            f"SELECT table_name, schema_name FROM duckdb_tables() WHERE database_name = '{NAMESPACE}'"
        ).fetchall()
        print(f"\n[info] catalog ATTACH succeeded, discovered tables: {rows}")
        for tname, sname in rows:
            if tname == TABLE:
                qualified_name = (
                    f"{NAMESPACE}.{sname}.{tname}" if sname and sname != "main" else f"{NAMESPACE}.{tname}"
                )
                break
    except Exception as exc:  # noqa: BLE001 - best-effort convenience path
        print(f"\n[info] catalog ATTACH unavailable in this DuckDB build ({exc}); using iceberg_scan() fallback")

    # ------------------------------------------------------------------
    # CHECK B (make-or-break) -- are _row_id values assigned?
    # ------------------------------------------------------------------
    hr("CHECK B (make-or-break) -- are _row_id values assigned via manifest inheritance?")

    rowid_rows = None
    read_path = None
    query_used = None

    if qualified_name:
        query_used = (
            f"SELECT _row_id, _last_updated_sequence_number, event_id "
            f"FROM {qualified_name} ORDER BY _row_id LIMIT 20;"
        )
        try:
            print(f"query: {query_used}")
            rowid_rows = con.execute(query_used).fetchall()
            read_path = f"catalog attach ({qualified_name})"
        except Exception as exc:  # noqa: BLE001
            print(f"[info] catalog-attach read failed ({exc}); falling back to iceberg_scan()")

    if rowid_rows is None:
        # Point iceberg_scan() straight at the metadata.json the REST catalog
        # just handed us in Check A, instead of the bare table-root directory.
        # The latter requires DuckDB to *guess* the latest metadata version by
        # globbing (blocked by default as unsafe, and this JdbcCatalog-backed
        # REST server never writes a version-hint.text anyway).
        query_used = (
            f"SELECT _row_id, _last_updated_sequence_number, event_id "
            f"FROM iceberg_scan('{metadata_location}') ORDER BY _row_id LIMIT 20;"
        )
        try:
            print(f"query: {query_used}")
            rowid_rows = con.execute(query_used).fetchall()
            read_path = f"iceberg_scan('{metadata_location}')"
        except Exception as exc:  # noqa: BLE001
            print(f"FATAL: both the catalog-attach and iceberg_scan() read paths failed: {exc}")
            results["check_b"] = False
            results["check_b_error"] = str(exc)
            rowid_rows = []
            read_path = "NONE (both paths failed)"

    print(f"\n(read path used: {read_path})")
    print(f"{'_row_id':>12} {'_last_updated_sequence_number':>30}  event_id")
    for r in rowid_rows:
        print(f"{str(r[0]):>12} {str(r[1]):>30}  {r[2]}")

    if "check_b" not in results:
        non_null = [r for r in rowid_rows if r[0] is not None]
        if non_null:
            ids = sorted(int(r[0]) for r in non_null)
            dense_sequential = all(b - a == 1 for a, b in zip(ids, ids[1:])) if len(ids) > 1 else True
            check_b_pass = (len(non_null) == len(rowid_rows)) and dense_sequential and len(rowid_rows) > 0
            print(
                f"\nnon-null: {len(non_null)}/{len(rowid_rows)}  "
                f"dense/sequential: {dense_sequential}  min={ids[0]}  max={ids[-1]}"
            )
        else:
            check_b_pass = False
            print("\nALL _row_id VALUES ARE NULL")
        results["check_b"] = check_b_pass

    print("\n" + ("PASS" if results["check_b"] else "FAIL") + ": _row_id assignment")

    # ------------------------------------------------------------------
    # CHECK C -- inheritance at the metadata layer (best evidence)
    # PASS = first_row_id advances by added_rows each commit.
    # ------------------------------------------------------------------
    hr("CHECK C -- first_row_id inheritance across snapshots (best evidence)")
    # Read straight from the REST catalog's own metadata.json (already fetched
    # for Check A) rather than DuckDB's iceberg_snapshots() table function or
    # Spark's `snapshots` metadata view: neither of those exposes the V3
    # row-lineage fields (first-row-id, summary.added-records) as columns --
    # confirmed empirically (DuckDB build only exposes
    # timestamp_ms/manifest_list/operation; Spark's view only exposes
    # committed_at/snapshot_id/parent_id/operation/manifest_list/summary,
    # neither carrying first-row-id at all). The metadata.json itself is the
    # actual "metadata layer" the check is named for, and always has these
    # fields per the V3 spec.
    check_c_needs_fallback = False
    snapshots = sorted(metadata.get("snapshots", []), key=lambda s: s.get("sequence-number", 0))
    print(f"{'snapshot_id':>20} {'sequence_number':>16} {'first_row_id':>13} {'added_rows':>11}  operation")
    prev_first = None
    prev_added = None
    check_c_pass = True
    if not snapshots:
        check_c_pass = False
        print("(no snapshots found)")
    for snap in snapshots:
        snapshot_id = snap.get("snapshot-id")
        sequence_number = snap.get("sequence-number")
        first_row_id = snap.get("first-row-id")
        added_rows = snap.get("summary", {}).get("added-records")
        operation = snap.get("summary", {}).get("operation")
        added_rows_int = int(added_rows) if added_rows is not None else None
        print(
            f"{str(snapshot_id):>20} {str(sequence_number):>16} {str(first_row_id):>13} "
            f"{str(added_rows_int):>11}  {operation}"
        )
        if first_row_id is None or added_rows_int is None:
            check_c_pass = False
        elif prev_first is not None and prev_added is not None:
            if first_row_id != prev_first + prev_added:
                check_c_pass = False
        prev_first, prev_added = first_row_id, added_rows_int

    results["check_c_duckdb_pass"] = check_c_pass
    results["check_c_needs_spark_fallback"] = check_c_needs_fallback
    print("\n" + ("PASS" if check_c_pass else "FAIL") + ": first_row_id advances by added_rows each commit")

    # ------------------------------------------------------------------
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "status.json"), "w") as f:
        json.dump(results, f, indent=2)

    hr("DuckDB pass summary")
    print(f"Check A (format-version == 3)   : {'PASS' if results['check_a'] else 'FAIL'}")
    print(f"Check B (_row_id assigned)      : {'PASS' if results['check_b'] else 'FAIL'}")
    if check_c_needs_fallback:
        print("Check C (metadata inheritance)  : PENDING (Spark fallback)")
    else:
        print(f"Check C (metadata inheritance)  : {'PASS' if check_c_pass else 'FAIL'}")

    return 0 if (results["check_a"] and results["check_b"]) else 2


if __name__ == "__main__":
    sys.exit(main())
