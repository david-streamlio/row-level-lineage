# Stage 04 -- Composable Lineage (correlation join / CLIMAX)

**The one point this proves:** graph-level lineage tooling (OpenLineage) and
row-level identity (Iceberg's `_row_id`/`_last_updated_sequence_number`) are
two completely separate models that know nothing about each other -- and
they can still be joined, precisely, on **one key**: `sequenceNumber`.

OpenLineage has **no row-level concept at all**. The join is the bridge.
That bridge is what we call **Composable Lineage** here -- never "BYOL".

## Run it

```
demo/run-stage.sh 4          # customer 9002 (new row)
demo/run-stage.sh 4 9001     # stage 2's customer: the join lands on an updated row (recorded)
```

## What happens

1. `docker/spark-demo` bundles a small custom
   `org.apache.iceberg.metrics.MetricsReporter`
   (`com.demo.lineage.OpenLineageMetricsReporter`) wired in via the catalog
   property `metrics-reporter-impl`. It receives Iceberg's own
   `CommitReport` after every commit -- `tableName`, `snapshotId`,
   `sequenceNumber`, `operation` -- and POSTs a minimal OpenLineage-shaped
   `RunEvent` to `openlineage-collector`.
2. A new event streams in like every other bronze row: Kafka ->
   Kafka Connect -> `bronze.events` (the stage waits for the commit). A
   Spark `MERGE` reads it from `bronze.events` (declared as the input via
   `OPENLINEAGE_INPUTS`) and folds it into `silver.customers`.
3. `scripts/latest_lineage_event.py` reads the emitted event back out of
   `out/openlineage/events.jsonl` and prints it -- **the graph-level view**.
   It extracts `sequenceNumber` from that event.
4. `scripts/read_row_lineage.py` queries
   `silver.customers WHERE _last_updated_sequence_number = <that number>`
   -- **the row-level view**, driven entirely by the graph event's own
   field.
5. **Back to the source:** the silver row's `last_event_id` joins it to its
   input event in `bronze.events`; that row's
   `_last_updated_sequence_number` is the Kafka Connect commit that wrote
   it, and `scripts/lineage_event_for_seq.py` finds that commit's lineage
   event: job `kafka-connect/iceberg-sink`, input the Kafka topic. Row ->
   input record -> ingest commit -> topic. *(Recording 2026-10-08: silver
   `_row_id` 0 at seq 6 -> bronze `_row_id` 490 at seq 38 -> iceberg-sink,
   `kafka://kafka:9092/events`.)*

## Why a custom MetricsReporter instead of `openlineage-spark`

The official `openlineage-spark` listener attaches at the Spark-job level
and has no visibility into Iceberg's own `CommitReport` fields. Implementing
`MetricsReporter` directly against Iceberg's documented extension point is
the deterministic path to exactly the three fields this stage needs, without
depending on a third-party package's internals for a live demo.
