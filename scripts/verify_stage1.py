#!/usr/bin/env python3
"""
Stage 01's verification: preflight/scripts/verify_duckdb.py's checks A/B/C,
unchanged, against the demo catalog.

verify_duckdb.py builds the catalog URL as {ICEBERG_REST_URI}/v1/namespaces/...,
which Lakekeeper doesn't serve (it needs the warehouse prefix in the path).
Instead of editing preflight/, this swaps in lineage_backend's catalog lookup
for its one fetch function and runs its main() as is.

Expects preflight/scripts mounted at /work/preflight-scripts.
"""
import os
import sys

sys.path.insert(0, "/work/preflight-scripts")
os.environ.setdefault("ICEBERG_REST_URI", os.environ.get("CATALOG_URI", ""))

import verify_duckdb  # noqa: E402

from lineage_backend import get_backend  # noqa: E402


def fetch_table_json() -> dict:
    location, metadata = get_backend().load_table(verify_duckdb.NAMESPACE, verify_duckdb.TABLE)
    return {"metadata-location": location, "metadata": metadata}


verify_duckdb.fetch_table_json = fetch_table_json
verify_duckdb.REST_URI = os.environ.get("CATALOG_URI", verify_duckdb.REST_URI)

if __name__ == "__main__":
    sys.exit(verify_duckdb.main())
