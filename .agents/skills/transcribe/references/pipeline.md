# Pipeline internals

Read this when you need to explain or debug a pipeline stage: where the transcript came from, why a re-run reused a cache, how blocks are cut, what the version line in the protocol means, how the caption cross-check works, CPU/GPU load, or what leaves the machine.

## Contents

- Transcript sources (captions vs. STT cascade)
- Idempotent re-runs (resume)
- Long audio: auto-split with overlap
- Transcript blocking (diarized runs)
- Cross-check against platform captions
- Version stamp
- CPU budget
- GPU load and heat
- Security and permissions
- Bundled scripts

## Transcript sources (captions vs. STT cascade)

1. **Native captions (free, preferred), only in the video's own language.** yt-dlp fetches captions in a second, download-free pass after the info JSON has revealed the video's `language`; `--sub-langs` then names only that language (`de,de-orig,de-DE`). YouTube auto-translates any video with one automatic caption track into many languages, so requesting a fixed language would silently return a machine translation. When the language cannot be determined, no captions are fetched and the STT path takes over: a transcript in the wrong language is worse than none. A `--print %(language)s` probe runs only when the info JSON carries no language.
2. **STT cascade, local first.** Without captions (or for local files) the script extracts audio (`ffmpeg -vn -ac 1 -ar 16000 -b:a 64k`, about 0.5 MB/min) and tries the configured backends in order; each failure falls through to the next:
   - **whisper-local** (default) – faster-whisper fully on-device in the managed venv (CUDA with `large-v3-turbo`, CPU fallback `medium`/int8). No key, nothing leaves the machine.
   - **Azure** – `gpt-4o-transcribe-diarize` on a private tenant (transcription and speakers in one call). Needs `AZURE_TRANSCRIBE_DIARIZE_URL` and `_KEY`.
   - **Groq** – `whisper-large-v3` cloud API, key from console.groq.com/keys.
   - **OpenAI** – `whisper-1` cloud API, key from platform.openai.com/api-keys.

Keys live in `~/.config/transcribe/.env`. The protocol header names the source (`captions`, `whisper (groq)`, …).

## Idempotent re-runs (resume)

When output is persisted (default for local files, or any `--save-md`), the STT result and diarization turns are written as `<base>.segments.json` and `<base>.turns.json`. Reprocessing the same source reuses them (a 41-min recording resumes in about 1 s) and goes straight to alignment and rendering, so re-cleaning or re-rendering is free.

**A cached transcript outranks captions.** Whether a platform hands out caption tracks varies between runs (rate limits), so letting captions win would make the same command yield a different transcript and discard a computed Whisper result. `--fresh` ignores the caches. With `--no-save-md` the caches live only in the ephemeral work dir; use `--out-dir DIR` to keep them.

## Long audio: auto-split with overlap

Cloud Whisper endpoints cap one upload at 25 MB. Above a 20 MB target the audio is split into `ceil(size / 20 MB)` even chunks with 20 s overlap (`ffmpeg -ss -c copy`), each sent in turn. Segments are shifted onto the absolute timeline; at each seam, segments of the second chunk starting before the overlap midpoint are dropped, and consecutive duplicate texts are collapsed. stderr shows `[transcribe] audio: … exceeds Whisper upload limit – splitting into N chunks (20s overlap)…`. The Azure backend splits by duration (about 600 s chunks). whisper-local streams any length natively. Frames are unaffected.

## Transcript blocking (diarized runs)

A diarized transcript is written as one block per speaker turn, `[MM:SS] [<Speaker>] <text>`. A block ends at a **speaker change**, a **silence of 2 s** (`MAX_TURN_GAP`) or once it spans **45 s** (`MAX_TURN_SECONDS`, both in `transcribe.py`). Without the latter two, a single-speaker recording would collapse into one block with only the first timestamp. Fluent speech triggers mostly the duration cap, slow instructional speech mostly the gap rule; in meetings both are rare. `python3 scripts/transcribe.py --selftest` covers these rules.

## Cross-check against platform captions

Meeting platforms often ship captions next to the recording (Teams exports a `.vtt`). Both that transcript and Whisper mishear, but rarely the same way, so divergence points to the passages worth re-listening to.

When a platform VTT was preserved as `<base>.original.vtt`, `run.py` runs `crosscheck.py` automatically: 45-second windows, both texts normalized (casefold, ß→ss, hyphens joined, punctuation dropped), token-level SequenceMatcher ratio per window. The threshold is adaptive (`min(0.55, mean − stdev)` over the recording's own ratios), so poor room-mic captions only flag outliers below their own baseline. Windows where one side has substantial text and the other almost none are flagged as `missing in captions/transcript`. At most the 25 worst windows go to `<base>.crosscheck.md`, Whisper text and caption text side by side.

The tool never decides which side is right; working through the windows is part of the Konsistenz-Check (`report-writing.md`, item 8). Standalone:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/crosscheck.py" --segments "<base>.segments.json" --vtt "<base>.original.vtt" -o "<base>.crosscheck.md"
```

## Version stamp

Every report records which build produced it. The version is resolved at runtime from `.claude-plugin/plugin.json` (bumped by the AI-Toolbox versioning hooks); `scripts/version.py` is the single accessor and returns `unknown` when the manifest is absent (the claude.ai `.skill` bundle strips `.claude-plugin/`). Do not add a hand-maintained version literal to the scripts: the bump hook only reaches the plugin manifest.

It appears in `<base>.protocol.md` (`- **Skill version:**`, next to `- **Generated:**`), in `<base>.segments.json` (`skill_version`) and in the `<base>.vtt` generator NOTE (`NOTE generated by transcribe-skill <version>`). Detection of skill-generated VTTs is a substring test against the bare marker, so VTTs without a version still count as skill-generated.

When a re-run resumes a cache written by a different version, stderr warns and the protocol line says so, for example `transcribe X, but the transcript was resumed from a cache written by Y (re-run with --fresh …)`. If transcript quality matters, re-run with `--fresh`.

## CPU budget

`scripts/cpu.py` decides how much CPU the CPU-bound stages may use together; they divide one budget instead of each taking all cores.

| Stage | Processes | Gets |
|---|---|---|
| scdet cut detection | 1 ffmpeg | whole budget |
| audio extraction | 1 ffmpeg | whole budget |
| frame extraction | N ffmpegs | budget split across them |
| whisper CPU fallback | in-venv | whole budget (via env) |
| pyannote CPU path | in-venv | `torch.set_num_threads` (via env) |

Resolution order: `--cpu-budget` > `TRANSCRIBE_CPU_BUDGET` (environment or `.env`) > 50 % of the usable cores (`sched_getaffinity` on Linux, so `taskset`, systemd slices and container cpusets are respected; `os.cpu_count()` elsewhere). The value is exported to the environment so the venv workers inherit it; an unparseable value falls back to the default.

`frame_workers()` uses `budget // 2` workers so every ffmpeg gets two threads: a single-threaded ffmpeg cannot overlap seek and decode, so many one-thread workers are the slowest split. The default costs about 15 % wall-clock against no cap. Lower the budget (`25%`) when the machine must stay responsive; `--cpu-budget all` removes the cap; `--frame-workers` overrides the worker count.

## GPU load and heat

On a laptop the CUDA stages (whisper, pyannote) dominate. Throttling the GPU lowers instantaneous draw but stretches the run, so total heat rises and the peak temperature stays the same. **Finishing sooner is what cuts heat**, so all knobs default to the fastest setting:

- `TRANSCRIBE_WHISPER_MODEL` – default `large-v3-turbo` (about 3.5× faster decode than `large-v3` at the same draw, and more robust against repetition collapse). `large-v3` is the slower alternative; `medium` loses domain terms and Swiss German. **Never `distil-large-v3`**: English-only, it translates German input instead of transcribing it.
- `TRANSCRIBE_GPU_COMPUTE` – ctranslate2 compute type (default `float16`; an unsupported type falls back to `float16`).
- `TRANSCRIBE_GPU_DUTY` – share of wall-clock spent decoding, `0.1`–`1.0` (default `1.0`). Only for a quieter fan over a longer time.

Transcription is about three quarters of a run's energy, diarization the rest; `--no-diarize` saves roughly a quarter. The CPU never drives the heat.

<details>
<summary>Background measurements (laptop GPU, real German recordings)</summary>

4.2 min of speech, `nvidia-smi` sampled twice a second:

| Setting | Wall-clock | GPU util | Power | Total energy | Peak temp |
|---|---|---|---|---|---|
| `float16`, no pauses (default) | 86 s | 51 % | 61 W | ~5200 Ws | 72 °C |
| `int8_float16` | 125 s | 40 % | 49 W | ~6100 Ws | 72 °C |
| `float16`, `TRANSCRIBE_GPU_DUTY=0.6` | 137 s | 32 % | 48 W | ~6600 Ws | 71 °C |

Full pipeline, 253 s of speech, energy above idle:

| Run | Wall-clock | Whisper stage | Diarization stage | Total energy |
|---|---|---|---|---|
| `large-v3` | 48.2 s | 24.3 s / 1205 Ws | 7.1 s / 469 Ws | 1674 Ws |
| `large-v3-turbo` (default) | 29.2 s | 6.9 s / 296 Ws | 7.5 s / 341 Ws | 637 Ws |

</details>

<details>
<summary>Old patterns</summary>

- An earlier energy estimate attributed 90 % of a run's heat to transcription and 24 % savings to `--no-diarize`. Both came from a synthetic looping fixture on which `large-v3` collapsed into a repetition loop, inflating its decode from about 12 s to 79.8 s. Benchmark only on real recordings.

</details>

## Security and permissions

What the skill does:

- Runs `yt-dlp` locally to download the media and native captions (the request goes directly to the host in the URL).
- Runs `ffmpeg` / `ffprobe` locally for frames, cut detection and a mono 16 kHz audio clip.
- Sends the audio clip (or 20 MB chunks) to a cloud STT backend only when that backend is configured and reached in the cascade (Azure, `api.groq.com`, `api.openai.com`), or for cloud diarization (pyannote.ai, AssemblyAI).
- Writes media, frames, audio and intermediates to a work dir under the system temp dir (or `--out-dir`), and the companion files next to the source or under `./transcribe/`.
- Reads/creates `~/.config/transcribe/.env` (mode `0600`) for keys and the `SETUP_COMPLETE` marker; falls back to `.env` in the current directory.
- Downloads `deno` and `uv` into `~/.transcribe/bin/` and builds the managed venv at `~/.config/transcribe/venv/` with a pinned ML stack (pyannote.audio, faster-whisper, torch; CUDA wheels when nvidia-smi is present). The Python running `run.py` is never modified.

What it does not do:

- Upload the video itself; only extracted audio goes out, and only to a configured cloud backend.
- Access any platform account (no login, no cookies, no posting).
- Share keys between providers or write keys to stdout, stderr or output files.

## Bundled scripts

Claude **runs** these; read them only when debugging:

- `run.py` – entry point.
- `setup.py` – preflight, installer, uv bootstrap, venv provisioning.
- `speakers.py --apply <base>` – substitutes names from `<base>.speakers.md` into transcript and VTT.
- `illustrate.py` – illustration scouting and cropping (see `report-writing.md`).
- `repair.py`, `crosscheck.py`, `ocr.py --render` – standalone re-runs of the corresponding stages.

Internal modules (imported or spawned by `run.py`, not called directly): `download.py`, `frames.py`, `transcribe.py`, `stt.py`, `diarize.py`, `pyannote_worker.py` and `whisper_local_worker.py` (run inside the managed venv), `resources.py`, `cpu.py`, `version.py`, `joblock.py`.
