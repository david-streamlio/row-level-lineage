# Stage 04 -- Composable Lineage (correlation join / CLIMAX)

**The one point this proves:** graph-level lineage tooling (OpenLineage) and
row-level identity (Iceberg's `_row_id`/`_last_updated_sequence_number`) are
two completely separate models that know nothing about each other -- and
they can still be joined, precisely, on **one key**: `sequenceNumber`.

OpenLineage has **no row-level concept at all**. The join is the bridge.
That bridge is what we call **Composable Lineage** here -- never "BYOL".

## Run it

```
demo/run-stage.sh 4
```

## What happens

1. `docker/spark-demo` bundles a small custom
   `org.apache.iceberg.metrics.MetricsReporter`
   (`com.demo.lineage.OpenLineageMetricsReporter`) wired in via the catalog
   property `metrics-reporter-impl`. It receives Iceberg's own
   `CommitReport` after every commit -- `tableName`, `snapshotId`,
   `sequenceNumber`, `operation` -- and POSTs a minimal OpenLineage-shaped
   `RunEvent` to `openlineage-collector`.
2. This stage runs one `MERGE` against `silver.customers`.
3. `scripts/latest_lineage_event.py` reads the emitted event back out of
   `out/openlineage/events.jsonl` and prints it -- **the graph-level view**.
   It extracts `sequenceNumber` from that event.
4. `scripts/read_row_lineage.py` queries
   `silver.customers WHERE _last_updated_sequence_number = <that number>`
   -- **the row-level view**, driven entirely by the graph event's own
   field.

## Why a custom MetricsReporter instead of `openlineage-spark`

The official `openlineage-spark` listener attaches at the Spark-job level
and has no visibility into Iceberg's own `CommitReport` fields. Implementing
`MetricsReporter` directly against Iceberg's documented extension point is
the deterministic path to exactly the three fields this stage needs, without
depending on a third-party package's internals for a live demo.
