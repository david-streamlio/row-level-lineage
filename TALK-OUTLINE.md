# Talk outline -- Iceberg V3 Meets the Lakehouse

**Accepted title:** Iceberg V3 Meets the Lakehouse: Row-Level Lineage and
Schema Evolution for Streaming Data

**Arc:** Explorer's Journey (pivot). Lineage built for batch tracks a graph of
tables. Streaming breaks the batch assumptions, so the talk moves to row
identity in the table format, then joins it back to the graph tool you
already run.

**Length:** 40 min slot = 35 min content + 5 min Q&A.

## Abstract coverage

| # | Abstract promise | Where it lands | How |
|---|---|---|---|
| 1 | V3 changes governance; discussion is batch-only | Stage 1-2 | Slides |
| 2 | Lakehouse-native streaming + V3 + REST catalog | Stage 3 + 5 | Recorded: demo stage 1 (Kafka -> Connect -> REST catalog -> V3 table); slide: catalog as the governance control point |
| 3 | Row-level lineage, records + transformations, continuous | Stage 3 + 5 | Recorded: demo stages 1, 2, 4 |
| 4 | Schema evolution, no stop/restart | Stage 3 | Recorded: demo stage 3 with events still flowing |
| 5 | Bring Your Own Lineage | Stage 5 | Title says BYOL once; pattern is named Composable Lineage. Recorded: demo stage 4 + blueprint slides |
| 6 | Trustworthy, auditable from ingest | Stage 5 close | Slide tying stage 1 (identity at commit) to stage 4 (join) |

---

## Stage 1 -- Initial Compass: "Lineage is a graph of tables. Done?"
**Time:** ~3 min (9% of 35)
**Say:** Most lineage tooling we run today answers one question: which job
read which table and wrote which table. For batch that was enough. You re-ran
the job, you got the same rows, and the table-level graph told you where to
look. Iceberg V3 arrived, and nearly every writeup about it pictures a batch
job. We wanted to know what it does for data that never stops arriving.
**Show:** Diagram: job -> table -> job -> table (an OpenLineage-style graph),
with one question mark over a single row: "which commit produced *this*?"

## Stage 2 -- Rough Terrain: "Streaming breaks every batch assumption"
**Time:** ~5 min (14%)
**Say:** A stream gives you commits every couple of seconds, upserts against
rows that already exist, and producers who add fields without telling
anyone. A table-level graph can't tell you which rows a given commit
touched, and it has no row concept at all. Then the detours: if you upgrade
an existing table from V2 to V3, `_row_id` comes back NULL. Flink's Iceberg
source can't project `_row_id`, so the engine most of us stream with can't
even read the lineage. Each of these cost us time, and each one now has a
rule in the blueprint at the end.
**Show:** Three-panel slide: "commits every 2 s" / "upserts" / "schema
drift". Then a detours slide:
- V2 -> V3 upgrade: `_row_id` is `NULL`
- Flink's Iceberg source can't project `_row_id`
- Kafka Connect auto-create produces **V2**; create the table explicitly as V3

## Stage 3 -- Hidden Valley: "Identity is inherited at commit, not written by the writer"
**Time:** ~11 min (31%)
**Say:** This is where it turned. Kafka Connect's Iceberg sink writes plain
Parquet with no lineage columns at all. Iceberg assigns `_row_id` itself when
the snapshot commits, through manifest inheritance. So the streaming writer
needs zero changes. Each commit's `first-row-id` picks up exactly where the
previous one stopped. Update a row through a merge-on-read `MERGE` and the
deletion vector carries the same `_row_id` forward; only
`_last_updated_sequence_number` moves. And when a producer adds a field
without warning, the Kafka Connect sink evolves the table itself: metadata
only, no data files rewritten, no snapshot for the change, nothing to
restart, nobody runs a DDL.
**Show (live):**
1. `demo/run-stage.sh 1` -> dashboard **Pipeline** view (`p`): raw Kafka JSON
   next to the same event in `bronze.events`, matched on `event_id`. The JSON
   has no `_row_id`; the Iceberg row does. Messages not committed yet say so
   (Connect commits every 2 s). Then tab `1`: `first-row-id` continuing commit
   to commit.
2. `demo/run-stage.sh 2` -> tab `2`: `_row_id` of customer 9001 across 3
   `MERGE`s, a flat line. `[NEEDS: captured _row_id / sequence numbers for the slide backup; PROGRESS.md notes 9001 sits at _row_id 0]`
3. `demo/run-stage.sh 3`: events stream into Kafka at 5/s; 20 s in, the
   producer starts sending a new field, `"channel"`. The sink
   (`iceberg.tables.evolve-schema-enabled=true`) adds the column itself, as
   optional with no default; rows from before read `NULL`.
   Proof (recording 2026-10-08, take 105614): 185 events streamed, all
   landed, the last 86 with `channel`; 15 snapshots during the stage, all
   Kafka Connect appends, 0 deleted files; schemas 1 -> 2; Kafka Connect task
   still `RUNNING`.

## Stage 4 -- Hard-Won Map: "What we got wrong"
**Time:** ~6 min (17%)
**Say:** Here's the one that hurts. The most-deployed streaming upsert,
the equality delete that Flink's `BaseEqualityDeltaWriter` and most CDC sinks
use, throws identity away. The table fully supports row lineage, and
`_row_id` still changes on every update, because an equality delete has no
positional link to the row it replaces. Put that next to the flat line from
a minute ago. The writer you pick decides whether you get lineage, not
the table format version.
**Show:** Dashboard tab `5` (pre-run before the talk): stage 2's flat line
next to customer 9500's churning `_row_id`, on one shared scale. Then lessons:
- Create V3 from scratch; never upgrade V2 -> V3 for lineage
- Position deletes / deletion vectors keep identity; equality deletes churn it
- Read lineage with Spark or DuckDB, never Flink
- Iceberg 1.11 Spark SQL can't `ADD COLUMN ... DEFAULT`; use the table API
  (`UpdateSchema.addColumn(name, type, default)`, `updateColumnDefault`)
- Iceberg 1.11's Kafka Connect sink ignores write-defaults: a NOT NULL column
  with a default kills its task (`NullPointerException` converting the
  record, task `FAILED` until restarted by hand); an optional one gets `NULL`.
  (Found building an earlier, operator-driven stage 3; slides only now.)
  Keep new columns optional unless every writer applies defaults.
- Infra footnote: the local REST catalog on `jdbc:sqlite::memory:` lost every
  table under 24 parallel GETs (`no such table: iceberg_tables`); file-backed
  SQLite fixed it
- Footnote: JavaScript rounds 19-digit snapshot ids; format them server-side

Wording: say "same observable effect as Flink", not "identical". Spark's
DELETE on V3 writes deletion vectors; the churn comes from delete + insert
being separate commits (PROGRESS.md open item 3).

## Stage 5 -- Blazed Trail: "Bring Your Own Lineage: Composable Lineage, joined on one key"
**Time:** ~10 min (29%)
**Say:** The abstract calls this Bring Your Own Lineage; from here on I'll
call the pattern Composable Lineage. You don't have to swap out your lineage system. OpenLineage knows
jobs and datasets; Iceberg knows rows. They share one field:
`sequenceNumber`. We hooked Iceberg's own `MetricsReporter` extension point,
so every commit emits a `CommitReport` with `tableName`, `snapshotId`,
`sequenceNumber` and `operation`. We forward it as an OpenLineage `RunEvent`.
Take the `sequenceNumber` from any event, filter on
`_last_updated_sequence_number`, and you get exactly the rows that
transformation produced. Nothing in the streaming pipeline changed to make
that work. That's what auditable from ingest means here: identity assigned at
commit, joined to the graph tool you already have.
**Show (slide, ~2 min) -- "The catalog is the control point":** every
commit, from Kafka Connect or Spark, goes through the catalog, and the lineage
hook is a catalog property (`metrics-reporter-impl`), not a job setting. So the
catalog is where streaming data gets governed from its first commit: one place
for schema history, snapshot history (who wrote each commit), and the lineage
emitter. Same pattern locally (REST catalog) and on AWS (Glue accepts V3).
`[NEEDS: which access-control / policy features to cite for "fine-grained
governance" -- e.g. your catalog's table/column permissions -- speaker to
supply; nothing in the repo demonstrates policies]`

**Show (live):** `demo/run-stage.sh 4 9001` -> tab `4`: newest lineage event,
its `sequenceNumber`, and the rows it selects. The join lands on stage 2's
row (`_row_id` 0). Click an older event in the feed to join that one instead.
Then the blueprint slide:
1. Create tables as format-version 3 from scratch (disable connector
   auto-create)
2. `write.delete.mode / update.mode / merge.mode = merge-on-read`
3. Upsert through position-delete `MERGE`, not equality deletes
4. Set `metrics-reporter-impl` on the catalog -> emit `sequenceNumber` to your
   lineage backend
5. Join: `WHERE _last_updated_sequence_number = <event.sequenceNumber>`
6. Schema drift: `iceberg.tables.evolve-schema-enabled=true` (sink adds new
   fields as optional columns, metadata-only); `VARIANT` for unmodeled fields;
   defaults only where every writer applies them
7. Catalog choice: REST catalog locally; AWS Glue accepts V3 tables too
   (read path verified; Athena not tested)

```
metrics-reporter-impl = com.demo.lineage.OpenLineageMetricsReporter
```
`[NEEDS: a short code excerpt of the reporter for the slide]`

**Total: 3 + 5 + 11 + 6 + 10 = 35 min, + 5 min Q&A = 40.**

---

## Recorded demo vs slides

The demo is **recorded end to end** before the talk (no venue Wi-Fi risk) and
played back in segments. Screenshots from the recording go on slides, with
callouts (e.g. an arrow on `_row_id` in the feed) to steer attention.

It's recorded as separate single-purpose windows, not the dashboard:

| Window | Shows | Command / URL |
|---|---|---|
| Kafka topic | raw events streaming in, no `_row_id` | `docker exec -it lineage-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic events` |
| Lineage feed (terminal) | one line per commit with `sequenceNumber` | `docker logs -f lineage-openlineage-collector` |
| Lineage graph | `events` topic -> `kafka-connect/iceberg-sink` -> `bronze.events`; Spark jobs; run facet with `sequenceNumber` | Marquez, http://localhost:3000 |
| Row lineage SQL | `_row_id`, `_last_updated_sequence_number` first; always the current snapshot | `demo/sql.sh` |
| Catalog | format v3, snapshots, last sequence number, Next row ID, schema history (Versioning tab) | Lakekeeper UI, http://localhost:8282/ui (red "Authentication is OFF" banner -- crop or mention) |
| Storage | files per commit under `lakekeeper/bronze/events-<uuid>/`; schema change adds only a metadata file | MinIO console, http://localhost:9001 |
| Writer terminal | the stage commands / Spark SQL `MERGE`, `ALTER` | `demo/run-stage.sh N` |

| Content | Format | Why |
|---|---|---|
| Demo stage 1: Kafka window + catalog, `first-row-id` continuing | **Recording** | Shows the streaming + REST catalog claim |
| Demo stage 2: `MERGE` x3, SQL window shows flat `_row_id` | **Recording** | Sets up the stage 5 contrast |
| Demo stage 3: the source adds a field mid-stream, the sink evolves the table, events keep flowing | **Recording** | Not re-runnable without `reset` (open item 2) |
| Demo stage 4: Marquez run's `sequenceNumber` -> SQL `WHERE _last_updated_sequence_number = N` | **Recording** | The climax |
| Demo stage 5: churning `_row_id` | **Recording or screenshot** | Negative result; can be one annotated slide |
| Key frames (raw event vs row with `_row_id`, flat vs churning line, graph) | **Annotated screenshots** | Steer attention; survive playback problems |
| Batch vs streaming framing | Slides | Concept |
| Manifest inheritance / `first-row-id` mechanics | Slides (diagram) | Too slow to show from metadata files |
| Detours: V2 upgrade, Flink, Spark SQL DEFAULT gap | Slides | Failures nobody needs to watch |
| Catalog SQLite bug, JS id rounding | Slide footnote | Good war stories, off the main line |
| Glue / AWS | Slide | Infra torn down; only the read path verified |
| Catalog as governance control point | Slide | Abstract promise; no policy demo exists |
| Blueprint + reporter code | Slides | Audience photographs it |
| Live Flink | Not shown | Spec paragraph in demo/05 README covers it as a slide |

Note: the stage sections above still describe dashboard tabs under "Show";
they get rewritten for these windows in the slide plan.

## Decided (2026-10-06)

- BYOL appears once, in the stage 5 title, to match the abstract; the pattern
  is called Composable Lineage everywhere else.
- Governance promise: covered by a catalog slide (abstract can't change),
  citing Lakekeeper's OpenFGA grants (describe / select / modify / create /
  manage_grants / pass_grants / ownership, inherited warehouse -> namespace ->
  table); not demonstrated -- the demo runs with authentication off.
- Stage 3 shows ingestion continuing across the schema changes (built and
  rehearsed 2026-10-07); `channel` is optional because the Kafka Connect sink
  ignores defaults (slide 12 in SLIDE-PLAN.md).
- 2026-10-08: stage 3 is source-driven to match the abstract -- the producer
  adds `channel` mid-stream and the sink evolves the table; defaults and
  `VARIANT` are slides only (12, 13, 21).
- Slot: 40 min, 35 content + 5 Q&A.
- Demo is recorded end to end and played back; annotated screenshots go on
  slides. Recorded as separate windows (table above), not the dashboard.
- Lineage graph: Marquez, fed by both Kafka Connect and Spark (built and
  verified 2026-10-06).

## Still open

1. Stage 4 default customer: use 9001 (PROGRESS.md open item 1).
2. Recording session: `reset` first (test commits are in the current data).
3. Remaining open item: slide 22's repo URL and links. `SLIDE-PLAN.md` is the
   current plan (22 slides); `DESIGN-PROMPT.md` is the Claude Design prompt.
