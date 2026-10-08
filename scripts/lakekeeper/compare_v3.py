#!/usr/bin/env python3
"""
V3 round-trip check: Lakekeeper vs the reference Iceberg REST catalog.

Lakekeeper rewrites table metadata with its own (Rust) implementation, not
the Iceberg Java library, so V3 fields written by Iceberg 1.11 clients could
in principle not survive. v3_roundtrip.sh runs identical Spark operations
against both catalogs (rt.customers) and has Kafka Connect ingest into
Lakekeeper (rt.events); this script then checks:

  1. rt.customers: the metadata.json each catalog wrote, normalized (no
     uuids, paths, timestamps, snapshot ids), must match on every V3 field:
     format-version, next-row-id, per-snapshot first-row-id / added-rows /
     sequence numbers, schemas incl. initial-default / write-default and the
     variant type. Other differences are listed as info.
  2. rt.customers: DuckDB reads identical rows, _row_id and
     _last_updated_sequence_number included.
  3. Lakekeeper's REST response (what Java clients read) == its metadata.json
     on S3 (what DuckDB reads).
  4. rt.events (Kafka Connect -> Lakekeeper): first-row-id chains across
     commits, next-row-id == rows added, _row_id dense 0..N-1.

Exit 0 only if every check passes. Runs in the duckdb-demo image.
"""
import gzip
import json
import os
import sys
import urllib.parse
import urllib.request

import boto3
import duckdb

REF_URI = os.environ["ICEBERG_REST_URI"]
# the catalog under test (Lakekeeper by default; v3_roundtrip.sh --candidate)
LK_URI = os.environ.get("CANDIDATE_URI") or "http://lakekeeper:8181/catalog"
LK_WAREHOUSE = os.environ.get("CANDIDATE_WAREHOUSE") or "demo"
LK_CREDENTIAL = os.environ.get("CANDIDATE_CREDENTIAL", "")   # "client_id:secret" (Polaris)
LK_SCOPE = os.environ.get("CANDIDATE_SCOPE", "")
LK_LABEL = os.environ.get("CANDIDATE_LABEL") or "Lakekeeper"
_token = None

S3 = boto3.client(
    "s3",
    endpoint_url="http://" + os.environ["MINIO_ENDPOINT"],
    aws_access_key_id=os.environ["MINIO_ROOT_USER"],
    aws_secret_access_key=os.environ["MINIO_ROOT_PASSWORD"],
    region_name=os.environ.get("AWS_REGION", "us-east-1"),
)

failures = []


def check(ok: bool, label: str, detail: str = "") -> None:
    print(f"{'PASS' if ok else 'FAIL'}: {label}{(' -- ' + detail) if detail and not ok else ''}")
    if not ok:
        failures.append(label)


def get_json(url: str) -> dict:
    global _token
    request = urllib.request.Request(url)
    if LK_CREDENTIAL and url.startswith(LK_URI):
        if _token is None:
            client_id, secret = LK_CREDENTIAL.split(":", 1)
            body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": client_id,
                                           "client_secret": secret, "scope": LK_SCOPE}).encode()
            with urllib.request.urlopen(f"{LK_URI}/v1/oauth/tokens", data=body, timeout=15) as resp:
                _token = json.loads(resp.read())["access_token"]
        request.add_header("Authorization", f"Bearer {_token}")
    with urllib.request.urlopen(request, timeout=15) as resp:
        return json.loads(resp.read())


def lk_prefix() -> str:
    config = get_json(f"{LK_URI}/v1/config?warehouse={LK_WAREHOUSE}")
    return config.get("overrides", {}).get("prefix") or config["defaults"]["prefix"]


def load(base: str, namespace: str, table: str) -> tuple[str, dict]:
    body = get_json(f"{base}/namespaces/{namespace}/tables/{table}")
    return body["metadata-location"], body["metadata"]


def read_s3_json(location: str) -> dict:
    bucket, key = location.split("://", 1)[1].split("/", 1)
    raw = S3.get_object(Bucket=bucket, Key=key)["Body"].read()
    # Lakekeeper writes gzip-compressed metadata (*.gz.metadata.json)
    return json.loads(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)


VOLATILE_SUMMARY = ("size", "iceberg-version", "engine", "app-id", "spark")


def normalize(m: dict) -> dict:
    """Keep what must survive a round trip; drop ids, paths and timestamps."""
    snapshots = sorted(m.get("snapshots", []), key=lambda s: s["sequence-number"])
    current = m.get("current-snapshot-id")
    return {
        "format-version": m.get("format-version"),
        "next-row-id": m.get("next-row-id"),
        "last-sequence-number": m.get("last-sequence-number"),
        "last-column-id": m.get("last-column-id"),
        "current-schema-id": m.get("current-schema-id"),
        "schemas": [
            {"schema-id": s.get("schema-id"), "fields": s.get("fields")}
            for s in sorted(m.get("schemas", []), key=lambda s: s.get("schema-id", 0))
        ],
        "snapshots": [
            {
                "sequence-number": s.get("sequence-number"),
                "first-row-id": s.get("first-row-id"),
                "added-rows": s.get("added-rows"),
                "schema-id": s.get("schema-id"),
                "summary": {
                    k: v for k, v in s.get("summary", {}).items()
                    if not any(word in k for word in VOLATILE_SUMMARY)
                },
            }
            for s in snapshots
        ],
        "current-snapshot-sequence": next(
            (s["sequence-number"] for s in snapshots if s.get("snapshot-id") == current), None
        ),
        "properties": m.get("properties", {}),
        "partition-specs": m.get("partition-specs"),
        "sort-orders": m.get("sort-orders"),
    }


V3_KEYS = ("format-version", "next-row-id", "last-sequence-number", "last-column-id",
           "current-schema-id", "schemas", "snapshots", "current-snapshot-sequence")


def diff(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            yield from diff(a.get(k), b.get(k), f"{path}.{k}" if path else k)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            yield from diff(x, y, f"{path}[{i}]")
    elif a != b:
        yield path, a, b


def duckdb_rows(con, location: str, columns: str, order: str):
    return con.execute(f"SELECT {columns} FROM iceberg_scan('{location}') ORDER BY {order}").fetchall()


def main() -> int:
    ref = f"{REF_URI}/v1"
    lk = f"{LK_URI}/v1/{lk_prefix()}"

    con = duckdb.connect()
    con.execute("LOAD httpfs; LOAD iceberg;")
    con.execute(
        f"""CREATE SECRET minio (TYPE S3, KEY_ID '{os.environ["MINIO_ROOT_USER"]}',
            SECRET '{os.environ["MINIO_ROOT_PASSWORD"]}', ENDPOINT '{os.environ["MINIO_ENDPOINT"]}',
            URL_STYLE 'path', USE_SSL false, REGION '{os.environ.get("AWS_REGION", "us-east-1")}')"""
    )

    print("=== 1. rt.customers: metadata.json written by each catalog (normalized)")
    ref_loc, _ = load(ref, "rt", "customers")
    lk_loc, lk_rest = load(lk, "rt", "customers")
    ref_file, lk_file = normalize(read_s3_json(ref_loc)), normalize(read_s3_json(lk_loc))
    print(f"reference: {ref_loc}\n{LK_LABEL}: {lk_loc}")
    print(f"format-version {lk_file['format-version']}, next-row-id {lk_file['next-row-id']}, "
          f"{len(lk_file['snapshots'])} snapshots, {len(lk_file['schemas'])} schemas")
    for key in V3_KEYS:
        diffs = list(diff(ref_file[key], lk_file[key], key))
        check(not diffs, f"{key} identical", "; ".join(f"{p}: ref={a!r} lk={b!r}" for p, a, b in diffs[:5]))
    for key in ("properties", "partition-specs", "sort-orders"):
        for p, a, b in diff(ref_file[key], lk_file[key], key):
            print(f"info: {p}: reference={a!r} {LK_LABEL}={b!r}")
    channel = next(f for f in lk_file["schemas"][-1]["fields"] if f["name"] == "channel")
    variant = next(f for f in lk_file["schemas"][-1]["fields"] if f["name"] == "raw_payload")
    print(f"lakekeeper channel field: {json.dumps(channel)}")
    print(f"lakekeeper raw_payload field: {json.dumps(variant)}")
    check(channel.get("initial-default") == "web" and channel.get("write-default") == "mobile",
          "channel keeps initial-default 'web' and write-default 'mobile'")
    check(variant.get("type") == "variant", "raw_payload keeps type variant")

    print("\n=== 2. rt.customers: rows as DuckDB reads them")
    cols = ("_row_id, _last_updated_sequence_number, customer_id, total_amount, "
            "last_event_id, CAST(updated_ts AS VARCHAR), channel")
    ref_rows = duckdb_rows(con, ref_loc, cols, "customer_id")
    lk_rows = duckdb_rows(con, lk_loc, cols, "customer_id")
    print(f"{'_row_id':>8} {'seq':>4} customer amount  event channel")
    for r in lk_rows:
        print(f"{r[0]:>8} {r[1]:>4} {r[2]:>8} {r[3]:>6} {r[4]:>6} {r[6]}")
    check(ref_rows == lk_rows, "rows identical incl. _row_id / _last_updated_sequence_number",
          f"ref={ref_rows} lk={lk_rows}")
    try:
        payload = con.execute(f"SELECT CAST(raw_payload AS VARCHAR) FROM iceberg_scan('{lk_loc}') "
                              "WHERE customer_id = 5").fetchone()[0]
        print(f"info: DuckDB reads raw_payload for customer 5 as {payload}")
    except Exception as exc:  # DuckDB's VARIANT read support is not under test
        print(f"info: DuckDB can't read the VARIANT column ({str(exc).splitlines()[0][:120]})")

    print("\n=== 3. Lakekeeper REST response == its metadata.json on S3")
    rest_diffs = list(diff(normalize(lk_rest), lk_file))
    check(not rest_diffs, "REST metadata matches the file",
          "; ".join(f"{p}: rest={a!r} file={b!r}" for p, a, b in rest_diffs[:5]))

    print("\n=== 4. rt.events: Kafka Connect -> Lakekeeper")
    ev_loc, ev_rest = load(lk, "rt", "events")
    ev = read_s3_json(ev_loc)
    snaps = sorted(ev.get("snapshots", []), key=lambda s: s["sequence-number"])
    print(f"format-version {ev.get('format-version')}, {len(snaps)} snapshots, next-row-id {ev.get('next-row-id')}")
    for s in snaps:
        print(f"  seq {s['sequence-number']}: first-row-id {s.get('first-row-id')}, added-rows {s.get('added-rows')}, "
              f"operation {s['summary'].get('operation')}")
    check(ev.get("format-version") == 3, "format-version 3")
    check(len(snaps) >= 2, "at least 2 Kafka Connect commits", f"{len(snaps)} snapshots")
    expected = 0
    chain_ok = True
    for s in snaps:
        chain_ok &= s.get("first-row-id") == expected
        expected += s.get("added-rows") or 0
    check(chain_ok, "first-row-id continues from the previous commit")
    check(ev.get("next-row-id") == expected, "next-row-id == rows added", f"{ev.get('next-row-id')} vs {expected}")
    count, distinct, lo, hi, nulls = con.execute(
        f"SELECT count(*), count(DISTINCT _row_id), min(_row_id), max(_row_id), "
        f"count(*) - count(_row_id) FROM iceberg_scan('{ev_loc}')").fetchone()
    print(f"  {count} rows, _row_id {lo}..{hi}, {distinct} distinct, {nulls} null")
    check(count == expected and distinct == count and lo == 0 and hi == count - 1 and nulls == 0,
          "_row_id dense 0..N-1, no nulls")
    check(not list(diff(normalize(ev_rest), normalize(ev))), "REST metadata matches the file (rt.events)")

    print(f"\n{'ALL CHECKS PASS' if not failures else str(len(failures)) + ' CHECK(S) FAILED: ' + ', '.join(failures)}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
