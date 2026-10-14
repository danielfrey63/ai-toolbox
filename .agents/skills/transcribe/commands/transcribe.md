---
description: Transcribe and analyse audio or video through the portable Transcribe CLI.
argument-hint: <video-or-audio-url-or-path> [question]
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
---

Read and follow the plugin's root SKILL.md with the user's arguments: $ARGUMENTS

SKILL.md routes installation to INSTALL.md and defines the model, harness and media-only paths. Use the same transcribe.py entrypoint as a terminal user. If the source is missing, ask for its URL or local path.
