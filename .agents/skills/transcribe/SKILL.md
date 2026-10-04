---
name: transcribe
description: "Transcribes and watches video or audio files (URL or local path): downloads with yt-dlp, extracts frames and scene cuts, transcribes via native captions or on-device Whisper with speaker diarization, and writes a persistent Markdown report (overview, summary, analysis, transcript, speaker mapping). Use when the user shares a video or audio URL or file (YouTube, Vimeo, meeting recording, voice memo, screen recording) and wants it transcribed, summarized, or asks what is said or shown in it. Trigger: «transkribiere», «Video zusammenfassen», «Meeting-Aufnahme auswerten», «was wird im Video gesagt»."
argument-hint: "<video-url-or-path> [question]"
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, SendUserFile
homepage: https://github.com/danielfrey63/ai-toolbox
repository: https://github.com/danielfrey63/ai-toolbox
license: MIT
user-invocable: true
---

# /transcribe – watch and transcribe a video or audio file

Claude has no video input; this skill provides one. `scripts/run.py` downloads the media, extracts frames as JPEGs, produces a timestamped (and by default speaker-labeled) transcript and writes companion files. Claude then `Read`s the frames and the transcript, writes the report and answers the user.

**Python interpreter:** commands use `python3` (macOS/Linux). On Windows use `python`; `python3` there is the Microsoft Store stub.

## When to use

- A video URL (YouTube, Vimeo, X, TikTok, Twitch clip, most yt-dlp-supported sites) or a local video file (`.mp4`, `.mov`, `.mkv`, `.webm`) with a request to transcribe, summarize or answer questions about it.
- A local **audio** file (`.m4a`, `.mp3`, `.wav`, voice memo, meeting recording). Frame stages are skipped automatically; transcription and diarization run fully on-device by default, so confidential recordings need no extra flags.
- `/transcribe <url-or-path> [question]`.

## Reference files

Load only what the current situation needs:

- `references/report-writing.md` – **mandatory before writing the report** (Step 4).
- `references/setup.md` – preflight exit codes, installer, managed venv, cloud keys.
- `references/options.md` – all `run.py` flags, frame budgets, focused mode, scene detection, glossary, output locations.
- `references/repair.md` – decoder-collapse repair pass, `**Repaired passages:**`.
- `references/pipeline.md` – transcript sources, cache resume, blocking, caption cross-check, version stamp, CPU/GPU, security, script list.

## Step 0 – Setup preflight (silent on success)

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --check
```

Exit 0: proceed without comment; do not announce "setup complete". Within a session, skip this step after the first exit 0.

| Exit | Meaning | Action |
|------|---------|--------|
| `2` | Missing `ffmpeg` / `ffprobe` / `yt-dlp` | Run `python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py"` |
| `3` | No transcription path | Run `python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --venv` |
| `4` | Both missing | Run the installer (it also provisions the venv) |

**Local first: never ask the user for a cloud key.** The default path is on-device whisper-local in a managed venv (no key, nothing leaves the machine). Mention cloud keys only if the user explicitly asks for cloud transcription or `--json` reports `venv_buildable: false`. Advisory warnings on exit 0 (stale yt-dlp, missing deno) matter only when a download fails; then see `references/setup.md`.

## Step 1 – Parse the input

Separate the source (URL or path) from any question: `/transcribe https://youtu.be/abc what language is this in?` → source `https://youtu.be/abc`, question `what language is this in?`.

**Local recordings: harmonize the base name first.** Every report family follows `YYYYMMDD-hhmm - <Thema>` (e.g. `20260824-1405 - ACA-DFR - Meeting.m4a`). If the source file does not match (Teams default names, `YYYY-MM-DD-hh-mm-ss - …` prefixes), rename it before the run so all companions inherit the base. Start time from ffprobe `creation_time`, or file mtime minus duration, rounded to the minute.

## Step 2 – Run the script

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/run.py" "<source>"
```

Pass the source verbatim with normal quoting. Defaults are right for most runs. Common flags (full list in `references/options.md`):

- `--start T` / `--end T` – the user names a moment or section ("around 2:30", "the last 30 seconds"), or only one part of a long video matters. Denser frames, transcript filtered to the range.
- `--language de` – pass whenever the language is known (used by the repair pass).
- `--resolution 1024` – only when on-screen text must be read (about 4× image tokens).
- `--no-scene` – talking heads without cuts; `--no-chunk` – one sparse pass instead of 10-min chunks.
- `--no-diarize` / `--diarize <backend>` – diarization is on by default (local first: pyannote-local → pyannote-api → assemblyai; silently off when none is configured). An explicit backend pins it.
- `--whisper <backend>` – pin one STT backend (default cascade: whisper-local → azure-diarize → groq → openai). `--no-whisper` – frames only when there are no captions.
- `--fresh` – ignore the cached `<base>.segments.json` / `.turns.json` and recompute.
- `--save-md PATH` / `--no-save-md` – override or disable the report location (default: next to local files; `./transcribe/<YYYY-MM-DD>-<slug>/` for URLs).
- `--background` – unattended run with a per-recording lock. A manual run that meets such a lock prints `[transcribe] Lauf auf derselben Aufnahme aktiv … übernommen: warte auf Abschluss`; that is progress, keep waiting.

**Transcript source decision (automatic):** native captions in the video's own language win for URLs; otherwise, and for local files, the on-device STT cascade runs. A cached transcript from a previous run outranks captions. The protocol header names the source. Details: `references/pipeline.md`.

**Domain glossary:** for recordings with rare names or jargon, put a `transcribe-glossary.txt` next to the source (one term per line, most-misheard first, max about 300 characters). Feed every term the user corrects back into it. Details: `references/options.md`.

**Cast list:** a `transcribe-participants.txt` next to the recording (`Name - role` per line) is the cheapest way to give the speaker mapping its candidates.

## Step 3 – Read frames and transcript

In one message with parallel tool calls:

- `Read` every frame path under `## Frames`. Entries carry `t=MM:SS` and are tagged `[REG]` (regular, gap-filled) or `[CUT]` (scene cut); read both. A `[CUT]` image is taken about 0.5–2.5 s after the timestamp in its filename.
- `Read` the transcript file from the `**Transcript file:**` header line (it is not printed to stdout). Skip only if the header says `Transcript: none available`.

Long videos are auto-chunked (about 80 frames per 10-min chunk); read them all, but suggest `--start`/`--end` if the user only cares about one part. In a follow-up question on a video already watched this session, do not re-run the script; answer from context.

## Step 4 – Write the report

Evidence streams:

- **Frames** – what is on screen. Frames are ground truth for names and labels; the transcript is noisy.
- **Transcript** – what is said, with `[MM:SS]` and speaker labels when diarized.
- **Resources** – `## Resources` in the protocol aggregates every `https://` URL from the description, the transcript and the screen, grouped by category with its origin.
- **On-screen references** – `<base>.links.md` lists URLs, wiki page IDs, ticket keys, hosts and UNC paths read by OCR from cut and changed frames, each with `[MM:SS]`. Rows marked `(?)` are below the confidence threshold: `Read` the named frame and confirm or correct the row before citing it. Raw OCR text (also name plates for speaker evidence) is cached in `<base>.ocr.json`; `python3 "${CLAUDE_SKILL_DIR}/scripts/ocr.py" --render <base>.ocr.json` re-renders `links.md`.
- **Repaired passages** – if the protocol lists `**Repaired passages:**`, those spans were re-transcribed after a decoder collapse; treat them as reviewed but not verified (`references/repair.md`).
- **Cross-check** – if `<base>.crosscheck.md` exists, it lists windows where Whisper and the platform captions diverge; work through them in the Konsistenz-Check.

**Always write the full report when companion files are persisted** (the default). A user question comes on top, never instead: write the report, then answer the question in chat with timestamps. Skip the report only with `--no-save-md`.

**Before writing, `Read` `${CLAUDE_SKILL_DIR}/references/report-writing.md`.** It defines the mandatory pre-stage (Inventar, Konsistenz-Check, date identification), the key-illustration extraction via `illustrate.py`, the three sections `## Übersicht`, `## Summary`, `## Analysis` and the exact layout. Do not write the report from memory.

## Step 5 – Persist and reply

**Append the report to the main file.** The header lines `**Protocol file:**`, `**Transcript file:**` and `**Analysis target:**` name the companions. `<base>.md` contains a stub with cross-links; append (do not overwrite) the full three-section report in the layout from `report-writing.md`. For URL sources with `--no-save-md`, just answer in chat.

**Embed key illustrations** if `<base>.illustrations/manifest.json` lists any. Illustrations exist only as output of `illustrate.py` from `<base>.illustrations.spec.json`, never as hand-cropped frames. Place each image once where it carries the most weight (usually its Summary `### <Thema>` group), with a relative path and the manifest's caption and timestamp:

```markdown
![Zielarchitektur DfA-GIS](<base>.illustrations/ill_01_t00734_zielarchitektur-dfa-gis.png)
*Abb. – Zielarchitektur DfA-GIS [12:14]*
```

Wrap paths containing spaces in angle brackets: `![…](<my video.illustrations/ill_01….png>)`.

**Speaker mapping (diarized runs only).** The script pre-fills `<base>.speakers.md` once: one row per label with talk time, turn count and active window, the participants found (OCR name plates, `<v Name>` tags of a platform VTT, `transcribe-participants.txt`), address hits («Simon, …») with the labels speaking before and after, self-introductions and caption-voice overlap (pre-filled `high` at ≥ 60 %). Do the identification **in that file**:

- Fill **Name** (canonical first name; `Andrea B` / `Andrea T` on collision), **Confidence** and **Evidence** for every label the evidence carries.
- Frame (or caption-voice) evidence AND address-pattern evidence = high. One of the two = medium, write the name with `(?)`. Neither = leave Name empty.
- Audio-only sources: consistent role/content evidence (a label owns a known person's responsibilities) plus at least one address hit counts as high.
- A shared room microphone files several people under one label: attribute single blocks via the **Overrides** table (`| Zeit | Name | Wortmeldung |`). Two labels given the same name merge.

Then substitute the names deterministically:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/speakers.py" --apply "<base>"
```

This rewrites `[SPEAKER_00]` → `[Urs]` in `<base>.transcript.md` and `<v SPEAKER_00>` → `<v Urs>` in `<base>.vtt` for every named label; `(?)` names and empty rows stay bare labels. Later `run.py` re-runs read the same file, so user corrections survive. The file is never overwritten; delete it to have it pre-filled again. The report's Inventar *Personen & Stimmen* summarizes this file, and labels left without a name become rows of `### Offene Sprecherzuordnung`. Non-diarized transcripts have no speakers file; skip this.

**Compact transcript (diarized runs only).** Write `<base>.transcript-kompakt.md`, an editorially condensed rendition:

- One block per substantive statement: `**[MM:SS] <Name>:** <polished text>`, timestamp = start of the turn.
- Fix misrecognitions resolved in the Konsistenz-Check, normalize dialect garbles into standard language, fold fillers and bare acknowledgements ("Ja.", "Genau.") into the flow.
- Group blocks under `## <Thema>` headings in chronological order.
- Header: source, duration, participants, a note that the file is condensed, and a pointer to `<base>.transcript.md` as the verbatim reference.
- Attribute leftover unsure labels by context where the speaker is obvious; otherwise keep the bare label. Statements inside mixed blocks get their attribution here.

**Chat reply: Kernaussagen and file links only.** Echo only the `### Kernaussagen` block (3–6 bullets), then the files as `file://` links built from the absolute header paths:

```
<### Kernaussagen block – 3–6 bullets, nothing else>

**Files**
- Protocol: [`<base>.protocol.md`](file:///absolute/path/to/<base>.protocol.md) – metadata + frame list
- Transcript: [`<base>.transcript.md`](file:///absolute/path/to/<base>.transcript.md) – full transcript
- Kompakt: [`<base>.transcript-kompakt.md`](file:///absolute/path/to/<base>.transcript-kompakt.md) – condensed transcript (only when diarized)
- Speakers: [`<base>.speakers.md`](file:///absolute/path/to/<base>.speakers.md) – label-to-name mapping, N open (only when diarized)
- Links: [`<base>.links.md`](file:///absolute/path/to/<base>.links.md) – references read off the screen (video only)
- Analysis: [`<base>.md`](file:///absolute/path/to/<base>.md) – Übersicht + Summary + full Analysis
```

Do not echo Chapter-Struktur, Summary or Analysis into chat. A specific user question is answered in addition to the Kernaussagen block. If the manifest lists illustrations, send them with **`SendUserFile`** (status `normal`, all crop paths in one call, short caption such as `"Schlüssel-Illustrationen aus dem Video"`), because `file://` PNG links do not render in the desktop and mobile apps.

## Step 6 – Clean up

The script prints a working directory. If no follow-ups are expected, delete it (`rm -rf <dir>`). Companion files (`<base>.md`, `.protocol.md`, `.transcript.md`, `.speakers.md`, `.links.md`, `.ocr.json`, `.segments.json`, `.turns.json`, `.vtt`, `.illustrations/`, `.illustrations.spec.json`) live outside the work dir and are preserved. The native OCR frames referenced from `links.md` are inside the work dir: resolve any `(?)` rows before deleting it. If the user might follow up, keep the work dir.

## Failure modes

- **Preflight failed** → run the installer (Step 0). Do not ask for a cloud key; only `venv_buildable: false` makes a key the fallback.
- **No transcript available** → no captions and every STT backend failed. The script prints a hint; proceed frames-only and tell the user.
- **Gated YouTube streams (SABR / PO token)** → `download.py` escalates on its own: normal 720p pull, then player clients without PO token (`tv,web_embedded,android_vr`, often 360p, enough for 512 px frames), then audio only (`**Degraded run:** audio-only`, transcript and diarization without frames). DRM-protected content is out of scope.
- **Download fails but captions landed** → the run degrades to **captions-only** (no frames, no STT, no diarization; `**Degraded run:**` line in the protocol). Analyze normally and state in the Summary that on-screen content is not covered. If the preflight reported a stale yt-dlp, refresh it once (`setup.py --install-binaries --force`) and re-run.
- **Download fails without captions** → the script exits with yt-dlp's classified reason (403, PO token, DRM, login, region lock). Tell the user plainly; do not retry in a loop. For 403/PO token suggest the yt-dlp refresh once.
- **Cloud STT request fails** → error on stderr (invalid key, rate limit, network). The cascade falls through; with a pinned backend, retry with another `--whisper` backend.
- **Transcript shows loops or foreign script despite the repair pass** → see `references/repair.md` (standalone `repair.py`, `--language`).
- **Protocol says the transcript was resumed from a cache written by another version** → re-run with `--fresh` if transcript quality matters.

## Token efficiency

Frames dominate the cost: 80 frames at 512 px are roughly 50–80k image tokens; the transcript of a 10-minute video is a few thousand. `--resolution 1024` roughly quadruples image tokens per frame. Prefer a focused `--start`/`--end` re-run over a denser full pass.
