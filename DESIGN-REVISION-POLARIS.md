# Claude Design revision prompt -- switch to Apache Polaris

Paste the block below into Claude Design to update the deck it already built
from `DESIGN-PROMPT.md` / `SLIDE-PLAN.md`. The demo's catalog changed from
Lakekeeper to Apache Polaris (ASF) on 2026-10-07 and the demo was re-recorded;
`SLIDE-PLAN.md` is already updated. This prompt lists exactly which slides
change, so the rest of the deck stays as it is.

---

## The prompt

```
Update the existing "Iceberg V3 Meets the Lakehouse" deck for one change:
the demo's Iceberg REST catalog is now Apache Polaris (an ASF project)
instead of Lakekeeper, and the demo was re-recorded with it. SLIDE-PLAN.md
in the linked folder is already updated and remains the locked spec; this
prompt only tells you which slides to touch.

Change ONLY the slides listed below. Keep every other slide, the slide
count (22), the order, the plates (1, 5, 15), the design system and all
speaker notes not mentioned here exactly as they are. All rules from the
original build still apply: no "[NEEDS: ...]" or "(rehearsal)" /
"(recording ...)" text on screen, no file names or paths on screen, numbers
exactly as written in the plan, nothing added that the plan doesn't say.

## New screenshots

Use the stills in demo/recordings/polaris/stills/ (the Polaris recording)
for every screenshot slide. Replace each screenshot that came from
demo/recordings/stills/ (the Lakekeeper recording, now the backup) -- same
crops and callouts as before unless a slide below says otherwise:
- Slide 7: slide07-stage1-message-vs-row.png
- Slide 8: slide08-stage1-polaris.png (see slide 8 below)
- Slide 9: slide09-stage2-flat-row-id.png
- Slide 10: slide10-stage3-mid-stream.png, slide10-12-stage3-end.png
- Slide 11: slide11-stage5-churn.png
- Slide 12: slide10-12-stage3-end.png
- Slides 18 and 19: slide18-19-stage4-end.png
- Slide 20: slide20-polaris-access-control.png (new; see slide 20 below)
No Lakekeeper screen may remain anywhere in the deck: no Lakekeeper logo,
no red "Authentication is OFF" banner, no "Next row ID" panel.

## Slide-by-slide changes

- Slide 8 -- rebuild from the plan. New title "One catalog, every engine".
  Crop two panes of the still side by side: the Apache Polaris console's
  bronze.events page (callout "Format Version 3") and the writer pane's
  check (callout "first_row_id 0, added_rows 300"). Replace the speaker
  notes with the plan's new slide 8 notes.
- Slide 10 -- numbers in the callouts/notes: 272 events streamed, all 272
  landed; 27 snapshots (25 Kafka Connect + 2 Spark), all appends, 0 deleted
  files; schemas 1 -> 4; Kafka Connect task still RUNNING. (Was 257 / 24 =
  22 + 2.)
- Slide 12 -- stage 3 result: 'web' 341, NULL 234, 'mobile' 2. (NULL was
  219.)
- Slide 14 -- item (3) now reads as in the plan: "Catalogs differ in the
  plumbing: Lakekeeper (our backup catalog) deletes a dropped table's files
  itself, so Spark's DROP TABLE ... PURGE races it."
- Slide 16 -- in the diagram, the catalog node is "Apache Polaris" (was
  Lakekeeper).
- Slides 18 and 19 -- new still only; the Marquez namespace shown is
  iceberg://polaris/demo. Text unchanged.
- Slide 20 -- rebuild from the plan. Keep the top three governance items.
  Replace the OpenFGA content with Apache Polaris RBAC: a small chain
  "privileges -> catalog role -> principal role -> principal" over
  catalog / namespace / table / view, and exactly four privilege chips in
  monospace: TABLE_READ_DATA, TABLE_WRITE_DATA, TABLE_LIST, TABLE_CREATE.
  Use slide20-polaris-access-control.png whole (a single-window
  screenshot), replacing the red banner strip. On-screen lines exactly:
  "Schema history, snapshot history, the lineage hook" /
  "Privileges -> catalog roles -> principal roles -> principals" /
  "This demo: one admin principal for every client". Replace the speaker
  notes with the plan's new slide 20 notes. Don't add privilege names or
  features beyond these.
- Slide 21 -- step 7 now reads "pick a V3-capable REST catalog and test it
  (Apache Polaris and Lakekeeper passed; Nessie doesn't support V3)".
- Slide 22 -- the resource cards are "Apache Iceberg V3 spec (row
  lineage)", "Apache Polaris" and "Marquez / OpenLineage" (Lakekeeper card
  removed). Still titles only and an empty QR panel captioned "Repo link".

Terminology: say "Apache Polaris" in full on first mention on a slide.
Never call Lakekeeper the demo's catalog; it may appear only in slide 14
item (3) and in speaker notes as the backup.

## After updating

Report: each slide you changed and what changed, every still you swapped
and its crop, and confirm by a text-only pass over the on-screen content
that "Lakekeeper" appears only on slide 14, that "OpenFGA", "Authentication
is OFF", "Next row ID", "257", "219" and "22 Kafka Connect" appear nowhere,
and that the deck still has 22 slides with plates at 1, 5 and 15.
```
