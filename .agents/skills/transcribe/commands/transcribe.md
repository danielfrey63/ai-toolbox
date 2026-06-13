---
description: Transcribe a video or audio file (URL or local path). Downloads with yt-dlp, extracts frames with ffmpeg for video (auto-chunked for long sources), transcribes via captions / Whisper / optional speaker diarization, and produces a three-file report (protocol + transcript + analysis) plus a clickable Summary in chat.
argument-hint: <video-or-audio-url-or-path> [question]
allowed-tools: [Bash, Read, AskUserQuestion]
---

Invoke the `transcribe` skill (defined in SKILL.md) with the user's arguments: $ARGUMENTS

Follow the skill's full pipeline: preflight setup check → download via yt-dlp → extract frames at auto-scaled fps (video only) → pull captions or Whisper transcript → Read each frame → answer the user grounded in frames and transcript. If the user provided no arguments, ask them for a video/audio URL or local path before proceeding.
