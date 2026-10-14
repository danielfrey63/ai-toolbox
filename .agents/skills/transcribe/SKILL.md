---
name: transcribe
description: "Transcribes and watches video or audio files (URL or local path): downloads with yt-dlp, extracts frames and scene cuts, transcribes via native captions or on-device Whisper with speaker diarization, and writes a persistent Markdown report (overview, summary, analysis, transcript, speaker mapping). Use when the user shares a video or audio URL or file (YouTube, Vimeo, meeting recording, voice memo, screen recording) and wants it transcribed, summarized, or asks what is said or shown in it. Trigger: «transkribiere», «Video zusammenfassen», «Meeting-Aufnahme auswerten», «was wird im Video gesagt»."
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, SendUserFile
license: MIT
metadata:
  homepage: https://github.com/danielfrey63/ai-toolbox
  repository: https://github.com/danielfrey63/ai-toolbox
---

# Transcribe

Transcribe audio or video and produce a report grounded in the transcript and, for video, selected frames. The same runtime works in any harness and on the CLI.

## Installation and discovery

**Read [INSTALL.md](INSTALL.md) before the first run or whenever setup is incomplete.** It is the single installation contract for humans and harnesses: prerequisites, noninteractive installation, verification, profiles, configuration and exit codes. `<skill>` is the absolute directory containing this file and `transcribe.py`; it works in both the toolbox and the split repository. Windows uses `python`; macOS/Linux usually use `python3`.

```text
python "<skill>/transcribe.py" doctor --profile local --json
python "<skill>/transcribe.py" install --profile local --non-interactive
python "<skill>/transcribe.py" doctor --profile local --json
```

Only install when the required profile is missing. Recheck after installation. Local transcription needs no cloud key. Local speaker separation additionally needs Hugging Face model access; use `--no-diarize` when it is not needed or unavailable.

## Choose the analysis path

- `--analysis model`: a configured model writes the report. Use when sending text and images to that endpoint is appropriate. The installation profile is `headless`.
- `--analysis harness`: the calling harness reads the companions and writes the report. Follow [references/interactive.md](references/interactive.md) and read [references/report-writing.md](references/report-writing.md) before writing.
- `--analysis none`: media processing and transcript output without model analysis.

`--local` pins audio transcription and speaker separation to local backends. It does not make cloud model analysis local. Without this flag, configured cloud audio backends can be reached after local failure. Honour explicit data-flow requirements for both audio and analysis.

## Run and resume

```text
python "<skill>/transcribe.py" run "<source>" --local --language de --analysis harness --plan --json
python "<skill>/transcribe.py" run "<source>" --local --language de --analysis harness --json
```

Read the JSON result for `base`, `protocol`, `transcript`, `report`, `review` and `status`. Progress appears on stderr. `handoff` means media processing succeeded and the harness still needs to write the report. Nonzero codes are not success; 4 and 5 identify review gates.

- Pass a known language and requested range (`--start`, `--end`). Audio-only sources skip frame stages.
- Optional inputs: `<base>.participants.txt` and `<base>.glossary.txt`; folder defaults are `transcribe-participants.txt` and `transcribe-glossary.txt`. Recording-specific inputs win.
- Reruns check dependencies and reuse completed work. `--rerun` repeats media preparation, `--fresh` recomputes speech and speaker separation, `--force` repeats model stages. `run --plan` explains the decision.
- Correct speaker names and block overrides in `<base>.speakers.md`, then rerun. Stable labels are retained separately so later corrections work.
- Failed batches and chapters remain incomplete. Do not present incomplete output as a complete analysis.

Do not rename source recordings merely to satisfy a convention. A consistent base is useful for new recordings; honour existing names and user preferences.

## Report and review

When analysis is requested, write Übersicht, Summary and Analysis using [references/report-writing.md](references/report-writing.md). Answer any specific question in addition, with timestamps. For model analysis, read and use the generated files instead of duplicating the model stages.

Speaker assignments, illustrations and uncertain passages must remain traceable to evidence. Unresolved names retain their labels. Degradation to captions-only or audio-only must be visible in the report. Use `illustrate.py` and its spec/manifest for reproducible crops.

Refresh reviews with `python "<skill>/transcribe.py" review "<base>"`. A person checks artefacts and publication target; never tick boxes on their behalf. Publication is a separate, explicitly requested action through `transcribe.py publish`. Changes to transcript, crop bytes, report or publication configuration invalidate the corresponding review.

Reply with key statements, clickable companion links supported by the client, and the answer to the user's question. Do not repeat the full report. Retain frames for expected follow-ups; remove only the specific run's work directory when no longer needed.

## References

- [INSTALL.md](INSTALL.md): bootstrap, profiles, keys, CLI and harness integration.
- [references/parameters.md](references/parameters.md): generated types, defaults and precedence.
- [references/options.md](references/options.md): advanced media options; `run --help-all` lists available flags.
- [references/interactive.md](references/interactive.md): harness-led evidence reading and persistence.
- [references/report-writing.md](references/report-writing.md): report methodology and illustrations.
- [references/repair.md](references/repair.md): suspect speech passages and targeted repair.
- [references/maintenance.md](references/maintenance.md): cache contracts, tests and release packaging.
