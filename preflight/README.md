# row-level-lineage

A local, reproducible pre-flight harness that answers one question empirically:

> **Can the Kafka Connect Iceberg sink write an Apache Iceberg V3 table with
> working row lineage (`_row_id` assigned via manifest inheritance)?**

This exists to de-risk a conference demo *before* it's built on stage. If the
answer is no, we want to know that now, cheaply, with a citable reason —
not during rehearsal.

## Why this is a real question

- Row lineage (`_row_id`, `_last_updated_sequence_number`) is an Iceberg V3
  table feature. It only works correctly if the writer assigns row IDs via
  **manifest inheritance** rather than baking them into data files.
- Iceberg **< 1.10.0** silently **reassigns** `_row_id` on compaction instead
  of preserving it. A demo built on an older library version would look like
  it works, then quietly produce wrong lineage the first time compaction
  runs — a much worse failure mode than an upfront "this doesn't work yet."
- Auto-creating the table from Kafka Connect (`iceberg.tables.auto-create-enabled=true`)
  almost certainly produces a **V2** table, which has no row lineage at all.
- Flink's Iceberg source has no `SupportsReadingMetadata` for `_row_id` — if
  you try to verify with Flink, you cannot even select the column, and might
  wrongly conclude the feature is broken when it's actually just unreadable
  from that engine.

This harness controls for all three failure modes.

## Architecture

```
                     ┌─────────────┐        ┌──────────────────┐
   producer script → │    Kafka    │ ─────→ │  Kafka Connect    │
   (scripts/produce)  │  (KRaft)    │        │  Iceberg Sink     │
                     └─────────────┘        │  Connector        │
                                             └─────────┬─────────┘
                                                        │ writes Parquet,
                                                        │ commits via REST catalog
                                                        ▼
   ┌────────────┐     catalog metadata      ┌──────────────────┐
   │  DuckDB    │ ◄───────────────────────  │  Iceberg REST     │
   │ (verify)   │                           │  catalog          │
   └─────┬──────┘                           └─────────┬─────────┘
         │ reads data + metadata (S3)                 │ warehouse = s3://warehouse/
         ▼                                            ▼
   ┌───────────────────────────────────────────────────────────┐
   │                          MinIO (S3)                        │
   └───────────────────────────────────────────────────────────┘

   ┌────────────┐
   │   Spark    │  used ONLY for: (1) explicit V3 CREATE TABLE DDL,
   │ (throwaway)│  (2) Check C fallback if DuckDB can't read .snapshots.
   └────────────┘  NEVER used to read _row_id.
```

All services run via Docker Compose. Nothing is installed on the host except
Docker, `bash`, `curl`, `jq`, and `python3` (stdlib only) to drive the scripts.

## Table schema

```sql
-- bronze.events, Iceberg format-version 3, Parquet
event_id     STRING
customer_id  BIGINT
amount       DECIMAL(12,2)
ts           TIMESTAMP
```

Created explicitly via Spark SQL (`sql/create_bronze_table.sql`) with:

```sql
TBLPROPERTIES (
  'format-version'       = '3',
  'write.format.default' = 'parquet'
)
```

The Kafka Connect sink is registered with `iceberg.tables.auto-create-enabled=false`
so it can only ever write into this pre-created V3/Parquet table — it cannot
silently downgrade the format by auto-creating a V2 table.

Ingest is **append-only**. No upserts, no equality/positional deletes.

## Prerequisites

- Docker + Docker Compose v2 (`docker compose version`)
- `bash`, `curl`, `jq`, `python3` on the host

## Quick start

```bash
./run.sh          # up → setup (topic + V3 table + connector) → produce → verify
# or:
make preflight
```

Tear down:

```bash
./teardown.sh      # or: make clean
```

`make clean` / `teardown.sh` removes the MinIO volume too, so a re-run starts
from a genuinely empty warehouse.

### Individual steps

```bash
make up        # docker compose up the core stack (build kafka-connect image)
make setup     # create topic, create V3 table via Spark, register connector
make produce   # emit 300 synthetic JSON events
make verify    # DuckDB checks A/B/C, PASS/FAIL summary
make logs      # tail all container logs
```

## What gets printed at startup

The `kafka-connect` container prints, before it starts the Connect worker:

```
==================================================================
 Iceberg Kafka Connect sink -- bundled Iceberg version check
==================================================================
jar                      : iceberg-kafka-connect-runtime-1.11.0.jar
bundled Iceberg version  : 1.11.0
required minimum         : 1.10.0  (row lineage / _row_id manifest inheritance)
RESULT: OK -- 1.11.0 >= 1.10.0
==================================================================
```

If the bundled version is **older than 1.10.0**, the container refuses to
start and exits non-zero with an explanation (see
`docker/connect/check_iceberg_version.sh`). This is a hard fail, not a
warning — a harness that quietly proceeded on an old jar would produce
results not worth trusting.

`scripts/setup.sh` re-prints this block from the container logs so it's
visible in the terminal that ran `make preflight`.

## The three checks (`scripts/verify.sh` → `scripts/verify_duckdb.py`)

All output is designed to be copy-pasteable straight into slides.

**Check A — format version survived?**
Reads the Iceberg REST catalog's own `LoadTableResult` JSON for
`bronze.events` (the authoritative source of truth for what was actually
committed) and asserts `metadata.format-version == 3`. Also prints the
table's `metadata-log`.

**Check B (make-or-break) — row IDs assigned?**

```sql
SELECT _row_id, _last_updated_sequence_number, event_id
FROM bronze.events
ORDER BY _row_id LIMIT 20;
```

- **PASS** = every row has a non-null `_row_id`, and the IDs are densely
  sequential (no gaps).
- **FAIL** = `_row_id` is `NULL` for some/all rows, or the values are
  non-sequential.

DuckDB reads this via a direct `ATTACH ... (TYPE ICEBERG, ENDPOINT ...)` of
the REST catalog when that succeeds, and transparently falls back to
`iceberg_scan()` against the table's S3 location if the catalog-attach SQL
surface isn't available in the installed DuckDB build. Either path reads the
same committed Parquet + manifest data, so both are valid evidence.

**Check C — inheritance at the metadata layer (best evidence)**

Reads the `snapshots` array directly out of the REST catalog's own
`metadata.json` (the same JSON Check A already fetched) and checks, per
snapshot in `sequence-number` order:

```
first_row_id[n] == first_row_id[n-1] + summary.added-records[n-1]
```

- **PASS** = `first_row_id` advances by the previous snapshot's
  `added-records` on every successive commit — i.e. row IDs are being
  inherited from manifests, not recomputed per-file.
- This reads the metadata.json directly rather than going through DuckDB's
  `iceberg_snapshots()` table function or Spark's `snapshots` metadata view,
  because neither exposes the V3 row-lineage fields as columns: the DuckDB
  build used here only surfaces `timestamp_ms`/`manifest_list`/`operation`,
  and Spark's `bronze.events.snapshots` view only surfaces
  `committed_at`/`snapshot_id`/`parent_id`/`operation`/`manifest_list`/`summary`
  — `first-row-id` isn't a column on either read path. The metadata.json is
  the actual "metadata layer" this check is named for, and it always carries
  `first-row-id` (top-level per V3 spec) and `added-records` (in `summary`)
  regardless of which query engine's metadata-table support has or hasn't
  caught up. `check_c_needs_spark_fallback` is kept in `out/status.json` and
  `scripts/verify.sh` for future-proofing, but is always `false` today.

## What a failure means

If **Check A** or **Check B** fails, row lineage does not survive this
ingest path today. That is itself a citable finding for the demo:
"as of Iceberg `<bundled version>` / the Iceberg Kafka Connect sink, direct
streaming ingest into a V3 table does not preserve `_row_id`."

The recommended fallback keeps everything else about the demo:

1. Point the Kafka Connect sink at a **V2** `bronze.events` table instead
   (drop `format-version=3`; row lineage isn't expected here regardless).
2. Batch-read `bronze` with Spark and `MERGE INTO` a **V3** `silver` table.
   `MERGE` on a V3 table assigns `_row_id` at the silver layer via normal
   Iceberg write paths — you lose row IDs *at ingest time*, but the rest of
   the lineage story (row IDs stable across silver's own future compactions,
   `_last_updated_sequence_number` reflecting the MERGE) still holds and is
   demoable.
3. Say this explicitly on stage: "streaming ingest doesn't get you row IDs
   yet; the batch MERGE layer does." That's a legitimate, specific finding —
   more credible than papering over it.

## Known sharp edges / things that may need adjusting

These are real packaging gaps this harness surfaced while getting from
"containers start" to "row lineage actually verified end-to-end" — kept here
because they're citable findings in their own right, not just implementation
trivia.

- **`tabulario/iceberg-rest` does not support format-version 3 at all.** Its
  last published tag (`1.6.0`, August 2024) bundles an Iceberg core library
  from before the V3 spec existed, and rejects
  `CREATE TABLE ... TBLPROPERTIES('format-version'='3', ...)` server-side
  with `"Unsupported format version: v3 (supported: v2)"` — regardless of
  which Iceberg client library version talks to it. There is no newer
  published tag, and Apache Iceberg does not publish a versioned
  `RESTCatalogServer` image of its own. **Fix used here:** `docker/iceberg-rest`
  builds the identical `org.apache.iceberg.rest.RESTCatalogServer` class
  (Apache Iceberg's own in-tree reference/test-fixture REST catalog, same
  `JdbcCatalog` backend, same `CATALOG_*` env var scheme) from Maven Central
  artifacts pinned to the current Iceberg version instead. See
  `docker/iceberg-rest/pom.xml` for the full dependency story.
- **`iceberg-aws-bundle` alone does not contain `org.apache.iceberg.aws.S3FileIO`.**
  It only contains the shaded/relocated AWS SDK v2 + HTTP client/Netty
  dependencies. The actual `S3FileIO` class lives in the separate
  `org.apache.iceberg:iceberg-aws` artifact, which in turn declares its AWS
  SDK dependency as Gradle `compileOnly` (never published to its own POM) —
  so Maven dependency resolution gives no signal that the two artifacts must
  be used together. Symptom if only `iceberg-aws-bundle` is present:
  `ClassNotFoundException: org.apache.iceberg.aws.s3.S3FileIO`. Both
  `docker/iceberg-rest/pom.xml` and `docker/connect/pom.xml` declare both
  artifacts.
- **Iceberg 1.11's `FormatModelRegistry` unconditionally initializes ORC
  support, even for a Parquet-only table.** The Kafka Connect sink task threw
  `NoClassDefFoundError: org/apache/iceberg/orc/OrcRowWriter` from a static
  initializer the moment it opened its first (Parquet) writer, despite the
  table being `write.format.default=parquet` end to end. `iceberg-orc` has to
  be on the plugin classpath purely to satisfy this static registration, even
  though it's never used to write. See `docker/connect/pom.xml`.
- **The Iceberg Kafka Connect sink's commit path needs
  `org.apache.hadoop.conf.Configuration` on the classpath**, same as
  `RESTCatalogServer` does — `CommitterImpl.save()` throws
  `NoClassDefFoundError: org/apache/hadoop/conf/Configuration` without
  `hadoop-common` present, even though neither JdbcCatalog nor S3FileIO ever
  touch HDFS.
- **DuckDB's Iceberg REST catalog `ATTACH` syntax and the exact columns
  returned by `iceberg_snapshots()`/`iceberg_metadata()` are still evolving
  across DuckDB releases.** `scripts/verify_duckdb.py` is written
  defensively (try the nicer path, fall back to a more primitive one that
  reads directly off the table's S3 location) specifically because of this.
  If DuckDB's syntax has moved since this was written, `docker/duckdb` pins
  `duckdb>=1.1.0` — bump that pin and adjust the `ATTACH`/table-function
  calls in `verify_duckdb.py` if needed. This is expected maintenance for a
  pre-flight harness against a fast-moving read path, not a design flaw.
  Check B's `iceberg_scan()` call is pointed at the exact `metadata.json`
  path returned by the REST catalog rather than the bare table-root
  directory, since this DuckDB build refuses to glob-guess the latest
  metadata version (`unsafe_enable_version_guessing`) and this JdbcCatalog
  backend never writes a `version-hint.text`.
- **Neither DuckDB nor Spark expose the V3 row-lineage fields
  (`first-row-id`, `added-records`) as columns on their `snapshots` metadata
  table/function yet.** Check C reads them directly out of the REST
  catalog's `metadata.json` instead of relying on either engine's metadata
  table support — see the Check C section above.
- **Iceberg REST catalog image** (`docker/iceberg-rest`, and previously
  `tabulario/iceberg-rest`) has no curl/wget, so it has no in-container
  healthcheck; readiness is polled from the host in `scripts/setup.sh`
  against `GET /v1/config` instead.
- All version pins live in a single `.env` file at the repo root.

## Repo layout

```
docker-compose.yml              services, healthchecks, dependency ordering
.env                             all version pins / config in one place
docker/connect/                  Kafka Connect image + version-gate + worker config
docker/spark/                    throwaway Spark image (DDL + Check C fallback only)
docker/duckdb/                   verification engine image
sql/create_bronze_table.sql      explicit V3 DDL
sql/check_c_snapshots.sql        Check C fallback query (Spark)
scripts/setup.sh                 bucket, topic, table, connector registration
scripts/produce.sh               emits synthetic events
scripts/generate_events.py       event generator (stdlib only)
scripts/verify.sh                orchestrates DuckDB verify + Spark fallback, prints summary
scripts/verify_duckdb.py         Checks A/B/C
run.sh / Makefile                make preflight / ./run.sh
teardown.sh                      docker compose down -v
```
