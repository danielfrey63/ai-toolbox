# run.py options, frame budgets and scene detection

Read this when a run needs a non-default flag, when the user asks about a specific moment or section, or when frame coverage looks wrong. SKILL.md lists the flags needed most often.

## Contents

- All flags
- Output locations (`--save-md`)
- Domain glossary
- Frame budget and auto-chunking
- Focusing on a section
- Scene cut detection

## All flags

Frames:

- `--start T` / `--end T` – focus on a section (`SS`, `MM:SS` or `HH:MM:SS`); fps scales denser, see "Focusing on a section". The transcript is filtered to the same range.
- `--max-frames N` – cap on regular frames per chunk (default 80, hard max 100). In single-chunk modes (focused or `--no-chunk`) this is also the global cap.
- `--no-chunk` – disable auto-chunking; one sparse pass with up to 100 frames over the whole video.
- `--fps F` – override auto-fps (clamped to 2 fps).
- `--resolution W` – frame width in px (default 512; 1024 only when on-screen text must be read, roughly 4x the image tokens).
- `--no-scene`, `--scene-threshold F`, `--scene-min-gap S` (default `2.0`), `--scene-max-frames N` (default `80`, separate from `--max-frames`), `--scene-settle-seconds S` (default `1.0`) – see "Scene cut detection".
- `--no-ocr` – skip the on-screen reference pass. `--ocr-max-frames N` caps the frames it reads (default `60`; cuts always win, regular candidates are thinned evenly), `--ocr-min-score F` sets the RapidOCR confidence under which a reference is marked `(?)` (default `0.85`).
- `--frame-workers N` – explicit worker count for frame extraction (normally derived from the CPU budget).

Transcription:

- `--whisper azure-diarize|groq|openai|whisper-local` – pin one transcription backend (no cascade, fails loudly). Default: local-first cascade whisper-local → azure-diarize → groq → openai, each failure falls through to the next configured backend.
- `--no-whisper` – no STT at all (frames-only if no captions).
- `--language de` – language hint for the repair pass (which scripts count as foreign, language of the re-transcription). Pass it whenever the language is known.
- `--no-repair` – disable the repair pass, see `repair.md`.
- `--fresh` – ignore the persisted `<base>.segments.json` / `.turns.json` and re-transcribe and re-diarize from scratch.

Diarization:

- `--diarize [BACKEND]` – on by default in auto mode, local first: pyannote-local (HF_TOKEN) → pyannote-api → assemblyai; silently off when nothing is configured; a failing auto backend falls through to the next configured one. An explicit backend pins it (no cascade, fails loudly). Transcript lines become `[MM:SS] [<speaker>] text`.
  - `assemblyai` – cloud, transcription and speakers in one call (`universal-3-pro`, fallback `universal-2`, `language_detection: true`, handles mixed DE-CH/EN/FR/IT). Needs `ASSEMBLYAI_API_KEY`, optional `ASSEMBLYAI_REGION=eu`. About 0.37 USD/h.
  - `pyannote-api` – cloud pyannote.ai, diarization only, aligned to the Whisper segments by overlap. Needs `PYANNOTE_API_KEY`.
  - `pyannote-local` – on-device, free, right choice for confidential recordings. Runs in the managed venv (`pyannote_worker.py`), GPU auto-detected. Needs `HF_TOKEN` plus accepted licenses for both gated repos `pyannote/speaker-diarization-3.1` and `pyannote/segmentation-3.0`. The speaker count stays on auto by design: forcing `num_speakers` collapses onto the dominant voice on single-mic recordings. Surplus mini-clusters are merged or labeled afterwards by Claude in `<base>.speakers.md`.
- `--no-diarize` – plain transcript; saves roughly a quarter of a run's energy on single-speaker recordings.

Resources and run control:

- `--cpu-budget SPEC` – share (`50%`), thread count (`6`) or `all`; default 50 % of the usable cores, overridable via `TRANSCRIBE_CPU_BUDGET`. See `pipeline.md`.
- `--background` – unattended run: below-normal priority, holds a per-recording lock `<base>.transcribe.lock`. A manual run meeting such a lock boosts the background run, waits for it (`[transcribe] Lauf auf derselben Aufnahme aktiv … übernommen: warte auf Abschluss`) and continues on its cache. Treat that message as progress and keep waiting. A second background run on a locked recording exits quietly; stale locks (dead pid, older than 12 h) are removed automatically.
- `--out-dir DIR` – keep the working files in a specific place (default: auto-generated temp dir).
- `--version` – print the skill version and exit.

## Output locations (`--save-md`)

`--save-md PATH` writes companion files: PATH itself (the main file, a stub to which Claude appends the report), `<base>.protocol.md` (metadata, frame list, resources) and `<base>.transcript.md`, where `<base>` is PATH without `.md`. Next to them: `<base>.vtt` (WebVTT with speaker voice tags). A pre-existing foreign VTT (for example a Teams export) is preserved as `<base>.original.vtt` first; skill-generated VTTs are overwritten on re-runs. When `<base>.original.vtt` exists, `<base>.crosscheck.md` is written as well.

Defaults:

- **Local files** → `<stem>.md` next to the source (`videos/test.mp4` → `videos/test.{md,protocol.md,transcript.md}`).
- **URL sources** → `./transcribe/<YYYY-MM-DD>-<slug>/<slug>.md` in the current working directory; `<slug>` is the sanitized video title (lowercase ASCII, non-alphanumeric → `-`, about 60 chars).
- `--no-save-md` disables auto-save; frames and transcript stay only in the temp work dir.

## Domain glossary

No flag, file-based. Whisper mishears rare domain vocabulary (product names, people, project jargon) as similar everyday words. Put a `transcribe-glossary.txt` next to the source (one term per line, `#` comments) and/or maintain `~/.config/transcribe/glossary.txt`. Both are merged (recording-local first) and passed to whisper-local as faster-whisper `hotwords`; the repair pass uses them too. Cloud backends ignore the glossary.

- The glossary shares the decoder's 448-token prompt budget and is truncated at 300 characters (about 20–30 terms) from the bottom. Put the most-misheard terms first and prefer bare surnames over full names.
- An overlong glossary leaves no decoding room (`The maximum decoding length must be > 0`); the worker clamps it and, if it still trips, retries once without biasing.
- For a recording series, seed the glossary with every term the user had to correct in the previous run.

## Frame budget and auto-chunking

Regular-frame budget by duration:

- ≤30 s → about 1–2 fps (up to 30 frames)
- 30 s–1 min → about 40 frames
- 1–3 min → about 60 frames
- 3–10 min → about 80 frames

**Videos over 10 min are auto-chunked.** Without `--start`/`--end`, the video is split into `ceil(duration / 10 min)` even chunks, each with the dense focused budget. A 60-min video becomes 6 chunks × about 80 frames = about 480 regular frames plus cut frames. `--max-frames` is the per-chunk cap; lower it or pass `--no-chunk` to clamp the total. The metadata line then says `chunked mode, N chunks × ~Xs`.

## Focusing on a section

When the user names a moment ("around 2:30", "the last 30 seconds", "0:45 to 1:00"), or the question concerns one part of a long video, pass `--start` and/or `--end`. Focused budgets (capped at 2 fps):

- ≤5 s → 2 fps (up to 10 frames)
- 5–15 s → 2 fps (up to 30 frames)
- 15–30 s → about 2 fps (up to 60 frames)
- 30–60 s → about 1.3 fps (up to 80 frames)
- 60–180 s → about 0.6 fps (100 frames, capped)

Also use focused mode for a re-run when a full scan lacked detail in some region. Frame timestamps stay absolute (real timeline).

```bash
# Last 10 seconds of a 1-minute video
python3 "${CLAUDE_SKILL_DIR}/scripts/run.py" video.mp4 --start 50 --end 60

# Zoom into 2:15 → 2:45 at 3 fps (clamped to 2 fps)
python3 "${CLAUDE_SKILL_DIR}/scripts/run.py" "$URL" --start 2:15 --end 2:45 --fps 3

# From 1h12m to the end
python3 "${CLAUDE_SKILL_DIR}/scripts/run.py" "$URL" --start 1:12:00
```

## Scene cut detection

On by default. An `scdet` pass extracts one extra frame at every detected cut, and the regular sampler fills the gaps between cuts proportionally to their length instead of sampling uniformly.

1. **Score** – `ffmpeg -vf scdet=threshold=0` scores every frame against the previous one; all scores are kept.
2. **Auto-threshold** – knee-point detection on the sorted score curve picks a per-video threshold (floor `5.0`, so static videos produce no false cuts). Score distributions differ widely between talking heads and montages, which is why no static threshold is used.
3. **De-cluster** – cuts within `--scene-min-gap` (2 s) collapse to one.
4. **Gap-fill** – each gap between cuts gets regular frames proportional to its length; gaps shorter than half the average spacing are skipped. Without cuts (or with `--no-scene`) this is uniform sampling.
5. **Extract** – one JPEG per timestamp via fast-seek at the same `--resolution`.

stderr shows `[transcribe] N cuts detected (auto-picked X.YZ)`; the report metadata shows `scdet ≥ X.Y auto` and `(gap-filled, ~F fps avg)`.

The frame list is merged chronologically and tagged `[REG]` (`frames/frame_NNNN_tNNNNNs.jpg`) or `[CUT]` (`cuts/cut_NNN_tNNNNNs.jpg`). Read both kinds.

**`[CUT]` filename vs. content:** the filename carries the detected cut point, but the image is taken `--scene-settle-seconds` later (default `1.0`, clamped to `next_cut - 0.3 s`), so the picture is typically 0.5–2.5 s after its name. `[REG]` filenames match their content. Verify timestamps with `illustrate.py --extract` before using them in an illustration spec (see `report-writing.md`). `--scene-settle-seconds 0` extracts right at the cut; 2–4 s helps slow-rendering apps but risks bleeding into transient flashes.

Use `--no-scene` for talking heads without real cuts, tight token budgets, or a fast first pass on a long video. Use `--scene-threshold F` when auto picked too few cuts (lower, e.g. `8`), too many (higher, e.g. `30`), or for reproducible re-runs. scdet adds about 5–10 % wall-clock; each cut frame costs the same image tokens as a regular frame.
