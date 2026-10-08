# Progress -- row-level lineage demo

Status as of 2026-10-06. Paused on purpose: everything is torn down (local
Docker stack reset; AWS resources deleted). Nothing runs; built Docker images
are kept for a fast restart.

## Where things stand

The five-stage demo (README.md) works end to end locally, and a live
dashboard now exists for showing it to an audience. All of it was verified by
a full `reset` + stages 1-5 run, with the results matching the original
2026-09-15 run.

### Built in this round

| Piece | Where | State |
|---|---|---|
| Backend adapter: same reads against local (MinIO + REST catalog) or AWS (S3 + Glue) | `scripts/lineage_backend.py`, `LINEAGE_BACKEND` in `.env` | Done. Stage read scripts use it; output byte-identical to before |
| Catalog concurrency fix | `compose.catalog-persistence.yml` | Done. See "Findings" |
| Dashboard: read-only API + single page | `dashboard/` (service `lineage-dashboard`, http://localhost:8088) | Done; 19/19 browser interaction checks pass on both backends |
| AWS seed scripts | `scripts/aws/seed_glue_tables.sh`, `scripts/aws/seed_bronze_events.sh`, `sql/aws/` | Done |
| Stage scripts start the dashboard | `demo/0[1-4]-*/run.sh` | Syntax-checked only -- not yet through a full run |

Dashboard views: **Pipeline** (landing: Kafka topic -> Kafka Connect ->
Iceberg table -> DuckDB, with raw Kafka messages next to their Iceberg rows),
**Tables** (browse any table: rows, snapshot history, schema), and the five
numbered stage tabs, each linking to the data behind it. Keys `p`, `b`,
`1`-`5`, `t`.

### Built 2026-10-06 (afternoon): lineage graph

| Piece | Where | State |
|---|---|---|
| Marquez 0.51.1 (db, api, web on :3000) | `docker-compose.yml` | Done; starts with `openlineage-collector` |
| Collector forwards events to Marquez | `docker/openlineage-collector/server.py` | Done; terminal + JSONL unchanged |
| Reporter emits inputs/outputs, per-writer job identity | `docker/spark-demo/reporter/` | Done |
| Kafka Connect emits lineage events | `compose.connect-lineage.yml`, `demo/01-ingest/run.sh` | Done |
| Stages 2-5 rebuild `spark-demo`; stage 5 starts the collector | `demo/0[2-5]-*/run.sh` | Done |

Verified by `reset` + stages 1-5: every stage passes with the same results
(stage 2 `_row_id` 0 flat; stage 3 snapshots/files 4 -> 4, schemas 1 -> 2;
stage 4 joins sequenceNumber 4 -> `_row_id` 3; stage 5 `_row_id` 0 -> 1 -> 2).
Marquez graph: `kafka://kafka:9092/events -> kafka-connect/iceberg-sink ->
bronze.events <- lake.bronze.events.commit`, plus `silver.customers` and
`failure_demo.customers_equality_upsert` jobs; run facets show
`sequenceNumber`. Dashboard unaffected (still `lake.*` events only).

### Built 2026-10-06 (evening): SQL window, offline DuckDB

| Piece | Where | State |
|---|---|---|
| Row-lineage SQL window | `demo/sql.sh`, `scripts/lineage_sql.py` | Done; verified a MERGE from another terminal shows up in an open session (`_row_id` 0 kept, seq 3 -> 5) |
| DuckDB extensions baked in, DuckDB pinned 1.5.6 | `docker/duckdb-demo/Dockerfile`, `dashboard/Dockerfile` | Done; query verified on a network without internet |
| Stage 01 verification runs in `duckdb-demo` | `demo/01-ingest/run.sh` | Done; Checks A/B/C pass |

The demo will be **recorded end to end** (no live run at the venue);
annotated screenshots go on slides. See TALK-OUTLINE.md "Recorded demo vs
slides" for the window set. Current data includes test commits (an extra
MERGE on customer 9001) -- `reset` before recording.

### Step 2, phase A (2026-10-06): Lakekeeper V3 round trip -- PASSED

`scripts/lakekeeper/v3_roundtrip.sh [--cleanup]` (Lakekeeper v0.13.6 under
compose profile `lakekeeper`, UI http://localhost:8282/ui) runs the same Spark
operations against the reference catalog and Lakekeeper (V3 merge-on-read
table, INSERT, 2 MERGE updates, MERGE insert, DELETE via deletion vector, a
required column with initial-default 'web' / write-default 'mobile', a
VARIANT column) and has Kafka Connect ingest into Lakekeeper. Two
back-to-back runs: ALL CHECKS PASS -- normalized metadata identical
(format-version, next-row-id, per-snapshot first-row-id / added-rows /
sequence numbers, all 4 schemas incl. defaults and `variant`), DuckDB rows
identical incl. `_row_id` / `_last_updated_sequence_number`, Lakekeeper's
REST response == its metadata.json, Kafka Connect commits chain
`first-row-id` (0 -> 300, next-row-id 350) with dense `_row_id`.
Only difference: the reference catalog adds table property
`write.parquet.compression-codec=zstd` on create, Lakekeeper doesn't (zstd is
Iceberg's default either way).

### Step 2, phase B (2026-10-06): the demo runs on Lakekeeper -- DONE

All demo clients use `CATALOG_*` in `.env` (Lakekeeper; fallback block for
preflight's reference server commented next to it). Changed: `spark-demo`
build args, Kafka Connect connector config, `lineage_backend.py` and
`lib.sh` (warehouse prefix from `/v1/config`), dashboard, Stage 01 (starts
`CATALOG_SERVICES`; bronze DDL via `spark-demo` + `sql/create_bronze_table.sql`;
checks via `scripts/verify_stage1.py`, which reuses preflight's
`verify_duckdb.py` unchanged), round-trip test (explicit `ref` / `lk` Spark
catalogs). Bootstrap: no remote signing, readable folder layout
(`lakekeeper/bronze/events-<uuid>/`).

Verified by `reset` + stages 1-5 on Lakekeeper: identical results to the
reference catalog (stage 1 Checks A/B/C pass; stage 2 `_row_id` 0 flat;
stage 3 snapshots/files 4 -> 4, schemas 1 -> 2; stage 4 sequenceNumber 4 ->
`_row_id` 3; stage 5 0 -> 1 -> 2). Reference catalog left empty. Marquez,
dashboard (catalog shown as Lakekeeper) and `demo/sql.sh` work. Lakekeeper UI
checked by headless screenshot: table page shows "Iceberg v3 Format",
snapshots, last sequence number, Next row ID; red "Authentication is OFF"
banner on every page.

### Offline work (2026-10-07)

The user will work while travelling. `scripts/offline-prep.sh` (online:
build + pull + back up MinIO; `--check`: verify offline), `LINEAGE_OFFLINE`
(auto/1/0) in `.env` handled by `scripts/lib.sh` (offline: skip builds), AWS
seed guarded. Spark/Connect reporter Dockerfiles restructured so source edits
and catalog switches rebuild without network. Verified: `--check` passes;
Marquez/Lakekeeper/dashboard render with all non-localhost hosts blocked;
forced-offline (`LINEAGE_OFFLINE=1`) `reset` + stages 1-5: zero image builds, every stage passes with the usual results.

### Stage 3 streams through the schema changes (2026-10-07)

`demo/run-stage.sh 3 [rate]` streams events into Kafka (`scripts/stream_events.py`,
default 5/s) for the whole stage; `scripts/schema_change_proof.py` lists every
snapshot since the baseline with its writer and checks: all appends, no
deleted files, schema count +N with no snapshot of its own. End of stage:
every streamed event landed, Kafka Connect task still `RUNNING`, and where
each `channel` value comes from. `channel` is now OPTIONAL (see finding).
Verified by `reset` + stages 1-5: all pass; stage 3: 234 streamed / 234
landed, 22 snapshots (20 Kafka Connect, 2 Spark), schemas 1 -> 4; `channel`
`'web'` 337 / `NULL` 200 / `'mobile'` 2. Slide plan updated (22 slides; new
slide 12 for the finding).

### Demo recorder (2026-10-07)

`demo/record-demo.sh` (pattern of fleet-trilogy's record-talk3-demo.sh): five
recorded windows on the external display, one clip per stage. Tests 1-4 fixed:
Chrome placement (moved via System Events; display extends above the main
one), the external display's Dock + 30 pt top inset (usable area), Terminal
landing windows off by the display offset (read back and corrected), stray
keystrokes when Chrome launched mid-way (Chrome now last), crops clamped above
the window below, teardown (`pkill -t` rejects these tty names -> ps-based;
only this run's windows; never forced). Test 4 frames clean.
`SLIDE-PLAN.md` has a "Handoff notes for design" section for Claude Design.

**Full recording done 2026-10-07:** `demo/recordings/stage1..5-20261007-162318.mp4`
plus stills in `demo/recordings/stills/` (mapped to slides in SLIDE-PLAN.md).
All stages passed: stage 3 257/257 events landed, connector RUNNING, 24
snapshots (22 Connect, 2 Spark), `channel` web 341 / NULL 219 / mobile 2;
stage 4 (customer 9001) sequenceNumber 4 -> `_row_id` 0. Stage 1 re-taken
(`stage1-20261007-172448.mp4`) with the recorder scrolling Lakekeeper to Next
row ID (300) via Chrome's DevTools protocol (`demo/record-windows/cdp.mjs`).

### ASF catalog: Apache Polaris (2026-10-07, in progress)

ASF conference -> ASF-licensed where possible (user: no Spark for queries, no
Ozone; keep OpenLineage + Marquez; Polaris as the alternative catalog with
Lakekeeper as backup). Polaris 1.8.0 added under compose profile `polaris`
(in-memory, OAuth client credentials root / `POLARIS_CLIENT_SECRET` in `.env`, `docker/polaris/bootstrap.sh`
creates catalog `demo` on MinIO with stsUnavailable). **V3 round trip vs the
reference catalog: ALL CHECKS PASS** (`scripts/lakekeeper/v3_roundtrip.sh
--candidate polaris`) -- only difference a `created-at` table property.
Polaris console built from apache/polaris-tools as `lineage-polaris-console:local`
(needs CORS on Polaris; shows tables/schema/format-version and RBAC, no
snapshot list or Next row ID). **Done the same evening:** `scripts/use-catalog.sh polaris|lakekeeper|rest`
switches `.env` blocks (active: **polaris**); OAuth credential/scope wired
through Spark image, Connect connector, lineage_backend, lib.sh; recorder
logs in to the console via `demo/record-windows/cdp.mjs`. Reset + stages 1-5
on Polaris: all pass. **Polaris recording:** `demo/recordings/polaris/`
(stage 3: 272/272 events, 27 snapshots = 25 + 2, channel 341/234/2; stage 4
seq 4 -> `_row_id` 0) + stills incl. the console's Access Control page.
SLIDE-PLAN.md and DESIGN-PROMPT.md now use Polaris as primary (slides 8, 10,
12, 16, 20, 21, 22); Lakekeeper recording kept as backup.

### Recording v2 (2026-10-08)

Recorder reworked from user feedback: per-stage layouts with only the 2-3
windows each slide needs, 18 pt fonts, pinned purple title bars
(`header.sh`, repainted per layout), browser in the full right half and moved
over DevTools instead of relaunched (no desktop flash), Polaris sign-in done
off screen, no Chrome password bubble, Compose progress quiet in the writer.
Stage 1 streams events (EVENT_INTERVAL, recorded at 0.5 s; default now 0.25 s).
Polaris: Iceberg's REST metrics report disabled
(`rest-metrics-reporting-enabled=false`) -- Polaris answered it with a
ForbiddenException stack trace on every Spark commit; Spark logs at ERROR.
Then (same day): Spark start-up noise filtered (`demo-spark-sql` /
`demo-spark-submit` wrappers in the image), SQL window waits quietly
instead of printing errors, compact lineage-feed lines, Polaris console
Schema view at the end of stage 3, browser pages prepared off screen then
moved in (crop gated on the move time), EVENT_INTERVAL 0.25 s.
**Final take:** `demo/recordings/polaris/*-20261008-093045.mp4` (stages 1
and 3 re-exported from raw with exact gate times 133.05 s / 63.1 s) + stills +
`stage1-slide07-streaming-55s.mp4`. Stage 1: 19 commits (last six
first-row-id 243/251/259/271/283/295); stage 3 250/250 events, 24 snapshots
(22 + 2), channel 341/212/2; stage 4 seq 4 -> `_row_id` 0. Claude Design
follow-up: `DESIGN-REVISION-RECORDING.md`.

### Source-driven schema evolution + silver lineage (2026-10-08)

Stage 3 now matches the abstract ("schemas change without warning"): the
producer (`scripts/stream_events.py --add-field-after 20`) starts sending
`channel` mid-stream and the Kafka Connect sink, with
`iceberg.tables.evolve-schema-enabled=true` (stage 1's connector), adds the
column to `bronze.events` itself -- optional, no default, metadata-only, task
never restarted. The operator version (initial/write-default, VARIANT) moved
to the slides (12, 13, 21) and the stage README's "slides only" section.
Stages 2 and 4 now INSERT the event into `bronze.events` and MERGE from it,
declaring it via `OPENLINEAGE_INPUTS`; the reporter never lists a table as
its own input. Marquez now shows one chain: `events -> iceberg-sink ->
bronze.events -> lake.silver.customers.commit -> silver.customers`. Stage 4
fills `channel` in its INSERT when the table has it.

Recorder fixes: Chrome's "Change your password" bubble (leaked-password
check on minioadmin) was the process's "window 1" and took every browser
move (stage 2's MinIO view never appeared in takes 100019 / 103248). Now:
MinIO sign-in through its login API (no form, nothing for Chrome to check),
Chrome launched with `--disable-features=PasswordLeakDetection,...`, moves
target the AXStandardWindow (AppleScript loop; `whose subrole` fails on
Chrome) and retry until the frame matches. Polaris secret changed from
`s3cr3t` to a unique value in `.env` (`POLARIS_CLIENT_SECRET`).

**Final take:** `demo/recordings/polaris/*-20261008-105614.mp4` + stills +
`stage1-slide07-streaming-55s.mp4` (stage 1, 74-129 s). Stage 1: 17 commits
(last six first-row-id 242/246/262/266/282/286, added 4/16/4/16/4/14);
stage 2 `_row_id` 0 at seq 1/2/3, ends in MinIO (`*-deletes.puffin`);
stage 3: 185/185 events, last 86 with `channel`, 15 Kafka Connect appends, 0
deleted files, schemas 1 -> 2, task RUNNING, 402 NULL / mobile 31 / store 25
/ web 30, Polaris "Current schema (id 1)"; stage 4 seq 4 -> `_row_id` 0 with
the full Marquez chain; stage 5 `_row_id` 0/1/2. `SLIDE-PLAN.md` and
`DESIGN-REVISION-RECORDING.md` updated for this take.

### Abstract gaps closed (2026-10-08)

- "Lakehouse-native streaming" defined on slide 3 (the stream lands as
  Iceberg commits through the catalog, continuously, no batch ETL hop);
  slide 6 notes: works for any writer that commits through the catalog;
  slide 17 notes: any OpenLineage backend.
- "Which specific records produced it": stage 4's event now streams in
  through Kafka -> Kafka Connect (no Spark INSERT), and a new step traces the
  silver row back: `last_event_id` -> bronze row -> its
  `_last_updated_sequence_number` = the Kafka Connect commit ->
  `scripts/lineage_event_for_seq.py` -> job `kafka-connect/iceberg-sink`,
  input `kafka://kafka:9092/events`. The recorder's stage 4 SQL pane shows the
  join. Stage 4 re-recorded alone on the 105614 state:
  `stage4-20261008-114602.mp4` (feed: seq 38 Kafka Connect, seq 6 Spark; SQL:
  silver `_row_id` 0 seq 6 -> bronze row 490 seq 38). Slide 19 rewritten.

### Talk materials (2026-10-07)

`SLIDE-PLAN.md` (22 slides, Datadog 2026 template, real recording values,
stills table) and `DESIGN-PROMPT.md` (Claude Design build prompt, folder
linked). Slide 20 cites Lakekeeper's OpenFGA grants, verified against
docs.lakekeeper.io ("Authorization", "Authorization (OpenFGA)"). Only open
content item: slide 22's repo URL and links.

### Findings worth keeping (also citable in the talk)
- **Kafka Connect's Iceberg sink loads a custom `MetricsReporter`** from a
  subdirectory of its plugin directory, configured only through the connector
  property `iceberg.catalog.metrics-reporter-impl` -- ingest commits emit
  lineage events with no change to the sink.
- **The `spark-demo` image was never rebuilt by any stage** (profile-gated,
  started with `dc run`), so reporter changes silently didn't apply until an
  explicit `dc build`. Stages 2-5 now build it.
- **DuckDB downloads its extensions on every container start** unless baked
  into the image, and `iceberg` also pulls in `avro` -- the dashboard image
  baked three of the four and still needed internet.
- **Lakekeeper specifics:** writes gzip-compressed `*.gz.metadata.json`;
  needs a per-warehouse URL prefix (from `GET /catalog/v1/config?warehouse=`);
  turns on S3 remote signing by default (disabled in
  `docker/lakekeeper/bootstrap.sh`); deletes a dropped table's files itself,
  so Spark's `DROP TABLE ... PURGE` races it -- use plain `DROP TABLE`; an
  existing warehouse answers 400 "storage profile overlaps", not 409.
- **Spark 4.0 + Iceberg 1.11 CAN read `_row_id`** (`SELECT _row_id,
  _last_updated_sequence_number ...` in `spark-demo` returns the same values
  as DuckDB). The repo's old comments said otherwise; corrected. Flink still
  can't.
- **The pinned MinIO images can no longer be pulled** from quay.io (401).
  Backup: `~/.cache/row-level-lineage/minio-images.tar`.
- **Docker builds contact the registry for base images** even when every
  layer is cached (base images weren't in the local image store), so offline
  mode skips builds rather than trusting the cache.
- **Iceberg 1.11's Kafka Connect sink ignores write-defaults.** NOT NULL
  column with a default: the task dies on the first record without the field
  (`DataException: An error occurred converting record ... Caused by:
  java.lang.NullPointerException: Cannot invoke
  "java.lang.CharSequence.toString()" because "value" is null`), `FAILED`
  until restarted by hand. Optional column: keeps ingesting, writes `NULL`.
  Also: Spark SQL `ALTER COLUMN ... DROP NOT NULL` reported success but left
  the column required; `UpdateSchema.makeColumnOptional` works.
- **A snapshot's `schema-id` is the table schema at commit time**, not the
  schema its files were written with: Kafka Connect files written just before
  the sink picked up a new column, committed just after, still read the
  initial-default.
- **`reset` deletes `out/`** -- don't redirect a rehearsal log into it.

- **The local REST catalog lost all tables under concurrent requests.**
  preflight's `RESTCatalogServer` used `jdbc:sqlite::memory:`, where every
  pooled connection gets its own empty database. 24 parallel GETs -> HTTP 500s
  ("no such table: iceberg_tables"), then every request failed. Fixed by a
  file-backed SQLite store (`compose.catalog-persistence.yml`), merged via
  `include:` so preflight/ stays untouched.
- **Glue accepts Iceberg format-version 3 tables**, and `_row_id` /
  `_last_updated_sequence_number` / `first-row-id` behave on real S3 exactly as
  locally (Iceberg 1.11 GlueCatalog, our own Spark 4.0 container). Not tested:
  Athena reading them; EMR / Glue jobs' bundled Iceberg and Spark versions.
- **JavaScript rounds 19-digit Iceberg snapshot ids** -- the dashboard showed
  a wrong id until the server started pre-formatting event JSON.
- **Stage 4 is stronger with `demo/run-stage.sh 4 9001`**: the join then lands
  on stage 2's row (`_row_id` 0, an update) instead of a brand-new customer.

## Open items

1. Decide whether to make 9001 Stage 4's default customer (currently 9002).
2. Stage 3 isn't re-runnable without `reset`: once `channel` exists, the sink
   has nothing to evolve and the "schema count +1" check fails.
3. Stage 5's README overstates the equivalence with Flink: Spark's DELETE on
   V3 writes deletion vectors, not equality deletes; the `_row_id` churn comes
   from delete + insert being separate commits. Say "same observable effect".
4. Root `.env` comment still calls the Stage 5 table "deliberately V2" (it's V3).
5. Full rehearsal still owed: `reset` + stages 1-5 with the dashboard open,
   to see the stage-script dashboard startup and the pipeline view's
   "not committed yet" moment live.
6. AWS covers the *read* path only. Moving the stages' writes to AWS (MSK /
   MSK Connect or a Glue-catalog Kafka Connect sink, Spark on Glue) is
   unplanned work.
7. In AWS mode the read scripts must run in the `lineage-dashboard` image
   (preflight's `duckdb-demo` image has no boto3).

8. Talk outline is in `TALK-OUTLINE.md` (40 min slot: 35 content + 5 Q&A).
   Stage 3 is source-driven since 2026-10-08 (see above).

9. Demo windows: Marquez, SQL window and Lakekeeper catalog done. Optional
   step 3: live access-control demo (Lakekeeper OpenFGA + an identity
   provider) for the governance slide. Slide plan done:
   `SLIDE-PLAN.md` (Datadog 2026 template, 21 slides, capture list).

## Resume

```
demo/run-stage.sh 1          # starts everything incl. the dashboard -> http://localhost:8088
demo/run-stage.sh 2 ... 5
demo/run-stage.sh reset      # tear down again
```

AWS (optional): `aws sso login --profile your-profile`, then
`AWS_PROFILE=your-profile scripts/aws/seed_glue_tables.sh` and
`scripts/aws/seed_bronze_events.sh 300 3` recreate the bucket contents and
Glue tables -- but **the bucket itself must be recreated first** if it was
deleted (us-west-1, private, tags `project=row-level-lineage-demo`), and
`.env` already holds `LINEAGE_S3_BUCKET` / `LINEAGE_AWS_REGION` /
`LINEAGE_NAMESPACE_PREFIX=rll_`. Then see README "AWS backend" to run the
dashboard in AWS mode.

## AWS

Account `<account-id>` (profile `your-profile`), us-west-1:
bucket `row-level-lineage-demo-<account-id>-usw1` and Glue databases
`rll_bronze`, `rll_silver`, `rll_failure_demo`. **Deleted 2026-10-06**
(verified: no `rll_` databases left, bucket returns 404). Recreate with the
steps under "Resume" if AWS mode is needed again.
