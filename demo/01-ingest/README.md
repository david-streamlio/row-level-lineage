# Stage 01 -- Ingest / row identity

**The one point this proves:** row identity (`_row_id`) is inherited at
commit time via manifest inheritance -- it is never materialized by the
writer. Kafka Connect's Iceberg sink writes plain Parquet rows; Iceberg
itself assigns `_row_id` when the snapshot commits.

## Run it

```
demo/run-stage.sh 1
```

## What happens

1. Brings up MinIO, the Iceberg REST catalog, Kafka (KRaft), and Kafka
   Connect -- all reused unmodified from `preflight/`.
2. Creates `bronze.events` explicitly as **format-version 3** (auto-create is
   disabled on the connector -- the default auto-create path produces V2).
3. Registers the Iceberg Sink connector and waits for it to reach `RUNNING`.
4. Produces synthetic events onto the `events` topic.
5. Runs the DuckDB verification: format-version check, `_row_id` /
   `_last_updated_sequence_number` populated and dense, and
   `first-row-id` advancing by `added-records` across snapshots (proof of
   inheritance at the metadata layer).

Row lineage is read via **DuckDB only** -- never Flink (Flink's Iceberg
source can't project `_row_id`).
