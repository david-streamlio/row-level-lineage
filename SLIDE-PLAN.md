# Slide plan -- Iceberg V3 Meets the Lakehouse

**Source arc:** `TALK-OUTLINE.md` (Explorer's Journey, 5 stages).
**Profile:** `DATADOG_PRESENTATION_2026` (Suggested Layout = its native slide types).
**Slot:** 40 min = 35 min content + 5 min Q&A.
**Demo:** pre-recorded end to end. "Clip" means a short segment of that
recording played inside a `Screenshot` slide. "Screenshot" means a still from
it with callouts. Values marked *(rehearsal)* come from the 2026-10-06 runs.
Re-capture them from the final recording; the demo is deterministic, so they
should match unless a stage's arguments change (e.g. stage 4 with customer 9001).

This plan replaces the "Show" lines in `TALK-OUTLINE.md`, which still
describe dashboard tabs.

Generated from `TALK-OUTLINE.md` with the `tech-slide-planner` skill
(2026-10-06), updated with the demo recording of 2026-10-08 (Polaris, take 105614). Facts come from
`PROGRESS.md`, `README.md`, the stage READMEs and the recorded runs.

**Accepted title:** "Iceberg V3 Meets the Lakehouse: Row-Level Lineage and
Schema Evolution for Streaming Data"

**Accepted abstract (verbatim, also in `ABSTRACT.md`):**

> Apache Iceberg V3 changes what's possible for Lakehouse governance -- but most discussions focus on batch scenarios. This session explores what V3 means for organizations streaming real-time data into their Lakehouse, where governance and lineage must evolve beyond batch assumptions.
>
> We'll show how Lakehouse-native streaming integrates with Iceberg V3 and REST catalogs to bring fine-grained governance to continuously ingested data. The centerpiece is row-level lineage: understanding not just which table data came from, but which specific records and transformations produced it, even as data arrives continuously. We'll also cover schema evolution patterns for streaming sources -- where schemas change without warning and pipelines can't just stop and restart.
>
> The talk introduces a Bring Your Own Lineage (BYOL) model: how to integrate your preferred lineage systems alongside your catalog without disrupting streaming pipelines. This session shows how Iceberg V3, catalog governance, and Lakehouse-native streaming deliver trustworthy, auditable data from the moment it's ingested.

**Where each promise is kept:**

| Promise | Slides |
|---|---|
| V3 changes governance; discussions are batch-only, streaming breaks batch assumptions | 2, 3, 4 |
| Lakehouse-native streaming + Iceberg V3 + REST catalogs (Apache Polaris) | 3 (defined), 6, 7, 8 |
| Fine-grained governance for continuously ingested data | 20 (catalog as control point; Apache Polaris RBAC) |
| Row-level lineage: which records and transformations produced the data, as it arrives | 6, 7, 9, 16, 18, 19 (row -> input record -> ingest commit -> topic) |
| Schema evolution for streaming sources, no stop/restart | 10, 12, 13 |
| Bring Your Own Lineage alongside your catalog, without disrupting pipelines | 15, 16, 17, 18 |
| Trustworthy, auditable data from the moment it's ingested | 19, 21 |

**Style profile: `DATADOG_PRESENTATION_2026`** -- "Suggested Layout" is that
template's native slide type. Plate types (`Cover`, `Divider`, `Subdivider`,
`Callout`) are never back to back and carry only text.

## Handoff notes for design

- **Template:** the 2026 Datadog presentation template. "Suggested Layout" on
  each slide names its native slide type (`Cover`, `Divider`, `TitleContent`,
  `Screenshot`, `FromTo`, `IdeaCards`, `BestPractices`, `ContentOneThird`,
  `ResourcesQR`). Canvas 1280x720, 73px side margins. Light content slides with
  black text; full-bleed `#5C00EF -> #9C43FE` gradient plates (white text) only
  for `Cover` / `Divider`. Roboto Bold titles, Roboto Regular body, Roboto Mono
  for code and numerals. Accents: pink `#FF0080`, green `#00B765`, blue
  `#0060FF`, cyan `#00CAFF`, orange `#FF5E00`. Sentence case, no emoji.
- **No native diagram type:** `Mermaid_Architecture` visuals (slides 2, 6, 16,
  20) are node-and-arrow diagrams built from the template's cards and hex
  icons inside a `TitleContent` / `ContentOneThird` slide.
- **Screenshots and clips come later** from the demo recording (slides 7, 8, 9,
  10, 11, 18, 19, 20): design those as framed image placeholders sized for
  a 1888x990 capture (or a crop of it), with the callouts described in each
  Spec as overlay arrows/labels. Numbers marked *(rehearsal)* are real values
  from the 2026-10-06/07 runs; keep them as written.
- **Code and log lines are verbatim:** reformat whitespace only, never change
  the text (slides 10, 12, 17).
- **Still open:** slide 22's URLs are marked `[NEEDS: ...]` -- render the cards
  without them.
- **Narrative:** five phases (Initial Compass -> Rough Terrain -> Hidden Valley
  -> Hard-Won Map -> Blazed Trail), 35 min + 5 min Q&A. "Bring Your Own
  Lineage" appears once (slide 15); the pattern is "Composable Lineage"
  everywhere else.

---

## Phase 1 -- Initial Compass (3 min)

### Slide 1 -- "Iceberg V3 Meets the Lakehouse"
**Suggested Layout:** `Cover`
**Core Message:** Row-level lineage and schema evolution, for data that never stops arriving.
**Visual Manifest:**
  - Type: `Typography_Only`
  - Spec: title "Iceberg V3 Meets the Lakehouse"; subtitle "Row-level lineage and schema evolution for streaming data"; speaker name.
**On-Screen Text:** title + subtitle only.
**Speaker Notes:** Open on the problem, not on yourself: "Every Iceberg V3 writeup I read pictured a batch job. We wanted to know what V3 does for a table that gets a new commit every two seconds." That sets up the next slide's question about which commit produced a given row.
**Time:** Initial Compass, ~0.5 min

### Slide 2 -- "Lineage today stops at the table"
**Suggested Layout:** `TitleContent`
**Core Message:** Graph-level lineage tells you which job wrote which table, not which commit produced a given row.
**Visual Manifest:**
  - Type: `Mermaid_Architecture`
  - Spec: built from `AccentCard` nodes: `job` -> `table` -> `job` -> `table` (OpenLineage-style graph). One row inside the last table is highlighted with a question mark: "which commit produced *this*?"
**On-Screen Text:** "Which commit produced this row?"
**Speaker Notes:** Most lineage tools answer one question: which job read which table and wrote which table. For batch that was enough; you re-ran the job, got the same rows, and the graph told you where to look. Point at the highlighted row and say the graph has no answer for it. Bridge: "That gap is small for batch. Streaming makes it big. Here's why."
**Time:** Initial Compass, ~2.5 min

## Phase 2 -- Rough Terrain (5 min)

### Slide 3 -- "A stream breaks three batch assumptions"
**Suggested Layout:** `IdeaCards`
**Core Message:** Continuous commits, upserts and schema drift each break something batch lineage relied on.
**Visual Manifest:**
  - Type: `Typography_Only` (three `AccentCard` + `HexIcon` cards, icons: pipeline, workflow, grid)
  - Spec: card 1 "A commit every 2 seconds" (Kafka Connect's commit interval in this demo, `iceberg.control.commit.interval-ms: 2000`); card 2 "Upserts against rows that already exist"; card 3 "Producers add fields without telling anyone". Above the cards, one definition line: "Lakehouse-native streaming: the stream lands as Iceberg commits through the catalog, continuously -- no batch ETL hop in between."
**On-Screen Text:** the definition line + the three card titles.
**Speaker Notes:** First, what I mean by lakehouse-native streaming: the stream doesn't wait for a batch job to copy it into the lakehouse; it lands as Iceberg commits through the catalog, continuously. In this demo that's Kafka through the Kafka Connect Iceberg sink. In a stream nothing waits for a nightly run. Kafka Connect commits every two seconds in this demo, CDC sinks rewrite rows that already exist, and producers change their payloads without asking. A table-level graph has no row concept, so it can't follow any of that. Bridge: "We hit all three, plus some traps we didn't expect."
**Time:** Rough Terrain, ~2 min

### Slide 4 -- "Three ways to get no row lineage at all"
**Suggested Layout:** `TitleContent`
**Core Message:** Row identity is easy to lose before you write a single row.
**Visual Manifest:**
  - Type: `Typography_Only` (three rows, each a short claim + the fact behind it)
  - Spec: (1) "Upgrade V2 -> V3: `_row_id` is `NULL`" (2) "Kafka Connect auto-create makes **V2** tables -- create V3 explicitly" (3) "Flink's Iceberg source can't project `_row_id`".
**On-Screen Text:** the three rows above.
**Speaker Notes:** These are detours we took and you can skip. Upgrading an existing table from V2 to V3 leaves `_row_id` empty, so create V3 tables from scratch. The Kafka Connect sink's auto-create produces V2, so we turned auto-create off and created the table ourselves. And Flink, the engine most of us stream with, can't even read the lineage columns. Bridge: "So where does identity come from, if the writer doesn't set it?"
**Time:** Rough Terrain, ~3 min

## Phase 3 -- Hidden Valley (11 min)

### Slide 5 -- "The writer never sets it"
**Suggested Layout:** `Divider`
**Core Message:** Row identity is assigned by Iceberg at commit, not written by the writer.
**Visual Manifest:**
  - Type: `Typography_Only`
  - Spec: title "The writer never sets it"; subtitle "Row identity in Iceberg V3".
**On-Screen Text:** title + subtitle.
**Speaker Notes:** One sentence: this is where our plan changed. Bridge straight into the mechanism.
**Time:** Hidden Valley, ~0.25 min

### Slide 6 -- "Identity is inherited at commit"
**Suggested Layout:** `TitleContent`
**Core Message:** Iceberg hands each commit a block of row ids; `first-row-id` picks up where the last commit stopped.
**Visual Manifest:**
  - Type: `Mermaid_Architecture`
  - Spec: Kafka JSON event (no `_row_id`) -> Kafka Connect writes plain Parquet -> commit -> snapshot with `first-row-id` + `added-rows` -> table `next-row-id`. Second commit continues from the first. Numbers *(Polaris recording 2026-10-08, take 105614: 300 events streamed one every 0.25 s, 17 Kafka Connect commits)*: the last six commits, sequence numbers 12-17, have `first-row-id` 242 / 246 / 262 / 266 / 282 / 286 with `added-rows` 4 / 16 / 4 / 16 / 4 / 14, so `next-row-id` = 300.
**On-Screen Text:** "`_row_id` = `first-row-id` + position"
**Speaker Notes:** Kafka Connect writes ordinary Parquet with no lineage columns. When the snapshot commits, Iceberg assigns the row ids through manifest inheritance: each commit gets a `first-row-id`, the next commit starts where it ended. So the streaming writer needs zero changes. And because identity is assigned at commit, not by the writer, this holds for any lakehouse-native streaming writer that commits through the catalog -- the Kafka Connect sink is just the one we used. Bridge: "Here it is on the stream -- recorded from the demo."
**Time:** Hidden Valley, ~2 min

### Slide 7 -- "The message has no id. The row does."
**Suggested Layout:** `Screenshot`
**Core Message:** The same event, before and after commit: the Kafka message has no `_row_id`, the Iceberg row has one.
**Visual Manifest:**
  - Type: `Typography_Only` (a framed clip, not a rendered visual)
  - Spec: clip from demo stage 1. Left: Kafka console consumer window streaming events. Right: SQL window, `SELECT * FROM bronze.events` with `_row_id`, `_last_updated_sequence_number` as the first columns. Callout arrows: one at the JSON ("no `_row_id`"), one at the `_row_id` column, matched on `event_id`.
**On-Screen Text:** callout labels only.
**Speaker Notes:** Same event, two views. The JSON on the left is exactly what the producer sent. On the right, the row in Iceberg has a `_row_id` that nobody wrote: Iceberg assigned it when the commit landed, about two seconds after the message arrived. Bridge: "And the catalog shows the bookkeeping behind it."
**Clip:** `demo/recordings/polaris/stage1-slide07-streaming-55s.mp4` (55 s, stage 1 at 74-129 s: the SQL window waits a few seconds, Kafka Connect's first commit lands as `_row_id` 0-141 at sequence number 1, then smaller commits keep adding rows while Kafka streams). End of streaming: the last Kafka message, customer 16, is the row with `_row_id` 299.
**Time:** Hidden Valley, ~2.5 min

### Slide 8 -- "One catalog, every engine"
**Suggested Layout:** `Screenshot`
**Core Message:** Kafka Connect, Spark and DuckDB share one Iceberg REST catalog -- Apache Polaris -- and it keeps the row-id counter: the next commit's `first-row-id` starts where this one ended.
**Visual Manifest:**
  - Type: `Typography_Only` (framed screenshot)
  - Spec: two stills from the Polaris recording, side by side: the Apache Polaris console's `bronze.events` page from `slide08-stage1-polaris.png` (the console fills the right half at the end of stage 1: "Format Version 3", location `s3://warehouse/polaris/bronze/events`) and the writer pane from `slide07-stage1-message-vs-row.png` (bottom right: the check reading the catalog's metadata, last six commits `first_row_id` 242 / 246 / 262 / 266 / 282 / 286, `added_rows` 4 / 16 / 4 / 16 / 4 / 14, "PASS: first_row_id advances by added_rows each commit"). Callouts: "Format Version 3" and the `first_row_id` column.
**On-Screen Text:** callouts "Format Version 3" and "first_row_id continues commit to commit".
**Speaker Notes:** This is Apache Polaris, the ASF's Iceberg REST catalog. Kafka Connect writes through it, Spark writes through it, DuckDB reads through it. The check reads the catalog's own metadata: every commit's `first-row-id` starts exactly where the previous commit's rows ended -- 242 plus 4 rows is 246, plus 16 is 262, and so on, 17 commits for 300 streamed events. We didn't take V3 support on trust: the same operations through Polaris and through Iceberg's reference catalog produced identical metadata and identical row ids. (Backup: the Lakekeeper recording shows the same counter as "Next row ID 300" in its UI, still `slide08-stage1-next-row-id.png` in `demo/recordings/stills/`.) Bridge: "Appends are easy. What happens when a row changes?"
**Time:** Hidden Valley, ~1.5 min

### Slide 9 -- "Update it three times. Same id."
**Suggested Layout:** `Screenshot`
**Core Message:** A merge-on-read `MERGE` keeps `_row_id`; only `_last_updated_sequence_number` moves.
**Visual Manifest:**
  - Type: `Typography_Only` (framed clip or still)
  - Spec: demo stage 2: writer terminal running 3 `MERGE` commits for customer 9001 (each reads a new event from `bronze.events`), SQL window after each. *(Polaris recording 2026-10-08: `_row_id` 0 at sequence numbers 1, 2, 3.)* Callouts: the constant `_row_id` column, the advancing sequence column. End of the clip: the MinIO console on `warehouse/polaris/silver/customers/data` -- Parquet data files, each with a `*-deletes.puffin` deletion vector next to it -- still `slide09-stage2-minio-deletion-vectors.png`; callout on a `-deletes.puffin` file: "deletion vector".
**On-Screen Text:** "`_row_id` 0 / 0 / 0, sequence 1 / 2 / 3"
**Speaker Notes:** `silver.customers` is merge-on-read. Each `MERGE` writes a deletion vector -- there they are in object storage, the small `-deletes.puffin` files next to the data files -- and Iceberg carries the old row's `_row_id` forward. Three updates, one identity, and the sequence number tells you which commit last touched the row. Remember this flat line; it comes back in a few minutes. Bridge: "Rows change. So do schemas, without warning."
**Time:** Hidden Valley, ~2 min

### Slide 10 -- "The source adds a field mid-stream. The stream never notices."
**Suggested Layout:** `Screenshot`
**Core Message:** When the producer starts sending a new field without warning, the Kafka Connect sink evolves the Iceberg table by itself: metadata only, no file rewritten, nothing stopped or restarted, nobody runs a DDL.
**Visual Manifest:**
  - Type: `Typography_Only` (framed clip + stills)
  - Spec: demo stage 3. Clip: Kafka window streaming at 5 events/s; 20 s in, the events gain `"channel": "web" | "mobile" | "store"`; the writer terminal reports "the Kafka Connect sink evolved bronze.events by itself: 1 -> 2 schemas"; the SQL window grows a `channel` column with values. Stills: `slide10-stage3-mid-stream.png` (Kafka JSON with `channel`; the writer's PASS line; SQL rows with `channel`), `slide10-stage3-end.png` (the proof: every snapshot since the baseline is a Kafka Connect append, 0 deleted files, schemas 1 -> 2; and the before/after table), `slide10-stage3-polaris-schema.png` (the Apache Polaris console's Schema section: "Current schema (id 1)" with `channel` string, not required). *(Polaris recording 2026-10-08, take 105614: 185 events streamed, all 185 landed, the last 86 with `channel`; 15 snapshots during the stage, all Kafka Connect appends, 0 deleted files; schemas 1 -> 2; Kafka Connect task still `RUNNING`. Before/after: 402 rows written before the field read `NULL`; after: `mobile` 31, `store` 25, `web` 30.)* Callouts: the new `"channel"` key in the JSON, "schemas: 1 -> 2", "task still RUNNING", the `channel` row in the Polaris schema.
**On-Screen Text:**
```
{"event_id": "...", "customer_id": ..., "amount": ..., "ts": "..."}                    <- first 20 s
{"event_id": "...", "customer_id": ..., "amount": ..., "ts": "...", "channel": "web"}   <- then

"iceberg.tables.evolve-schema-enabled": "true"
```
**Speaker Notes:** This is the case from the abstract: the source changes its schema without warning. Twenty seconds into the stream the producer starts sending a field called `channel` -- nobody told the pipeline. The Kafka Connect sink sees it and adds the column to the Iceberg table itself; that's one connector property. Iceberg never creates a snapshot for a schema change, so every snapshot in this list is a Kafka Connect append; nothing was deleted or rewritten, the task never restarted, and every one of the 185 events landed. Rows written before the change read NULL for the new column, and that NULL is worth a second look. Bridge: "So far, everything worked. Here's what didn't."
**Time:** Hidden Valley, ~2.75 min

## Phase 4 -- Hard-Won Map (6 min)

### Slide 11 -- "Same three updates, different writer"
**Suggested Layout:** `FromTo`
**Core Message:** The equality-delete upsert most CDC sinks use throws identity away; the table format isn't the problem.
**Visual Manifest:**
  - Type: `Bar_Comparison`
  - Spec: From: stage 2, position-delete `MERGE`, customer 9001, `_row_id` 0 / 0 / 0. To: stage 5, equality delete + insert, customer 9500, `_row_id` 0 / 1 / 2 at sequence numbers 2 / 4 / 6 *(Polaris recording 2026-10-08)*. Both tables are V3 created from scratch. The "To" half hosts the clip `stage5-slide11-churn-24s.mp4` (24 s: the three rounds, `_row_id` 0 -> 1 -> 2, then the POINT line); the "From" half stays static (slide 9 already played stage 2). Poster image: `slide11-stage5-churn.png`.
**On-Screen Text:** "Deletion vector: 0, 0, 0 -- Equality delete: 0, 1, 2"
**Speaker Notes:** Same three updates, same V3 table setup. On the left, the deletion-vector `MERGE` from earlier: flat. On the right, delete-then-insert: a new `_row_id` every time, because an equality delete has no positional link to the row it replaces. This is the same observable effect as Flink's equality-delete upsert (`BaseEqualityDeltaWriter`) and most CDC sinks; say "same effect", not "identical", since the demo reproduces it with Spark. The writer you pick decides whether you get lineage. Bridge: "And the writer decides one more thing: your defaults."
**Time:** Hard-Won Map, ~2 min

### Slide 12 -- "Defaults are only as good as the writer"
**Suggested Layout:** `FromTo`
**Core Message:** V3 column defaults could fill those NULLs, but Iceberg 1.11's Kafka Connect sink ignores write-defaults: a NOT NULL column with a default kills it, an optional one gets NULL.
**Visual Manifest:**
  - Type: `Bar_Comparison`
  - Spec: (slides only, not in the recording.) From: `channel` NOT NULL with a default -> the sink's task dies on the first record without the field, until restarted by hand. Log line: `java.lang.NullPointerException: Cannot invoke "java.lang.CharSequence.toString()" because "value" is null`. To: `channel` optional with the same default -> the sink keeps ingesting, writes `NULL`. Small print: V3's `initial-default` (what existing rows read) and `write-default` (what new rows get if the writer applies it); Spark's `INSERT ... DEFAULT` applies it, the sink doesn't. Tie-in from slide 10: the sink adds a new field as an optional column with no default, so the 402 earlier rows read `NULL`.
**On-Screen Text:** "NOT NULL + default: sink task FAILED -- optional + default: NULL"
**Speaker Notes:** Back to those NULLs. Iceberg V3 has column defaults: an `initial-default` that every existing row reads, and a `write-default` for new rows. We tried it while building the schema-change stage, adding the column ourselves with a default. Make it required, and the Kafka Connect sink dies on the very next record, because it doesn't fill in the default; it stays dead until someone restarts it by hand. That's exactly the "pipelines can't just stop" case. Make it optional and the stream keeps flowing, but the sink writes NULL. Spark applies the default; the sink doesn't. So check what your writers do with defaults before you rely on them. Bridge: "Here's the short list of what we'd tell ourselves on day one."
**Time:** Hard-Won Map, ~1.5 min

### Slide 13 -- "What we'd tell ourselves on day one"
**Suggested Layout:** `BestPractices`
**Core Message:** Four rules keep row identity intact in a streaming pipeline.
**Visual Manifest:**
  - Type: `Typography_Only` (2x2 hex-icon grid)
  - Spec: (1) "Create V3 from scratch" -- never upgrade V2 -> V3 for lineage. (2) "Deletion vectors keep identity" -- equality deletes churn it. (3) "Read lineage with Spark or DuckDB" -- Flink's Iceberg source can't project `_row_id`; Spark 4.0 + Iceberg 1.11 and DuckDB both return it. (4) "Let the sink evolve the schema; keep new columns optional" -- `iceberg.tables.evolve-schema-enabled=true` adds new source fields as optional columns, metadata-only. Defaults need the table API (Iceberg 1.11's Spark SQL rejects `ADD COLUMN ... DEFAULT`: "setting default values in Spark is currently unsupported"; use `UpdateSchema.addColumn(name, type, default)`), and keep any column optional unless every writer applies defaults (the Kafka Connect sink doesn't).
**On-Screen Text:** the four headings.
**Speaker Notes:** Walk the four quickly; each one cost us time. On (3): verified 2026-10-06, `SELECT _row_id, _last_updated_sequence_number ...` in Spark 4.0 + Iceberg 1.11 returns the same values as DuckDB. Bridge: "And a few things that bit us in the plumbing."
**Time:** Hard-Won Map, ~1.5 min

### Slide 14 -- "Plumbing that bit us"
**Suggested Layout:** `TitleContent`
**Core Message:** Small infrastructure details can quietly corrupt a lineage demo, or a lineage pipeline.
**Visual Manifest:**
  - Type: `Typography_Only` (short list, footnote-sized detail)
  - Spec: (1) in-memory SQLite REST catalog: 24 parallel GETs -> HTTP 500 `no such table: iceberg_tables`; file-backed store fixed it. (2) JavaScript rounds 19-digit snapshot ids; format them server-side. (3) Catalogs differ in the plumbing: Lakekeeper (our backup catalog) deletes a dropped table's files itself, so Spark's `DROP TABLE ... PURGE` races it. (4) Kafka Connect's Iceberg sink has no native OpenLineage support; one catalog property adds it (next phase).
**On-Screen Text:** four one-line items.
**Speaker Notes:** War stories, fast. The first one is the best: the catalog forgot every table under a burst of parallel requests, because each pooled connection got its own empty in-memory database. Point (4) is the bridge: "No native lineage from the sink. That's where Bring Your Own Lineage comes in."
**Time:** Hard-Won Map, ~1 min

## Phase 5 -- Blazed Trail (10 min)

### Slide 15 -- "Bring Your Own Lineage"
**Suggested Layout:** `Divider`
**Core Message:** Keep your lineage system; join it to row identity on one key.
**Visual Manifest:**
  - Type: `Typography_Only`
  - Spec: title "Bring Your Own Lineage"; subtitle "Composable Lineage, joined on one key".
**On-Screen Text:** title + subtitle.
**Speaker Notes:** "The abstract calls this Bring Your Own Lineage. From here on I'll call the pattern Composable Lineage." The only use of "BYOL" in the deck.
**Time:** Blazed Trail, ~0.25 min

### Slide 16 -- "Two models, one key: sequenceNumber"
**Suggested Layout:** `TitleContent`
**Core Message:** OpenLineage knows jobs and datasets, Iceberg knows rows; Iceberg's commit `sequenceNumber` joins them.
**Visual Manifest:**
  - Type: `Mermaid_Architecture`
  - Spec: Kafka Connect and Spark -> catalog (Apache Polaris) with `metrics-reporter-impl` -> `OpenLineageMetricsReporter` -> collector -> Marquez (graph). Separately: Iceberg table rows with `_last_updated_sequence_number`. A join arrow labeled `sequenceNumber = _last_updated_sequence_number`.
**On-Screen Text:** "`sequenceNumber` = `_last_updated_sequence_number`"
**Speaker Notes:** OpenLineage has no row concept; Iceberg has no job concept. They share one field. Every Iceberg commit produces a `CommitReport` with `tableName`, `snapshotId`, `sequenceNumber` and `operation`; we forward it as an OpenLineage event. Take the `sequenceNumber`, filter rows on `_last_updated_sequence_number`, and you have exactly the rows that commit produced. Bridge: "Here's all the code it takes."
**Time:** Blazed Trail, ~2 min

### Slide 17 -- "One extension point, one property"
**Suggested Layout:** `TitleContent`
**Core Message:** A `MetricsReporter` on the catalog turns every commit, from any writer, into a lineage event.
**Visual Manifest:**
  - Type: `Code_Block`
  - Spec: excerpt of `docker/spark-demo/reporter/.../OpenLineageMetricsReporter.java` plus the connector property (below).
**On-Screen Text:**
```java
public class OpenLineageMetricsReporter implements MetricsReporter {
  @Override
  public void report(MetricsReport report) {
    if (!(report instanceof CommitReport)) {
      return;
    }
    CommitReport commit = (CommitReport) report;
    // POST an OpenLineage RunEvent: tableName, snapshotId,
    // sequenceNumber, operation -> your lineage backend
```
```
"iceberg.catalog.metrics-reporter-impl":
    "com.demo.lineage.OpenLineageMetricsReporter"
```
**Speaker Notes:** Iceberg calls `report()` after every commit; we keep only `CommitReport`. The same jar runs in Spark and in Kafka Connect. For Connect it's one connector property, no change to the sink itself. That's what "without disrupting streaming pipelines" means here. And it emits standard OpenLineage events, so any OpenLineage backend can take them -- we show Marquez, the reference implementation; that's the "bring your own" part. Bridge: "Now the graph has the ingest leg too."
**Time:** Blazed Trail, ~1.5 min

### Slide 18 -- "The graph now starts at the topic"
**Suggested Layout:** `Screenshot`
**Core Message:** Ingest commits show up in the lineage graph, each run carrying its `sequenceNumber`.
**Visual Manifest:**
  - Type: `Typography_Only` (framed screenshot)
  - Spec: Marquez graph, as in still `slide18-19-stage4-end.png` (right half): dataset `events` (Kafka topic) -> job `iceberg-sink` (Kafka Connect) -> dataset `bronze.events` -> job `lake.silver.customers.commit` (Spark `MERGE`) -> dataset `silver.customers`, with the Spark job `lake.bronze.events.commit` also writing `bronze.events`. Inset: a run's `iceberg_commit` facet with `sequenceNumber` highlighted.
**On-Screen Text:** callout "sequenceNumber".
**Speaker Notes:** This is Marquez, the OpenLineage reference UI, fed by the reporter. The topic, the Kafka Connect job, the bronze table, the `MERGE` and the silver table are one connected graph, from the stream all the way to the curated table. Open a run and there's the `sequenceNumber`. Bridge: "So let's use it."
**Time:** Blazed Trail, ~1.5 min

### Slide 19 -- "From a lineage event to the exact rows -- and back to the stream"
**Suggested Layout:** `Screenshot`
**Core Message:** The `sequenceNumber` in a lineage event selects exactly the rows that commit produced -- and one hop back, the input record and the Kafka Connect commit that brought it in from the topic.
**Visual Manifest:**
  - Type: `Typography_Only` (framed clip)
  - Spec: demo stage 4 (`stage4-20261008-114602.mp4`, still `slide18-19-stage4-end.png`). A new event for customer 9001 streams in through Kafka; Kafka Connect commits it to `bronze.events`; a Spark `MERGE` folds it into `silver.customers`. Lineage feed (top left), two lines: `sequenceNumber=38   bronze.events      append      Kafka Connect` and `sequenceNumber=6    silver.customers   overwrite   Spark`. SQL window (bottom left) joins the silver row to the bronze event it points at (`last_event_id`): `_row_id` 0, `seq` 6, customer 9001, `bronze_row_id` 490, `bronze_seq` 38. *(Polaris recording 2026-10-08. Writer output, not in the clip: the lineage event for `bronze.events` at sequenceNumber 38 is job `kafka-connect/iceberg-sink`, input `kafka://kafka:9092/events`.)* Callouts: `seq` 6 <-> the feed's `sequenceNumber=6` line; `bronze_seq` 38 <-> the feed's `sequenceNumber=38` line.
**On-Screen Text:**
```
WHERE _last_updated_sequence_number = <sequenceNumber>     -- the rows a commit produced
silver row -> last_event_id -> bronze row -> its commit -> Kafka topic
```
**Speaker Notes:** Graph event on top, rows underneath, joined on one number: the `MERGE` was sequenceNumber 6, and that selects silver row 0, the same row stage 2 updated. Now walk it back. The silver row says which event fed it; that event is bronze row 490, last written at sequence number 38 -- and the feed has a line for 38: Kafka Connect, reading the `events` topic. So from one row in a curated table we got to the exact input record, the commit that ingested it, and the topic it came from. Nothing in the streaming pipeline changed to make this work. That's the "auditable from the moment it's ingested" claim. Bridge: "Which raises the governance question: who controls all this?"
**Time:** Blazed Trail, ~2 min

### Slide 20 -- "The catalog is the control point"
**Suggested Layout:** `ContentOneThird`
**Core Message:** Every commit goes through the catalog, so the catalog is where streaming data is governed from its first commit -- including who may read or write it.
**Visual Manifest:**
  - Type: `Mermaid_Architecture`
  - Spec: gradient side panel: "Every commit goes through the catalog". Content, top: three items -- schema history, snapshot history (who wrote each commit), the lineage hook (`metrics-reporter-impl` is a catalog property). Content, bottom: Apache Polaris's RBAC chain as a small diagram: `privileges -> catalog role -> principal role -> principal`, applied to securable objects `catalog / namespace / table / view`, with example table privileges as chips: `TABLE_READ_DATA`, `TABLE_WRITE_DATA`, `TABLE_LIST`, `TABLE_CREATE`. Screenshot strip: still `slide20-polaris-access-control.png` (the console's "Users & Access Control" page: Principals / Principal Roles / Catalog Roles / Privileges; the demo's one principal, `root`, with role `service_admin`).
**On-Screen Text:**
  - "Schema history, snapshot history, the lineage hook"
  - "Privileges -> catalog roles -> principal roles -> principals"
  - "This demo: one admin principal for every client"
**Speaker Notes:** Kafka Connect and Spark both commit through the catalog, and the lineage hook is configured on the catalog, not per job. Access control lives in the same place. In Apache Polaris, privileges such as `TABLE_READ_DATA` and `TABLE_WRITE_DATA` are granted to catalog roles, catalog roles to principal roles, and principal roles to principals; the securable objects are the catalog, namespaces, tables and views. The honest moment, on the screenshot: "Every client in this demo connects as the bootstrap admin, `root`. In production, Kafka Connect gets write privileges on its tables and your analysts get read." (Source: Apache Polaris docs, "Role-Based Access Control"; not demonstrated beyond the screenshot.) Backup (Lakekeeper recording): Lakekeeper's OpenFGA grants (`describe`, `select`, `modify`, `create`, `manage_grants`, `pass_grants`, `ownership`, inherited warehouse -> namespace -> table) and its red "Authentication is OFF" banner. Bridge: "Here's the whole thing as a checklist."
**Time:** Blazed Trail, ~1.25 min

### Slide 21 -- "The blueprint"
**Suggested Layout:** `TitleContent`
**Core Message:** Seven steps get you row-level lineage on a streaming table, minus our detours.
**Visual Manifest:**
  - Type: `Typography_Only` (numbered list, mono for properties)
  - Spec: 1 create tables as format-version 3 from scratch (connector auto-create off); 2 `write.delete.mode / update.mode / merge.mode = merge-on-read`; 3 upsert through deletion-vector `MERGE`, not equality deletes; 4 set `metrics-reporter-impl` on the catalog, emit `sequenceNumber` to your lineage backend; 5 join `WHERE _last_updated_sequence_number = <event.sequenceNumber>`; 6 schema drift: `iceberg.tables.evolve-schema-enabled=true` lets the sink add new fields as optional columns, metadata-only; `VARIANT` for fields nobody modeled; defaults only where every writer applies them; 7 pick a V3-capable REST catalog and test it (Apache Polaris and Lakekeeper passed; Nessie doesn't support V3).
**On-Screen Text:** the seven steps, one line each.
**Speaker Notes:** The slide people photograph. Read the steps, don't explain them again. On step 7: "Test your catalog's V3 support; some rewrite metadata themselves." Bridge: "Everything's in the repo."
**Time:** Blazed Trail, ~1 min

### Slide 22 -- "Run it yourself"
**Suggested Layout:** `ResourcesQR`
**Core Message:** The whole demo runs on a laptop; take it.
**Visual Manifest:**
  - Type: `Resource_Links`
  - Spec: QR panel -> demo repo `[NEEDS: public repo URL -- this folder isn't a git repo yet]`. Resource cards: Apache Iceberg V3 spec (row lineage) `[NEEDS: URL]`, Apache Polaris `[NEEDS: URL]`, Marquez / OpenLineage `[NEEDS: URL]`.
**On-Screen Text:** card titles + URLs.
**Speaker Notes:** One line, then open Q&A.
**Time:** Blazed Trail, ~0.5 min

---

**Total: 35 min across 22 slides (target: 35 min content + 5 min Q&A = 40 min).**
Per phase: 3 + 5 + 11 + 6 + 10 = 35, matching the outline. 22 is above the
skill's ~14-18 guideline for 35 minutes, but 4 of them are quick beats (cover,
2 dividers, closing); 18 carry content.

Rhythm check: plate slides are 1 (`Cover`), 5 and 15 (`Divider`). None are
adjacent, and all three are `Typography_Only`.

## Recorded clips and stills (2026-10-08, take 105614)

**Primary: Apache Polaris** (ASF catalog) -- `demo/recordings/polaris/`:
`stage1..3,5-20261008-105614.mp4` + `stage4-20261008-114602.mp4` (stage 4
re-recorded alone with the trace back to the source; 1888x990 / 1888x976 /
1888x1002; 141 s, 53 s, 70 s, 41 s, 40 s), recorded with per-stage layouts (only the windows each slide needs,
18 pt, pinned title bars), stage 1 streaming one event every 0.25 s, the
Polaris console taking the right half at the end of stages 1 and 3, MinIO
full frame at the end of stage 2, Marquez on the right through stage 4; plus
`stage1-slide07-streaming-55s.mp4` (stage 1, 74-129 s) and
`stage5-slide11-churn-24s.mp4` (stage 5, 9-33 s). Stage 3 is
source-driven: the producer adds `channel` mid-stream and the sink evolves
the table. Stills in `demo/recordings/polaris/stills/`:

| Slide | Still |
|---|---|
| 7 | `slide07-stage1-message-vs-row.png` -- Kafka pane + SQL pane (last message, customer 16 = `_row_id` 299) + writer's first_row_id check |
| 8 | `slide08-stage1-polaris.png` -- Polaris console `bronze.events` (right half), Format Version 3; pair with the writer pane of the slide 7 still |
| 9 | `slide09-stage2-flat-row-id.png` -- writer + SQL, customer 9001, `_row_id` 0 at seq 3; `slide09-stage2-minio-deletion-vectors.png` -- MinIO, `silver/customers/data`: Parquet files + `*-deletes.puffin` |
| 10 | `slide10-stage3-mid-stream.png` -- Kafka JSON with `channel`, "sink evolved bronze.events by itself: 1 -> 2 schemas", SQL rows with `channel`; `slide10-stage3-end.png` -- proof (15 Kafka Connect appends, 0 deleted files, schemas 1 -> 2) + before/after table (402 NULL / mobile 31 / store 25 / web 30); `slide10-stage3-polaris-schema.png` -- Polaris console Schema: id 1, `channel` string |
| 11 | `slide11-stage5-churn.png` -- writer + SQL, customer 9500, `_row_id` 2 after 3 rounds |
| 12 | none (slides only) |
| 18, 19 | `slide18-19-stage4-end.png` -- lineage feed (seq 38 Kafka Connect, seq 6 Spark) + SQL (silver `_row_id` 0 seq 6 -> bronze row 490 seq 38) (left), Marquez graph `events -> iceberg-sink -> bronze.events -> lake.silver.customers.commit -> silver.customers` (right) |
| 20 | `slide20-polaris-access-control.png` -- Polaris console, Users & Access Control |

**Backup: Lakekeeper** -- `demo/recordings/` (`stage1-20261007-172448.mp4`,
`stage2..5-20261007-162318.mp4`) and `demo/recordings/stills/`: same stages,
plus Lakekeeper's "Next row ID 300" view and red "Authentication is OFF"
banner. Its stage 3 numbers differ (257 / 257 events, 24 snapshots = 22 + 2,
`channel` 341 / 219 / 2) and its stage 1 is one 300-row commit; the rest matches.

Values marked *(rehearsal)* on slide 11 match both recordings. The Lakekeeper backup recording predates the source-driven stage 3 and the silver lineage edge: its stage 3 is the operator version (defaults + `VARIANT`).

## Capture list for the recording

| Slide | Capture | Windows | When |
|---|---|---|---|
| 7 | clip + still | Kafka consumer + SQL window (`bronze.events`) | stage 1, while events stream |
| 8 | still | catalog console `bronze.events` + writer pane check C | right after stage 1 |
| 9 | clip + 2 stills | writer terminal + SQL window (customer 9001); MinIO `silver/customers/data` | stage 2 |
| 10 | clip + 3 stills | Kafka consumer (field appears) + writer terminal + SQL; final proof output; catalog console schema | stage 3 |
| 11 | still | SQL window (customer 9500) | stage 5 |
| 12 | none | slides only (the NPE log line goes on the slide as text) | -- |
| 18 | 2 stills | Marquez graph + a run's facets | after stage 4 |
| 19 | clip + still | lineage feed terminal + SQL window | stage 4 (`demo/run-stage.sh 4 9001`) |
| 20 | still | Polaris console Access Control page (headless screenshot) | any time |

Before recording: `demo/run-stage.sh reset`.

## Open items from this plan

1. Repo URL and resource links (slide 22).
