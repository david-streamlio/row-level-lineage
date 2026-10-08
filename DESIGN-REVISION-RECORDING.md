# Claude Design revision prompt -- final demo recording (2026-10-08, take 105614)

Paste the block below into the Claude Design session that already has the
deck (after `DESIGN-REVISION-POLARIS.md`). It supersedes any earlier version
of this file. Stage 4 was re-recorded alone (take 114602) to trace a silver row
back to its Kafka input, and slide 3 now defines lakehouse-native streaming.
The demo was re-recorded with a new stage 3: the source adds a
field mid-stream and the Kafka Connect sink evolves the table by itself (no
more operator schema changes, defaults or VARIANT in the demo). The lineage
graph now reaches silver.customers, and stage 2 ends in the MinIO console.
`SLIDE-PLAN.md` is already updated.

---

## The prompt

```
The demo was re-recorded and its schema-evolution story changed, so update
the deck's screenshots, a few numbers, and slides 3, 10, 12, 13, 19 and 21.
SLIDE-PLAN.md in the linked folder is already updated and remains the
locked spec -- reread slides 3, 6-13, 17, 18, 19 and 21 there. Change only what's
listed; keep everything else, all the original rules (no placeholders or
file names on screen, numbers exactly as written, code verbatim), 22 slides,
plates at 1, 5 and 15.

## Screenshots

Every still in demo/recordings/polaris/stills/ has a new image. Re-import
them on slides 7, 8, 9, 10, 11, 18, 19 (slide 20's still is unchanged).
Changes to the file set:
- NEW slide09-stage2-minio-deletion-vectors.png
- NEW slide10-stage3-end.png
- REMOVED slide10-12-stage3-end.png (slide 12 has no screenshot any more)
Each still shows 2-3 large windows with a purple title bar -- crop to the
pane(s) each slide is about and keep the title bars in the crop:
- Slide 7: Kafka pane (left) next to the SQL pane (top right). The last
  Kafka message and the row with _row_id 299 are both customer 16.
- Slide 8: Polaris console from slide08-stage1-polaris.png (right half:
  "Format Version 3") + writer pane from slide07-stage1-message-vs-row.png
  (bottom right: the first_row_id check). Callouts unchanged.
- Slide 9: writer + SQL pane from slide09-stage2-flat-row-id.png, plus the
  new MinIO still (Parquet data files, each with a "-deletes.puffin" file
  next to it) with a callout on one "-deletes.puffin" file: "deletion vector".
- Slide 10: new title and story (see below). Stills:
  slide10-stage3-mid-stream.png (Kafka JSON now carrying "channel"; the
  writer's "evolved bronze.events by itself: 1 -> 2 schemas" line; SQL rows
  with a channel column), slide10-stage3-end.png (the proof list + the
  before/after table), slide10-stage3-polaris-schema.png ("Current schema
  (id 1)" with the channel string row). Callouts: the "channel" key in the
  JSON, "schemas: 1 -> 2", "task still RUNNING", the channel row in Polaris.
- Slide 11: unchanged layout, new still image.
- Slides 18 and 19: lineage feed (top left) + SQL (bottom left), Marquez
  graph (right). The graph is now one chain: events -> iceberg-sink ->
  bronze.events -> lake.silver.customers.commit -> silver.customers (plus
  lake.bronze.events.commit writing bronze.events). Redraw slide 18's
  diagram/callouts to match. The feed now has two lines --
  "sequenceNumber=38   bronze.events   append   Kafka Connect" and
  "sequenceNumber=6   silver.customers   overwrite   Spark" -- and the SQL
  pane joins the silver row to its input event: _row_id 0, seq 6, customer
  9001, bronze_row_id 490, bronze_seq 38. Slide 19 callouts: seq 6 <-> the
  feed's sequenceNumber=6 line, bronze_seq 38 <-> the sequenceNumber=38 line.

## Story changes

- Slide 10: title "The source adds a field mid-stream. The stream never
  notices." Replace the old ADD COLUMN / write-default / VARIANT code block
  with the two JSON lines and the connector property from SLIDE-PLAN.md
  (verbatim). Speaker notes as in the plan.
- Slide 12: same title and From/To, but it is now slides-only (no
  screenshot, drop the 'web' / NULL / 'mobile' counts). It opens from slide
  10's NULLs: V3 defaults could fill them, but the sink ignores
  write-defaults. Speaker notes as in the plan.
- Slide 13: rule 4 is now "Let the sink evolve the schema; keep new columns
  optional" (detail in the plan).
- Slide 21: step 6 reworded (evolve-schema-enabled, VARIANT for unmodeled
  fields, defaults only where every writer applies them).
- Slide 3: add the one-line definition of lakehouse-native streaming above
  the three cards (text in the plan); notes as in the plan.
- Slides 6 and 17: speaker notes only (any writer that commits through the
  catalog; any OpenLineage backend).
- Slide 19: new title "From a lineage event to the exact rows -- and back to
  the stream", new core message, two-line on-screen code block, notes as in
  the plan: the row, its input record, the commit that ingested it, the
  topic.

## Numbers

- Slide 6: last six commits of the streamed ingest: first-row-id
  242 / 246 / 262 / 266 / 282 / 286 with added-rows 4 / 16 / 4 / 16 / 4 / 14,
  next-row-id 300 (17 commits for 300 events).
- Slide 8 notes: 242 + 4 = 246, + 16 = 262 ... 17 commits.
- Slide 10: 185 events streamed, all 185 landed, the last 86 with channel;
  15 snapshots, all Kafka Connect appends, 0 deleted files; schemas 1 -> 2;
  task still RUNNING; before/after: 402 NULL, mobile 31, store 25, web 30.
- Slide 19: sequenceNumber 6 -> silver _row_id 0 (customer 9001), its
  input event = bronze _row_id 490 at sequenceNumber 38 (Kafka Connect,
  topic events).
- Slides 9 (sequence 1 / 2 / 3) and 11 (0 / 1 / 2) are unchanged.

## Video slots

Speaker notes name the clips (I embed them): slide 7 ->
stage1-slide07-streaming-55s.mp4; slide 8 (optional, before the stills) ->
stage1-slide08-catalog-20s.mp4; slide 9 -> stage2-20261008-105614.mp4;
slide 10 -> stage3-20261008-105614.mp4; slide 11 -> stage5-slide11-churn-24s.mp4
(in the "To" half of the FromTo layout; the "From" half stays static);
slide 19 -> stage4-20261008-114602.mp4 (stage 4 was re-recorded alone).

## After updating

Report what changed per slide and how you cropped each still, and confirm
with a text-only pass over the on-screen content and notes that none of
these old values appear: "1727", "243 / 251", "19 commits", "250 events",
"24 snapshots", "22 Kafka Connect", "1 -> 4", "341", "212", "id 3",
"raw_payload", "ADD COLUMN channel", "093045", "sequenceNumber=4".
```
