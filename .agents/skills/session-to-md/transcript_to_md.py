#!/usr/bin/env python3
"""Convert a Claude Code session transcript (JSONL) into a readable Markdown
conversation file.

Keeps only real user messages and assistant text blocks. Drops tool calls,
tool results (incl. diffs), thinking blocks, sidechain (subagent) traffic,
system reminders and compaction summaries.

Usage:
    python transcript_to_md.py [session.jsonl] [-o output.md]
                               [--user-name NAME] [--assistant-name NAME]
                               [--title TITLE] [--no-timestamps]
    python transcript_to_md.py --name SUBSTR [-o output.md]   # named session(s)
    python transcript_to_md.py --list [SUBSTR]                 # list (optionally filtered)

Without an input argument, the newest session of the current working
directory's Claude Code project (~/.claude/projects/<cwd-slug>/) is used.

With --name, every session whose Claude Code title contains SUBSTR
(case-insensitive) is selected — the title is the one the resume picker
shows: an explicit /title, else the auto-generated ai-title, else the
latest summary. A single match is written like a normal transcript;
several matches are concatenated into one combined Markdown file, newest last.

Idempotent: output is a pure function of the input file(s); re-runs overwrite.
"""

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

# Harness-injected wrappers that are not part of the human conversation.
STRIP_TAG_PATTERNS = [
    re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL),
    re.compile(r"<local-command-caveat>.*?</local-command-caveat>", re.DOTALL),
]
COMMAND_NAME_RE = re.compile(r"<command-name>(.*?)</command-name>", re.DOTALL)
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)
COMMAND_STDOUT_RE = re.compile(r"<local-command-stdout>(.*?)</local-command-stdout>", re.DOTALL)
COMMAND_MSG_RE = re.compile(r"<command-message>.*?</command-message>", re.DOTALL)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def parse_ts(raw):
    """Parse an ISO timestamp to local time; return None on failure."""
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def clean_user_text(text):
    """Strip harness wrappers from a user text block; render slash commands
    compactly. Returns '' if nothing human-readable remains."""
    for pat in STRIP_TAG_PATTERNS:
        text = pat.sub("", text)

    commands = COMMAND_NAME_RE.findall(text)
    if commands:
        args = [a.strip() for a in COMMAND_ARGS_RE.findall(text)]
        stdouts = [ANSI_RE.sub("", s).strip() for s in COMMAND_STDOUT_RE.findall(text)]
        rendered = []
        for i, cmd in enumerate(c.strip() for c in commands):
            arg = args[i] if i < len(args) and args[i] else ""
            line = f"*[Befehl: {cmd}{' ' + arg if arg else ''}]*"
            if i < len(stdouts) and stdouts[i] and len(stdouts[i]) <= 200:
                line += f"\n*[Ausgabe: {stdouts[i]}]*"
            rendered.append(line)
        # Remove all command markup, keep any free text the user typed alongside.
        for pat in (COMMAND_NAME_RE, COMMAND_MSG_RE, COMMAND_ARGS_RE, COMMAND_STDOUT_RE):
            text = pat.sub("", text)
        remainder = text.strip()
        return "\n".join(rendered) + (f"\n\n{remainder}" if remainder else "")

    return text.strip()


def extract_text(entry):
    """Return (role, text) for a transcript line, or None if it carries no
    human-readable conversation content."""
    etype = entry.get("type")
    if etype not in ("user", "assistant"):
        return None
    if entry.get("isSidechain"):
        return None  # subagent traffic
    message = entry.get("message") or {}
    content = message.get("content")

    if etype == "user":
        if isinstance(content, str):
            text = clean_user_text(content)
        elif isinstance(content, list):
            parts = [b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text"]
            text = clean_user_text("\n\n".join(p for p in parts if p))
        else:
            return None
        return ("user", text) if text else None

    # assistant: keep text blocks only (no thinking, no tool_use)
    if isinstance(content, list):
        parts = [b.get("text", "").strip() for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        text = "\n\n".join(p for p in parts if p)
        return ("assistant", text) if text else None
    return None


def convert(jsonl_path, user_name, assistant_name, with_timestamps,
            title_override=None, as_section=False):
    """Read the JSONL transcript and return (markdown_string, stats_dict).

    With as_section=True the block starts at heading level 2 (no document
    title / distillation note), so it can be embedded under a shared H1 when
    several sessions are combined into one file.
    """
    groups = []   # list of [role, first_ts, [texts]]
    titles = []
    stats = {"lines": 0, "kept": 0, "skipped": 0, "errors": 0}
    session_id = None
    first_ts = last_ts = None

    with open(jsonl_path, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            stats["lines"] += 1
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                stats["errors"] += 1
                continue

            if entry.get("type") == "summary" and entry.get("summary"):
                titles.append(entry["summary"])
                continue
            session_id = session_id or entry.get("sessionId")

            result = extract_text(entry)
            if result is None:
                stats["skipped"] += 1
                continue
            role, text = result
            ts = parse_ts(entry.get("timestamp"))
            first_ts = first_ts or ts
            last_ts = ts or last_ts
            stats["kept"] += 1

            # Merge consecutive messages of the same role into one section.
            if groups and groups[-1][0] == role:
                groups[-1][2].append(text)
            else:
                groups.append([role, ts, [text]])

    title = title_override or (titles[-1] if titles else jsonl_path.stem)
    names = {"user": user_name, "assistant": assistant_name}

    lines = [f"## {title}" if as_section else f"# Konversations-Transcript — {title}", ""]
    lines += ["| | |", "|---|---|",
              f"| **Quelle** | `{jsonl_path.name}` |",
              f"| **Session** | `{session_id or 'unbekannt'}` |"]
    if first_ts and last_ts:
        lines.append(f"| **Zeitraum** | {first_ts:%d.%m.%Y %H:%M} – {last_ts:%d.%m.%Y %H:%M} |")
    lines.append(f"| **Generiert** | {datetime.now().astimezone():%d.%m.%Y %H:%M} |")
    lines.append("")
    if not as_section:
        lines += ["*Automatisch destilliert: nur User-/Assistent-Text — ohne Tool-Aufrufe,"
                  " Tool-Resultate, Diffs und interne Denkschritte.*", ""]
    lines += ["---", ""]

    prev_date = None
    for role, ts, texts in groups:
        stamp = ""
        if with_timestamps and ts:
            stamp = f" — {ts:%d.%m.%Y %H:%M}" if ts.date() != prev_date else f" — {ts:%H:%M}"
            prev_date = ts.date()
        lines += [f"### {names[role]}{stamp}", "", "\n\n".join(texts), ""]

    return "\n".join(lines), stats


def find_project_dir():
    """Return the Claude Code project directory enclosing the cwd, or None.

    Claude Code stores transcripts under ~/.claude/projects/<slug>/, where the
    slug is the project directory path with every non-alphanumeric character
    replaced by '-'. Sessions belong to the directory Claude Code was started
    in, so we walk up from the cwd until a matching project is found.
    """
    projects_root = Path.home() / ".claude" / "projects"
    for directory in (Path.cwd(), *Path.cwd().parents):
        slug = re.sub(r"[^A-Za-z0-9]", "-", str(directory))
        proj = projects_root / slug
        if proj.is_dir() and any(proj.glob("*.jsonl")):
            return proj
    return None


def require_project_dir():
    """Like find_project_dir but exit with guidance when nothing is found."""
    proj = find_project_dir()
    if proj is None:
        sys.exit(f"ERROR: no Claude Code project found for {Path.cwd()} or any parent "
                 f"directory (searched {Path.home() / '.claude' / 'projects'}).\n"
                 f"Pass the .jsonl path explicitly instead.")
    return proj


def read_session_title(jsonl_path):
    """Return the session's effective title — the one Claude Code's resume picker
    shows — or None.

    Claude Code records up to three title kinds; precedence mirrors the picker:
    an explicit /title (`custom-title`) wins, else the auto-generated `ai-title`,
    else the latest compaction `summary`. The last entry of each kind wins.
    Lines without any marker are skipped cheaply before JSON parsing.
    """
    custom = ai = summary = None
    with open(jsonl_path, encoding="utf-8") as fh:
        for raw in fh:
            if ('"custom-title"' not in raw and '"ai-title"' not in raw
                    and '"summary"' not in raw):
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            etype = entry.get("type")
            if etype == "custom-title" and entry.get("customTitle"):
                custom = entry["customTitle"]
            elif etype == "ai-title" and entry.get("aiTitle"):
                ai = entry["aiTitle"]
            elif etype == "summary" and entry.get("summary"):
                summary = entry["summary"]
    return custom or ai or summary


def list_sessions(project_dir):
    """Return [(path, title_or_None, mtime)] for the project, newest last."""
    sessions = []
    for path in project_dir.glob("*.jsonl"):
        sessions.append((path, read_session_title(path), path.stat().st_mtime))
    sessions.sort(key=lambda s: s[2])
    return sessions


def find_sessions_by_name(substr):
    """Return [(path, title)] of sessions whose title contains substr (ci), newest last."""
    project_dir = require_project_dir()
    needle = substr.casefold()
    return [(path, title) for path, title, _ in list_sessions(project_dir)
            if title and needle in title.casefold()]


def discover_latest_transcript():
    """Locate the newest session transcript for the enclosing Claude Code project."""
    project_dir = require_project_dir()
    candidates = sorted(project_dir.glob("*.jsonl"),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


def sanitize_filename(text):
    """Reduce arbitrary text to a safe-ish file stem."""
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-") or "sessions"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path, nargs="?",
                    help="Claude Code session transcript (.jsonl); "
                         "default: newest session of the current project")
    ap.add_argument("--name", help="select session(s) by Claude Code title — the "
                    "title shown in the resume picker (custom /title, else ai-title, "
                    "else summary); case-insensitive substring, every match included")
    ap.add_argument("--list", nargs="?", const="", default=None, metavar="TEXT",
                    help="list the current project's sessions (title, time) and exit; "
                         "with an optional TEXT, show only sessions whose title contains it")
    ap.add_argument("-o", "--output", type=Path,
                    help="output Markdown file (default: derived from input/name in cwd)")
    ap.add_argument("--user-name", default="User", help="label for user messages")
    ap.add_argument("--assistant-name", default="Claude", help="label for assistant messages")
    ap.add_argument("--no-timestamps", action="store_true", help="omit timestamps")
    ap.add_argument("--title", help="document title (default: last summary line or file stem)")
    args = ap.parse_args()

    with_ts = not args.no_timestamps

    if args.list is not None:
        needle = args.list.casefold() if args.list else None
        for path, title, mtime in list_sessions(require_project_dir()):
            if needle and not (title and needle in title.casefold()):
                continue
            stamp = datetime.fromtimestamp(mtime).astimezone()
            print(f"{stamp:%d.%m.%Y %H:%M}  {path.name}  {title or '(unbenannt)'}")
        return

    if args.name:
        if args.input is not None:
            sys.exit("ERROR: pass either a transcript path or --name, not both.")
        matches = find_sessions_by_name(args.name)
        if not matches:
            names = [t for _, t, _ in list_sessions(require_project_dir()) if t]
            hint = ("\nAvailable session titles: " + ", ".join(sorted(set(names)))
                    if names else "\nNo titled sessions in this project yet.")
            sys.exit(f"ERROR: no session title contains {args.name!r}.{hint}")

        output = args.output or Path.cwd() / f"{sanitize_filename(args.name)}.md"
        combined = len(matches) > 1
        blocks, totals = [], {"lines": 0, "kept": 0, "skipped": 0, "errors": 0}
        for path, title in matches:
            # Heading is the session's own name; --title only renames the combined doc.
            section_title = title if combined else (args.title or title)
            md, stats = convert(path, args.user_name, args.assistant_name, with_ts,
                                section_title, as_section=combined)
            blocks.append(md)
            for k in totals:
                totals[k] += stats[k]
            print(f"  + {title}  ({path.name}): {stats['kept']} messages")

        if combined:
            doc_title = args.title or f"{len(matches)} Sessions — '{args.name}'"
            markdown = (f"# Konversations-Transcript — {doc_title}\n\n"
                        "*Automatisch destilliert: nur User-/Assistent-Text — ohne "
                        "Tool-Aufrufe, Tool-Resultate, Diffs und interne Denkschritte.*\n\n"
                        + "\n".join(blocks))
        else:
            markdown = blocks[0]

        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(markdown, encoding="utf-8")
        print(f"Written: {output}  ({len(matches)} session(s))")
        print(f"Lines: {totals['lines']} | conversation messages kept: {totals['kept']} | "
              f"non-conversation lines skipped: {totals['skipped']} | "
              f"parse errors: {totals['errors']}")
        return

    if args.input is None:
        args.input = discover_latest_transcript()
        print(f"Auto-discovered: {args.input}")
    if not args.input.is_file():
        sys.exit(f"ERROR: input file not found: {args.input}")
    output = args.output or Path.cwd() / f"{args.input.stem}.md"

    markdown, stats = convert(args.input, args.user_name, args.assistant_name,
                              with_ts, args.title)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(markdown, encoding="utf-8")

    print(f"Written: {output}")
    print(f"Lines: {stats['lines']} | conversation messages kept: {stats['kept']} | "
          f"non-conversation lines skipped: {stats['skipped']} | parse errors: {stats['errors']}")


if __name__ == "__main__":
    main()
