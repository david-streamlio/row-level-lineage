# Row-Level Lineage -- Staged Conference Demo

Five deterministic, independently runnable stages proving Apache Iceberg
V3 row lineage (`_row_id`, `_last_updated_sequence_number`) works end-to-end
-- and where it breaks. Built on top of `preflight/`, a working harness
(Kafka KRaft + Kafka Connect Iceberg sink + MinIO + Iceberg REST catalog +
DuckDB) that is kept **untouched**; the root `docker-compose.yml` reuses it
via Compose's `include:` directive and adds a Spark 4.0 image with a custom
Composable Lineage reporter plus a lightweight event collector.

The demo's catalog is switchable (`scripts/use-catalog.sh polaris|lakekeeper|rest`):
**Apache Polaris** (ASF; the primary version for the talk, with its console UI),
**Lakekeeper** (the backup, with a UI that shows snapshots and Next row ID), or
preflight's reference REST server. All three passed the V3 round trip
(`scripts/lakekeeper/v3_roundtrip.sh [--candidate polaris]`). See "Catalog (Lakekeeper)"
and "Catalog (Apache Polaris)".

## Prerequisites

- Docker + Docker Compose v2.20+ (for `include:`; this repo was built/tested
  against Compose v5.5.1)
- `jq`, `python3` on the host
- If your Docker CLI is configured with credential helpers you don't want
  touched, export `DOCKER_CONFIG` to an isolated directory before running
  anything here.

## Guardrails baked into every stage

- Iceberg **1.11.0+**, version printed at the start of every stage.
- `write.format.default=parquet` everywhere.
- Every demo table is created as **V3 from scratch** -- never a V2->V3
  upgrade (that path leaves `_row_id` `NULL`). The one deliberate exception
  is Stage 05's unwritten V2 reference table; see its README.
- Row lineage is read via **DuckDB or Spark only, never Flink** (Flink's
  Iceberg source can't project `_row_id`).
- `rewrite_manifests` is never called. If compaction is ever shown, only
  `rewrite_data_files` is used.
- The term is **"Composable Lineage"** -- never "BYOL" -- throughout.

## Working offline

The local demo needs no internet once prepared, and never touches AWS unless
`LINEAGE_BACKEND=aws` (default `local`).

```
scripts/offline-prep.sh          # while ONLINE: build + pull every image, back up MinIO
scripts/offline-prep.sh --check  # anywhere, offline too: verify, change nothing
```

- **Offline mode** (`LINEAGE_OFFLINE` in `.env`): `auto` (default) probes
  Docker Hub once per run (3 s); `1` forces offline, `0` online. Offline, the
  stage scripts skip image builds and run on the images already built.
  Bind-mounted code (`scripts/`, `sql/`, `dashboard/`) still changes live;
  edits to the reporter or collector need one rebuild back online.
- **Rebuilds:** the Dockerfiles keep downloads (Maven dependencies, Iceberg
  jars, pip) in layers that only re-run when versions or `pom.xml` change; a
  reporter source edit or a `CATALOG_*` switch only re-runs steps that run
  with no network (`RUN --network=none`). Builds still contact the registry for
  their base images, which is why offline mode skips them.
- **No runtime downloads:** DuckDB's extensions are baked into `duckdb-demo`
  and `lineage-dashboard`; Spark's and Kafka Connect's jars are in their images.
- **UIs offline:** Marquez works but falls back to a serif font (its fonts
  come from Google); Lakekeeper loses its home-page logo. Record the demo
  online for the proper look.
- **MinIO image backup:** the pinned `quay.io/minio` tags can no longer be
  pulled (HTTP 401, 2026-10-07). `offline-prep.sh` saves them to
  `~/.cache/row-level-lineage/minio-images.tar`; restore with `docker load -i`.
- **AWS seed scripts** refuse to run in offline mode.

## Run sequence

```
demo/run-stage.sh 1   # Ingest / row identity
demo/run-stage.sh 2   # Mutation with deletion vectors
demo/run-stage.sh 3   # Schema evolution at the source (sink evolves the table)
demo/run-stage.sh 4   # Composable Lineage (correlation join)
demo/run-stage.sh 5   # Failure mode (closer)

demo/run-stage.sh reset   # stop everything, wipe state, start clean next time
```

Each stage is independently runnable and idempotent against a running stack
(they `dc up -d` only what they need), but the intended narrative order is
1 -> 5. Run `reset` between full rehearsals for a guaranteed-clean start.

| Stage | Directory | Proves |
|---|---|---|
| 01 | `demo/01-ingest/` | Identity is inherited at commit, not materialized |
| 02 | `demo/02-mutation/` | Identity survives mutation only on the DV (position-delete) path |
| 03 | `demo/03-schema-evolution/` | The producer adds a field mid-stream; the Kafka Connect sink evolves the table itself -- metadata-only, zero rewrites, no restart |
| 04 | `demo/04-composable-lineage/` | Graph-level lineage + row-level identity, joined on one key |
| 05 | `demo/05-failure-mode/` | Equality-delete upsert (Flink's default pattern) churns identity |

## Live dashboard

Every stage starts `lineage-dashboard` and prints its URL:
**http://localhost:8088** (port set by `DASHBOARD_PORT_HOST` in `.env`). It's a
read-only page for projecting to the audience while stages run in a terminal.
It updates every 2 seconds and needs no internet (no web fonts or CDN
scripts). Keys: `p` pipeline, `b` browse tables, `1`-`5` stages, `t` light/dark.

Two views show the data itself:

- **Pipeline** (the landing page): Kafka topic -> Kafka Connect -> Iceberg
  table -> DuckDB with live status, then the newest raw Kafka messages next to
  the same events in `bronze.events`, matched on `event_id` -- the JSON has no
  `_row_id`, the Iceberg row does. Messages Connect hasn't committed yet say
  so (it commits every 2 s).
- **Tables**: every table in the catalog, with its rows (paged, `_row_id` and
  `_last_updated_sequence_number` first), snapshot history (who wrote each
  commit: Kafka Connect or Spark) and schema. "Rows it last changed" on a
  snapshot filters the rows to that commit.

The numbered stage tabs are the guided path; each links to the data behind it.

| Tab | Shows |
|---|---|
| 1 Ingest | `bronze.events` format version, and each commit's `first-row-id` continuing from the previous one |
| 2 Mutation | `_row_id` of customer 9001 at every snapshot -- a flat line |
| 3 Schema evolution | snapshot / data-file / schema / metadata-file counts with changes since a resettable baseline, plus column defaults |
| 4 Composable lineage | the newest lineage event, its `sequenceNumber`, and the rows that number selects. Click any event in the feed to join that one instead |
| 5 Failure mode | stage 2's flat line next to customer 9500's churning `_row_id`, on one shared scale |

Customer keys come from the stage scripts' defaults; override with
`?s2=<customer_id>&s5=<customer_id>` in the URL. Tip: `demo/run-stage.sh 4 9001`
makes stage 4's join land on the same row as stage 2 (`_row_id` 0), not on a
newly inserted customer.

The dashboard and the stage read scripts share `scripts/lineage_backend.py`,
selected by `LINEAGE_BACKEND` in `.env`: `local` (MinIO + REST catalog,
default) or `aws` (S3 + Glue Data Catalog; credentials from the AWS credential
chain, never `.env`).

## Recording the demo

```
demo/record-demo.sh --teardown          # reset, then record stages 1-5, one clip each
demo/record-demo.sh 3 --no-reset        # re-record one stage on the current state
```

Same approach as fleet-trilogy's `deploy/record-talk3-demo.sh`: windows placed
on the **external display**, one ffmpeg capture of it, each shown window's
content cropped onto a black canvas. Clips go to `demo/recordings/stage<N>-<timestamp>.mp4`
(raw captures kept as `.raw-*`).

Each stage shows only the 2-3 windows its slides need, in half-screen slots at
18 pt (legible from the back of the room); the others wait on the laptop
screen, which isn't recorded:

| Stage | Windows (left / right) | Slides |
|---|---|---|
| 1 | Kafka topic / SQL + writer (the catalog console takes the writer's slot at the end) | 7, 8 |
| 2 | writer / SQL | 9 |
| 3 | Kafka topic / writer + SQL | 10, 12 |
| 4 | lineage feed / SQL + Marquez | 18, 19 |
| 5 | writer / SQL | 11 |

Every terminal has a pinned purple title bar (`demo/record-windows/header.sh`,
repainted at each stage's window size). The browser is one Chrome app window,
moved between slots and pages over the DevTools protocol (`cdp.mjs`) rather
than relaunched; for the Polaris console it signs in off screen first. Stage 4
runs with customer 9001. Window scripts: `demo/record-windows/`.

- Needs: an external display, Google Chrome, ffmpeg; Screen Recording,
  Automation and (to place Chrome exactly) Accessibility permission for the
  terminal running it. Record online (Marquez fonts).
- Don't use the external display while it records (~10 min for all stages).
- Stills for slides: `ffmpeg -ss <sec> -i clip.mp4 -frames:v 1 still.png`.
- `--teardown` stops only the recorder's own commands in the windows it opened,
  then closes them; Terminal keeps closed windows in its scripting list
  (invisible) -- harmless.

## Row-lineage SQL window

```
demo/sql.sh                                   # interactive DuckDB prompt
demo/sql.sh "SELECT * FROM silver.customers WHERE customer_id = 9001;"
```

Every catalog table is a view under its own name (`bronze.events`,
`silver.customers`, ...) with `_row_id` and `_last_updated_sequence_number` as
the first columns on V3 tables. The views are re-pointed at each table's
current `metadata.json` before every statement, so a query typed right after
a commit sees it without restarting. `.tables` lists tables, `.quit` exits.
DuckDB because it starts in about 2 s. Spark 4.0 + Iceberg 1.11 can read the
row-lineage columns too (`SELECT _row_id ... FROM silver.customers` in
`spark-demo` returns the same values); Flink can't.

The DuckDB images (`duckdb-demo`, `lineage-dashboard`) have DuckDB's
`httpfs`, `avro`, `iceberg` and `aws` extensions baked in, so reads work
without internet (DuckDB otherwise downloads them on every container start).
Stage 01's verification runs preflight's `verify_duckdb.py` in `duckdb-demo`
for the same reason.

## Lineage graph (Marquez)

**http://localhost:3000** (port set by `MARQUEZ_WEB_PORT_HOST` in `.env`).
Marquez 0.51.1 (the OpenLineage reference server + web UI) starts with
`openlineage-collector`, which forwards every event to it in the background
and keeps its terminal summary and `out/openlineage/events.jsonl` as the
fallback (`docker logs -f lineage-openlineage-collector`).

Both writers emit events through the same `OpenLineageMetricsReporter`:

- **Kafka Connect** (`compose.connect-lineage.yml` puts the jar in the Iceberg
  sink's plugin directory; Stage 01's connector config sets
  `iceberg.catalog.metrics-reporter-impl`): job `kafka-connect / iceberg-sink`,
  input `kafka://kafka:9092 / events`, output `bronze.events`.
- **Spark** (`spark-demo`): job `row-level-lineage-demo / lake.<table>.commit`,
  output the table it committed to. The MERGEs read literals, so no inputs.

Dataset names drop the writer's catalog name (`iceberg.` in Connect, `lake.`
in Spark) and share the namespace `OPENLINEAGE_DATASET_NAMESPACE`, so both
writers land on one `bronze.events` node. Each run carries the
`iceberg_commit` facet (`tableName`, `snapshotId`, `sequenceNumber`,
`operation`). Connect's events keep its `iceberg.` table names in that facet,
so the dashboard (`lake.*` only) and Stage 04's lookup don't see them.

The Marquez images are amd64-only and run under emulation on Apple silicon
(~650 MB for the three containers). `reset` wipes Marquez's database too.

## AWS backend (S3 + Glue)

The read path (dashboard + `scripts/read_row_lineage.py` / `table_stats.py`)
also runs against real S3 and the Glue Data Catalog. Verified 2026-10-06 in
your AWS account: Glue accepts Iceberg **format-version 3** tables
written by Iceberg 1.11's `GlueCatalog`, and `_row_id` /
`_last_updated_sequence_number` / `first-row-id` behave exactly as locally.

Resources (us-west-1, tagged `project=row-level-lineage-demo`):

- bucket `row-level-lineage-demo-<account-id>-usw1` (private, SSE-S3)
- Glue databases `rll_bronze`, `rll_silver`, `rll_failure_demo` -- the
  `rll_` prefix is `LINEAGE_NAMESPACE_PREFIX`, so the dashboard's `bronze`
  maps to `rll_bronze`

Seed (or add more commits to) the three demo tables, then add ~300 events to
`rll_bronze.events` (3 commits, same generator as local Stage 01):

```
aws sso login --profile your-profile
AWS_PROFILE=your-profile scripts/aws/seed_glue_tables.sh
AWS_PROFILE=your-profile scripts/aws/seed_bronze_events.sh 300 3
```

Both append on every run. On AWS the pipeline view shows Kafka and Kafka
Connect as not used, since Spark writes these tables directly.

Run the dashboard in AWS mode. Credentials are temporary and come from your
shell, never `.env`; re-export after `aws sso login` when they expire:

```
eval "$(aws configure export-credentials --profile your-profile --format env)"
LINEAGE_BACKEND=aws docker compose up -d --force-recreate lineage-dashboard
```

Each dashboard only lists lineage events from its own catalog (`lake.*`
locally, `glue.*` on AWS), since both share `out/openlineage/events.jsonl`.

Not covered yet: the stages themselves still write locally (Kafka Connect and
`spark-demo`'s `lake` catalog point at MinIO); only the seed script writes to
Glue. In AWS mode, run the read scripts in the `lineage-dashboard` image --
preflight's `duckdb-demo` image has no `boto3`.

Remove everything (irreversible):

```
export AWS_PROFILE=your-profile AWS_REGION=us-west-1
for db in rll_bronze rll_silver rll_failure_demo; do aws glue delete-database --name $db; done
aws s3 rb s3://row-level-lineage-demo-<account-id>-usw1 --force
```

## Catalog (Lakekeeper)

Every demo client -- `spark-demo`'s `lake` catalog, the Kafka Connect sink,
DuckDB reads, the dashboard -- uses the catalog in `CATALOG_*` (`.env`):
Lakekeeper v0.13.6, warehouse `demo` under `s3://warehouse/lakekeeper/`.

- **UI:** http://localhost:8282/ui -- namespaces, tables, format version,
  snapshots, `Next row ID`, schema history (Versioning), files. It shows a red
  "Authentication is OFF" banner: the demo runs without auth.
- **Why Lakekeeper:** it writes table metadata with its own (Rust)
  implementation, so it had to pass `scripts/lakekeeper/v3_roundtrip.sh`
  first: the same V3 operations on Lakekeeper and on the reference catalog
  produce identical metadata (format-version, `next-row-id`, per-snapshot
  `first-row-id`, defaults, `variant`) and identical `_row_id` values, and
  Kafka Connect's commits chain `first-row-id` correctly. Nessie has no V3
  support.
- **Setup** (`docker/lakekeeper/bootstrap.sh`, run by `lakekeeper-bootstrap`):
  no STS, no remote signing (clients use their own MinIO keys, as with the
  reference server); folders `lakekeeper/<namespace>/<table>-<uuid>/`.
- **Differences to know:** Lakekeeper needs a warehouse prefix in REST paths
  (`lineage_backend.py` and `lib.sh` read it from `/v1/config?warehouse=`);
  metadata files are gzip-compressed (`*.gz.metadata.json`); a dropped table's
  files are deleted by Lakekeeper itself -- use plain `DROP TABLE`, not
  `PURGE`.
- **Fallback:** swap in the commented `CATALOG_*` block in `.env` (preflight's
  `iceberg-rest`), then `demo/run-stage.sh reset` and re-run the stages.
  `iceberg-rest` starts anyway (Kafka Connect depends on it in preflight's
  compose file) and sits idle.

## Catalog (Apache Polaris)

Apache Polaris 1.8.0 (`polaris`, `polaris-bootstrap`, `polaris-console`;
REST at http://localhost:8383/api/catalog, console at http://localhost:8484).
In-memory: `reset` or a restart starts it empty and `docker/polaris/bootstrap.sh`
recreates catalog `demo` on MinIO (`s3://warehouse/polaris/`, no credential
vending). Every client authenticates with OAuth client credentials
(`CATALOG_CREDENTIAL` = the bootstrap principal `root`). The console is built
from apache/polaris-tools at a pinned commit (no published image); CORS is on
for it. It shows tables (format version, locations, properties) and RBAC
(principals, roles, privileges), not snapshots -- the recorder logs in through
the DevTools protocol (`cdp.mjs login`) and navigates in-app.

V3 round trip vs the reference catalog: all checks pass; the only difference
is a `created-at` table property Polaris adds.

## Catalog persistence (reference REST server)

`compose.catalog-persistence.yml` is merged onto preflight's compose file via
`include:` and points the REST catalog's JDBC store at a SQLite file on a named
volume. preflight's default (`jdbc:sqlite::memory:`) gives every pooled
connection its own empty database, so any burst of concurrent catalog requests
returned HTTP 500 and could leave the catalog with no tables at all. `reset`
still wipes the catalog together with the warehouse.

## Stage 05 note

Stage 05 runs as a **scripted, deterministic contrast** (Spark
`DELETE`+`INSERT` reproducing the observable effect of Flink's
`BaseEqualityDeltaWriter` equality-delete upsert), not live Flink -- this is
the fallback the original spec explicitly allows for this stage. See
`demo/05-failure-mode/README.md` for the full rationale and the spec
paragraph describing what a live Flink version would look like.

## Repo layout

```
preflight/          the working pre-flight harness -- untouched
docker-compose.yml   includes preflight's stack, adds spark-demo + openlineage-collector
.env                 root config; mirrors preflight/.env plus demo-only vars
docker/duckdb-demo/  DuckDB reader image with extensions baked in (works offline)
docker/spark-demo/   Spark 4.0 + Iceberg 1.11 runtime + custom MetricsReporter jar
docker/openlineage-collector/   stdlib-only HTTP sink for lineage events
dashboard/           live demo dashboard: read-only API (server.py) + static page
compose.catalog-persistence.yml  file-backed reference REST catalog store (see above)
docker/lakekeeper/   Lakekeeper bootstrap (terms + "demo" warehouse)
scripts/lakekeeper/  V3 round-trip test: Lakekeeper vs reference catalog
compose.connect-lineage.yml      lineage reporter for Kafka Connect (see "Lineage graph")
sql/                 DDL/ALTER for silver.customers, schema evolution, failure tables
scripts/             shared bash helpers + DuckDB/verification python scripts,
                     incl. lineage_backend.py (local vs AWS catalog/S3 access)
demo/                one directory per stage, plus run-stage.sh
```
