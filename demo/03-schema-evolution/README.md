# Stage 03 -- Schema evolution at the source, with the stream still flowing

**The one point this proves:** when a streaming source changes its schema
without warning, the pipeline doesn't stop. The producer starts sending a new
field mid-stream; the Kafka Connect Iceberg sink
(`iceberg.tables.evolve-schema-enabled=true`, set in Stage 01) adds the column
to `bronze.events` by itself. Metadata only -- no snapshot for the change, no
data file rewritten -- and Kafka Connect never restarts. Nobody runs a DDL.

## Run it

```
demo/run-stage.sh 3          # 5 events/s, new field after 20 s
demo/run-stage.sh 3 10 30    # other rate / delay
```

## What happens

0. Records a baseline (sequence number, schema count), then starts
   `scripts/stream_events.py` piped into `kafka-console-producer`, with the
   original 4 fields.
1. After `FIELD_AFTER` seconds the producer adds `"channel"`
   (`web`/`mobile`/`store`) to every record (`--add-field-after`). The stage
   waits until the catalog shows a new schema -- the sink evolved the table
   on its own -- then keeps streaming 15 s more.
2. Stops the stream and checks: every streamed event is in `bronze.events`,
   the Kafka Connect task is still `RUNNING`, and
   `scripts/schema_change_proof.py` lists every snapshot since the baseline:
   all Kafka Connect appends, no deleted files, schema count +1.
3. Before/after: rows written before the field appeared read `NULL` for
   `channel` (the sink adds it as optional, no default); the new rows carry
   their value. `_row_id` stays dense across the change.

Tested on V3 / Polaris (2026-10-08): schema 0 -> 1 with `channel` string,
old rows NULL, new rows set, `_row_id` contiguous, task RUNNING.

## Defaults (initial-default / write-default) -- slides only

V3's column defaults are covered on the slides, not in this stage, because
the streaming writer doesn't apply them. These findings came from an earlier
version of this stage (operator-added column with a default,
`scripts/spark/add_column_with_default.py`, still in the repo):

### Kafka Connect ignores write-defaults

Iceberg 1.11's Kafka Connect sink doesn't apply write-defaults. Found live
while building this stage:

- **NOT NULL column** (`addRequiredColumn`): the sink's task dies on the first
  record without the field and stays dead until restarted by hand:
  `DataException: An error occurred converting record ... Caused by:
  java.lang.NullPointerException: Cannot invoke
  "java.lang.CharSequence.toString()" because "value" is null`.
- **Optional column** (`addColumn(name, type, default)`): the sink keeps
  ingesting but writes `NULL`.

So in the result: `'web'` = the data file has no `channel` column
(initial-default; includes Connect files written just before the sink picked
up the new schema), `'mobile'` = Spark applied the write-default, `NULL` =
Kafka Connect. Defaults are only as good as the writer that applies them.

### Why the defaults scripts run as `spark-submit` jobs, not `spark-sql -f`

Discovered empirically while building this stage: Iceberg 1.11.0's Spark
integration does not support `ALTER TABLE ... ADD COLUMN ... DEFAULT` (or
`ALTER COLUMN ... SET DEFAULT`) through Spark SQL DDL at all. Decompiling
`Spark3Util.apply(TableChange.AddColumn)` in
`iceberg-spark-runtime-4.0_2.13-1.11.0.jar` shows it throws
`UnsupportedOperationException("Cannot add column %s since setting default
values in Spark is currently unsupported")` for any column carrying a Spark
`ColumnDefaultValue` -- confirmed by hitting exactly that failure mode live
against this stack before switching approaches. The underlying Iceberg table
API has supported this for longer, via
`UpdateSchema.addRequiredColumn(name, type, defaultLiteral)` and
`UpdateSchema.updateColumnDefault(name, literal)` (both in `iceberg-api`).
`scripts/spark/add_column_with_default.py` and
`scripts/spark/set_column_write_default.py` call those directly through
`Spark3Util.loadIcebergTable(spark, "lake.bronze.events")` and PySpark's
JVM gateway, run via `spark-submit` instead of `spark-sql`. The *result* is
identical metadata-only schema evolution -- this is a Spark-SQL-grammar gap
in this Iceberg version, not a difference in what actually happens to the
table.

One more wrinkle found live: Iceberg's `SparkTable` *does* correctly expose
the current write-default to Spark's analyzer for reads -- but Spark's
`INSERT INTO t (col_list) VALUES (...)` only fills an omitted NOT NULL
column from its default when the literal `DEFAULT` keyword is used in the
matching `VALUES` position; silently leaving the column out of both the
column list and the values list throws
`[INCOMPATIBLE_DATA_FOR_TABLE.CANNOT_FIND_DATA]`. Step 2b's INSERT spells
out `channel` explicitly as `DEFAULT` for exactly this reason.

### Why Spark 4.0 there (VARIANT)

`VARIANT` / `PARSE_JSON` don't exist in Spark 3.5. `docker/spark-demo`
bundles Spark 4.0 + `iceberg-spark-runtime-4.0_2.13:1.11.0` specifically for
this. `preflight/docker/spark` (Spark 3.5.4) is untouched but no longer used:
its catalog config is baked against preflight's REST server, so Stage 01's
DDL also runs in `spark-demo`, whose `lake` catalog is the demo catalog.
