# /watch

**Give Claude the ability to watch any video.**

`/watch` is a skill + Claude Code plugin maintained as part of the
[AI-Toolbox](https://github.com/danielfrey63/ai-toolbox), at
`.agents/skills/watch/`. See [Install](#install) below for Claude Code,
Codex and claude.ai (web).

Zero config to start — `yt-dlp` and `ffmpeg` install on first run via `brew` on macOS (Linux/Windows print exact commands). Captions cover most public videos for free. Whisper API key is only needed when a video has no captions.

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

## How it works

1. **You paste a video and a question.** URL (anything yt-dlp supports — YouTube, Loom, TikTok, X, Instagram, plus a few hundred more) or a local path (`.mp4`, `.mov`, `.mkv`, `.webm`).
2. **`yt-dlp` downloads it.** For URLs, into a temp working directory. For local files, no download — just probed in place.
3. **`ffmpeg` runs an `scdet` pass to find scene cuts.** Every frame's pixel-difference score is recorded; a knee-point heuristic on the score distribution picks a per-video threshold (no static cut-off). Each surviving cut becomes one extracted frame, with a configurable settle-delay (default 1.0 s) so UI transitions / launchers / dialogs finish rendering before capture — no more black mid-transition pixels. Disable scene detection with `--no-scene`, override the threshold with `--scene-threshold F`.
4. **`ffmpeg` extracts the regular frame budget gap-filled around the cuts.** The frame budget is duration-aware (≤30s gets ~30 frames, 30-60s gets ~40, 1-3min gets ~60, 3-10min gets ~80). Instead of sampling at uniform intervals, the script distributes those frames into the gaps between cuts proportional to gap length — cut-dense regions don't waste regular budget; long uncovered spans get more attention. JPEGs at 512px wide by default — bump with `--resolution 1024` if Claude needs to read on-screen text.
5. **Long videos auto-chunk by default.** Videos longer than 10 min without an explicit `--start`/`--end` window split into `ceil(duration / 10min)` evenly-sized chunks; each chunk gets the focused-mode dense frame budget (default 80 per chunk) and per-chunk gap-fill against the cuts that fall in it. A 60-min video yields ~480 regular frames instead of 100 sparse ones — proportionally more image tokens, but per-chunk coverage comparable to dedicated focused runs. Pass `--no-chunk` to revert to single-pass sparse, or `--start`/`--end` to focus on one section.
6. **The transcript comes from captions or a pluggable speech-to-text backend.** First: `yt-dlp` pulls native captions (manual or auto-generated) — free, covers most public videos. Otherwise the skill extracts mono 16 kHz audio and sends it to an STT backend: **Azure `gpt-4o-transcribe-diarize`** (preferred when configured — runs on your own Azure tenant and transcribes *and* diarizes in one call, so private content never touches a public API), or Groq's `whisper-large-v3` (preferred public — cheaper and faster) / OpenAI's `whisper-1`. Long audio is chunked automatically — by file size for Whisper, by duration for Azure — and stitched back onto a single timeline; for the Azure backend each chunk is diarized independently and a `claude-opus-4-7` pass reconciles the per-chunk speaker labels into consistent global speakers. On top of that, `--diarize` adds a dedicated diarization step for the Whisper path — AssemblyAI (cloud, transcription + speaker labels in one call), pyannote.ai (cloud, diarization-only, aligned to Whisper), or pyannote.audio local (free, runs on your machine, heavy install). Output transcript lines become `[12:34] [<speaker>] text`; speaker letters get substituted with canonical first names (`[A]` → `[Urs]`) by Claude during the analysis based on address-pattern + frame-avatar evidence.
7. **A `## Resources` section aggregates URLs.** Every `https://` link in the video description (yt-dlp's `description` field) plus URLs that appear in the transcript get deduped, normalized (tracking params stripped), and grouped — Projects (GitHub/GitLab/Bitbucket/Codeberg/sr.ht repos, npm/PyPI/crates/RubyGems/Go/Packagist/NuGet, Hugging Face), Docs, Articles (incl. arxiv/openreview), Videos, Social, Other. Each entry is annotated with where it came from (`description` or `transcript@MM:SS`).
8. **Frames + transcript + resources are handed to Claude.** Each entry in the merged frame list is tagged `[REG]` (regular gap-filled) or `[CUT]` (scdet-detected). Claude `Read`s every frame path in parallel — JPEGs render directly as images in its context.
9. **Claude answers grounded in what's actually on screen and in the audio.** Not "based on the description" or "according to the title." It saw the frames. It heard the transcript. It surfaces the relevant URLs from `## Resources` so you can click through. It answers the way someone who watched the video would.
10. **The persistent report is three companion files.** For local sources, they sit next to the video (`videos/test.mp4` → `videos/test.{md,protocol.md,transcript.md}`). For URL sources, they land in `./watch/<YYYY-MM-DD>-<slug>/<slug>.{md,protocol.md,transcript.md}` in your current working directory — sortable by date, per-video subfolder, `.gitignore`-friendly (`watch/` covers it). The `.md` file has Claude's Summary + Analysis; `.protocol.md` has metadata + the frame list; `.transcript.md` has the timestamped transcript (with speaker names when diarized). Override with `--save-md PATH`, disable with `--no-save-md`.
11. **Cleanup.** The script prints a working directory at the end. The three saved companion files persist; the temp work_dir gets removed.

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
- **API keys** — scaffolds `~/.config/watch/.env` (mode `0600`) from `.env.example` with commented placeholders for every backend: `GROQ_API_KEY` (preferred Whisper) / `OPENAI_API_KEY`, the private Azure `gpt-4o-transcribe-diarize` + `claude-opus-4-7` endpoints, and the speaker-diarization backends.

After setup, preflight is silent and `/watch` just works. The check is a sub-100ms lookup, so it doesn't slow you down on subsequent runs.

## Bring your own keys

Captions cover the majority of public videos for free. The Whisper fallback only kicks in when a video genuinely has no caption track — typically local files, TikToks, some Vimeos, and the occasional caption-less YouTube upload.

| Capability | What you need | Cost |
|------------|---------------|------|
| Download + native captions | `yt-dlp` + `ffmpeg` | Free |
| Whisper fallback (preferred) | [Groq API key](https://console.groq.com/keys) — `whisper-large-v3` | Cheap, fast |
| Whisper fallback (alt) | [OpenAI API key](https://platform.openai.com/api-keys) — `whisper-1` | Standard pricing |
| Transcription + diarization, private (`--whisper azure-diarize`) | Azure `gpt-4o-transcribe-diarize` deployment URL + key | Your Azure tenant — audio never leaves it |
| Speaker reconciliation for long private audio | Azure `claude-opus-4-7` endpoint URL + key | Your Azure tenant |
| Disable transcription entirely | `--no-whisper` | Free, frames-only when no captions |
| Speaker diarization — AssemblyAI (`--diarize assemblyai`) | [AssemblyAI key](https://www.assemblyai.com/dashboard/api-keys) — `universal-3-pro` + speaker labels | ~$0.37/h, replaces Whisper |
| Speaker diarization — pyannote.ai (`--diarize pyannote-api`) | [pyannote.ai key](https://www.pyannote.ai/) — cloud diarization, aligned to Whisper | Cheaper than AssemblyAI, two API calls |
| Speaker diarization — local (`--diarize pyannote-local`) | `pip install pyannote.audio` + [HF_TOKEN](https://huggingface.co/pyannote/speaker-diarization-3.1) + license accept | Free, slow on CPU, fast on GPU |

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

Speaker diarization (who said what):
```
/watch meeting.mp4 --diarize                 # auto-pick (AssemblyAI > pyannote.ai > local)
/watch meeting.mp4 --diarize assemblyai      # cloud, all-in-one
/watch meeting.mp4 --diarize pyannote-local  # free, on-device (needs HF_TOKEN + pyannote.audio)
```

Other knobs (passed to `scripts/watch.py`):

- `--max-frames N` — cap on regular frames per chunk (default 80, hard max 100). In single-chunk modes (focused or `--no-chunk`) this is also the global cap.
- `--no-chunk` — disable auto-chunking for long videos. Reverts to the old single-pass sparse behavior (100 frames spread thinly).
- `--diarize [BACKEND]` — enable speaker diarization. Backends: `assemblyai` (cloud, replaces Whisper), `pyannote-api` (cloud, alongside Whisper), `pyannote-local` (free, on-device). Without arg: auto-pick the first configured. Output transcript gets `[12:34] [<speaker>] text` lines; Claude then substitutes anonymous labels with canonical first names.
- `--resolution W` — bump frame width to 1024 px when Claude needs to read on-screen text (slides, terminals, code).
- `--fps F` — override the auto-fps calculation (still capped at 2 fps).
- `--no-scene` — disable scene cut detection; falls back to uniform sampling.
- `--scene-threshold F` — override the auto-tuned scdet threshold (default: knee-point on the score distribution).
- `--scene-min-gap S` — minimum seconds between consecutive cut frames (default 2.0; de-clusters animation/B-roll bursts).
- `--scene-max-frames N` — cap on additional cut frames (default 80, applied separately from `--max-frames`).
- `--scene-settle-seconds S` — seconds after a detected cut to wait before extracting (default 1.0). Lets UI transitions render so cut frames don't land on loading-state pixels. Set to 0 for the old just-before-cut behavior.
- `--whisper azure-diarize|groq|openai` — force a specific transcription backend. Default: prefer `azure-diarize` when its keys are set, then Groq, then OpenAI.
- `--no-whisper` — disable transcription entirely; frames only.
- `--out-dir DIR` — keep working files somewhere specific (default: auto-generated tmp dir).
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
│   ├── stt.py               # speech-to-text — pluggable backends (Azure transcribe-diarize, Groq/OpenAI Whisper), auto-split + stitch + speaker reconcile
│   ├── diarize.py           # AssemblyAI / pyannote.ai / pyannote.audio local backends
│   ├── resources.py         # URL extraction from description + transcript, categorized
│   ├── setup.py             # preflight + installer + .env scaffolding
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

Built on `yt-dlp`, `ffmpeg`, and Claude's multimodal `Read` tool. Whisper transcription via [Groq](https://groq.com) or [OpenAI](https://openai.com).

---

Part of [github.com/danielfrey63/ai-toolbox](https://github.com/danielfrey63/ai-toolbox) · [LICENSE](LICENSE)
