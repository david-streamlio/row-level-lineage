#!/usr/bin/env python3
"""
Interactive DuckDB SQL over every table in the catalog -- the live-demo
query window for row lineage. Run it via demo/sql.sh.

Every catalog table is a view under its own name (bronze.events,
silver.customers, ...) with _row_id and _last_updated_sequence_number as the
first two columns on V3 tables. The views are re-pointed at each table's
CURRENT metadata.json before every statement, so a query typed right after a
Kafka Connect commit or a Spark MERGE sees that commit -- no restart.

DuckDB because it starts in ~2 s; Spark 4.0 + Iceberg 1.11 can read the
row-lineage columns too, Flink can't.
Catalog + S3 access come from lineage_backend (LINEAGE_BACKEND=local|aws).

Usage:
  lineage_sql.py                      interactive prompt
  lineage_sql.py "SELECT ... ;"       run one statement and exit
  lineage_sql.py --watch SECONDS FILE re-run the statement in FILE every SECONDS
                                      (re-read each time; a first line "-- title"
                                      is shown as a heading). Used by
                                      demo/record-demo.sh's SQL window.

At the prompt: statements end with ';'. ".tables" lists the tables,
".quit" (or Ctrl-D) exits.
"""
import os
import shutil
import sys
import time

try:
    import readline  # noqa: F401 -- arrow keys + history for input()
except ImportError:
    pass

from lineage_backend import get_backend

ROW_LINEAGE = "_row_id, _last_updated_sequence_number, "
MAX_ROWS = 40


def refresh_views(backend, con) -> list[tuple[str, str, int, int]]:
    """(Re)create one view per catalog table; return (namespace, table, format-version, snapshots)."""
    tables = []
    for namespace, table in backend.list_tables():
        metadata_location, metadata = backend.load_table(namespace, table)
        version = metadata.get("format-version")
        lineage = ROW_LINEAGE if version and version >= 3 else ""
        con.execute(f'CREATE SCHEMA IF NOT EXISTS "{namespace}"')
        con.execute(
            f'CREATE OR REPLACE VIEW "{namespace}"."{table}" AS '
            f"SELECT {lineage}* FROM iceberg_scan('{metadata_location}')"
        )
        tables.append((namespace, table, version, len(metadata.get("snapshots", []))))
    return tables


def run(backend, con, statement: str) -> None:
    refresh_views(backend, con)
    try:
        relation = con.sql(statement)
    except Exception as exc:  # show the error, keep the prompt alive
        print(f"Error: {exc}")
        return
    if relation is not None:
        relation.show(max_rows=MAX_ROWS, max_width=200)


def show_tables(backend, con) -> None:
    print(f"{'table':<45} {'format':>6} {'snapshots':>9}")
    for namespace, table, version, snapshots in refresh_views(backend, con):
        print(f"{namespace + '.' + table:<45} {'v' + str(version):>6} {snapshots:>9}")


def watch(backend, con, seconds: float, path: str) -> int:
    """Clear the screen and re-run FILE's statement every SECONDS, forever."""
    while True:
        try:
            with open(path) as f:
                statement = f.read().strip()
        except OSError:
            statement = ""
        title = statement.splitlines()[0][2:].strip() if statement.startswith("--") else ""
        print("\033[H\033[2J", end="")
        # pinned-style title bar, like the recorder's other windows (header.sh)
        cols = shutil.get_terminal_size((80, 24)).columns
        bar = f"Row lineage SQL (DuckDB, every {seconds:g} s)  {time.strftime('%H:%M:%S')}"
        print(f"\033[1;38;5;231;48;5;55m {bar:<{cols - 1}.{cols - 1}}\033[0m")
        print(f"\n{title}\n" if title else "")
        if not statement:
            print(f"waiting for a query in {os.path.basename(path)} ...")
        else:
            try:
                refresh_views(backend, con)
                relation = con.sql(statement)
                if relation is not None:
                    relation.show(max_rows=MAX_ROWS, max_width=200)
            except Exception:  # catalog still starting, or the table not created/committed yet
                if hasattr(backend, "_base"):
                    backend._base = None  # re-resolve the catalog prefix next time
                # no error text on screen: this window is recorded for an audience
                print("\033[2mwaiting for the table and its first commit ...\033[0m")
        sys.stdout.flush()
        time.sleep(seconds)


def main() -> int:
    backend = get_backend()
    con = backend.duckdb_connect()

    if len(sys.argv) == 4 and sys.argv[1] == "--watch":
        return watch(backend, con, float(sys.argv[2]), sys.argv[3])

    if len(sys.argv) > 1:
        run(backend, con, " ".join(sys.argv[1:]))
        return 0

    print("Row-lineage SQL (DuckDB). Views always read the current snapshot.")
    show_tables(backend, con)
    print('End statements with ";". .tables lists tables, .quit exits.\n')
    buffer = []
    while True:
        try:
            line = input("lineage> " if not buffer else "     ...> ")
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        stripped = line.strip()
        if not buffer and stripped in (".quit", ".exit", "quit", "exit"):
            return 0
        if not buffer and stripped == ".tables":
            show_tables(backend, con)
            continue
        buffer.append(line)
        if stripped.endswith(";"):
            run(backend, con, "\n".join(buffer))
            buffer = []


if __name__ == "__main__":
    sys.exit(main())
