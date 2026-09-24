#!/usr/bin/env python3
"""Merge two or more Claude Code sessions into one new session.

A session lives in ~/.claude/projects/<project-slug>/ as <session-id>.jsonl plus an
optional <session-id>/ sidecar directory (custom-title.json, tool-results, subagents).
Message lines form a tree via uuid/parentUuid; Claude Code resumes a session by walking
up from the newest leaf, so everything that should stay visible must hang on one chain.

The merge therefore:
  * orders the sources chronologically (first message timestamp) unless --keep-order,
  * re-parents the root of every later source onto the leaf of the previous one,
  * rewrites the top-level sessionId of every line to the new session id,
  * drops per-session state that must not be inherited (bridge-session, custom-title,
    agent-name), emits a single title, aggregates cost-state, keeps the last last-prompt,
  * copies the sidecar directories (tool-results etc.) into the new sidecar.

Sources are never modified or deleted. Desired-state: if a session with the requested
title already exists in the project the script reports it and exits 0 (use --new-id to
force a specific id, --force to bypass the freshness guard on recently written sources).

Usage:
  merge-sessions.py --project <project-slug> --title LPM <session-id> <session-id> [...]
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import shutil
import sys
import time
import uuid
from pathlib import Path

# Lines that are bound to the source session and must not be carried over verbatim.
DROP_TYPES = {"bridge-session", "custom-title", "agent-name"}
# Lines that carry uuid/parentUuid and form the conversation tree. Attachments hang off
# the chain as side nodes (never parents), system lines are regular chain members.
MESSAGE_TYPES = {"user", "assistant", "system", "attachment"}
COUNTED_TYPES = {"user", "assistant"}


def projects_root() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")) / "projects"


def load_lines(path: Path) -> list[dict]:
    out = []
    with path.open(encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                out.append(json.loads(raw))
            except json.JSONDecodeError as exc:
                sys.exit(f"[ERR] {path.name}:{n}: invalid JSON ({exc})")
    return out


def dump(obj: dict) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def messages(lines: list[dict]) -> list[dict]:
    return [o for o in lines if "uuid" in o and o.get("type") in MESSAGE_TYPES]


def first_timestamp(lines: list[dict]) -> str:
    for o in messages(lines):
        if o.get("timestamp"):
            return o["timestamp"]
    return ""


def leaf_uuid(lines: list[dict], label: str) -> str:
    """Newest main-chain line; this is where Claude Code itself would hang the next prompt."""
    msgs = [m for m in messages(lines) if not m.get("isSidechain") and m["type"] != "attachment"]
    if not msgs:
        sys.exit(f"[ERR] {label}: no messages")
    parents = {m.get("parentUuid") for m in messages(lines)}
    last = msgs[-1]
    if last["uuid"] in parents:
        print(f"[WARN] {label}: last message {last['uuid']} already has children; chaining onto it anyway")
    return last["uuid"]


def roots(lines: list[dict]) -> list[dict]:
    return [m for m in messages(lines) if m.get("parentUuid") is None]


def existing_title(project_dir: Path, title: str) -> str | None:
    for path in project_dir.glob("*.jsonl"):
        sidecar = project_dir / path.stem / "custom-title.json"
        if sidecar.is_file():
            try:
                if json.loads(sidecar.read_text(encoding="utf-8")).get("customTitle") == title:
                    return path.stem
            except (json.JSONDecodeError, OSError):
                pass
    return None


def merge_cost(states: list[dict], session_id: str) -> dict | None:
    if not states:
        return None
    total = copy.deepcopy(states[0])
    total["sessionId"] = session_id
    for st in states[1:]:
        for key, val in st.items():
            if key == "modelUsage" and isinstance(val, dict):
                usage = total.setdefault("modelUsage", {})
                for model, fields in val.items():
                    tgt = usage.setdefault(model, {})
                    for f, v in fields.items():
                        if isinstance(v, (int, float)) and not isinstance(v, bool):
                            tgt[f] = tgt.get(f, 0) + v
                        else:
                            tgt.setdefault(f, v)
            elif key == "startTime" and isinstance(val, (int, float)):
                total["startTime"] = min(total.get("startTime", val), val)
            elif isinstance(val, (int, float)) and not isinstance(val, bool) and key != "sessionId":
                total[key] = total.get(key, 0) + val
    return total


def rewrite_sidecar_jsonl(path: Path, new_id: str) -> None:
    lines = load_lines(path)
    with path.open("w", encoding="utf-8") as fh:
        for o in lines:
            if "sessionId" in o:
                o["sessionId"] = new_id
            fh.write(dump(o) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sessions", nargs="+", help="source session ids (2 or more)")
    ap.add_argument("--project", required=True, help="project slug under ~/.claude/projects")
    ap.add_argument("--title", required=True, help="/rename title of the merged session")
    ap.add_argument("--new-id", help="session id for the result (default: random uuid4)")
    ap.add_argument("--keep-order", action="store_true", help="use the given order instead of sorting by first timestamp")
    ap.add_argument("--force", action="store_true", help="skip the freshness guard on recently written sources")
    ap.add_argument("--dry-run", action="store_true", help="report what would be written, write nothing")
    args = ap.parse_args()

    if len(args.sessions) < 2:
        sys.exit("[ERR] need at least two source sessions")
    project_dir = projects_root() / args.project
    if not project_dir.is_dir():
        sys.exit(f"[ERR] project dir not found: {project_dir}")

    # Desired-state: a session with this title already exists -> nothing to do.
    if not args.new_id:
        found = existing_title(project_dir, args.title)
        if found:
            print(f"[OK] session titled '{args.title}' already exists: {found}")
            return 0

    sources: list[tuple[str, Path, list[dict]]] = []
    for sid in args.sessions:
        path = project_dir / f"{sid}.jsonl"
        if not path.is_file():
            sys.exit(f"[ERR] source not found: {path}")
        age = time.time() - path.stat().st_mtime
        if not args.force and age < 120:
            sys.exit(f"[ERR] {sid} was written {int(age)}s ago - close the session first, then re-run (or --force)")
        sources.append((sid, path, load_lines(path)))

    if not args.keep_order:
        sources.sort(key=lambda s: first_timestamp(s[2]))

    # Sanity: uuids must be unique across sources.
    seen: dict[str, str] = {}
    for sid, _, lines in sources:
        for o in lines:
            u = o.get("uuid")
            if u and u in seen and seen[u] != sid:
                sys.exit(f"[ERR] uuid {u} exists in both {seen[u]} and {sid}")
            if u:
                seen[u] = sid

    new_id = args.new_id or str(uuid.uuid4())
    out_path = project_dir / f"{new_id}.jsonl"
    out_dir = project_dir / new_id
    if out_path.exists():
        sys.exit(f"[ERR] target already exists: {out_path}")

    merged: list[dict] = [
        {"type": "custom-title", "customTitle": args.title, "sessionId": new_id},
        {"type": "agent-name", "agentName": args.title, "sessionId": new_id},
    ]
    cost_states: list[dict] = []
    last_prompt: dict | None = None
    prev_leaf: str | None = None
    for sid, _, lines in sources:
        src_roots = roots(lines)
        if len(src_roots) != 1:
            sys.exit(f"[ERR] {sid}: expected exactly one root message, found {len(src_roots)}")
        root_uuid = src_roots[0]["uuid"]
        src_cost: list[dict] = []
        n_msgs = 0
        for o in lines:
            t = o.get("type")
            if t in DROP_TYPES:
                continue
            o = copy.deepcopy(o)
            if "sessionId" in o:
                o["sessionId"] = new_id
            if t == "cost-state":
                src_cost = [o]  # last one per source wins, then aggregated across sources
                continue
            if t == "last-prompt":
                last_prompt = o
                continue
            if "uuid" in o and o["uuid"] == root_uuid and prev_leaf:
                o["parentUuid"] = prev_leaf
            if t in COUNTED_TYPES:
                n_msgs += 1
            merged.append(o)
        cost_states.extend(src_cost)
        prev_leaf = leaf_uuid(lines, sid)
        print(f"[INFO] {sid}: {n_msgs} messages, first {first_timestamp(lines)}, leaf {prev_leaf}")

    cost = merge_cost(cost_states, new_id)
    if cost:
        merged.append(cost)
    if last_prompt:
        merged.append(last_prompt)

    print(f"[INFO] result: {new_id} ({len(merged)} lines) titled '{args.title}'")
    if args.dry_run:
        return 0

    with out_path.open("w", encoding="utf-8") as fh:
        for o in merged:
            fh.write(dump(o) + "\n")

    out_dir.mkdir(exist_ok=True)
    for sid, _, _ in sources:
        src_dir = project_dir / sid
        if not src_dir.is_dir():
            continue
        for item in src_dir.rglob("*"):
            if item.is_dir() or item.name == "custom-title.json":
                continue
            target = out_dir / item.relative_to(src_dir)
            if target.exists():
                print(f"[WARN] sidecar collision, keeping first: {target.relative_to(out_dir)}")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, target)
            if target.suffix == ".jsonl":
                rewrite_sidecar_jsonl(target, new_id)
    (out_dir / "custom-title.json").write_text(dump({"customTitle": args.title}), encoding="utf-8")

    print(f"[OK] wrote {out_path}")
    print(f"[OK] sources left untouched: {', '.join(s[0] for s in sources)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
