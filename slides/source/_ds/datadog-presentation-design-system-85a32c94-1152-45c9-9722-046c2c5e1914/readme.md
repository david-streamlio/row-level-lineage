# Datadog Presentation Design System

Everything in this system was extracted from one source file:

- `uploads/2026_Datadog Presentation Template for Claude (1) (1).pptx` — the official **2026 Datadog corporate presentation template** (31 sample slides, 41 slide layouts, 1 slide master). Copied to `uploads/template.pptx` for programmatic reading.

No codebase, Figma file, or web property was provided. Colours, gradients, type sizes, geometry, shadows, radii, logo vectors, icon vectors, background plates and chart plates below are all read out of that `.pptx` XML — not from memory of the brand. Where a value could not be read cleanly it is flagged in **Caveats**.

## What Datadog is, and what this system covers

Datadog is an observability and security platform: infrastructure monitoring, APM, log management, RUM, cloud security and cost management, all in one product. The template this system encodes is the **customer-facing GTM deck** template used by sales and go-to-market teams — QBRs, business reviews, pitch decks, roadmap sessions.

So the surface covered here is **presentations**, not product UI. The template contains exactly one product screenshot (Service Catalog, kept in `assets/imagery/`), which is not enough to responsibly recreate the app. **There is no product UI kit in this system** — see Caveats.

---

## Index

| Path | What it is |
|---|---|
| `styles.css` | The single entry point consumers link. `@import` lines only. |
| `tokens/` | `fonts.css`, `colors.css`, `gradients.css`, `typography.css`, `spacing.css`, `effects.css`, `base.css` |
| `assets/` | `logo*.svg`, `icons/` (14 glyphs), `backgrounds/` (14 plates), `charts/` (6 plates), `imagery/` |
| `components/chrome/` | `SlideFrame`, `Logo`, `Icon` |
| `components/content/` | `AccentCard`, `GradientPanel`, `HexIcon`, `StatBlock`, `AgendaList` |
| `components/data/` | `DataTable`, `ChartCard`, `LegendDot`, `PricingCard` |
| `slides/` | 15 sample slide layouts + `index.html` (all of them, stacked) |
| `guidelines/` | 18 foundation specimen cards (Colors, Type, Spacing, Brand) |
| `templates/datadog-deck/` | Starting-point deck template: cover, divider, content cards, big stat, callout |
| `extract/` | Provenance: the digested slide/layout XML the system was built from |
| `SKILL.md` | Agent Skills front matter, for use in Claude Code |

**Components:** SlideFrame, Logo, Icon, AccentCard, GradientPanel, HexIcon, StatBlock, AgendaList, DataTable, ChartCard, LegendDot, PricingCard.

### Intentional additions

The source is a deck, not a component library, so the "inventory" is the deck's own visual vocabulary — each component above corresponds to a shape family that recurs across the 41 layouts. Two are wrappers with no single counterpart shape:

- **`Icon`** — a wrapper for the 14 line glyphs found as `custGeom` paths across the slides, so they can be recoloured. Needed because the glyphs exist but have no component form in a `.pptx`.
- **`Logo`** — a wrapper for the two lockups found in the master and cover layout.

---

## Content fundamentals

**Voice.** Plain, declarative, technical-peer. Datadog writes to engineers and the people who buy for engineers; it does not sell with adjectives. The template's own instructional copy is the best specimen:

> "For big or complex ideas, consider using multiple slides to present the information. Breaking up the content helps ensure it remains clear, digestible, and easy to understand."

> "Think about what the biggest takeaway should be and focus on that. Remember, not all words need to be on the slide—use your voice over to add additional context."

Note the qualities: second person ("your audience", "your deck"), imperative openings ("Think about", "Tailor", "Opt for"), no exclamation marks, no hype, em-dashes used for asides.

**Casing.** Sentence case everywhere — slide titles, headings, body, buttons. Title Case only for names and job titles. ALL CAPS only for two things: eyebrow labels (`AUGUST 2026`) and mono numerals (`4.2X`).

**Headline length rule from the template.** Two-to-three-word headlines get Title Case; four or more words get sentence case. Short beats clever.

**Person.** "You/your" for the audience, "we" for Datadog. Never "I". Never "users" when "your engineers" or "your teams" is available.

**Numbers.** Always numerals, always in Roboto Mono Bold when they're the point of the slide (`63%`, `1,894`, `$641,000`). Multipliers are capitalised: `4.2X`, not `4.2x`.

**Emoji.** None. Not in decks, not in labels, not as icons. The template contains zero emoji and zero unicode-symbol icons.

**Fine print.** Footnotes lead with an asterisk and sit in `#787878` at 12pt: `*billed annually`.

**Placeholder language to strip.** The template ships with `Lorem ipsum`, `Body, 16pt Normal`, `XX`, `$0`, `Category`, `Cell`, `Header`. If any of these survive into a real deck, the deck isn't finished.

---

## Visual foundations

**Colour.** One brand hue with a spectrum of accents. `#632CA6` is the corporate/logo purple; the 2026 deck system runs on `#5C00EF → #9C43FE`. Accents are saturated and near-fluorescent: pink `#FF0080`, green `#00B765`, blue `#0060FF`, cyan `#00CAFF`, orange `#FF5E00`, amber `#FF9B00`. Each has one light companion (`#FF7AB3`, `#57E8B3`, `#60D3F5`, `#CC99FE`) used for hexagon outlines and gradient ends. Neutrals are true black on true white — no warm greys, no cream, no beige. Grey appears only for page numbers (`#969EA5`), footnotes (`#787878`), zebra rows (`#F2F2F2`) and hairlines (`#D8D8D8`).

**Two background modes, never mixed on one slide.** Either (a) a full-bleed angular geometric gradient plate — large overlapping triangles and parallelograms in one colour family, all 14 shipped in `assets/backgrounds/` — used for covers, dividers and sub-dividers with white text; or (b) plain white with coloured accent elements, used for every content slide with black text. There is no third option and no photography anywhere in the template.

**Gradients.** Every gradient in the file is the same construction: 45° in DrawingML (`ang="2700000"`), i.e. `135deg` in CSS, with stops held flat at 0–30% and 90–100% so the blend happens across the middle third. Never radial, never multi-hue beyond the pair.

**Type.** Roboto only — Bold for titles and headings, Regular for body, and Roboto Mono Bold for numerals. Nothing else, ever (the theme's `Arial` fallbacks are a Google Slides export artifact, not the brand). Scale, in template points: 72 cover / 66 divider / 54 sub-divider and callout / 48 agenda / 36 slide title / 24 subtitle and large body / 20 heading / 18 body / 16 card body / 14 label / 12 caption / 10 page number. Leading is 100% on display sizes, 114% inside cards, ~140% for running body. Slight negative tracking (`-0.01em`) on display sizes; `+0.04em` on caps labels.

**Layout rules.** A rigid 1280×720 grid (13.333in × 7.5in). 73px side margins. Title block top at 37.6px, 91px tall. Content row starts at 151px. Content width 1133px. Card rows: 4-up at 267px, 3-up at 361px, 2-up at 438px, always 20px gutters. Two elements are fixed on every slide except the cover: the horizontal logo at x=1111, y=677 (113.4×28.8px) and the page number at x=1243.5, y=683. Body text is left-aligned; the *only* centred text in the system is inside gradient boxes and hexagons.

**Cards.** White fill, 9px radius — and specifically `round2SameRect`: the template's content cards round only their **top two corners** (8.3px) because a 9.6px gradient bar sits flush across the top edge. Tables and pricing tiles use the fully rounded 9px variant. Card insets are 19.2px left/right, 28.8px top, 24px bottom.

**Shadows.** There is exactly one shadow in the entire template and everything uses it: `0 5.33px 10.67px rgba(0,0,0,0.10)` (DrawingML `blurRad 101600`, `dist 50800`, `dir 90°`, black at 10%). Screenshots get the same blur with no offset. No inner shadows anywhere. No protection gradients or scrim capsules — text never sits over imagery except on the geometric plates, which are flat enough to carry white type directly.

**Borders.** Almost none. A 1.33px `#D8D8D8` hairline separates a pricing header from its body and a total row from its table. Hexagons carry a 6.67px light-tint outline. Otherwise shape separation is done with white space and shadow, never with strokes.

**Transparency and blur.** None. No frosted glass, no translucent overlays, no backdrop filters. Every fill in the file is opaque (the shadow's 10% alpha is the single exception).

**Imagery vibe.** Cool, synthetic, high-chroma. Purple/magenta/blue dominate; orange and teal plates exist for variety. No photography, no grain, no illustration style beyond the geometric plates and the line icons. Charts are flat, gridline-light, and always in series order pink → blue → purple → orange.

**Motion, hover, press.** The source is a static deck, so none of this is defined by the brand. For interactive recreations this system defines one quiet convention and nothing more: 200ms `cubic-bezier(.4,0,.2,1)`, hover = shift to the accent's light companion (or 8% white overlay on gradients), press = no scale, just the next darker step. Flagged as an addition — see Caveats.

---

## Iconography

**One set, 14 glyphs, all extracted from the source.** They live in the `.pptx` as `custGeom` vector paths (an icon font that Google Slides flattened to outlines), and are now real SVGs in `assets/icons/`:

`workflow` · `containers` · `network` · `cost` · `cloud` · `dashboard` · `grid` · `feedback` · `chart-bars` · `pipeline` · `collaboration` · `bits` · `chat` · `people`

**Style.** Monoline, open, ~2px stroke at 40px, square-ish caps, no fill, geometric construction with rounded joins where paths meet. They read as technical-diagrammatic, not friendly-rounded. `bits` is the Datadog mascot mark (the dog carrying a chart), which appears as an illustrative accent, not a UI icon.

**How they're used.** Always white, inside a gradient hexagon (`HexIcon`), sized 56px inside a 143px hex or 78px inside a 402px hex. Occasionally purple on white as a standalone accent. Never coloured per-icon, never two colours, never in a circle or square badge.

**Delivery.** The `Icon` component inlines each vector as a real `<svg>` and paints it with the `color` prop, so it takes any brand colour. The same paths also sit as standalone files in `assets/icons/` with `fill="currentColor"` — inline those rather than referencing them from `<img>`, which would render them black.

**No icon font, no sprite, no CDN set.** Do not substitute Lucide/Heroicons/Feather into Datadog material: the stroke construction is visibly different. If you need a glyph outside these 14, ask for it — don't draw one.

**Emoji and unicode symbols:** never used.

---

## Caveats and flags

1. **Fonts are loaded from Google Fonts, not the template.** The `.pptx` embeds Roboto, Roboto Medium and Roboto Mono as Google-obfuscated `.fntdata` blobs that are not valid TTFs and cannot be decoded here. Roboto and Roboto Mono on Google Fonts are the *identical* families, so this is not a substitution — but if you have licensed static `.ttf`/`.woff2` files, drop them in `assets/fonts/` and I'll write proper `@font-face` rules for offline use.
2. **Three gradient stops in the source point at Office theme slots, not brand colours.** The pink, green and orange gradient bars reference `dk2` (`#44546A`), `accent2` (`#ED7D31`) and `accent4` (`#FFC000`) — Office defaults left behind by the Google Slides export, which render as muddy slate/amber and are almost certainly not intended. I defined those gradients as each accent paired with its light companion from the same slides (`#FF0080→#FF7AB3`, `#00B765→#57E8B3`, `#FF5E00→#FF9B00`). **Please confirm against the live brand palette.**
3. **No product UI kit.** The template holds one product screenshot. Recreating the Datadog app from a single 1600px image would be guesswork, so I didn't. Attach the app codebase or a Figma library and I'll build proper UI kits.
4. **Motion, hover and press states are additions.** A static deck defines none of them. The tokens in `effects.css` are a minimal, conservative convention, clearly separable if your web brand guide says otherwise.
5. **Slide-master defaults list `Arial`.** That's the exported Office theme, overridden by every real run in the deck. This system treats Roboto as the only typeface, per the brand rules.
