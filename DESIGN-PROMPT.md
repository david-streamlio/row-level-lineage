# Claude Design build prompt -- Iceberg V3 Meets the Lakehouse

Paste the block below into Claude Design with this folder
(`row-level-lineage/`) linked. Same structure and rules as fleet-trilogy's
`docs/TALK3-DECK-BUILD-PROMPT.md` (rules 1-5 exist because an earlier first
pass put planning-doc artifacts on rendered slides). Reflects `SLIDE-PLAN.md`
as of 2026-10-07: 22 slides, demo recorded, stills in `demo/recordings/stills/`.

---

## The prompt

```
You are building presentation slides for "Iceberg V3 Meets the Lakehouse:
Row-Level Lineage and Schema Evolution for Streaming Data" (40-minute slot:
35 min of content + 5 min Q&A) from the linked folder.

Use these files:
- SLIDE-PLAN.md -- the locked content spec. Follow it exactly. Do not
  improve, embellish, or summarize it; it is not a starting point for your
  own rewrite. Read its "Handoff notes for design" section first.
- TALK-OUTLINE.md and ABSTRACT.md -- narrative context only. Where they
  disagree with SLIDE-PLAN.md, the slide plan wins (the outline's "Show" lines
  are outdated).
- demo/recordings/polaris/stills/*.png -- real screenshots from the recorded
  demo (the Apache Polaris recording; it's the primary version). The slide
  plan's "Recorded clips and stills" table says which still goes on which
  slide. Ignore demo/recordings/stills/ (the Lakekeeper backup recording).
Ignore everything else in the folder (code, Docker files, scripts, logs).

## Non-negotiable rules

1. Never render planning-doc syntax as slide content. `[NEEDS: ...]` tags
   are instructions to YOU, not text for the audience. If the sentence works
   without the tag, drop the tag. If it marks something that can't be left
   out, render a presentable version (see "Specifics" below) and flag it in
   your summary. "NEEDS:", "[Insert", "TODO", "*(rehearsal)*", "*(recording
   ...)*" and bracketed placeholders must never appear as visible text.

2. File references belong in speaker notes only. Never put a file path, a
   `.md` / `.png` / `.mp4` filename, or a script name on screen. Copy each
   slide's Speaker Notes into the slide's speaker notes verbatim, including
   any file references.

3. Add no claim, number, title, subtitle, or tagline that isn't in the plan.
   Every on-screen number must appear in that slide's On-Screen Text or
   Visual Manifest exactly as written: 300, 299, 0 / 0 / 0 at sequence
   numbers 1 / 2 / 3, 0 / 1 / 2 at 2 / 4 / 6, 272 streamed / 272 landed, 27
   snapshots (25 Kafka Connect + 2 Spark), schemas 1 -> 4, 341 / 234 / 2,
   sequenceNumber 4 -> _row_id 0, first_row_id 0 / added_rows 300, 7
   blueprint steps. Don't
   round, convert, or recompute.

4. Terminology is fixed: the catalog is "Apache Polaris" (ASF), and the
   pattern is "Composable Lineage". "Bring Your
   Own Lineage" appears exactly once, as slide 15's title, and "BYOL" never
   on screen. Stage 5 reproduces Flink's equality-delete upsert with Spark:
   say "same effect as Flink", never "identical". Keep "_row_id",
   "_last_updated_sequence_number", "sequenceNumber" and "first-row-id"
   spelled exactly so, in monospace.

5. Match the structure exactly: 22 slides, numbered and ordered as in the
   plan, in its five phases. Plate slides are 1 (Cover), 5 and 15 (Divider)
   and carry text only; never put two plates back to back. Add no slides (no
   agenda, no "about me", no extra Q&A or thank-you slide) without flagging
   it.

6. Visual system: the 2026 Datadog presentation design system -- use it from
   your workspace if available; otherwise follow the tokens in the plan's
   handoff notes (1280x720, 73px margins, light content slides with black
   text, the #5C00EF -> #9C43FE gradient ONLY on plates, Roboto / Roboto
   Mono, accents pink #FF0080 / green #00B765 / blue #0060FF / cyan #00CAFF /
   orange #FF5E00, sentence case, no emoji). Use each slide's "Suggested
   Layout" as its slide type. Don't introduce a new theme.

## Specifics

- Screenshots are real. Place the named still on slides 7, 8, 9, 10, 11, 12,
  18, 19 and 20, framed, never redrawn or mocked up. Each still is the whole
  recorded screen (five panes); crop to the pane(s) the slide's Spec is
  about (e.g. slide 9: the SQL pane; slide 18: the Marquez graph; slide 7:
  the Kafka pane next to the SQL pane). Slide 20's Access Control still is a
  single-window screenshot -- use it whole. Add the callouts the Spec lists as
  overlay arrows and short labels in an accent color. Slide 8: crop the
  Polaris console pane and the writer pane's first_row_id check side by side.
- Video. Slides 7, 9, 10 and 19 also have a recorded clip. Use the still as
  the poster frame of a clearly framed video slot with a small neutral
  caption ("Video: stage 1", "Video: stage 2", "Video: stage 3", "Video:
  stage 4"); name the clip file in the speaker notes only. I'll embed the
  clips myself.
- Code and log lines are verbatim: slide 10's SQL, slide 12's
  NullPointerException line, slide 17's Java excerpt and connector property.
  Same lines, comments, names; whitespace and syntax highlighting only.
- Diagrams are native. Build the Mermaid_Architecture manifests (slides 2, 6,
  16, 20) as clean node-and-arrow diagrams from the design system's cards and
  hex icons, with labels from the Spec. Never show Mermaid source.
- Comparisons (slides 11 and 12, FromTo): left = before / the losing
  writer, right = after / the other case, with the numbers from the Spec.
- Slide 20: the three governance items, the small RBAC chain (privileges ->
  catalog role -> principal role -> principal) over catalog / namespace /
  table / view, the four privilege names as monospace chips exactly as
  listed (TABLE_READ_DATA, TABLE_WRITE_DATA, TABLE_LIST, TABLE_CREATE), and
  the Polaris Access Control screenshot. Don't add privilege names or
  features beyond these.
- Slide 22 (ResourcesQR): the repo URL and resource links aren't final.
  Render the resource cards with their titles only and an empty, clearly
  framed QR panel captioned "Repo link". No placeholder text. Flag it.

## After generating

Do a text-only pass over every slide's on-screen content (not the speaker
notes) and confirm none of these appear: "NEEDS:", "[Insert", "TODO",
"rehearsal", "recording 2026", "BYOL", any file path or filename, any
bracketed placeholder, "identical" next to Flink. Confirm 22 slides with
plates exactly at 1, 5 and 15. Then report every slide where you made a
judgment call instead of a literal transcription, the stills you used per
slide and how you cropped them, and the list of empty video / QR slots.
```
