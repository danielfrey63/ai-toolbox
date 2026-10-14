# CLI-Optionen

Generiert mit `python transcribe.py config options` aus den argparse-Definitionen.

Installation: [INSTALL.md](../INSTALL.md). Konfigurationswerte: [parameters.md](parameters.md).

`python transcribe.py run --help` zeigt den üblichen Ablauf; `--help-all` ergänzt alle Medienoptionen.

## Ablauf und Auswertung

| Option | Default | Bedeutung |
|---|---|---|
| `--language` | `auto/unset` | Language of transcript and report, e.g. de |
| `--local` | `False` | Pin whisper-local and pyannote-local (no cloud transcription or diarization) |
| `--rerun` | `False` | Run run.py again although a transcript exists |
| `--stop-at-speakers` | `False` | End after the speaker stage so a person can correct speakers.md |
| `--redact` | `auto/unset` | Black out person-name lists in the crops; on a finished run only the redaction is added (default: TRANSCRIBE_REDACT, else the state of the existing crops, else off) |
| `--no-frames` | `False` | Skip every image call in the agent stages |
| `--force` | `False` | Redo finished agent stages |
| `--analysis` | `model` | Who writes the report (default model; harness produces an explicit handoff) Choices: model, harness, none |
| `--plan` | `False` | Show stages and cache decisions without running them |
| `--json` | `False` | Machine-readable plan or final result on stdout |

## Medienaufbereitung

| Option | Default | Bedeutung |
|---|---|---|
| `--version` | `==SUPPRESS==` | Print the skill version and exit. |
| `--max-frames` | `80` | Cap on frame count (default 80, hard max 100) |
| `--resolution` | `512` | Frame width in pixels (default 512) |
| `--fps` | `auto/unset` | Override auto-fps |
| `--start` | `auto/unset` | Range start (SS, MM:SS, or HH:MM:SS) |
| `--end` | `auto/unset` | Range end (SS, MM:SS, or HH:MM:SS) |
| `--out-dir` | `auto/unset` | Working directory (default: tmp) |
| `--no-whisper` | `False` | Disable Whisper fallback. Report frames-only if no captions available. |
| `--whisper` | `auto/unset` | Force a specific transcription backend. Default: whisper-local first, then configured Azure, Groq and OpenAI cloud fallbacks. Local faster-whisper runs in the managed venv; no key needed, self-provisions on first use). Choices: azure-diarize, groq, openai, whisper-local |
| `--whisper-workers` | `auto/unset` | Parallel Whisper chunk uploads (default 1 = sequential). Higher values speed up long videos but risk hitting the audio-second-per-hour rate limit on Groq Free Tier (Retry-After can be several hundred seconds). Try 2 if you have a paid tier or your video is moderate-length. |
| `--no-scene` | `False` | Disable scdet-based cut detection. By default, an extra frame is extracted at every detected cut, in addition to the regular sampling. |
| `--no-repair` | `False` | Disable the post-transcription repair pass. By default, passages where the decoder collapsed (repetition loops, drift into another script) are detected and re-transcribed from their own audio window with a fresh context. |
| `--scene-threshold` | `auto/unset` | Override the auto-detected scdet threshold (default: auto via knee-point detection on the score distribution; lower = more sensitive) |
| `--scene-min-gap` | `2.0` | Minimum seconds between consecutive cut frames (default 2.0) |
| `--scene-max-frames` | `80` | Cap on additional cut frames extracted (default 80) |
| `--no-ocr` | `False` | Skip the on-screen reference pass. By default the scene-cut frames and every visually changed regular frame are re-extracted at native resolution and read by RapidOCR (isolated uv env); URLs, wiki page IDs, ticket keys, hosts and share paths land in <base>.links.md with the [MM:SS] they were seen at. Cached in <base>.ocr.json (--fresh recomputes). |
| `--ocr-max-frames` | `60` | Cap on frames the OCR pass reads (default 60; cuts win, regular candidates are thinned evenly) |
| `--ocr-min-score` | `0.85` | RapidOCR confidence below which a reference is marked (?) in <base>.links.md (default 0.85) |
| `--scene-settle-seconds` | `1.0` | Seconds after a detected scene cut to wait before extracting the frame (default 1.0). Lets UI transitions / dialogs / launcher windows render before capture, so cut frames don't land on loading-state / black mid-transition pixels. Capped at next_cut - 0.3s so we never bleed into the following shot. Set to 0 to revert to the old just-before-cut behavior. |
| `--cpu-budget` | `auto/unset` | Cap the CPU the pipeline's CPU-bound stages may use together: a share ("50%"), an absolute thread count ("6"), or "all" for no limit. Default: 50% of the usable cores, or TRANSCRIBE_CPU_BUDGET from the environment / .env. Lower it if the machine gets hot or unresponsive during a run. |
| `--frame-workers` | `auto/unset` | Thread-pool size for per-frame ffmpeg calls (default: derived from the shared CPU budget). Each worker spawns one ffmpeg subprocess. Set to 1 to force sequential extraction (useful on HDDs where concurrent seeks thrash, or for benchmark comparison). Going above 8 rarely helps on consumer hardware - ffmpeg instances start contending for cache and disk bandwidth. |
| `--no-dedup` | `False` | Disable dHash-based deduplication of near-identical regular frames (default: adaptive threshold). Cut frames are never deduplicated regardless of this flag. |
| `--dedup-threshold` | `auto` | Hamming-distance threshold for the dHash dedup. 'auto' (default) picks the threshold via knee-point detection on the per-video distance distribution - adapts to talking-head (cliff around 4) vs UI-demo (cliff around 10). Pass an integer to override (sensible range 3-12). Ignored when --no-dedup is set. |
| `--save-md` | `auto/unset` | Save the markdown report to this path. Defaults to <video-stem>.md next to the source for local files; ./transcribe/<YYYY-MM-DD>-<slug>/<slug>.md for URL sources. |
| `--no-save-md` | `False` | Disable the default auto-save for local-file sources. |
| `--no-chunk` | `False` | Disable auto-chunking. By default, videos longer than 10 minutes without --start/--end are split into ~10-minute chunks, each processed with focused-mode frame budget, then merged. Use this flag to revert to the sparse single-pass behavior. |
| `--diarize` | `auto` | Speaker diarization backend. DEFAULT: auto - ON whenever a backend is configured, local first (pyannote local with HF_TOKEN > pyannote.ai > AssemblyAI); silently off when nothing is configured. Explicit choices pin one backend: 'pyannote-local' (fully on-device, managed venv), 'pyannote-api' (cloud pyannote.ai), 'assemblyai' (cloud, transcription + diarization in one call - replaces Whisper). Use --no-diarize to turn diarization off. Choices: auto, assemblyai, pyannote-api, pyannote-local |
| `--no-diarize` | `False` | Disable speaker diarization (overrides the on-by-default auto mode). |
| `--fresh` | `False` | Ignore persisted intermediates (<base>.segments.json / .turns.json) and re-transcribe + re-diarize from scratch. By default a re-run against the same output reuses them (idempotent). |
| `--background` | `False` | Unattended run (watcher): below-normal process priority, and a manual run on the same recording takes over instead of competing - see joblock.py. |
| `--result-json` | `auto/unset` | Write machine-readable result metadata to this file |
