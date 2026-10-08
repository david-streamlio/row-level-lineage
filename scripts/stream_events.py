#!/usr/bin/env python3
"""
Stream synthetic bronze.events JSON records to stdout, one per line, at a
steady rate until a stop file appears (or --max-seconds passes). Same record
shape as preflight/scripts/generate_events.py, with ts = now.

Stage 03 pipes this into kafka-console-producer. With --add-field-after, the
producer changes its schema mid-stream without warning: after that many
seconds every event also carries "channel" (web / mobile / store), as when an
upstream team ships a new field. A marker file records the moment it started.

Usage: stream_events.py --rate 5 --stop-file out/.stop-stream [--max-seconds 900]
                        [--add-field-after 20 --marker-file out/.field-added]
"""
import argparse
import json
import os
import random
import sys
import time
import uuid
from datetime import datetime, timezone


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rate", type=float, default=5.0, help="events per second")
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--max-seconds", type=float, default=900)
    parser.add_argument("--add-field-after", type=float, default=None,
                        help="seconds until events start carrying a new 'channel' field")
    parser.add_argument("--marker-file", default=None, help="touched when the new field starts")
    args = parser.parse_args()

    interval = 1.0 / args.rate
    start = time.monotonic()
    deadline = start + args.max_seconds
    field_added = False
    while not os.path.exists(args.stop_file) and time.monotonic() < deadline:
        record = {
            "event_id": str(uuid.uuid4()),
            "customer_id": random.randint(1, 5000),
            "amount": round(random.uniform(1.00, 999.99), 2),
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        }
        if args.add_field_after is not None and time.monotonic() - start >= args.add_field_after:
            record["channel"] = random.choice(["web", "mobile", "store"])
            if not field_added:
                field_added = True
                if args.marker_file:
                    open(args.marker_file, "w").close()
        print(json.dumps(record), flush=True)
        time.sleep(interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
