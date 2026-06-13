# /watch

**Give Claude the ability to watch any video.**

`/watch` is a skill + Claude Code plugin maintained as part of the
[AI-Toolbox](https://github.com/danielfrey63/ai-toolbox), at
`.agents/skills/watch/`. See [Install](#install) below for Claude Code,
Codex and claude.ai (web).

Zero config to start — `yt-dlp` and `ffmpeg` install on first run via `brew` on macOS (Linux/Windows auto-download standalone binaries). Captions cover most public videos for free. When a video has no captions, transcription runs **fully on-device by default** (faster-whisper in a managed venv, GPU auto-detected) — no API key required, nothing leaves your machine. Cloud backends are an optional upgrade, not a prerequisite.

---

Claude can read a webpage, run a script, browse a repo. What it can't do, out of the box, is *watch a video*. You paste a YouTube link and it has to either guess from the title or pull a transcript that's missing 90% of what's on screen.

With `/watch` you can paste a URL or a local path, ask a question, and Claude downloads the video, extracts frames at an auto-scaled rate, pulls a timestamped transcript (free captions when available, Whisper API as fallback), and `Read`s every frame as an image. By the time it answers, it has *seen* the video and *heard* the audio.

```
/watch https://youtu.be/dQw4w9WgXcQ what happens at the 30 second mark?
```

## Why this exists

I built this because I'm constantly using video to keep up with content. If I see a YouTube video that's blowing up, I want to know how the creator structured the hook — what's on screen in the first 3 seconds, what they said, why it worked. That used to mean watching it myself with a notepad. Now I just paste the URL and ask.

The other half is summarization. Most YouTube videos don't deserve 20 minutes of my attention. I hand the URL to Claude, it pulls the transcript, and tells me what actually happened. If the visual matters, frames come along too. If it's a podcast or a talking head, transcript is enough.

Claude is great at reading and synthesizing — but until now, video was the one input I couldn't hand it. Pasting a YouTube link got you nothing useful. `/watch` closes that gap.

## What people actually use it for

**Analyze someone else's content.** `/watch https://youtu.be/<viral-video> what hook did they open with?` Claude looks at the first frames, reads the opening transcript, breaks down the structure. Same for ad creative, competitor launches, podcast intros, anything where the *how* matters as much as the *what*.

**Diagnose a bug from a video.** Someone sends you a screen recording of something broken. `/watch bug-repro.mov what's going wrong?` Claude watches the recording, finds the frame where the issue appears, describes what's on screen, often catches the cause without you ever opening the file.

**Summarize a video.** `/watch https://youtu.be/<long-thing> summarize this` does the obvious thing — pulls the structure, the key moments, what was actually said and shown. Faster than watching at 2x.

**Transcribe a meeting recording or voice memo.** `/watch meeting.m4a` works on pure audio — the frame stages skip automatically, and the default pipeline (local Whisper + local speaker diarization) turns a 41-minute recording into a speaker-labeled, timestamped transcript plus a condensed editorial version, without a single byte leaving your machine. Built for confidential recordings.

## How it works

Five stages. The visual stage is skipped automatically for audio-only sources; everything else runs the same.

| Stage | What happens |
|-------|--------------|
| **1. Input** | You hand it a source (video/audio, URL or local path) and an optional question. |
| **2. Acquire** | yt-dlp downloads URLs (or local files are probed in place); audio-only sources skip the visual stage. |
| **3. See** *(video only)* | Scene-cut detection + gap-filled frame sampling, auto-chunked for long videos. |
| **4. Hear** | Transcription → diarization → turn-merge → speaker-naming — four distinct sub-steps. |
| **5. Answer & persist** | Claude reads frames + transcript + resources, answers grounded in them, and saves a reusable report. |

### 1. Input

- A **source**: a URL (anything yt-dlp supports — YouTube, Loom, TikTok, X, Instagram, plus a few hundred more) or a local path — video (`.mp4`, `.mov`, `.mkv`, `.webm`) or **pure audio** (`.m4a`, `.mp3`, `.wav`). For audio, stage 3 is skipped automatically.
- An optional **question**. With one, Claude tailors the answer to it; without one, you get a structured Summary + Analysis.

### 2. Acquire

- **URLs** — `yt-dlp` downloads into a temp working directory and grabs the description (for the resource scan) plus native captions when the platform has them.
- **Local files** — no download; probed in place with `ffprobe`. The presence of a video stream (`has_video`) decides whether stage 3 runs at all.

### 3. See — frames *(video only)*

- **Scene cuts** — an `scdet` pass scores every frame's pixel-difference; a knee-point heuristic picks a per-video threshold (no static cut-off). Each cut becomes one frame after a settle-delay (default 1.0 s) so transitions / dialogs finish rendering. `--no-scene`, `--scene-threshold F`.
- **Gap-filled sampling** — a duration-aware budget (≤30s → ~30 frames … 3-10min → ~80) is distributed into the gaps *between* cuts rather than at uniform intervals, so cut-dense regions don't waste budget and long uncovered spans get coverage. 512px JPEGs; `--resolution 1024` for on-screen text.
- **Auto-chunk** — videos > 10 min split into ~10-min chunks, each with the dense focused budget. `--no-chunk` reverts to sparse single-pass; `--start`/`--end` zeroes in on one section.

### 4. Hear — transcript

Four separate sub-steps, in order:

- **Transcription** — native captions first (`yt-dlp`, free, covers most public videos). Otherwise a **local-first STT cascade** over the extracted mono 16 kHz audio, each failure falling through to the next: **whisper-local** (DEFAULT — faster-whisper `large-v3` on CUDA / `medium` int8 on CPU, in the managed venv; no key, on-device) → **Azure `gpt-4o-transcribe-diarize`** (private tenant) → Groq `whisper-large-v3` → OpenAI `whisper-1`. `--whisper <backend>` pins one (no cascade). Long cloud audio auto-splits + stitches onto one timeline; whisper-local streams arbitrary length natively.
- **Diarization** ("who spoke when") — **ON by default**, local first: pyannote.audio in the managed venv (HF token) → pyannote.ai → AssemblyAI; failures cascade between the configured pyannote variants. pyannote emits speaker **turns** (time ranges) that the next step aligns to the transcript; AssemblyAI and Azure instead deliver speakers *inline* with the transcription. `--no-diarize` turns it off; `--diarize <backend>` pins one.
- **Turn-merge** (readability, pure Python — *not* the same thing as diarization) — consecutive segments by the *same* speaker collapse into one block, so the transcript reads `[MM:SS] [Speaker] <the whole turn>` instead of one line per ~2-second segment. Non-diarized transcripts keep their per-segment granularity (the frame-to-transcript alignment relies on it).
- **Speaker-naming** (Claude, during analysis — the one LLM step here) — anonymous labels (`[A]`, `[SPEAKER_00]`) are substituted with canonical first names (`[A]` → `[Urs]`) from address-pattern + frame-avatar evidence; for audio-only sources, role/content evidence takes the place of frames. Labels that can't be pinned with confidence stay as bare letters.

### 5. Answer & persist

- **Resources** — every `https://` link in the description + transcript is deduped, normalized (tracking params stripped), and grouped (Projects / Docs / Articles / Videos / Social / Other), each annotated with its origin (`description` or `transcript@MM:SS`).
- **Hand-off & answer** — frames (tagged `[REG]` gap-filled / `[CUT]` scene-cut) + transcript + resources go to Claude; it `Read`s every frame as an image and answers grounded in what's actually on screen and in the audio — not the title or description.
- **Report** — three companion files next to local sources (`test.mp4` → `test.{md,protocol.md,transcript.md}`) or under `./watch/<YYYY-MM-DD>-<slug>/` for URLs; the `.md` carries Summary + Analysis, `.protocol.md` the metadata + frame list, `.transcript.md` the timestamped (and speaker-labeled) transcript. Diarized runs get a fourth `transcript-kompakt.md` — editorially condensed: one polished block per statement, STT garbles fixed, fillers dropped, grouped by topic. `--save-md PATH`, `--no-save-md`.
- **Idempotent intermediates** — raw STT segments + diarization turns persist as `<base>.segments.json` / `.turns.json`; reprocessing the same source resumes in ~1 s (skips stage 4's STT + diarization). `--fresh` forces a clean re-run.
- **Cleanup** — the temp work_dir is removed; the saved companions (report + intermediates) persist.

## Frame budget — why it matters

Token cost is dominated by frames. Every frame is an image; image tokens add up fast. The script's auto-fps logic exists so you don't blow your context budget on a sparse scan of a 30-minute video that would have been better answered by a focused 30-second window.

| Duration | Default frame budget | What you get |
|----------|---------------------|--------------|
| ≤30 s | ~30 frames | Dense — basically every key moment |
| 30 s - 1 min | ~40 frames | Still dense |
| 1 - 3 min | ~60 frames | Comfortable |
| 3 - 10 min | ~80 frames | Sparse but workable |
| > 10 min | **auto-chunked**: `ceil(duration/10min)` × ~80 frames each | Dense per-chunk coverage |

The "auto-chunk" row replaced the old "sparse scan" mode. A 60-min video now becomes 6 chunks × 80 frames = ~480 regular frames (plus scene-cut frames on top). More image tokens than the old sparse scan, but per-chunk coverage comparable to dedicated focused runs. Pass `--no-chunk` to revert to single-pass sparse (100 frames spread thinly), or `--start`/`--end` to zero in on one section.

This budget is the **regular sampling** target per chunk. With scene detection enabled (default), the regular frames are gap-filled around cut timestamps rather than placed at uniform intervals — same total budget, redistributed into the spans not already covered by cut frames. Cut frames are extracted on top with their own cap (`--scene-max-frames`, default 80, global).

When the user names a moment ("around 2:30", "the last 30 seconds", "from 0:45 to 1:00"), pass `--start` / `--end`. Focused mode gets denser per-second budgets, capped at 2 fps. Far more useful than a sparse pass over the whole thing.

## Install

`/watch` lives in the [AI-Toolbox](https://github.com/danielfrey63/ai-toolbox)
at `.agents/skills/watch/`. Clone the toolbox first:

```bash
git clone https://github.com/danielfrey63/ai-toolbox.git
```

`<ai-toolbox>` below is the absolute path to that clone.

| Surface | Install |
|---------|---------|
| **Claude Code** | `/plugin marketplace add <ai-toolbox>/.agents/skills/watch` then `/plugin install watch@watch` |
| **Codex** | Symlink the skill into `~/.codex/skills/watch` (see below) |
| **claude.ai** (web) | Build `dist/watch.skill` with `scripts/build-skill.sh`, upload it under Settings → Capabilities → Skills |
| **Other skill clients** | The skill sits on the cross-client `.agents/skills/` path — point the client at it or symlink it |

### Claude Code

`watch/` is its own single-plugin marketplace. Register it as a local
marketplace and install:

```
/plugin marketplace add <ai-toolbox>/.agents/skills/watch
/plugin install watch@watch
```

After editing the skill, refresh the installed copy with
`/plugin marketplace update watch` then `/plugin update watch@watch`.

### Codex

Codex discovers skills under `~/.codex/skills/`. Symlink the toolbox copy so
it stays in sync:

```bash
ln -s <ai-toolbox>/.agents/skills/watch ~/.codex/skills/watch
```

### claude.ai (web)

1. Build the upload bundle: `bash scripts/build-skill.sh` → `dist/watch.skill`.
2. Go to Settings → Capabilities → Skills.
3. Click `+` and drop the file in.

Enable "Code execution and file creation" under Capabilities first — the skill shells out to `ffmpeg` and `yt-dlp`, so it won't run without it.

## First run

On the first `/watch` call, the skill runs `scripts/setup.py --check`. If `ffmpeg` / `yt-dlp` aren't on your PATH, or no Whisper API key is set, it walks you through fixing it:

- **macOS** — auto-runs `brew install ffmpeg yt-dlp`.
- **Linux** — prints the exact `apt` / `dnf` / `pipx` commands.
- **Windows** — prints the `winget` / `pip` commands.
- **API keys** — scaffolds `~/.config/watch/.env` (mode `0600`) from `.env.example` with commented placeholders for every backend: `GROQ_API_KEY` / `OPENAI_API_KEY`, the private Azure `gpt-4o-transcribe-diarize` + `claude-opus-4-7` endpoints, and the speaker-diarization backends. **None of these are required** — the local backends carry transcription (and, with a free `HF_TOKEN`, diarization) on their own.
- **Managed ML venv** — the local backends (whisper-local, pyannote-local) run as worker subprocesses inside a pinned venv at `~/.config/watch/venv/`, provisioned automatically on first use (or explicitly via `setup.py --venv`). GPU is auto-detected (CUDA wheels); your own Python environments are never touched. The pin set lives in `setup.py` (`VENV_PINS`) and the venv self-heals when it changes.

After setup, preflight is silent and `/watch` just works. The check is a sub-100ms lookup, so it doesn't slow you down on subsequent runs.

## Bring your own keys

Captions cover the majority of public videos for free. The STT fallback only kicks in when a source genuinely has no caption track — typically local files, TikToks, some Vimeos, and the occasional caption-less YouTube upload — and it works **without any key**: the default is the on-device whisper-local backend. Cloud keys buy you the cascade levels behind it.

| Capability | What you need | Cost |
|------------|---------------|------|
| Download + native captions | `yt-dlp` + `ffmpeg` | Free |
| **Transcription, local (DEFAULT)** | Nothing — managed venv self-provisions on first use (`setup.py --venv` to pre-provision; GPU auto-detected) | Free, fully on-device |
| Whisper cloud (cascade level 3) | [Groq API key](https://console.groq.com/keys) — `whisper-large-v3` | Cheap, fast |
| Whisper cloud (cascade level 4) | [OpenAI API key](https://platform.openai.com/api-keys) — `whisper-1` | Standard pricing |
| Transcription + diarization, private tenant (cascade level 2) | Azure `gpt-4o-transcribe-diarize` deployment URL + key | Your Azure tenant — audio never leaves it |
| Speaker reconciliation for long private audio | Azure `claude-opus-4-7` endpoint URL + key | Your Azure tenant |
| Disable transcription entirely | `--no-whisper` | Free, frames-only when no captions |
| **Speaker diarization, local (DEFAULT)** | [HF_TOKEN](https://huggingface.co/settings/tokens) + license accept on [speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1) *and* [segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0) — model runs in the managed venv | Free; ~90 s for 41 min audio on GPU |
| Speaker diarization — pyannote.ai (cascade level 2) | [pyannote.ai key](https://www.pyannote.ai/) — cloud diarization, aligned to the transcript | Cheaper than AssemblyAI, two API calls |
| Speaker diarization — AssemblyAI (cascade level 3) | [AssemblyAI key](https://www.assemblyai.com/dashboard/api-keys) — `universal-3-pro` + speaker labels | ~$0.37/h, replaces the transcription |
| Disable diarization | `--no-diarize` | — |

## Usage

```
/watch https://youtu.be/dQw4w9WgXcQ what happens at the 30 second mark?
/watch https://www.tiktok.com/@user/video/123 summarize this
/watch ~/Movies/screen-recording.mp4 when does the UI break?
/watch https://vimeo.com/123 what tools does she mention?
```

Focused on a specific section — denser frame budget, lower token cost:
```
/watch https://youtu.be/abc --start 2:15 --end 2:45
/watch video.mp4 --start 50 --end 60
/watch "$URL" --start 1:12:00            # from 1h12m to end
```

Speaker diarization (who said what) — **on by default** when a backend is configured, local first:
```
/watch meeting.mp4                           # default: pyannote local > pyannote.ai > AssemblyAI
/watch meeting.m4a                           # audio-only works the same — fully on-device
/watch meeting.mp4 --no-diarize              # plain transcript, no speaker labels
/watch meeting.mp4 --diarize assemblyai      # pin one backend (no cascade, fails loudly)
```

Other knobs (passed to `scripts/watch.py`):

- `--max-frames N` — cap on regular frames per chunk (default 80, hard max 100). In single-chunk modes (focused or `--no-chunk`) this is also the global cap.
- `--no-chunk` — disable auto-chunking for long videos. Reverts to the old single-pass sparse behavior (100 frames spread thinly).
- `--diarize [BACKEND]` — speaker diarization, **on by default** (auto mode, local first: `pyannote-local` with HF_TOKEN → `pyannote-api` → `assemblyai`; silently off when nothing is configured; failures cascade to the next configured backend). Explicit backend pins it (no cascade). Output transcript gets `[12:34] [<speaker>] text` lines; Claude then substitutes anonymous labels with canonical first names.
- `--no-diarize` — disable speaker diarization.
- `--resolution W` — bump frame width to 1024 px when Claude needs to read on-screen text (slides, terminals, code).
- `--fps F` — override the auto-fps calculation (still capped at 2 fps).
- `--no-scene` — disable scene cut detection; falls back to uniform sampling.
- `--scene-threshold F` — override the auto-tuned scdet threshold (default: knee-point on the score distribution).
- `--scene-min-gap S` — minimum seconds between consecutive cut frames (default 2.0; de-clusters animation/B-roll bursts).
- `--scene-max-frames N` — cap on additional cut frames (default 80, applied separately from `--max-frames`).
- `--scene-settle-seconds S` — seconds after a detected cut to wait before extracting (default 1.0). Lets UI transitions render so cut frames don't land on loading-state pixels. Set to 0 for the old just-before-cut behavior.
- `--whisper azure-diarize|groq|openai|whisper-local` — pin a specific transcription backend (no cascade). Default: local-first cascade `whisper-local` → `azure-diarize` → `groq` → `openai`, each failure falling through to the next configured backend.
- `--no-whisper` — disable transcription entirely; frames only.
- `--fresh` — ignore persisted `<base>.segments.json` / `.turns.json` and re-transcribe + re-diarize from scratch. The default reuses them, so reprocessing the same source (e.g. to re-clean a transcript or re-render after a tweak) resumes in ~1 s instead of re-running STT + diarization.
- `--out-dir DIR` — keep working files somewhere specific (default: auto-generated tmp dir). The persisted intermediates live next to the saved report; this flag only affects the ephemeral work dir.
- `--save-md PATH` — override the auto-save location (defaults: `<video-stem>.md` next to local sources; `./watch/<YYYY-MM-DD>-<slug>/<slug>.md` for URL sources).
- `--no-save-md` — disable auto-save entirely (frames + transcript only in temp work_dir).

## Limits

- **Best per-second accuracy: under 10 minutes.** For longer videos, auto-chunking gives you per-chunk dense coverage (~80 frames each), but image-token cost grows proportionally. Pass `--start`/`--end` to focus on a section, or `--no-chunk` to fall back to sparse single-pass.
- **Per-chunk cap: 2 fps, 100 frames.** Frame count drives token cost; the script enforces this even when the auto-fps math would imply higher.
- **Transcription length limits: handled internally.** Long audio auto-splits transparently — Whisper by file size (20 MB chunks), the Azure backend by duration (~600 s chunks; the model caps a single call at ~1500 s) — both with 20 s overlap, stitched back onto one timeline.
- **AssemblyAI upload limit: 5 GB / 10 h per file.** Effectively unlimited for normal use.
- **No private platforms.** This skill doesn't log into anything. Public URLs and local files only. If yt-dlp can't reach it without auth, neither can `/watch`.

## Structure

```
.
├── SKILL.md                 # skill contract — loaded by all three surfaces
├── scripts/
│   ├── watch.py             # entry point — orchestrates download → frames → transcript → diarize
│   ├── download.py          # yt-dlp wrapper
│   ├── frames.py            # ffmpeg frame extraction + scdet + auto-fps + auto-chunk
│   ├── transcribe.py        # VTT parsing + dedupe + segment formatting
│   ├── stt.py               # speech-to-text — pluggable backends (whisper-local, Azure transcribe-diarize, Groq/OpenAI Whisper), local-first cascade, auto-split + stitch + speaker reconcile
│   ├── diarize.py           # pyannote local / pyannote.ai / AssemblyAI backends + transcript alignment
│   ├── pyannote_worker.py   # diarization worker — runs INSIDE the managed venv
│   ├── whisper_local_worker.py  # faster-whisper worker — runs INSIDE the managed venv
│   ├── resources.py         # URL extraction from description + transcript, categorized
│   ├── setup.py             # preflight + installer + .env scaffolding + managed-venv provisioning
│   └── build-skill.sh       # build dist/watch.skill for claude.ai upload
├── hooks/                   # SessionStart status hook (Claude Code only)
├── .claude-plugin/          # plugin.json + marketplace.json (Claude Code)
├── .codex-plugin/           # codex packaging
└── .github/workflows/       # release.yml — auto-builds watch.skill on tag push
```

## Develop

```bash
# Build the claude.ai upload bundle:
bash scripts/build-skill.sh      # → dist/watch.skill
```

Versioning is handled by the AI-Toolbox: `plugin.json`'s `version` is the
source of truth, bumped automatically by the toolbox's per-edit and
pre-commit hooks. See `git log` for history.

## Credits & license

MIT license.

`/watch` began as [**claude-video**](https://github.com/bradautomates/claude-video)
by **Bradley Bonanno** ([bradautomates](https://github.com/bradautomates)) — full
credit and thanks for the original work. It is now maintained as a fork inside
the AI-Toolbox.

Built on `yt-dlp`, `ffmpeg`, and Claude's multimodal `Read` tool. On-device transcription via [faster-whisper](https://github.com/SYSTRAN/faster-whisper), on-device diarization via [pyannote.audio](https://github.com/pyannote/pyannote-audio); cloud cascade via Azure, [Groq](https://groq.com), [OpenAI](https://openai.com), [pyannote.ai](https://www.pyannote.ai/), [AssemblyAI](https://www.assemblyai.com/).

---

Part of [github.com/danielfrey63/ai-toolbox](https://github.com/danielfrey63/ai-toolbox) · [LICENSE](LICENSE)
