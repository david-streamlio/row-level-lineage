# Claude Design revision prompt -- final demo recording (2026-10-08, take 105614)

Paste the block below into the Claude Design session that already has the
deck (after `DESIGN-REVISION-POLARIS.md`). It supersedes any earlier version
of this file. The demo was re-recorded with a new stage 3: the source adds a
field mid-stream and the Kafka Connect sink evolves the table by itself (no
more operator schema changes, defaults or VARIANT in the demo). The lineage
graph now reaches silver.customers, and stage 2 ends in the MinIO console.
`SLIDE-PLAN.md` is already updated.

---

## The prompt

```
The demo was re-recorded and its schema-evolution story changed, so update
the deck's screenshots, a few numbers, and slides 10, 12, 13 and 21.
SLIDE-PLAN.md in the linked folder is already updated and remains the
locked spec -- reread slides 6-13, 18, 19 and 21 there. Change only what's
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
  diagram/callouts to match. Feed line still reads
  "sequenceNumber=4   silver.customers   overwrite   Spark".

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

## Numbers

- Slide 6: last six commits of the streamed ingest: first-row-id
  242 / 246 / 262 / 266 / 282 / 286 with added-rows 4 / 16 / 4 / 16 / 4 / 14,
  next-row-id 300 (17 commits for 300 events).
- Slide 8 notes: 242 + 4 = 246, + 16 = 262 ... 17 commits.
- Slide 10: 185 events streamed, all 185 landed, the last 86 with channel;
  15 snapshots, all Kafka Connect appends, 0 deleted files; schemas 1 -> 2;
  task still RUNNING; before/after: 402 NULL, mobile 31, store 25, web 30.
- Slide 9 (sequence 1 / 2 / 3), 11 (0 / 1 / 2) and 19 (sequenceNumber 4 ->
  _row_id 0) are unchanged.

## Video slots

Speaker notes name the clips (I embed them): slide 7 ->
stage1-slide07-streaming-55s.mp4; slide 9 -> stage2-20261008-105614.mp4;
slide 10 -> stage3-20261008-105614.mp4; slide 19 -> stage4-20261008-105614.mp4.

## After updating

Report what changed per slide and how you cropped each still, and confirm
with a text-only pass over the on-screen content and notes that none of
these old values appear: "1727", "243 / 251", "19 commits", "250 events",
"24 snapshots", "22 Kafka Connect", "1 -> 4", "341", "212", "id 3",
"raw_payload", "ADD COLUMN channel", "093045".
```
