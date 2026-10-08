#!/usr/bin/env python3
"""
Minimal, dependency-free OpenLineage-shaped event collector.

Not the full OpenLineage REST spec -- just enough to receive the RunEvent
JSON that the demo's Spark MetricsReporter POSTs on every Iceberg commit,
print a readable one-line summary (this is a live-demo moment), and persist
the full payload to a JSONL file so Stage 04 can grep a run's sequenceNumber
back out after the fact.

If MARQUEZ_URL is set, each event is also forwarded there (in the
background, so a slow or absent Marquez never delays the writer's commit)
for the lineage graph UI. The terminal summary and the JSONL file stay the
fallback.
"""
import http.server
import json
import os
import socketserver
import sys
import threading
import urllib.request
from datetime import datetime, timezone

LOG_DIR = "/var/log/openlineage"
LOG_FILE = os.path.join(LOG_DIR, "events.jsonl")
MARQUEZ_URL = os.environ.get("MARQUEZ_URL", "")


def forward_to_marquez(raw: bytes) -> None:
    request = urllib.request.Request(
        MARQUEZ_URL, data=raw, method="POST", headers={"Content-Type": "application/json"}
    )
    try:
        urllib.request.urlopen(request, timeout=10).close()
    except Exception as exc:  # Marquez is optional; never fail the commit path
        print(f"[openlineage-collector] Marquez forward failed: {exc}", flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silence default access log noise
        pass

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
            return
        self._respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/v1/lineage":
            self._respond(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            event = json.loads(raw)
        except json.JSONDecodeError as exc:
            self._respond(400, {"error": f"invalid JSON: {exc}"})
            return

        event.setdefault("receivedAt", datetime.now(timezone.utc).isoformat())

        os.makedirs(LOG_DIR, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(event) + "\n")

        self._print_summary(event)
        if MARQUEZ_URL:
            # the writer's original body, not `event` (no receivedAt)
            threading.Thread(target=forward_to_marquez, args=(raw,), daemon=True).start()
        self._respond(201, {"status": "accepted"})

    def _print_summary(self, event: dict) -> None:
        run_id = event.get("run", {}).get("runId", "?")
        job = event.get("job", {}).get("name", "?")
        facets = event.get("run", {}).get("facets", {})
        iceberg = facets.get("iceberg_commit", {})
        table = iceberg.get("tableName", "?")
        snapshot_id = iceberg.get("snapshotId", "?")
        sequence_number = iceberg.get("sequenceNumber", "?")
        operation = iceberg.get("operation", "?")
        event_type = event.get("eventType", "?")

        line = (
            f"[openlineage-collector] {event_type:9s} job={job} table={table} "
            f"operation={operation} snapshotId={snapshot_id} sequenceNumber={sequence_number} "
            f"runId={run_id}"
        )
        print(line, flush=True)

    def _respond(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main() -> None:
    port = int(os.environ.get("PORT", "5000"))
    os.makedirs(LOG_DIR, exist_ok=True)
    with socketserver.ThreadingTCPServer(("0.0.0.0", port), Handler) as httpd:
        print(f"[openlineage-collector] listening on :{port}, logging to {LOG_FILE}", flush=True)
        if MARQUEZ_URL:
            print(f"[openlineage-collector] forwarding to Marquez at {MARQUEZ_URL}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
