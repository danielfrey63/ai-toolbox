---
name: watch
description: Watch a video (URL or local path). Downloads with yt-dlp, extracts gap-filled frames + scdet-detected cuts (settle-delayed for stable post-transition content), auto-chunks long videos for dense per-chunk coverage, transcribes via captions / Whisper / AssemblyAI / pyannote diarization (with Claude-driven speaker-to-name substitution), and produces a three-file persistent report (`<base>.{md,protocol.md,transcript.md}` next to local sources or under `./watch/<YYYY-MM-DD>-<slug>/` for URLs) plus a Summary that hits the chat with clickable file:// links.
argument-hint: "<video-url-or-path> [question]"
allowed-tools: Bash, Read, AskUserQuestion
homepage: https://github.com/danielfrey63/ai-toolbox
repository: https://github.com/danielfrey63/ai-toolbox
author: bradautomates
license: MIT
user-invocable: true
---

# /watch — Claude watches a video

You don't have a video input; this skill gives you one. A Python script downloads the video, extracts frames as JPEGs, gets a timestamped transcript (native captions first, then Whisper API as fallback), and prints frame paths. You then `Read` each frame path to see the images and combine them with the transcript to answer the user.

## Step 0 — Setup preflight (runs every `/watch` invocation, silent on success)

**Python interpreter:** every `python3 ...` command in this skill is for macOS/Linux. On **Windows**, substitute `python` — the `python3` command on Windows is the Microsoft Store stub and will not run the script.

Before every `/watch` run, verify that dependencies and an API key are in place:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --check
```

This is a <100ms lookup. On exit 0, the script emits **nothing** — proceed to Step 1 without comment. **Do NOT announce "setup is complete" to the user** — they don't need a status message on every turn. The only acceptable user-visible output from Step 0 is when remediation is required.

On non-zero exit, follow the table:

| Exit | Meaning | Action |
|------|---------|--------|
| `2` | Missing binaries (`ffmpeg` / `ffprobe` / `yt-dlp`) | Run installer |
| `3` | No Whisper API key | Run installer to scaffold `.env`, then ask user for a key |
| `4` | Both missing | Run installer, then ask for a key |

The installer is idempotent — safe to re-run:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py"
```

On all three platforms, the default installer now does the right thing automatically:
- **macOS** — auto-runs `brew install ffmpeg yt-dlp`.
- **Linux / Windows** — routes to `cmd_install_binaries()` and downloads standalone binaries into `~/.watch/bin/` (yt-dlp from GitHub Releases, ffmpeg from johnvansickle on Linux / Gyan.dev on Windows). No `apt install`, no `pip install`, no admin rights needed. A `find_tool()` helper in `setup.py` prefers `~/.watch/bin/` and falls back to anything on PATH — system-installed versions still win when present.

It scaffolds `~/.config/watch/.env` with commented placeholders at `0600` perms, and writes `SETUP_COMPLETE=true` once deps + a key are in place so the next session knows this user has already been through the wizard.

**Direct standalone-binary invocation** (explicit, useful for `--force` re-download or skipping the env scaffolding):

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --install-binaries [--force]
```

Same as what the default installer routes to on Linux/Windows. Add `--force` to refresh existing binaries.

**If an API key is still missing after install:** use `AskUserQuestion` to ask the user whether they have a Groq API key (preferred — cheaper, faster) or an OpenAI key. Then write it into `~/.config/watch/.env` — set the matching `GROQ_API_KEY=...` or `OPENAI_API_KEY=...` line. If they don't want to set up Whisper, proceed with `--no-whisper` and tell them videos without native captions will come back frames-only.

**Structured mode (optional):** `python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --json` emits `{status, first_run, missing_binaries, whisper_backend, has_api_key, config_file, platform}` where `status` is one of `ready | needs_install | needs_key | needs_install_and_key`. Use this when you need to branch on specifics (e.g. "is this the user's very first run?" → `first_run: true`).

Within a single session, you can skip Step 0 on follow-up `/watch` calls — once `--check` returned 0, nothing about the environment changes between turns.

## When to use

- User pastes a video URL (YouTube, Vimeo, X, TikTok, Twitch clip, most yt-dlp-supported sites) and asks about it.
- User points at a local video file (`.mp4`, `.mov`, `.mkv`, `.webm`, etc.) and asks about it.
- User points at a local **audio** file (`.m4a`, `.mp3`, `.wav`, voice memos, meeting recordings) — the frame stages are skipped automatically; transcription, diarization, and the report pipeline run normally. Combine `--whisper whisper-local --diarize pyannote-local` for fully on-device processing of confidential recordings.
- User types `/watch <url-or-path> [question]`.

## Recommended limits

- **Frame budget scales with duration:**
  - ≤30s → ~1-2 fps (up to 30 frames)
  - 30s-1min → ~40 frames
  - 1-3min → ~60 frames
  - 3-10min → ~80 frames
- **Long videos (>10 min) auto-chunk by default.** Without `--start`/`--end`, the script splits the video into `ceil(duration / 10min)` chunks of even size and runs each chunk through the focused-mode dense budget. A 60-min video becomes 6 chunks of 10 min × ~80 frames per chunk = ~480 regular frames total (plus scene-cut frames). This costs proportionally more image tokens than the old sparse single-pass behavior, but yields per-chunk coverage comparable to dedicated focused runs. Pass `--no-chunk` to revert to the sparse single-pass behavior, or `--start`/`--end` to zero in on one specific section instead.
- **Hard caps remain: 2 fps and `--max-frames` per chunk.** `--max-frames N` (default 80) is now the *per-chunk* cap, not the global cap. A 60-min video at default settings extracts up to 80 × 6 = 480 regular frames; if you want to clamp the total, lower `--max-frames` or pass `--no-chunk`.

## How to invoke

**Step 1 — parse the user input.** Separate the video source (URL or path) from any question the user asked. Example: `/watch https://youtu.be/abc what language is this in?` → source = `https://youtu.be/abc`, question = `what language is this in?`.

**Step 2 — run the watch script.** Pass the source verbatim. Do not shell-escape it yourself beyond normal quoting:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/watch.py" "<source>"
```

Optional flags:
- `--start T` / `--end T` — focus on a section. Accepts `SS`, `MM:SS`, or `HH:MM:SS`. When either is set, fps auto-scales denser (see "Focusing on a section" below).
- `--max-frames N` — cap on regular frames per chunk (default 80, hard max 100). In single-chunk modes (focused or `--no-chunk`) this is also the global cap.
- `--no-chunk` — disable auto-chunking for long videos. Reverts to the old single-pass sparse behavior (100 frames spread thinly across the whole video).
- `--diarize [BACKEND]` — enable speaker diarization. Output transcript lines become `[MM:SS] [<speaker>] text`. Backends:
  - **omitted** — diarization off (default; pure Whisper transcript).
  - **`--diarize`** (no value) — auto-pick the first configured backend, in order: AssemblyAI → pyannote.ai → pyannote local.
  - **`--diarize assemblyai`** — cloud, all-in-one. Replaces Whisper: one API call returns transcription + speaker labels. Uses `universal-3-pro` (fallback `universal-2`) and `language_detection: true` by default — handles multilingual content (DE-CH + EN + FR/IT references) without an explicit language hint. Needs `ASSEMBLYAI_API_KEY` in env or `.env`; optionally `ASSEMBLYAI_REGION=eu` for EU data residency. ~$0.37/h.
  - **`--diarize pyannote-api`** — cloud pyannote.ai (diarization-only). Runs alongside Whisper; the script aligns speaker turns to Whisper segments by overlap. Needs `PYANNOTE_API_KEY`. Cheaper than AssemblyAI.
  - **`--diarize pyannote-local`** — local pyannote.audio. Free, fully on-device (nothing leaves the machine — the right choice for confidential recordings). Zero manual setup: the heavy ML stack lives in a **managed venv** at `~/.config/watch/venv/`, provisioned idempotently on first use (or explicitly via `setup.py --venv`); the diarization itself runs as a worker subprocess (`pyannote_worker.py`) inside that venv, so the host Python is never touched. GPU is auto-detected (nvidia-smi → cu124 wheels; a 41-min recording diarizes in ~90 s on GPU vs ~36 min on CPU). Requirements that remain with the user: a Hugging Face token (`HF_TOKEN`) plus license acceptance for **both** gated repos: `pyannote/speaker-diarization-3.1` *and* `pyannote/segmentation-3.0`. Speaker count stays on auto by design — forcing `num_speakers` collapses onto the dominant voice on single-mic recordings (observed: 95% one speaker on a real 2-person meeting); surplus mini-clusters are merged/labeled afterwards by Claude from transcript context. Diarization aligns to the Whisper transcript.
  - Identifying *which name* maps to `A`/`B`/`SPEAKER_00` is done later by Claude using address patterns in the transcript (see Step 4 Inventar → Personen & Stimmen). For **audio-only sources** (no frames as ground truth), role/content evidence substitutes for frame evidence: a label that consistently owns a known person's responsibilities ("I'll prepare the compliance slide") plus at least one address-pattern hit qualifies as high-confidence; document the reasoning in the transcript header. Surplus diarization clusters that map to no one stay as bare letters with a header note.
- `--resolution W` — change frame width in px (default 512; bump to 1024 only if the user needs to read on-screen text)
- `--fps F` — override auto-fps (clamped to 2 fps max)
- `--out-dir DIR` — keep working files somewhere specific (default: an auto-generated tmp dir)
- `--whisper azure-diarize|groq|openai|whisper-local` — force a specific transcription backend (auto order: azure-diarize → groq → openai → whisper-local). `whisper-local` = faster-whisper fully on-device in the managed venv (`~/.config/watch/venv/`, self-provisions on first use, GPU auto-detected) — no key, nothing leaves the machine; the right choice for confidential recordings.
- `--no-whisper` — disable the Whisper fallback entirely (frames-only if no captions)
- `--no-scene` — disable scdet-based cut detection (default: enabled with auto-tuned threshold, see "Scene cut detection" below)
- `--scene-threshold F` — override the auto-detected scdet threshold (default: auto via knee-point on the score distribution; lower = more sensitive)
- `--scene-min-gap S` — minimum seconds between consecutive cut frames (default `2.0`, de-clusters animation/B-roll bursts)
- `--scene-max-frames N` — cap on additional cut frames (default `80`, applied separately from `--max-frames`)
- `--scene-settle-seconds S` — seconds after a detected cut to wait before extracting (default `1.0`). Lets UI transitions / dialogs / launcher windows render before capture, so cut frames don't land on loading-state / black mid-transition pixels. Capped at `next_cut - 0.3s` so we never bleed into the following shot. Set to `0` to revert to the old just-before-cut behavior. Higher values (~2–4 s) help apps that take longer to render but risk bleeding into transient flashes.
- `--save-md PATH` — save the report as **three companion files**: PATH itself (the main file — a stub for Claude to append `## Summary` and `## Analysis`), plus `<base>.protocol.md` (metadata + frame list + resources + footer) and `<base>.transcript.md` (full transcript) as siblings, where `<base>` is PATH with `.md` (or legacy `.watch.md`) stripped. Defaults:
  - **Local-file sources** → `<video-stem>.md` next to the source (e.g. `videos/test.mp4` → `videos/test.{md,protocol.md,transcript.md}`).
  - **URL sources** (YouTube, Vimeo, etc.) → `./watch/<YYYY-MM-DD>-<slug>/<slug>.md` in the current working directory, where `<slug>` is a sanitized form of the video title returned by yt-dlp (lowercase ASCII, non-alphanumeric → `-`, ~60 chars max). The per-video subfolder keeps multiple runs tidy and leaves room for retained video / frame snapshots. `.gitignore`-friendly via a single `watch/` entry.
  - Pass `--no-save-md` to disable auto-save entirely (frames + transcript stay only in the temp work_dir until Step 6 cleanup).
- `--no-save-md` — disable the local-file auto-save

### Focusing on a section (higher frame rate)

When the user asks about a specific moment — "what happens at the 2 minute mark?", "zoom into 0:45 to 1:00", "the first 10 seconds" — pass `--start` and/or `--end`. The script switches to focused-mode budgets, which are denser than full-video budgets (still capped at 2 fps):

- ≤5s → 2 fps (up to 10 frames)
- 5-15s → 2 fps (up to 30 frames)
- 15-30s → ~2 fps (up to 60 frames)
- 30-60s → ~1.3 fps (up to 80 frames)
- 60-180s → ~0.6 fps (100 frames, capped)

Focused mode is the right call for:
- Any moment/range the user names explicitly ("around 2:30", "the intro", "the last 30 seconds").
- Any video longer than ~10 minutes where the user's question is about a specific part — running focused on the relevant section is far more useful than a sparse scan of the whole thing.
- Re-runs after a full scan didn't have enough detail in some region.

Transcript is auto-filtered to the same range. Frame timestamps are absolute (real video timeline, not offset-from-start).

### Scene cut detection (default on, auto-tuned threshold)

In addition to the regular sampling, the script runs an `scdet` pass and extracts **one extra frame at every detected cut**. The regular sampler is **gap-filling**: it does not sample at uniform time intervals but distributes its budget into the gaps between cut timestamps, proportional to gap length. This avoids redundancy in cut-dense regions and guarantees coverage of long uncovered spans.

How it works:
1. **scdet Pass 1** — `ffmpeg -vf scdet=threshold=0` scores every frame's pixel-difference to the previous one. **All** scores are captured (no static threshold).
2. **Auto-threshold** — knee-point detection on the sorted-descending score curve picks where the distribution transitions from "real cuts" to "noise floor". Each video gets its own threshold, calibrated to its own score distribution. A floor of `5.0` prevents misclassifying noise on static videos with no real cuts.
3. **De-cluster** — within 2 s gaps, consecutive cuts collapse to one (avoids spamming animation sequences).
4. **Gap-fill regular sampling** — the cut timestamps partition the video into gaps. Each gap gets regular frames proportional to its length. Gaps shorter than `(duration / target_count) / 2` are skipped (already covered by neighboring cuts). When `--no-scene` is set or no cuts exist, gap-fill collapses to uniform sampling.
5. **Pass 2** — for each cut and each gap-fill timestamp, a single JPEG is extracted via fast-seek (`-ss t-0.05`) at the same `--resolution`.

The chosen auto-threshold is printed to stderr (`[watch] N cuts detected (auto-picked X.YZ)`) and shown in the report metadata as `scdet ≥ X.Y auto`. The regular-sampler line shows `(gap-filled, ~F fps avg)` so it's clear the spacing is non-uniform.

Why content-aware: scdet score distributions differ wildly between content types. A talking-head video has all scores near 0; an action montage may have hundreds above 30. A single static threshold like 15 misses everything in the first case and over-includes in the second. The knee-point method adapts to whatever distribution is actually in the video.

Why gap-filled rather than uniform: in cut-dense regions (e.g. an Eklat-cluster with 7 cuts in 78 s), uniform sampling would add 1–2 redundant regular frames where the cut frames already cover the moment in detail. Meanwhile a 3-minute monologue without cuts would get the same average density as the cluster. Gap-filling shifts the regular budget away from already-covered regions and into the long uncovered ones — same total budget, better coverage.

Output — the report's frame list is **merged chronologically** and each entry is tagged:
- `[REG]` — regular gap-filled frame (`frames/frame_NNNN_tNNNNNs.jpg`)
- `[CUT]` — scene-cut frame (`cuts/cut_NNN_tNNNNNs.jpg`)

Read both kinds the same way — they are JPEGs in the same format.

When to disable with `--no-scene`:
- Talking-head videos with no real cuts (the scdet pass takes ~30 s on a 30-min video for ~0 useful cuts anyway).
- Token budget is tight and the regular sampling alone is sufficient.
- Long video where you want a fast first pass before re-running focused.

When `--no-scene` is set, the regular sampler falls back to uniform spacing — same effective behaviour as the original watch skill.

When to override with `--scene-threshold F`:
- Auto picked too few cuts and you know there are subtle transitions worth catching (force lower, e.g. `--scene-threshold 8`).
- Auto picked too many on cut-heavy content and you only want hard cuts (force higher, e.g. `--scene-threshold 30`).
- Debugging or reproducibility (locking the threshold across re-runs).

Cost: scdet adds ~5–10 % to wall-clock time. Each cut frame costs the same as a regular frame in image tokens. Gap-filling itself is free (pure timestamp arithmetic).

Examples:
```bash
# Last 10 seconds of a 1 minute video
python3 "${CLAUDE_SKILL_DIR}/scripts/watch.py" video.mp4 --start 50 --end 60

# Zoom into 2:15 → 2:45 at 3 fps (90 frames)
python3 "${CLAUDE_SKILL_DIR}/scripts/watch.py" "$URL" --start 2:15 --end 2:45 --fps 3

# From 1h12m to the end of the video
python3 "${CLAUDE_SKILL_DIR}/scripts/watch.py" "$URL" --start 1:12:00
```

**Step 3 — Read frames and transcript.** Two things to load into context, in parallel:
- Every frame path the script listed under `## Frames` — the Read tool renders JPEGs directly as images. Frames are in chronological order with a `t=MM:SS` timestamp so you can align them to the transcript. When scene detection is enabled (default), entries are tagged `[REG]` (regular sampling) or `[CUT]` (scdet-detected cut) — read both kinds.
- The transcript file (the `**Transcript file:**` path from the script's metadata header). The script does **not** dump the transcript to stdout — it writes it to `<base>.transcript.md` and you Read it from there. Skip this Read only if the metadata says `Transcript: none available`.

Run all frame Reads and the transcript Read in a single message (parallel tool calls) so everything lands in context together.

**Step 4 — answer the user.** You now have three streams of evidence:
- **Frames** — what's on screen at each timestamp
- **Transcript** — what's said at each timestamp. The report's header shows the source (`captions` = yt-dlp pulled native subs; `whisper (groq)` or `whisper (openai)` = transcribed by API).
- **Resources** — a `## Resources` section at the end of the report aggregates every `https://` URL found in the **video description** plus URLs that appear in the **transcript**, deduped and grouped by category (Projects / Docs / Articles / Videos / Social / Other). Each entry shows where it was sourced from (`description` or `transcript@MM:SS`).

If the user asked a specific question, answer it directly citing timestamps and stop. Don't impose the report structure below — they asked something specific, give them that.

If they didn't ask anything specific, write a **two-section report** with `## Summary` first and `## Analysis` second. Write everything in the **user's language** (German user → German headers and body; English user → English). The deutsche Begriffe below are anchors for the meaning of each section — translate them, don't transliterate.

The reader uses Summary as the standalone takeaway and Analysis as the deeper synthesis. **Don't duplicate** — Summary is comprehensive-but-flat (thematic bullets covering every named entity and concrete fact); Analysis is selective-and-judgmental (top claims, opinions, audit). A reader who only reads Summary should know everything that was said; a reader who reads both gets the editorial layer on top.

#### Pflicht-Vorstufe (before writing either section): Inventar + Konsistenz-Check

Narrative writing reliably drops entities that the video mentioned only in passing — named consumer systems, integration partners, "X, Y, Z, ..."-style enumerations, release cadences with concrete numbers. To prevent that, build the inventory and resolve transcription inconsistencies **first**, then use the canonical names in both Summary and Analysis.

**Inventar — enumerate, don't synthesize.** Mentally walk through frames + transcript and group every named entity you find:

- **Systeme / Tools / DBs** — applications, databases, platforms with their role and `[MM:SS]` of first mention
- **Konsumenten / Abnehmer** — every system that consumes data from the main architecture, even if mentioned once
- **Externe Schnittstellen** — bridges to third parties (SAP modules, regulator interfaces, partner tools)
- **Personen & Rollen** — named people with their role (`Beat — neuer Streckeneditor`, `Andrea — Onboardee`)
- **Personen & Stimmen** *(only if the transcript carries speaker labels — `[A]`, `[B]`, `[SPEAKER_00]`, ...)*: for each speaker label, map it to a real name by inspecting transcript context. **High-confidence criteria** (both must hold for a label to be substituted in the transcript later — see Step 5):
  - **Frame evidence**: an avatar / participant-list / on-screen name plate confirms the person, AND
  - **Address-pattern evidence**: at least one direct address (`"Andrea, hast du eine Frage?"`) where the previous or next speaker change goes to / comes from this label.

  If only one of the two holds, the mapping is **medium-confidence**; if only weak / circumstantial evidence (a single off-hand name, no avatar), it's **low-confidence** — keep the bare letter in the transcript later. Mark medium / low explicitly with `(?)` in the entry so the post-analysis step in Step 5 can tell which labels to leave alone.

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

**Step 5 — persist Übersicht + Summary + Analysis to the main file.** Check the report header for the three saved-files lines (`**Protocol file:**`, `**Transcript file:**`, `**Analysis target:**`). The script has already written the protocol (`<base>.protocol.md`) and transcript (`<base>.transcript.md`). The Analysis-target file (the main `<base>.md`) contains only a short stub with cross-links — **append the full three-section report to it** so the user ends up with one human-readable document alongside the two raw-data companions. Use this layout:

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

Append (don't overwrite) — the stub header above stays intact. For URL sources without `--save-md`, skip this step entirely and just answer in chat.

**After the append, surface Übersicht + Summary in chat.** The chat / console is where the user actually reads the result; the saved file is the persistent artifact. Echo the **full `## Übersicht`** block (Kernaussagen + Chapter-Struktur — quick orient, ~15 lines) and the **full `## Summary`** block (thematic catalog) into your final chat message, then a short pointer block listing the three companion files **as markdown links with `file://` URLs** so the user can click through (clickable in Claude Code and most modern terminals):

```
<full ## Übersicht block — Kernaussagen + Chapter-Struktur>

<full ## Summary block — all ### <Thema> groups and bullets>

**Files**
- Protocol: [`<base>.protocol.md`](file:///absolute/path/to/<base>.protocol.md) — metadata + frame list
- Transcript: [`<base>.transcript.md`](file:///absolute/path/to/<base>.transcript.md) — full transcript
- Analysis: [`<base>.md`](file:///absolute/path/to/<base>.md) — Übersicht + Summary + full Analysis
```

Use the **absolute paths** from the `**Protocol file:**` / `**Transcript file:**` / `**Analysis target:**` lines in the report header (those are already absolute). Just prefix each with `file://` to form the URL.

Do **not** echo the Analysis subsections (Inventar, Beurteilungen, Schlüsselaussagen, Details, Abdeckung, Resources) into chat — those live in the saved `<base>.md` and would make the chat response unwieldy. The user opens `<base>.md` if they want them.

**Apply speaker-name mapping to the transcript (only when diarized).** If the run produced a diarized transcript (the Step 2 metadata says `Transcript: N segments (via assemblyai (transcript + diarization))` or similar) **and** the Inventar's *Personen & Stimmen* contains **high-confidence** mappings (frame evidence AND address-pattern evidence — see Step 4), substitute the anonymous speaker labels in `<base>.transcript.md` with the canonical first names you decided in the Inventar:

- For each high-confidence entry, run an `Edit` with `replace_all: true` on `<base>.transcript.md`: `[A]` → `[Urs]`, `[C]` → `[Andrea]`, etc. The substitution applies to every segment line in the transcript.
- **Do NOT substitute** entries marked with `(?)` in the Inventar — keep their bare letters. The asymmetry signals to the reader which speakers are confidently identified and which remain provisional.
- Names use the canonical form decided in the Inventar (first name; or `Andrea B` / `Andrea T`-style on collision).

Result: a reader opens `<base>.transcript.md` and sees `[12:34] [Urs] …` instead of `[12:34] [A] …`, which makes the transcript self-explanatory without cross-referencing the analysis file. The Inventar in `<base>.md` remains the audit trail for *why* `[A] = Urs`.

If the transcript came from VTT captions or pure Whisper (no `[A]/[B]/…` labels in the first place), skip this substitution step entirely.

**Compact transcript (only when diarized).** After the speaker-name mapping, write a fourth companion `<base>.transcript-kompakt.md`: an editorially polished, condensed rendition of the diarized transcript. The raw transcript already merges consecutive same-speaker segments into turns — the compact file adds the human layer on top:

- One block per substantive statement: `**[MM:SS] <Name>:** <polished text>`, timestamp = start of the turn.
- Fix STT misrecognitions you can resolve from context (the Konsistenz-Check results), normalize dialect garbles into clean standard language, drop pure fillers and bare acknowledgements ("Ja.", "Genau.") by folding them into the surrounding flow.
- Group the blocks under `## <Thema>` headings in chronological order, mirroring the conversation's phases.
- Header: source, duration, participants, a note that the file is editorially condensed, and a pointer to `<base>.transcript.md` as the verbatim reference.
- Attribute leftover unsure-cluster labels by context where the content makes the speaker obvious; otherwise keep the bare letter.

Skip the compact file for non-diarized transcripts — without speakers it would just duplicate the transcript.

**Step 6 — clean up.** The script prints a working directory at the end. If the user isn't going to ask follow-ups about this video, delete it with `rm -rf <dir>`. **If `--save-md` produced the three companion files (`<base>.md` + `<base>.protocol.md` + `<base>.transcript.md`), they live outside the work dir and are preserved** by the cleanup. If the user might follow up, leave the work dir in place too.

## Transcription

The script gets a timestamped transcript in one of two ways:

1. **Native captions (free, preferred).** yt-dlp pulls manual or auto-generated subtitles from the source platform if available.
2. **STT fallback.** If no captions came back (or the source is a local file), the script extracts audio (`ffmpeg -vn -ac 1 -ar 16000 -b:a 64k`, ~0.5 MB/min) and runs the first configured backend (auto order):
   - **Azure** — `gpt-4o-transcribe-diarize` on a private tenant (transcription + speakers in one call). Needs `AZURE_TRANSCRIBE_DIARIZE_URL` + `_KEY`.
   - **Groq** — `whisper-large-v3` cloud API. Cheaper/faster than OpenAI. Get a key at console.groq.com/keys.
   - **OpenAI** — `whisper-1` cloud API. Get a key at platform.openai.com/api-keys.
   - **whisper-local** — faster-whisper **fully on-device** (large-v3 on CUDA, medium/int8 CPU fallback) in the managed venv; always available, no key, self-provisions on first use. Auto-selected only when no cloud backend is configured; force with `--whisper whisper-local` for confidential recordings.

Keys live in `~/.config/watch/.env`. Override the auto order with `--whisper <backend>`. Use `--no-whisper` to skip the fallback entirely.

**Iteration caching:** with a stable `--out-dir DIR`, the STT result (`segments.json`) and diarization turns (`turns.json`) are cached in the work dir — a re-run against the same dir skips both expensive steps. Default temp work dirs are fresh per run.

### Long videos: auto-split with overlap

Whisper's HTTP endpoint caps a single multipart upload at 25 MB. The script targets 20 MB per chunk (~40 minutes of 64 kbps mono mp3, leaving headroom for the multipart envelope) so it can handle arbitrarily long inputs:

1. Audio is extracted once as a single mp3 (`ffmpeg -vn -ac 1 -ar 16000 -b:a 64k`).
2. If the file fits under the 20 MB target, it's uploaded as one request — fast path, no behaviour change.
3. Otherwise, the audio is split into `ceil(size / 20 MB)` even-sized chunks with **20 seconds of overlap** between adjacent chunks (`ffmpeg -ss -c copy`, no re-encoding). Each chunk goes to Whisper in turn.
4. Returned segments are shifted onto the absolute video timeline by their chunk's start offset, then merged. At each seam, segments from the **second** chunk whose `start` falls before the overlap midpoint are dropped — the first chunk already covered that audio. A final pass collapses any consecutive duplicate texts that survive.

You don't need to do anything to enable this — it kicks in automatically when audio exceeds the threshold. The progress line on stderr looks like `[watch] audio: 38400 kB exceeds Whisper upload limit — splitting into 2 chunks (20s overlap)…` followed by one line per chunk. Cost-wise: longer audio → more Whisper minutes billed, same per-minute rate. Frames are unaffected — ffmpeg seeks the source video directly regardless of length.

## Failure modes and handling

- **Setup preflight failed** → run `python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py"` (auto-installs ffmpeg/yt-dlp via brew on macOS, scaffolds the `.env`). For API key, ask the user via `AskUserQuestion` and write it to `~/.config/watch/.env`.
- **No transcript available** → captions missing AND (no Whisper key OR Whisper API failed). Script prints a hint pointing to setup. Proceed frames-only and tell the user.
- **Long video auto-chunked** → the metadata line will say `chunked mode, N chunks × ~Xs`. The Read frame list is much longer than for a short video (~80 frames per chunk). Read them all, but be aware the image-token cost scales. If the user only cares about a specific section, suggest a re-run with `--start`/`--end` for tighter focus on that range; if they want the whole thing but cheaper, `--no-chunk` reverts to the sparse single-pass behavior.
- **Download fails** → yt-dlp's error goes to stderr. If it's a login-required or region-locked video, tell the user plainly; do not keep retrying.
- **Whisper request fails** → the error is printed to stderr (likely: invalid key, rate limit, or a network blip mid-chunk). The 25 MB single-upload limit no longer applies — long audio is auto-chunked (see "Long videos: auto-split with overlap"). The report will say "none available" for transcript on failure. You can retry with `--whisper openai` if Groq failed (or vice versa).

## Token efficiency

This skill burns tokens primarily on frames. Order of magnitude:
- 80 frames at 512px wide is roughly 50-80k image tokens depending on aspect ratio.
- The transcript is cheap (a few thousand tokens at most for a 10-minute video).
- Bumping `--resolution` to 1024 roughly quadruples the image tokens per frame. Only do it when necessary.

If you already watched a video this session and the user asks a follow-up, do **not** re-run the script — you already have the frames and transcript in context. Just answer from what you have.

## Security & Permissions

**What this skill does:**
- Runs `yt-dlp` locally to download the video and pull native captions when the source supports them (public data; the request goes directly to whatever host the URL points at)
- Runs `ffmpeg` / `ffprobe` locally to extract frames as JPEGs (regular interval sampling + scdet-detected scene cuts) and, when Whisper is needed, a mono 16 kHz audio clip
- Sends the extracted audio clip (or, for long videos, one ~20 MB chunk at a time) to Groq's Whisper API (`api.groq.com/openai/v1/audio/transcriptions`) when `GROQ_API_KEY` is set (preferred — cheaper, faster)
- Sends the extracted audio clip (or chunks) to OpenAI's audio transcription API (`api.openai.com/v1/audio/transcriptions`) when `OPENAI_API_KEY` is set and Groq is not, or when `--whisper openai` is forced
- Writes the downloaded video, frames, audio, audio chunks (when splitting), and an intermediate transcript to a working directory under the system temp dir (or `--out-dir` if specified) so Claude can `Read` them
- When `--save-md PATH` is used (or auto-defaulted for local-file sources), writes three companion files (the main `<base>.md` with a stub that Claude appends Summary + Analysis to, `<base>.protocol.md` with metadata + frames + resources, `<base>.transcript.md` with the transcript), all **outside the work dir** and preserved after cleanup
- Reads / creates `~/.config/watch/.env` (mode `0600`) to store the Whisper API key(s) and a `SETUP_COMPLETE` marker. As a fallback, also reads `.env` in the current working directory
- Creates / repairs a managed Python venv at `~/.config/watch/venv/` (pinned ML stack for the local backends: pyannote.audio, faster-whisper, torch — CUDA wheels when nvidia-smi is present) and runs `pyannote_worker.py` / `whisper_local_worker.py` inside it as subprocesses; the Python running watch.py is never modified

**What this skill does NOT do:**
- Does not upload the video itself to any API — only the extracted audio goes out, and only when native captions are missing AND Whisper is not disabled with `--no-whisper`
- Does not access any platform account (no login, no session cookies, no posting)
- Does not share API keys between providers (Groq key only goes to `api.groq.com`, OpenAI key only goes to `api.openai.com`)
- Does not log, cache, or write API keys to stdout, stderr, or output files
- Does not persist anything outside the working directory and `~/.config/watch/.env` — clean up the working directory when you're done (Step 5)

**Bundled scripts:** `scripts/watch.py` (entry point), `scripts/download.py` (yt-dlp wrapper), `scripts/frames.py` (ffmpeg frame extraction + scdet cut detection), `scripts/transcribe.py` (caption selection + Whisper orchestration), `scripts/stt.py` (pluggable speech-to-text backends - Azure / Groq / OpenAI / whisper-local), `scripts/diarize.py` (diarization backends + alignment), `scripts/pyannote_worker.py` + `scripts/whisper_local_worker.py` (run inside the managed venv, never imported by the host), `scripts/resources.py` (URL extraction from description + transcript, grouped by category), `scripts/setup.py` (preflight + installer + venv provisioning)

Review scripts before first use to verify behavior.
