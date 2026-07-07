# Report writing methodology (Übersicht + Summary + Analysis)

Read this file BEFORE writing the report when the user asked no specific question. It defines the mandatory pre-stage (inventory + consistency check + date identification), the key-illustration extraction, the three report sections, and the exact markdown layout to append to `<base>.md`.

Write everything in the **user's language** (German user → German headers and body; English user → English). The deutsche Begriffe below are anchors for the meaning of each section — translate them, don't transliterate.

The reader uses Summary as the standalone takeaway and Analysis as the deeper synthesis. **Don't duplicate** — Summary is comprehensive-but-flat (thematic bullets covering every named entity and concrete fact); Analysis is selective-and-judgmental (top claims, opinions, audit). A reader who only reads Summary should know everything that was said; a reader who reads both gets the editorial layer on top.

## Pflicht-Vorstufe (before writing either section): Inventar + Konsistenz-Check

Narrative writing reliably drops entities that the video mentioned only in passing — named consumer systems, integration partners, "X, Y, Z, ..."-style enumerations, release cadences with concrete numbers. To prevent that, build the inventory and resolve transcription inconsistencies **first**, then use the canonical names in both Summary and Analysis.

**Inventar — enumerate, don't synthesize.** Mentally walk through frames + transcript and group every named entity you find:

- **Systeme / Tools / DBs** — applications, databases, platforms with their role and `[MM:SS]` of first mention
- **Konsumenten / Abnehmer** — every system that consumes data from the main architecture, even if mentioned once
- **Externe Schnittstellen** — bridges to third parties (SAP modules, regulator interfaces, partner tools)
- **Personen & Rollen** — named people with their role (`Beat — neuer Streckeneditor`, `Andrea — Onboardee`)
- **Personen & Stimmen** *(only if the transcript carries speaker labels — `[A]`, `[B]`, `[SPEAKER_00]`, ...)*: for each speaker label, map it to a real name by inspecting transcript context. **High-confidence criteria** (both must hold for a label to be substituted in the transcript later — see the speaker-name mapping step in SKILL.md):
  - **Frame evidence**: an avatar / participant-list / on-screen name plate confirms the person, AND
  - **Address-pattern evidence**: at least one direct address (`"Andrea, hast du eine Frage?"`) where the previous or next speaker change goes to / comes from this label.

  If only one of the two holds, the mapping is **medium-confidence**; if only weak / circumstantial evidence (a single off-hand name, no avatar), it's **low-confidence** — keep the bare letter in the transcript later. Mark medium / low explicitly with `(?)` in the entry so the post-analysis step can tell which labels to leave alone.

  **Canonical name format**:
  - Default: **first name only** (`Andrea`, `Urs`, `Maurice`).
  - On collision (two speakers with the same first name): append the shortest unique surname prefix that disambiguates, with a single space — `Andrea B` vs `Andrea T`. If the first letters also collide, extend by one letter at a time until unique (`Andrea Br` vs `Andrea Bo`). Never include the full surname — first names are what people actually use in conversation; the surname prefix is just a disambiguator.

  Entry format: `[A] = Urs Daschinger — Architekt, Hauptpresenter (Frame cut_001 + Anrede "Urs" [12:34])`. Skip this category entirely if there are no speaker labels in the transcript.
- **Fachbereiche / Listen-Aufzählungen** — every "X, Y, Z, ..." enumeration the speaker uses verbatim (these get dropped by narrative summaries; capture them as lists)
- **Prozesse / Rhythmen** — release cadences, batch cycles, retention intervals with their numbers (`3 grosse Releases pro TFI-Zyklus + monatliche Modelländerungen`)
- **Akronyme** — every three/four-letter code with its resolution if stated (`RGS — Railway GIS (vermutet, [06:00])`)

Bias toward over-inclusion. If you're unsure whether something deserves a slot, include it. **Vollständigkeit > Eleganz.** The inventory becomes a visible `### Inventar` subsection at the top of Analysis (see below).

**Konsistenz-Check — neutralize Whisper misrecognitions before they propagate.** Whisper transcripts garble proper names, acronyms, dialect words, and domain terms. While building the inventory:

1. **Cluster suspected variants of the same entity.** If `TopoRail / Toporail / TopOrel / Hopporell / Dr. Porel / Top-A-Rail` all appear, they are the same tool. Pick the canonical form (frames win — see below), list the variants in parens: `TopoRail (Transkript-Varianten: Toporail, TopOrel, Hopporell, Dr. Porel, Top-A-Rail)`.
2. **Frames are ground truth.** Slide text, diagram labels, application UI, on-screen captions are correct; transcript is noisy. If the transcript says `DfAKIS-Datenbank` but the diagram label reads `DFAGIS`, the diagram wins. State this in the inventory entry.
3. **Resolve implausible names via context.** Examples from real runs: `Lac Lemoyne` → Lac Léman (Swiss geography), `E-Sell` → Iselle (Italian Simplon terminus), `DfAKIS` → DFA-GIS, `im McWight` → likely product name visible on a frame. If context + frames point unambiguously at a known thing, correct it and keep the original in parens.
4. **Mark genuine uncertainty with `(?)`.** If a name is plausible but you have no evidence — neither a frame match nor a strong contextual clue — write `Beronito (?)`. Never invent corrections.
5. **Don't over-correct.** Swiss town names, dialect expressions, and obscure internal acronyms may be transcribed correctly. Only "correct" what frames or context actually confirm.

The inventory's canonical forms are the **only spellings used in Übersicht, Summary, and Analysis**.

**Datum identifizieren — priority order.** Many meeting / training / talk videos open with a title card carrying the date. The script also surfaces metadata-derived candidates in `protocol.md` under `**Date candidates**`. Pick *one* recording / meeting date by walking this priority list and stop at the first match:

1. **Title slide on the first 1–3 frames.** A frame showing "Meeting Title — 4. März 2024" / "DfA Architecture Overview, 2024-03-04" / a date stamp in a corner / a Teams meeting "Started at …" caption is the most credible source. Always check first.
2. **`**Date candidates**` block in protocol.md**, in the order the script emits them: filename / title regex → yt-dlp `upload_date` → ffprobe `creation_time` → file mtime. Two independent sources matching is a strong confirmation.
3. **Date inside the transcript** (someone explicitly says "wir treffen uns heute am 4. März 2024 …").
4. If nothing matches: mark `Datum: unbekannt`. Don't guess.

**Anti-pattern — never use UI timestamps from inside the video** (version footers, "last-modified" stamps in an opened app, dummy default timestamps in dialog corners). Those are not the recording date and have burned us before (real example: a Gebäude-DB-footer at 52:29 of a meeting video showed `04.03.2024 14:55:53`, which turned out to be a default app timestamp coincidentally matching nothing). Only explicit title-card / system "now"-displays / meta candidates count.

Document the chosen date in the **Setting und Teilnehmer** Summary group with its source: `Meeting vom 2024-03-04 (Quelle: Titel-Slide [00:02])` or `Recording date: 2024-03-04 (yt-dlp upload_date — kein Titel-Slide gefunden)`.

## Schlüssel-Illustrationen ausschneiden (only for video sources with a saved report)

Some frames *are* the content — an architecture diagram, a chart with the key numbers, a data-flow slide. A reader of the report should see that illustration **inline**, cropped out of the surrounding talking-head / slide chrome, not have to scrub the video. `illustrate.py` does the deterministic work (native-res re-extraction, crop, margin-trim, dedup); you do the analytical part — *which* frame, *which* region, *what* caption.

**Skip this step entirely when:** the source is audio-only (no frames), `--no-save-md` was used (no persistent dir to write into), or the video is pure talking-head with no diagrams/charts/slides worth extracting. Zero illustrations is a valid outcome — don't manufacture them.

Otherwise, from the frames already read:

1. **Select the decisive frames.** Pick the ones carrying an illustration that *materially aids understanding* — diagrams, architecture/data-flow slides, charts, tables, screenshots with substantive content. `[CUT]` frames are the prime candidates (slides land on scene cuts). Exclude talking-head, transitions, decorative title cards, and anything redundant. Be selective: typically **3–10** for a talk, often fewer.
2. **For each, give a normalized bounding box** `[x, y, w, h]` in `0..1` of the illustration *region within the frame* (estimate it from the image — the script trims uniform margins afterwards, so a slightly generous box is fine; omit `bbox` to keep the whole frame). Add a short `caption` (use canonical names from the Inventar) and a `type` (`Architektur` / `Diagramm` / `Chart` / `Tabelle` / `Screenshot` / `Slide`).
3. **Write the spec** to `<base>.illustrations.spec.json` (the `Write` tool) as a JSON list:
   ```json
   [ { "id": 1, "timestamp": 734.0, "bbox": [0.08, 0.12, 0.84, 0.76],
       "caption": "Zielarchitektur DfA-GIS", "type": "Architektur" } ]
   ```
   `timestamp` is in seconds (the absolute `t=` of the frame). `<base>` is the report base (the `.md` stem from the header's saved-files lines).
4. **Run the cropper**, passing the `**Video file:**` path from the report header verbatim:
   ```bash
   python3 "${CLAUDE_SKILL_DIR}/scripts/illustrate.py" \
     --video "<Video file from header>" \
     --spec "<base>.illustrations.spec.json" \
     --out-dir "<base>.illustrations"
   ```
   It prints the surviving crops and writes `<base>.illustrations/manifest.json`. **Read the manifest** — dedup may have dropped near-duplicate slides, so the manifest (not your spec) is the authoritative list of what to embed. The crops are PNGs at native resolution, idempotent on re-run.

The embedding happens in SKILL.md Step 5; the work happens here because the Summary references the illustrations.

## Übersicht (top-level section, comes first)

A two-block orientation header at the very top of the report. The reader hits this before anything else and walks away with two things: **what the video is arguing** (Kernaussagen) and **how it is built** (Chapter-Struktur). Everything else — the thematic catalog, the editorial layer, the inventory — comes after.

### Kernaussagen / Core claims
The central theses the speaker is arguing for. 3–6 bullets, each a standalone claim a viewer should walk away with. Skip intros and throat-clearing; capture what the video is actually trying to convince you of. These are **facts and positions** as stated by the video. Use canonical names from the Inventar.

### Chapter-Struktur / Structural outline
A chronological skeleton — typically 5–8 numbered entries — showing how the video is built. Each entry: `[MM:SS – MM:SS]` plus a one-line topic label. Don't repeat the Kernaussagen content; the role of this block is *navigational* (where in the video is each topic discussed). Use the chapter boundaries the speaker actually establishes (slide transitions, "und jetzt kommen wir zu …", topic shifts), not arbitrary time-slices.

## Summary / Zusammenfassung (top-level section, comes second)

A comprehensive thematic recap modeled after a meeting-protocol summary. The reader gets every concrete fact the video carried, organized by topic, in scannable bullet form. **No editorial commentary, no top-N selection — Summary is the catalog, not the curation.**

Format:

- Cluster the video's content into 5–10 thematic groups (`### <Thema>`). Topics are derived from what the video actually covers; don't force a fixed schema.
- Under each `### <Thema>` heading: 3–8 short bullet points. One concrete fact per bullet — a named system with its role, a concrete number, an enumeration captured verbatim, a relationship between two entities, a decision with its rationale.
- Use the canonical names from the Inventar. Use `[MM:SS]` timestamps sparingly — only where a specific moment matters (a quote, a decision point). The Summary's job is content coverage, not source-anchoring.
- Every Inventar entry must appear in at least one Summary bullet OR in a later Analysis section. The Abdeckung audit (in Analysis) will check this.

The Summary is the reader's main entry point — it must stand alone. A busy reader who reads only Summary should walk away knowing every named entity, every list-style enumeration, every concrete decision, every open question. The Analysis layer below adds editorial weight and audit; it does not replace the catalog.

## Analysis (top-level section, comes third)

Synthesized, judgmental layer on top of Übersicht + Summary. Six subsections in order:

### Inventar (canonical names + Konsistenz-Check variants)

Write out the inventory you built in the Pflicht-Vorstufe. Group by the seven categories listed there (Systeme, Konsumenten, Schnittstellen, Personen, Fachbereiche, Prozesse, Akronyme). For each entry: the canonical name, a one-line role, the first-mention `[MM:SS]`, and — only if the entity was misrecognized in the transcript — `(Transkript-Varianten: <variant1>, <variant2>, …)` in parens. Skip a category subheading entirely if it has no entries (don't write empty headings).

Inventar is reference material, not narrative — keep it dry and listy. The reader uses it as a glossary while reading Übersicht, Summary, and the rest of Analysis.

### Beurteilungen / Verdicts & recommendations
Every value judgement, comparison, or recommendation the speaker delivers — "X is the cheapest capable model on the market", "not a drop-in replacement", "the gap is closing", "use Y for narrow tasks, not open-ended ones". Distinguish the speaker's own opinions from cited third-party reports (Reddit, papers, benchmarks). This is where the **opinions and weightings** live, as opposed to the facts in Kernaussagen.

### Schlüsselaussagen / Key quotes
3–5 of the most pointed lines from the transcript, quoted verbatim with `[MM:SS]` timestamps. These are the punchlines a viewer would screenshot — pick for memorability and density, not for length.

### Details
Supporting evidence and visual context the other sections didn't carry. Two scopes:
- **Visual language** — one or two lines if the video has a notable visual register (slides vs talking head, motion graphics, diagrams dominating the screen, webcam grid, etc.).
- **Notable artifacts** — on-screen file names, version stamps, URL bars, dashboard captions that ground the analysis in evidence (e.g. `dfagis_prod.dfa.ch · v 20.0.2.1 · 04.03.2024 14:55:53` proves the meeting date).

**Details are useful but secondary**; do not let this section outgrow the three above. Chapter walk-through belongs in **Übersicht → Chapter-Struktur** at the top of the report, not here.

### Abdeckung / Coverage (audit against Inventar)

After Details, sweep the Inventar entry by entry against **the full report** (Übersicht + Summary + Beurteilungen + Schlüsselaussagen + Details). For each entry:

- If it appears (under its canonical name) anywhere → nothing to do.
- If it does **not** appear anywhere → one bullet here naming the entry and a short reason for the deliberate omission (`<Name> — nur Nebenerwähnung, kein eigenständiger Inhalt darüber hinaus`).

If every Inventar entry is covered, write a single line: `Alle Inventar-Einträge sind in Übersicht, Summary oder Analysis berücksichtigt.` — and move on.

This section is the audit mechanism, not the highlight. Keep it dry and short. Its job is to make accidental omissions visible — if you find yourself writing more than 5–8 lines of "weil ...", that's a signal that the Summary skipped too much and you should fold a few of those entries back into the right thematic Summary group instead.

### Resources
When relevant, surface the most useful entries from `## Resources` (Projects + Docs especially) — the concrete things a viewer can click on after watching. Skip this section if the resources are thin or off-topic.

## Report layout (append to `<base>.md`)

```markdown
## Übersicht

### Kernaussagen
<3–6 top claims>

### Chapter-Struktur
<5–8 numbered entries: `[MM:SS – MM:SS]` + one-line topic>

## Summary

### <Thema 1>
- <bullet>
- <bullet>

### <Thema 2>
- <bullet>

<… 5–10 thematic groups total, comprehensive coverage in scannable bullets>

## Analysis

### Inventar
<grouped lists from the Inventar + Konsistenz-Check pass — canonical names,
one-line roles, [MM:SS] of first mention, Transkript-Varianten in parens for
any Whisper-misrecognized terms; skip empty category headings>

### Beurteilungen
<judgments, comparisons, recommendations — distinguish speaker's own vs. cited>

### Schlüsselaussagen
<3–5 verbatim quotes with [MM:SS]>

### Details
<visual language one-liner + notable on-screen artifacts; no chapter walk-through>

### Abdeckung
<coverage audit against Inventar — either deliberate-omission bullets or
the "alle berücksichtigt"-line>

### Resources
<curated subset of the ## Resources extracted in protocol.md, if relevant>
```
