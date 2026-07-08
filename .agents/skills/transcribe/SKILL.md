---
name: transcribe
description: Transcribe a video or audio file (URL or local path; .m4a/.mp3 voice memos and meeting recordings skip the frame stages automatically). Downloads with yt-dlp, extracts gap-filled frames + scdet-detected cuts, auto-chunks long videos, and transcribes via captions or a LOCAL-FIRST cascade (on-device faster-whisper by default, cloud backends as fallback) with speaker diarization ON by default (on-device pyannote, Claude-driven speaker-to-name substitution). Produces a persistent report (`<base>.{md,protocol.md,transcript.md}` plus `transcript-kompakt.md` when diarized) and a Summary that hits the chat with clickable file:// links.
argument-hint: "<video-url-or-path> [question]"
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, SendUserFile
homepage: https://github.com/danielfrey63/ai-toolbox
repository: https://github.com/danielfrey63/ai-toolbox
license: MIT
user-invocable: true
---

# /transcribe — Claude transcribes (and watches) a video or audio file

You don't have a video input; this skill gives you one. A Python script downloads the video, extracts frames as JPEGs, gets a timestamped transcript (native captions first, then Whisper API as fallback), and prints frame paths. You then `Read` each frame path to see the images and combine them with the transcript to answer the user.

## Step 0 — Setup preflight (runs every `/transcribe` invocation, silent on success)

**Python interpreter:** every `python3 ...` command in this skill is for macOS/Linux. On **Windows**, substitute `python` — the `python3` command on Windows is the Microsoft Store stub and will not run the script.

Before every `/transcribe` run, verify that dependencies and an on-device transcription path are in place:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --check
```

This is a <100ms lookup. On exit 0, the script emits **nothing** — proceed to Step 1 without comment. **Do NOT announce "setup is complete" to the user** — they don't need a status message on every turn. The only acceptable user-visible output from Step 0 is when remediation is required.

On non-zero exit, follow the table. **Local-first: never ask the user for a cloud key** — the default transcription path is on-device whisper-local (managed venv, no key, nothing leaves the machine). Only mention cloud keys if the user explicitly asks for cloud.

| Exit | Meaning | Action |
|------|---------|--------|
| `2` | Missing binaries (`ffmpeg` / `ffprobe` / `yt-dlp`) | Run installer |
| `3` | No transcription path | Provision the local venv — **don't** ask for a key (see below) |
| `4` | Both missing | Run installer (it auto-provisions the local venv on a keyless box) |

**Provisioning the on-device venv (exit 3, or exit 4 after binaries land):** the default installer (`setup.py` with no args) auto-provisions the venv on a keyless box, so usually just run it. To provision explicitly, just:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --venv
```

**Self-heal on a moved base Python:** `--check` / `--json` don't just look for the venv directory — they verify the base interpreter recorded in the venv's `pyvenv.cfg` still exists. A venv keeps its own launcher even after the Python it was built against is upgraded or removed (a scoop/pyenv/Homebrew bump), so the old behaviour reported it `ready` and the run then died deep in the worker with a cryptic exit. Now such a venv is reported **not ready** (exit `3`), and `--venv` rebuilds it from scratch (idempotent) instead of pip-installing into a dead venv. A re-run after a Python update repairs itself.

**No host-Python caveat:** the venv is built by `uv` (bootstrapped as a standalone binary into `~/.transcribe/bin/`, same as ffmpeg/yt-dlp), which fetches its own managed CPython 3.13. So the command above works **regardless of the host Python version** — even on a 3.14-only box where the torch wheels wouldn't otherwise resolve. There is no launcher dance and no `py -3.13` requirement anymore. The only platform where it can't provision is one `uv` ships no build for (`venv_buildable: false` in `--json`) — there, fall back to a cloud key.

The installer is idempotent — safe to re-run:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py"
```

On all three platforms, the default installer now does the right thing automatically:
- **macOS** — auto-runs `brew install ffmpeg yt-dlp`.
- **Linux / Windows** — routes to `cmd_install_binaries()` and downloads standalone binaries into `~/.transcribe/bin/` (yt-dlp from GitHub Releases, ffmpeg from johnvansickle on Linux / Gyan.dev on Windows). No `apt install`, no `pip install`, no admin rights needed. A `find_tool()` helper in `setup.py` prefers `~/.transcribe/bin/` and falls back to anything on PATH — system-installed versions still win when present.

It scaffolds `~/.config/transcribe/.env` with commented placeholders at `0600` perms, auto-provisions the on-device whisper-local venv on a keyless box (so the first run leaves the machine transcription-ready with no second command), and writes `SETUP_COMPLETE=true` so the next session knows this user has already been through the wizard.

**Direct standalone-binary invocation** (explicit, useful for `--force` re-download or skipping the env scaffolding):

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --install-binaries [--force]
```

Same as what the default installer routes to on Linux/Windows. Add `--force` to refresh existing binaries.

**No cloud key? That's the normal, fully-supported case — do not ask for one.** Transcription runs on-device via whisper-local (the managed venv), which the installer provisions automatically. Cloud keys (`GROQ_API_KEY` / `OPENAI_API_KEY`) are an opt-in speed upgrade, not a requirement — only set one up if the user explicitly asks for cloud transcription, in which case write the matching line into `~/.config/transcribe/.env`. If the local venv genuinely can't be built (`venv_buildable: false` in `--json` — i.e. `uv` ships no binary for this platform), offer a cloud key as the fallback; only then is `--no-whisper` (frames-only for caption-less videos) the degraded path.

**Structured mode (optional):** `python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --json` emits `{status, first_run, missing_binaries, whisper_backend, has_api_key, diarize_configured, local_venv, venv_buildable, config_file, platform}` where `status` is one of `ready | needs_install | needs_local_venv | needs_install_and_local_venv`. Branch on `venv_buildable` (does `uv` ship for this platform, i.e. can the on-device venv be built at all?) and `local_venv.ready` / `first_run` (already-provisioned vs. first-run). Provisioning is always just `setup.py --venv` — uv handles the Python, so no interpreter selection is needed.

Within a single session, you can skip Step 0 on follow-up `/transcribe` calls — once `--check` returned 0, nothing about the environment changes between turns.

## When to use

- User pastes a video URL (YouTube, Vimeo, X, TikTok, Twitch clip, most yt-dlp-supported sites) and asks about it.
- User points at a local video file (`.mp4`, `.mov`, `.mkv`, `.webm`, etc.) and asks about it.
- User points at a local **audio** file (`.m4a`, `.mp3`, `.wav`, voice memos, meeting recordings) — the frame stages are skipped automatically; transcription, diarization, and the report pipeline run normally. The defaults are already fully on-device (whisper-local + pyannote-local), so confidential recordings need no extra flags.
- User types `/transcribe <url-or-path> [question]`.

## Recommended limits

- **Frame budget scales with duration:**
  - ≤30s → ~1-2 fps (up to 30 frames)
  - 30s-1min → ~40 frames
  - 1-3min → ~60 frames
  - 3-10min → ~80 frames
- **Long videos (>10 min) auto-chunk by default.** Without `--start`/`--end`, the script splits the video into `ceil(duration / 10min)` chunks of even size and runs each chunk through the focused-mode dense budget. A 60-min video becomes 6 chunks of 10 min × ~80 frames per chunk = ~480 regular frames total (plus scene-cut frames). This costs proportionally more image tokens than the old sparse single-pass behavior, but yields per-chunk coverage comparable to dedicated focused runs. Pass `--no-chunk` to revert to the sparse single-pass behavior, or `--start`/`--end` to zero in on one specific section instead.
- **Hard caps remain: 2 fps and `--max-frames` per chunk.** `--max-frames N` (default 80) is now the *per-chunk* cap, not the global cap. A 60-min video at default settings extracts up to 80 × 6 = 480 regular frames; if you want to clamp the total, lower `--max-frames` or pass `--no-chunk`.

## How to invoke

**Step 1 — parse the user input.** Separate the video source (URL or path) from any question the user asked. Example: `/transcribe https://youtu.be/abc what language is this in?` → source = `https://youtu.be/abc`, question = `what language is this in?`.

**Step 2 — run the transcribe script.** Pass the source verbatim. Do not shell-escape it yourself beyond normal quoting:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/run.py" "<source>"
```

Optional flags:
- `--start T` / `--end T` — focus on a section. Accepts `SS`, `MM:SS`, or `HH:MM:SS`. When either is set, fps auto-scales denser (see "Focusing on a section" below).
- `--max-frames N` — cap on regular frames per chunk (default 80, hard max 100). In single-chunk modes (focused or `--no-chunk`) this is also the global cap.
- `--no-chunk` — disable auto-chunking for long videos. Reverts to the old single-pass sparse behavior (100 frames spread thinly across the whole video).
- `--diarize [BACKEND]` — speaker diarization. Output transcript lines become `[MM:SS] [<speaker>] text`. **ON by default** (auto mode): the first configured backend runs, **local first** — pyannote local (HF_TOKEN) → pyannote.ai → AssemblyAI; when none is configured, the run degrades silently to a plain transcript. If the chosen auto backend fails, the cascade falls through to the next configured one. `--no-diarize` turns diarization off; an explicit `--diarize <backend>` pins exactly that backend (no cascade, fails loudly). Backends:
  - **`--diarize assemblyai`** — cloud, all-in-one. Replaces Whisper: one API call returns transcription + speaker labels. Uses `universal-3-pro` (fallback `universal-2`) and `language_detection: true` by default — handles multilingual content (DE-CH + EN + FR/IT references) without an explicit language hint. Needs `ASSEMBLYAI_API_KEY` in env or `.env`; optionally `ASSEMBLYAI_REGION=eu` for EU data residency. ~0.37 USD/h.
  - **`--diarize pyannote-api`** — cloud pyannote.ai (diarization-only). Runs alongside Whisper; the script aligns speaker turns to Whisper segments by overlap. Needs `PYANNOTE_API_KEY`. Cheaper than AssemblyAI.
  - **`--diarize pyannote-local`** — local pyannote.audio. Free, fully on-device (nothing leaves the machine — the right choice for confidential recordings). Zero manual setup: the heavy ML stack lives in a **managed venv** at `~/.config/transcribe/venv/`, provisioned idempotently on first use (or explicitly via `setup.py --venv`); the diarization itself runs as a worker subprocess (`pyannote_worker.py`) inside that venv, so the host Python is never touched. GPU is auto-detected (nvidia-smi → cu124 wheels; a 41-min recording diarizes in ~90 s on GPU vs ~36 min on CPU). Requirements that remain with the user: a Hugging Face token (`HF_TOKEN`) plus license acceptance for **both** gated repos: `pyannote/speaker-diarization-3.1` *and* `pyannote/segmentation-3.0`. Speaker count stays on auto by design — forcing `num_speakers` collapses onto the dominant voice on single-mic recordings (observed: 95% one speaker on a real 2-person meeting); surplus mini-clusters are merged/labeled afterwards by Claude from transcript context. Diarization aligns to the Whisper transcript.
  - Identifying *which name* maps to `A`/`B`/`SPEAKER_00` is done later by Claude using address patterns in the transcript (see Step 4 Inventar → Personen & Stimmen). For **audio-only sources** (no frames as ground truth), role/content evidence substitutes for frame evidence: a label that consistently owns a known person's responsibilities ("I'll prepare the compliance slide") plus at least one address-pattern hit qualifies as high-confidence; document the reasoning in the transcript header. Surplus diarization clusters that map to no one stay as bare letters with a header note.
- `--resolution W` — change frame width in px (default 512; bump to 1024 only if the user needs to read on-screen text)
- `--fps F` — override auto-fps (clamped to 2 fps max)
- `--out-dir DIR` — keep working files somewhere specific (default: an auto-generated tmp dir)
- `--fresh` — ignore persisted `<base>.segments.json` / `.turns.json` and re-transcribe + re-diarize from scratch (default behaviour reuses them for idempotent re-runs)
- `--whisper azure-diarize|groq|openai|whisper-local` — pin a specific transcription backend (no cascade, fails loudly). Default is a **local-first cascade**: whisper-local → azure-diarize → groq → openai — each backend that fails falls through to the next configured one. `whisper-local` = faster-whisper fully on-device in the managed venv (`~/.config/transcribe/venv/`, self-provisions on first use, GPU auto-detected) — no key, nothing leaves the machine.
- `--no-whisper` — disable the Whisper fallback entirely (frames-only if no captions)
- `--no-scene` — disable scdet-based cut detection (default: enabled with auto-tuned threshold, see "Scene cut detection" below)
- `--scene-threshold F` — override the auto-detected scdet threshold (default: auto via knee-point on the score distribution; lower = more sensitive)
- `--scene-min-gap S` — minimum seconds between consecutive cut frames (default `2.0`, de-clusters animation/B-roll bursts)
- `--scene-max-frames N` — cap on additional cut frames (default `80`, applied separately from `--max-frames`)
- `--scene-settle-seconds S` — seconds after a detected cut to wait before extracting (default `1.0`). Lets UI transitions / dialogs / launcher windows render before capture, so cut frames don't land on loading-state / black mid-transition pixels. Capped at `next_cut - 0.3s` so we never bleed into the following shot. Set to `0` to revert to the old just-before-cut behavior. Higher values (~2–4 s) help apps that take longer to render but risk bleeding into transient flashes.
- `--save-md PATH` — save the report as **three companion files**: PATH itself (the main file — a stub for Claude to append `## Summary` and `## Analysis`), plus `<base>.protocol.md` (metadata + frame list + resources + footer) and `<base>.transcript.md` (full transcript) as siblings, where `<base>` is PATH with `.md` (or legacy `.transcribe.md`) stripped. Defaults:
  - **Local-file sources** → `<video-stem>.md` next to the source (e.g. `videos/test.mp4` → `videos/test.{md,protocol.md,transcript.md}`).
  - **URL sources** (YouTube, Vimeo, etc.) → `./transcribe/<YYYY-MM-DD>-<slug>/<slug>.md` in the current working directory, where `<slug>` is a sanitized form of the video title returned by yt-dlp (lowercase ASCII, non-alphanumeric → `-`, ~60 chars max). The per-video subfolder keeps multiple runs tidy and leaves room for retained video / frame snapshots. `.gitignore`-friendly via a single `transcribe/` entry.
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

The chosen auto-threshold is printed to stderr (`[transcribe] N cuts detected (auto-picked X.YZ)`) and shown in the report metadata as `scdet ≥ X.Y auto`. The regular-sampler line shows `(gap-filled, ~F fps avg)` so it's clear the spacing is non-uniform.

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

When `--no-scene` is set, the regular sampler falls back to uniform spacing — same effective behaviour as the original upstream skill.

When to override with `--scene-threshold F`:
- Auto picked too few cuts and you know there are subtle transitions worth catching (force lower, e.g. `--scene-threshold 8`).
- Auto picked too many on cut-heavy content and you only want hard cuts (force higher, e.g. `--scene-threshold 30`).
- Debugging or reproducibility (locking the threshold across re-runs).

Cost: scdet adds ~5–10 % to wall-clock time. Each cut frame costs the same as a regular frame in image tokens. Gap-filling itself is free (pure timestamp arithmetic).

Examples:
```bash
# Last 10 seconds of a 1 minute video
python3 "${CLAUDE_SKILL_DIR}/scripts/run.py" video.mp4 --start 50 --end 60

# Zoom into 2:15 → 2:45 at 3 fps (90 frames)
python3 "${CLAUDE_SKILL_DIR}/scripts/run.py" "$URL" --start 2:15 --end 2:45 --fps 3

# From 1h12m to the end of the video
python3 "${CLAUDE_SKILL_DIR}/scripts/run.py" "$URL" --start 1:12:00
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

If they didn't ask anything specific, write the full three-section report (`## Übersicht`, `## Summary`, `## Analysis`). **Before writing it, Read `${CLAUDE_SKILL_DIR}/references/report-writing.md`** — it defines the mandatory pre-stage (Inventar + Konsistenz-Check + Datum identifizieren), the Schlüssel-Illustrationen extraction via `illustrate.py`, the spec of all three sections, and the exact markdown layout to append. Do not write the report from memory of this paragraph; the reference file is the authoritative methodology.

**Step 5 — persist Übersicht + Summary + Analysis to the main file.** Check the report header for the three saved-files lines (`**Protocol file:**`, `**Transcript file:**`, `**Analysis target:**`). The script has already written the protocol (`<base>.protocol.md`) and transcript (`<base>.transcript.md`). The Analysis-target file (the main `<base>.md`) contains only a short stub with cross-links — **append the full three-section report to it** so the user ends up with one human-readable document alongside the two raw-data companions. Use the exact layout defined in `${CLAUDE_SKILL_DIR}/references/report-writing.md`, section «Report layout».

Append (don't overwrite) — the stub header above stays intact. For URL sources without `--save-md`, skip this step entirely and just answer in chat.

**Embed the key illustrations (if Step 4 produced any).** For each entry in `<base>.illustrations/manifest.json`, drop a Markdown image at the most relevant spot in the report — usually inside the Summary `### <Thema>` group whose topic the illustration depicts, or right under the Chapter-Struktur entry it belongs to. Use a **relative** path so the `.md` stays portable, and the manifest's caption + timestamp:

```markdown
![Zielarchitektur DfA-GIS](<base>.illustrations/ill_01_t00734_zielarchitektur-dfa-gis.png)
*Abb. — Zielarchitektur DfA-GIS [12:14]*
```

When the relative path contains spaces (typical for meeting recordings), wrap it in angle brackets — `![…](<my video.illustrations/ill_01….png>)` — otherwise CommonMark truncates the URL at the first space.

Place each image once, where it carries the most explanatory weight; don't scatter the same crop across sections. If the manifest is empty or absent, there's nothing to embed — move on.

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

**Surface the illustrations as images in chat (if any).** A `file://` link to a PNG renders in a terminal but not in the Claude mobile/desktop app, where the user often reads. So when `<base>.illustrations/manifest.json` lists crops, send them with **`SendUserFile`** (status `normal`) right after the Files block — the app renders them inline. Pass all crop paths in one call with a short `caption` (e.g. `"Schlüssel-Illustrationen aus dem Video"`); the user then sees the diagrams without opening the file. Skip when there are no illustrations.

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

**Step 6 — clean up.** The script prints a working directory at the end. If the user isn't going to ask follow-ups about this video, delete it with `rm -rf <dir>`. **If `--save-md` produced the companion files (`<base>.md` + `<base>.protocol.md` + `<base>.transcript.md`, plus `<base>.illustrations/` and `<base>.illustrations.spec.json` when illustrations were extracted), they live outside the work dir and are preserved** by the cleanup. If the user might follow up, leave the work dir in place too.

## Transcription

The script gets a timestamped transcript in one of two ways:

1. **Native captions (free, preferred).** yt-dlp pulls manual or auto-generated subtitles from the source platform if available.
2. **STT cascade, local first.** If no captions came back (or the source is a local file), the script extracts audio (`ffmpeg -vn -ac 1 -ar 16000 -b:a 64k`, ~0.5 MB/min) and tries the configured backends in order — each failure cascades to the next:
   - **whisper-local** (DEFAULT) — faster-whisper **fully on-device** (large-v3 on CUDA, medium/int8 CPU fallback) in the managed venv; always available, no key, self-provisions on first use. Nothing leaves the machine.
   - **Azure** — `gpt-4o-transcribe-diarize` on a private tenant (transcription + speakers in one call). Needs `AZURE_TRANSCRIBE_DIARIZE_URL` + `_KEY`.
   - **Groq** — `whisper-large-v3` cloud API. Cheaper/faster than OpenAI. Get a key at console.groq.com/keys.
   - **OpenAI** — `whisper-1` cloud API. Get a key at platform.openai.com/api-keys.

Keys live in `~/.config/transcribe/.env`. `--whisper <backend>` pins one backend and disables the cascade. Use `--no-whisper` to skip the fallback entirely.

**Idempotent re-runs (resume):** when the output is persisted (the default for local files, or any `--save-md`), the STT result and diarization turns are written next to it as `<base>.segments.json` and `<base>.turns.json`. Reprocessing the same source reuses them — the expensive STT + diarization steps are skipped (a 41-min recording resumes in ~1 s) and the pipeline goes straight to alignment, rendering, and (Claude's) cleanup. This makes "re-clean an existing transcript" or "re-render after a tweak" free. Pass `--fresh` to ignore the persisted intermediates and re-transcribe + re-diarize from scratch. With `--no-save-md` the caches live only in the ephemeral work dir (so use `--out-dir DIR` if you want them to survive).

### Long videos: auto-split with overlap

Whisper's HTTP endpoint caps a single multipart upload at 25 MB. The script targets 20 MB per chunk (~40 minutes of 64 kbps mono mp3, leaving headroom for the multipart envelope) so it can handle arbitrarily long inputs:

1. Audio is extracted once as a single mp3 (`ffmpeg -vn -ac 1 -ar 16000 -b:a 64k`).
2. If the file fits under the 20 MB target, it's uploaded as one request — fast path, no behaviour change.
3. Otherwise, the audio is split into `ceil(size / 20 MB)` even-sized chunks with **20 seconds of overlap** between adjacent chunks (`ffmpeg -ss -c copy`, no re-encoding). Each chunk goes to Whisper in turn.
4. Returned segments are shifted onto the absolute video timeline by their chunk's start offset, then merged. At each seam, segments from the **second** chunk whose `start` falls before the overlap midpoint are dropped — the first chunk already covered that audio. A final pass collapses any consecutive duplicate texts that survive.

You don't need to do anything to enable this — it kicks in automatically when audio exceeds the threshold. The progress line on stderr looks like `[transcribe] audio: 38400 kB exceeds Whisper upload limit — splitting into 2 chunks (20s overlap)…` followed by one line per chunk. Cost-wise: longer audio → more Whisper minutes billed, same per-minute rate. Frames are unaffected — ffmpeg seeks the source video directly regardless of length.

## Failure modes and handling

- **Setup preflight failed** → run `python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py"` (auto-installs ffmpeg/yt-dlp + uv, scaffolds the `.env`, and auto-provisions the on-device whisper-local venv on a keyless box). Transcription is local-first — **don't ask the user for a cloud key**; the venv is built by uv with its own managed Python, so the host Python version never matters. Only if `venv_buildable: false` (uv has no build for this platform) is a cloud key the fallback.
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
- Reads / creates `~/.config/transcribe/.env` (mode `0600`) to store the Whisper API key(s) and a `SETUP_COMPLETE` marker. As a fallback, also reads `.env` in the current working directory
- Downloads `uv` (standalone binary, into `~/.transcribe/bin/`) and uses it to create / repair a managed Python venv at `~/.config/transcribe/venv/` from its own fetched CPython (no dependency on the host Python version), with a pinned ML stack for the local backends (pyannote.audio, faster-whisper, torch — CUDA wheels when nvidia-smi is present), then runs `pyannote_worker.py` / `whisper_local_worker.py` inside it as subprocesses; the Python running run.py is never modified

**What this skill does NOT do:**
- Does not upload the video itself to any API — only the extracted audio goes out, and only when native captions are missing AND Whisper is not disabled with `--no-whisper`
- Does not access any platform account (no login, no session cookies, no posting)
- Does not share API keys between providers (Groq key only goes to `api.groq.com`, OpenAI key only goes to `api.openai.com`)
- Does not log, cache, or write API keys to stdout, stderr, or output files
- Does not persist anything outside the working directory and `~/.config/transcribe/.env` — clean up the working directory when you're done (Step 5)

**Bundled scripts:** `scripts/run.py` (entry point), `scripts/download.py` (yt-dlp wrapper), `scripts/frames.py` (ffmpeg frame extraction + scdet cut detection), `scripts/transcribe.py` (caption selection + Whisper orchestration), `scripts/stt.py` (pluggable speech-to-text backends - Azure / Groq / OpenAI / whisper-local), `scripts/diarize.py` (diarization backends + alignment), `scripts/pyannote_worker.py` + `scripts/whisper_local_worker.py` (run inside the managed venv, never imported by the host), `scripts/resources.py` (URL extraction from description + transcript, grouped by category), `scripts/setup.py` (preflight + installer + uv bootstrap + venv provisioning)

Review scripts before first use to verify behavior.
