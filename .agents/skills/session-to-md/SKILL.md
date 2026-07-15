---
name: session-to-md
description: Convert a Claude Code session transcript (JSONL) into a clean, readable Markdown conversation — only real user/assistant text, with tool calls, tool results, diffs, thinking blocks and subagent traffic stripped out. Selects sessions by the title shown in the resume picker (explicit /title, else auto-generated ai-title, else summary) with a case-insensitive substring match, exports several matching sessions into one combined file, lists the current project's sessions, or just converts the newest session. Use when the user wants to export, archive, summarize, or share the chat history of the current or a named Claude Code session as Markdown.
argument-hint: "[--name SUBSTR | --list | <session.jsonl>] [-o out.md]"
allowed-tools: Bash, Read
user-invocable: true
metadata:
  version: "0.0.1"
---

# /session-to-md — export a Claude Code session as Markdown

A bundled Python script (`transcript_to_md.py`, in this skill's directory) reads
Claude Code's own session transcripts (the `*.jsonl` files under
`~/.claude/projects/<cwd-slug>/`) and distils them into a readable Markdown
conversation. It keeps only real user messages and assistant text blocks, and
drops tool calls, tool results (incl. diffs), thinking blocks, sidechain
(subagent) traffic, system reminders and compaction summaries. Output is a pure
function of the input — re-runs overwrite, so it is idempotent.

## Interpreter

Every command below uses `python`. On **Windows** that is correct. On
**macOS/Linux** substitute `python3` if `python` is not on PATH. The script needs
only the standard library — no install step.

Let `SCRIPT` be the absolute path to `transcript_to_md.py` in *this skill's
directory* (the same folder as this SKILL.md). Always pass that absolute path so
the skill works from any working directory.

## How sessions are selected

Claude Code stores one transcript per session, named by session UUID, under
`~/.claude/projects/<slug>/`, where `<slug>` is the project directory path with
every non-alphanumeric character replaced by `-`. The script walks up from the
current working directory until it finds the matching project folder.

A session's **title** is the same one the resume picker shows. Claude Code
records up to three kinds and precedence mirrors the picker: an explicit
`/title` (`custom-title`) wins, else the auto-generated `ai-title`, else the
latest compaction `summary`. The script reads the last entry of each kind.
Sessions with none of these have no title and can only be selected by path or
as the newest session.

## Usage

**1. List the project's sessions** (time · file · title) to discover names:
```
python SCRIPT --list                 # all sessions
python SCRIPT --list SEM             # only sessions whose title contains "SEM"
```

**2. Export by name** — case-insensitive substring against the session title:
```
python SCRIPT --name Eric            # 1 match  -> Eric.md (single transcript)
python SCRIPT --name SEM             # >1 match -> SEM.md  (combined, one ## section per session, oldest first)
python SCRIPT --name SEM -o out.md   # explicit output path
```

**3. Export a specific or the newest session** (original behaviour):
```
python SCRIPT                        # newest session of the current project
python SCRIPT path/to/session.jsonl  # explicit transcript file
```

## Options

- `--name SUBSTR` — select every session whose title contains SUBSTR (ci).
- `--list [TEXT]` — print sessions and exit; with optional TEXT, show only titles containing it.
- `-o, --output PATH` — output file (default: derived from input/name in cwd).
- `--title TITLE` — document title (for combined output, the top-level H1 only).
- `--user-name NAME` / `--assistant-name NAME` — section labels (default User / Claude).
- `--no-timestamps` — omit per-message timestamps.

`--name` and a positional path are mutually exclusive. If `--name` matches
nothing, the script exits with an error listing the available named sessions.

## Workflow for the agent

1. If the user names a session vaguely, run `--list` (optionally `--list <hint>`)
   first and confirm which session(s) they mean before exporting.
2. Run the export. The script prints the output path and per-session message counts.
3. Report the written file path back to the user (a clickable `file://` path on
   their platform is helpful). Do not dump the whole Markdown into chat unless asked.
