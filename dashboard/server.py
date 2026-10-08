#!/usr/bin/env python3
"""
Read-only JSON API + static page for the live demo dashboard.

Every read goes through scripts/lineage_backend.py, the same adapter the
stage scripts use, so the dashboard shows exactly what the terminal shows
and works against either backend (LINEAGE_BACKEND=local|aws).

  GET /api/backend                                  active backend, versions
  GET /api/events?since=N                           lineage events from the collector's JSONL
  GET /api/pipeline?limit=N                         Kafka topic -> Connect -> Iceberg, with live data
  GET /api/catalog                                  every table in the catalog
  GET /api/tables/{ns}/{t}/stats                    snapshots, schemas, file/record counts
  GET /api/tables/{ns}/{t}/data?limit=&offset=&seq= all columns, paged, with row lineage columns
  GET /api/tables/{ns}/{t}/rows?col=&val=&id_col=   _row_id/_last_updated_sequence_number rows
  GET /api/tables/{ns}/{t}/identity/{key}?key_col=  one key's _row_id at every snapshot

The browser polls these every couple of seconds. Nothing here writes to the
catalog, the warehouse, or the event log.
"""
import http.server
import json
import os
import re
import socketserver
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.environ.get("LINEAGE_SCRIPTS_DIR", "/app/scripts"))
import duckdb  # noqa: E402
from lineage_backend import TableNotFound, get_backend  # noqa: E402

STATIC_DIR = Path(__file__).resolve().parent / "static"
EVENTS_FILE = Path(os.environ.get("EVENTS_FILE", "/data/openlineage/events.jsonl"))
NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")
ROW_LINEAGE_COLUMNS = ("_row_id", "_last_updated_sequence_number")
MAX_ROWS = 200

BACKEND = get_backend()

# Local and AWS commits share one events.jsonl. Show only this backend's
# catalog ("lake" = spark-demo's local REST catalog, "glue" = the AWS seed's
# catalog): a sequenceNumber from one catalog's table must never be joined
# against the other catalog's table of the same name.
EVENT_CATALOG = os.environ.get("LINEAGE_EVENT_CATALOG") or ("glue" if BACKEND.name == "aws" else "lake")

# Kafka + Kafka Connect exist only in the local stack. On AWS the tables are
# written by scripts/aws/seed_glue_tables.sh, so the pipeline view skips them.
KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP") if BACKEND.name == "local" else None
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "events")
KAFKA_CONNECT_URL = os.environ.get("KAFKA_CONNECT_URL") if BACKEND.name == "local" else None
KAFKA_CONNECTOR = os.environ.get("KAFKA_CONNECTOR", "iceberg-sink")
PIPELINE_TABLE = ("bronze", "events")
KAFKA_TTL_S = 2.0
_kafka_cache: dict = {}
_kafka_lock = threading.Lock()

# Several panels poll the same table at once; within TABLE_TTL_S they share
# one catalog round-trip (and concurrent callers wait for the in-flight one
# rather than each hitting the catalog). Bounded staleness, well under the
# browser's poll interval.
TABLE_TTL_S = 1.0
_table_cache: dict = {}
_table_locks: dict = {}
_table_locks_guard = threading.Lock()

# Identity history is a pure function of (metadata.json, key column, key):
# a new commit always writes a new metadata.json, so caching on its
# location can never serve stale data.
_identity_cache: dict = {}
_identity_lock = threading.Lock()


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def _load_table(namespace: str, table: str) -> tuple[str, dict]:
    key = (namespace, table)
    with _table_locks_guard:
        lock = _table_locks.setdefault(key, threading.Lock())
    with lock:
        cached = _table_cache.get(key)
        if cached and cached[0] > time.monotonic():
            return cached[1]
        result = BACKEND.load_table(namespace, table)
        _table_cache[key] = (time.monotonic() + TABLE_TTL_S, result)
        return result


def _check_name(value: str, what: str) -> str:
    if not NAME_RE.match(value):
        raise ApiError(400, f"invalid {what}: {value!r}")
    return value


def _current_schema(metadata: dict) -> dict:
    schema_id = metadata.get("current-schema-id")
    return next((s for s in metadata.get("schemas", []) if s.get("schema-id") == schema_id), {})


def _check_column(metadata: dict, column: str) -> str:
    _check_name(column, "column")
    fields = {f["name"] for f in _current_schema(metadata).get("fields", [])}
    if column not in fields and column not in ROW_LINEAGE_COLUMNS:
        raise ApiError(400, f"unknown column {column!r} (have: {sorted(fields)})")
    return column


def _snapshots_by_sequence(metadata: dict) -> list:
    return sorted(metadata.get("snapshots", []), key=lambda s: s.get("sequence-number", 0))


def _jsonable(value):
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)  # Decimal, datetime, UUID, VARIANT, ...


# --------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------

def api_backend(_query) -> dict:
    info = {
        "backend": BACKEND.name,
        "iceberg_version": os.environ.get("ICEBERG_VERSION"),
        "warehouse": os.environ.get("CATALOG_WAREHOUSE"),
        "eventCatalog": EVENT_CATALOG,
    }
    if BACKEND.name == "local":
        info["catalog"] = os.environ.get("CATALOG_URI")
        info["storage"] = os.environ.get("MINIO_ENDPOINT")
    else:
        info["catalog"] = "AWS Glue Data Catalog"
        info["region"] = BACKEND.region
    return info


def api_events(query) -> dict:
    try:
        since = int(query.get("since", ["0"])[0])
    except ValueError:
        raise ApiError(400, "since must be an integer")
    events = []
    total = 0
    if EVENTS_FILE.exists():
        with open(EVENTS_FILE) as f:
            for index, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                total = index + 1
                if index < since:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue  # a line the collector is mid-way through writing
                commit = event.get("run", {}).get("facets", {}).get("iceberg_commit", {})
                if not str(commit.get("tableName", "")).startswith(EVENT_CATALOG + "."):
                    continue
                events.append({
                    "index": index,
                    "eventType": event.get("eventType"),
                    "eventTime": event.get("eventTime"),
                    "job": event.get("job", {}).get("name"),
                    "runId": event.get("run", {}).get("runId"),
                    "table": commit.get("tableName"),
                    "snapshotId": str(commit.get("snapshotId")) if commit.get("snapshotId") is not None else None,
                    "sequenceNumber": commit.get("sequenceNumber"),
                    "operation": commit.get("operation"),
                    # Pretty-printed here, not in the browser: JSON.parse rounds
                    # 19-digit snapshot ids, which would put a wrong id on screen.
                    "rawPretty": json.dumps(event, indent=2),
                })
    return {"events": events, "next": total}


def api_stats(namespace: str, table: str, _query) -> dict:
    metadata_location, metadata = _load_table(namespace, table)
    schemas = metadata.get("schemas", [])
    current_id = metadata.get("current-snapshot-id")
    snapshots = []
    current_summary = {}
    for s in _snapshots_by_sequence(metadata):
        summary = s.get("summary", {})
        if s.get("snapshot-id") == current_id:
            current_summary = summary
        snapshots.append({
            # snapshot ids exceed JS's safe integer range -- send as strings
            "snapshotId": str(s.get("snapshot-id")),
            "sequenceNumber": s.get("sequence-number"),
            "timestampMs": s.get("timestamp-ms"),
            "operation": summary.get("operation"),
            "writer": _writer(summary),
            "firstRowId": s.get("first-row-id"),
            "addedRows": s.get("added-rows"),
            "addedRecords": _int_or_none(summary.get("added-records")),
            "deletedRecords": _int_or_none(summary.get("deleted-records")),
            "addedDataFiles": _int_or_none(summary.get("added-data-files")),
            "addedDeleteFiles": _int_or_none(summary.get("added-delete-files")),
            "totalDataFiles": _int_or_none(summary.get("total-data-files")),
            "totalDeleteFiles": _int_or_none(summary.get("total-delete-files")),
            "totalRecords": _int_or_none(summary.get("total-records")),
        })
    return {
        "table": f"{BACKEND.catalog_namespace(namespace)}.{table}",
        "formatVersion": metadata.get("format-version"),
        "metadataLocation": metadata_location,
        "metadataVersions": len(metadata.get("metadata-log", [])) + 1,
        "lastUpdatedMs": metadata.get("last-updated-ms"),
        "nextRowId": metadata.get("next-row-id"),
        "currentSnapshotId": str(current_id) if current_id is not None else None,
        "snapshotCount": len(snapshots),
        "totalDataFiles": _int_or_none(current_summary.get("total-data-files")),
        "totalDeleteFiles": _int_or_none(current_summary.get("total-delete-files")),
        "totalRecords": _int_or_none(current_summary.get("total-records")),
        "schemaCount": len(schemas),
        "currentSchemaId": metadata.get("current-schema-id"),
        "columns": [
            {
                "name": f["name"],
                "type": f["type"] if isinstance(f["type"], str) else json.dumps(f["type"]),
                "required": f.get("required"),
                "initialDefault": f.get("initial-default"),
                "writeDefault": f.get("write-default"),
            }
            for f in _current_schema(metadata).get("fields", [])
        ],
        "schemas": [
            {"schemaId": s.get("schema-id"), "columns": [f["name"] for f in s.get("fields", [])]}
            for s in schemas
        ],
        "properties": metadata.get("properties", {}),
        "snapshots": snapshots,
    }


def api_rows(namespace: str, table: str, query) -> dict:
    metadata_location, metadata = _load_table(namespace, table)
    id_col = _check_column(metadata, query.get("id_col", ["customer_id"])[0])
    col = query.get("col", [None])[0]
    val = query.get("val", [None])[0]

    sql = (
        f"SELECT _row_id, _last_updated_sequence_number, {id_col} "
        f"FROM iceberg_scan('{metadata_location}')"
    )
    params = []
    if col is not None and val is not None:
        _check_column(metadata, col)
        sql += f" WHERE {col} = ?"
        params.append(_coerce(val))
    sql += f" ORDER BY {id_col} LIMIT {MAX_ROWS}"

    con = BACKEND.duckdb_connect()
    try:
        rows = con.execute(sql, params).fetchall()
    finally:
        con.close()
    return {
        "table": f"{BACKEND.catalog_namespace(namespace)}.{table}",
        "metadataLocation": metadata_location,
        # shown on screen in the Stage 4 join panel, with the value inlined
        "sql": sql.replace("?", repr(params[0]) if params else "?"),
        "columns": ["_row_id", "_last_updated_sequence_number", id_col],
        "rows": [[_jsonable(v) for v in r] for r in rows],
        "truncated": len(rows) == MAX_ROWS,
    }


def api_identity(namespace: str, table: str, key: str, query) -> dict:
    metadata_location, metadata = _load_table(namespace, table)
    key_col = _check_column(metadata, query.get("key_col", ["customer_id"])[0])
    key_value = _coerce(key)

    cache_key = (metadata_location, key_col, key_value)
    with _identity_lock:
        cached = _identity_cache.get(cache_key)
    if cached is not None:
        return cached

    points = []
    con = BACKEND.duckdb_connect()
    try:
        for s in _snapshots_by_sequence(metadata):
            rows = con.execute(
                f"SELECT _row_id, _last_updated_sequence_number "
                f"FROM iceberg_scan('{metadata_location}', snapshot_from_id => {int(s['snapshot-id'])}) "
                f"WHERE {key_col} = ? ORDER BY _row_id",
                [key_value],
            ).fetchall()
            points.append({
                "snapshotId": str(s["snapshot-id"]),
                "sequenceNumber": s.get("sequence-number"),
                "timestampMs": s.get("timestamp-ms"),
                "operation": s.get("summary", {}).get("operation"),
                # [] = key absent at this snapshot (e.g. between a delete and its re-insert)
                "rows": [{"rowId": r[0], "lastUpdatedSequenceNumber": r[1]} for r in rows],
            })
    finally:
        con.close()

    distinct_ids = sorted({r["rowId"] for p in points for r in p["rows"]})
    result = {
        "table": f"{BACKEND.catalog_namespace(namespace)}.{table}",
        "keyColumn": key_col,
        "key": key_value,
        "metadataLocation": metadata_location,
        "distinctRowIds": distinct_ids,
        "identityStable": len(distinct_ids) <= 1,
        "points": points,
    }
    with _identity_lock:
        _identity_cache[cache_key] = result
    return result


def _writer(summary: dict) -> str:
    """Which tool made a commit, from the keys it leaves in the snapshot summary."""
    if "kafka.connect.commit-id" in summary or "kafka.connect.task-id" in summary:
        return "Kafka Connect"
    if summary.get("engine-name"):
        return summary["engine-name"].capitalize()
    return "unknown"


def _quote(column: str) -> str:
    return '"' + column.replace('"', '""') + '"'


def api_catalog(_query) -> dict:
    return {
        "tables": [
            {"namespace": ns, "catalogNamespace": BACKEND.catalog_namespace(ns), "table": t}
            for ns, t in BACKEND.list_tables()
        ]
    }


def api_data(namespace: str, table: str, query) -> dict:
    """Every column, paged, ordered by _row_id. Values are cast to text in SQL
    so timestamps, decimals and VARIANT all arrive display-ready."""
    metadata_location, metadata = _load_table(namespace, table)
    try:
        limit = max(1, min(MAX_ROWS, int(query.get("limit", ["25"])[0])))
        offset = max(0, int(query.get("offset", ["0"])[0]))
        seq = query.get("seq", [None])[0]
        seq = int(seq) if seq not in (None, "") else None
    except ValueError:
        raise ApiError(400, "limit, offset and seq must be integers")

    fields = [f["name"] for f in _current_schema(metadata).get("fields", [])]
    select = ", ".join(f"CAST({_quote(c)} AS VARCHAR) AS {_quote(c)}" for c in fields)
    source = f"iceberg_scan('{metadata_location}')"
    where, params = "", []
    if seq is not None:
        where, params = " WHERE _last_updated_sequence_number = ?", [seq]

    con = BACKEND.duckdb_connect()
    try:
        total = con.execute(f"SELECT count(*) FROM {source}{where}", params).fetchone()[0]
        rows = con.execute(
            f"SELECT _row_id, _last_updated_sequence_number{', ' + select if select else ''} "
            f"FROM {source}{where} ORDER BY _row_id LIMIT {limit} OFFSET {offset}",
            params,
        ).fetchall()
    finally:
        con.close()
    return {
        "table": f"{BACKEND.catalog_namespace(namespace)}.{table}",
        "columns": ["_row_id", "_last_updated_sequence_number"] + fields,
        "rows": [[_jsonable(v) for v in r] for r in rows],
        "total": total,
        "offset": offset,
        "limit": limit,
        "seq": seq,
    }


def _kafka_recent(limit: int) -> dict:
    """Newest `limit` messages on KAFKA_TOPIC plus its total size. Cached for
    KAFKA_TTL_S so a polling browser doesn't open a consumer every request."""
    from kafka import KafkaConsumer, TopicPartition

    with _kafka_lock:
        cached = _kafka_cache.get(limit)
        if cached and cached[0] > time.monotonic():
            return cached[1]
        consumer = KafkaConsumer(
            bootstrap_servers=KAFKA_BOOTSTRAP, enable_auto_commit=False,
            request_timeout_ms=5000,
        )
        try:
            partitions = consumer.partitions_for_topic(KAFKA_TOPIC)
            if not partitions:
                result = {"available": True, "topic": KAFKA_TOPIC, "exists": False, "messageCount": 0, "recent": []}
            else:
                tps = [TopicPartition(KAFKA_TOPIC, p) for p in sorted(partitions)]
                begin, end = consumer.beginning_offsets(tps), consumer.end_offsets(tps)
                consumer.assign(tps)
                wanted = 0
                for tp in tps:
                    start = max(begin[tp], end[tp] - limit)
                    consumer.seek(tp, start)
                    wanted += end[tp] - start
                records = []
                deadline = time.monotonic() + 4
                while len(records) < wanted and time.monotonic() < deadline:
                    for tp, batch in consumer.poll(timeout_ms=500).items():
                        records.extend(r for r in batch if r.offset < end[tp])
                records.sort(key=lambda r: (r.timestamp, r.offset), reverse=True)
                recent = []
                for r in records[:limit]:
                    text = r.value.decode("utf-8", "replace") if r.value is not None else None
                    try:
                        parsed = json.loads(text) if text else None
                    except json.JSONDecodeError:
                        parsed = None
                    recent.append({"partition": r.partition, "offset": r.offset, "timestampMs": r.timestamp,
                                   "value": text, "parsed": parsed if isinstance(parsed, dict) else None})
                result = {
                    "available": True, "topic": KAFKA_TOPIC, "exists": True,
                    "messageCount": sum(end[tp] - begin[tp] for tp in tps),
                    "partitions": len(tps), "recent": recent,
                }
        finally:
            consumer.close()
        _kafka_cache[limit] = (time.monotonic() + KAFKA_TTL_S, result)
        return result


def _connect_status() -> dict:
    def get(path):
        with urllib.request.urlopen(f"{KAFKA_CONNECT_URL}{path}", timeout=5) as resp:
            return json.loads(resp.read())
    try:
        status = get(f"/connectors/{KAFKA_CONNECTOR}/status")
        config = get(f"/connectors/{KAFKA_CONNECTOR}/config")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return {"available": True, "registered": False, "name": KAFKA_CONNECTOR}
        raise
    return {
        "available": True, "registered": True, "name": KAFKA_CONNECTOR,
        "state": status.get("connector", {}).get("state"),
        "tasks": [t.get("state") for t in status.get("tasks", [])],
        "topics": config.get("topics"),
        "table": config.get("iceberg.tables"),
        "commitIntervalMs": _int_or_none(config.get("iceberg.control.commit.interval-ms")),
    }


def api_pipeline(query) -> dict:
    try:
        limit = max(1, min(50, int(query.get("limit", ["8"])[0])))
    except ValueError:
        raise ApiError(400, "limit must be an integer")
    out = {"backend": BACKEND.name}

    if KAFKA_BOOTSTRAP:
        try:
            out["kafka"] = _kafka_recent(limit)
        except Exception as exc:
            out["kafka"] = {"available": False, "error": f"{type(exc).__name__}: {exc}"}
    else:
        out["kafka"] = {"available": False, "reason": "not part of this backend"}

    if KAFKA_CONNECT_URL:
        try:
            out["connect"] = _connect_status()
        except Exception as exc:
            out["connect"] = {"available": False, "error": f"{type(exc).__name__}: {exc}"}
    else:
        out["connect"] = {"available": False, "reason": "not part of this backend"}

    ns, table = PIPELINE_TABLE
    try:
        stats = api_stats(ns, table, {})
    except TableNotFound:
        out["table"] = {"exists": False, "name": f"{BACKEND.catalog_namespace(ns)}.{table}"}
        return out
    snaps = stats["snapshots"]
    out["table"] = {
        "exists": True, "name": stats["table"], "formatVersion": stats["formatVersion"],
        "totalRecords": stats["totalRecords"], "totalDataFiles": stats["totalDataFiles"],
        "snapshotCount": stats["snapshotCount"], "nextRowId": stats["nextRowId"],
        "commitsByWriter": {w: sum(1 for s in snaps if s["writer"] == w) for w in sorted({s["writer"] for s in snaps})},
        "lastCommit": snaps[-1] if snaps else None,
    }

    # The same events read back from Iceberg: the Kafka messages shown above
    # (matched on event_id), or simply the newest rows when there's no Kafka.
    metadata_location, _ = _load_table(ns, table)
    event_ids = [m["parsed"]["event_id"] for m in out["kafka"].get("recent", [])
                 if m.get("parsed") and isinstance(m["parsed"].get("event_id"), str)]
    con = BACKEND.duckdb_connect()
    try:
        if event_ids:
            marks = ", ".join("?" for _ in event_ids)
            rows = con.execute(
                f"SELECT _row_id, _last_updated_sequence_number, event_id FROM iceberg_scan('{metadata_location}') "
                f"WHERE event_id IN ({marks})", event_ids).fetchall()
            out["matched"] = {r[2]: {"rowId": r[0], "lastUpdatedSequenceNumber": r[1]} for r in rows}
        rows = con.execute(
            f"SELECT _row_id, _last_updated_sequence_number, event_id, CAST(customer_id AS VARCHAR), "
            f"CAST(amount AS VARCHAR) FROM iceberg_scan('{metadata_location}') ORDER BY _row_id DESC LIMIT {limit}"
        ).fetchall()
        out["latestRows"] = [
            {"rowId": r[0], "lastUpdatedSequenceNumber": r[1], "event_id": r[2], "customer_id": r[3], "amount": r[4]}
            for r in rows
        ]
    finally:
        con.close()
    return out


def _int_or_none(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _coerce(value: str):
    try:
        return int(value)
    except ValueError:
        return value


# --------------------------------------------------------------------------
# HTTP plumbing
# --------------------------------------------------------------------------

TABLE_ROUTE = re.compile(r"^/api/tables/([^/]+)/([^/]+)/(stats|rows|data|identity)(?:/([^/]+))?$")


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # browser polls constantly; keep stdout readable
        pass

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        try:
            if url.path == "/health":
                self._json(200, {"status": "ok"})
            elif url.path == "/api/backend":
                self._json(200, api_backend(query))
            elif url.path == "/api/events":
                self._json(200, api_events(query))
            elif url.path == "/api/pipeline":
                self._json(200, api_pipeline(query))
            elif url.path == "/api/catalog":
                self._json(200, api_catalog(query))
            elif m := TABLE_ROUTE.match(url.path):
                namespace = _check_name(m.group(1), "namespace")
                table = _check_name(m.group(2), "table")
                kind, key = m.group(3), m.group(4)
                if kind == "identity":
                    if key is None:
                        raise ApiError(400, "identity needs a key: /identity/{key}")
                    self._json(200, api_identity(namespace, table, key, query))
                elif key is not None:
                    raise ApiError(404, "not found")
                elif kind == "stats":
                    self._json(200, api_stats(namespace, table, query))
                elif kind == "data":
                    self._json(200, api_data(namespace, table, query))
                else:
                    self._json(200, api_rows(namespace, table, query))
            elif not url.path.startswith("/api/"):
                self._static(url.path)
            else:
                raise ApiError(404, "not found")
        except ApiError as exc:
            self._json(exc.status, {"error": str(exc)})
        except duckdb.ConversionException as exc:
            self._json(400, {"error": f"value doesn't match the column type: {exc}"})
        except TableNotFound as exc:
            # Normal before the stage that creates the table has run.
            self._json(404, {"error": f"table not found: {exc}"})
        except Exception as exc:  # catalog down, S3 error, bad SQL, ...
            traceback.print_exc()
            self._json(502, {"error": f"{type(exc).__name__}: {exc}"})

    def _static(self, path: str):
        name = "index.html" if path in ("", "/") else path.lstrip("/")
        target = (STATIC_DIR / name).resolve()
        if STATIC_DIR.resolve() not in target.parents or not target.is_file():
            raise ApiError(404, "not found")
        content_type = {
            ".html": "text/html; charset=utf-8",
            ".js": "text/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".svg": "image/svg+xml",
        }.get(target.suffix, "application/octet-stream")
        self._send(200, target.read_bytes(), content_type)

    def _json(self, status: int, body: dict):
        self._send(status, json.dumps(body).encode(), "application/json")

    def _send(self, status: int, payload: bytes, content_type: str):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    port = int(os.environ.get("PORT", "8088"))
    with Server(("0.0.0.0", port), Handler) as httpd:
        print(f"[dashboard] backend={BACKEND.name} listening on :{port}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
