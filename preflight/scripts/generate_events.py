#!/usr/bin/env python3
"""Emit N synthetic bronze.events JSON records, one per line, to stdout."""
import json
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone


def main() -> None:
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    start = datetime.now(timezone.utc) - timedelta(seconds=count)
    for i in range(count):
        record = {
            "event_id": str(uuid.uuid4()),
            "customer_id": random.randint(1, 5000),
            "amount": round(random.uniform(1.00, 999.99), 2),
            "ts": (start + timedelta(seconds=i)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        }
        print(json.dumps(record))


if __name__ == "__main__":
    main()
