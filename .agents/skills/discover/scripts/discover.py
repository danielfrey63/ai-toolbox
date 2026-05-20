#!/usr/bin/env python3
"""Discover the most interesting recent videos across configured topics.

Runs `yt-dlp ytsearch:` queries with a `--dateafter` recency filter, dedupes by
video ID, ranks by views-per-day, and prints a markdown table. The topic list
lives in `topics.json` next to this script — edit it to taste.

Output rows are tagged with the originating topic so it's clear which queries
surfaced what. The companion `/watch` skill can then summarize any URL on demand.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
DEFAULT_TOPICS_FILE = SCRIPT_DIR / "topics.json"


def load_topics(path: Path) -> dict[str, list[str]]:
    if not path.exists():
        raise SystemExit(f"topics file not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def parse_upload_date(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        if len(s) == 8 and s.isdigit():
            return datetime.strptime(s, "%Y%m%d").replace(tzinfo=timezone.utc)
        return datetime.fromisoformat(s).astimezone(timezone.utc)
    except (ValueError, TypeError):
        return None


def search_query(query: str, n: int, dateafter: str) -> list[dict]:
    """Run `yt-dlp ytsearch{n}:query --dateafter dateafter` and return per-video dicts."""
    cmd = [
        "yt-dlp",
        "--skip-download",
        "--dump-json",
        "--ignore-errors",
        "--no-warnings",
        "--dateafter", dateafter,
        f"ytsearch{n}:{query}",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    out: list[dict] = []
    for line in result.stdout.strip().splitlines():
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def fmt_duration(seconds: int | float | None) -> str:
    if not seconds:
        return "?"
    total = int(seconds)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def fmt_age(upload: datetime | None, now: datetime) -> str:
    if not upload:
        return "?"
    days = (now - upload).days
    if days <= 0:
        return "today"
    if days == 1:
        return "1d"
    if days < 30:
        return f"{days}d"
    if days < 365:
        return f"{days // 30}mo"
    return f"{days // 365}y"


def fmt_views(n: int | None) -> str:
    if not n:
        return "?"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def score(video: dict, now: datetime) -> float:
    """views-per-day, with sub-day floor at 1 to avoid huge numbers on brand-new uploads."""
    views = video.get("view_count") or 0
    upload = parse_upload_date(video.get("upload_date"))
    if not upload:
        return views * 0.001
    age_days = max(1, (now - upload).days)
    return views / age_days


def shorten(s: str, n: int) -> str:
    if not s:
        return ""
    s = re.sub(r"\s+", " ", s).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="discover",
        description="Curate recent interesting videos across configured topics via yt-dlp search.",
    )
    ap.add_argument("--days", type=int, default=14,
                    help="Recency window — only videos uploaded in the last N days (default 14)")
    ap.add_argument("--per-query", type=int, default=15,
                    help="Search results to fetch per query before date filter (default 15)")
    ap.add_argument("--top", type=int, default=20,
                    help="Number of results to show after ranking (default 20)")
    ap.add_argument("--topics", type=str, default=None,
                    help="Comma-separated subset of topic names (default: all from topics.json)")
    ap.add_argument("--topics-file", type=str, default=str(DEFAULT_TOPICS_FILE),
                    help="Path to topics JSON (default: topics.json next to this script)")
    ap.add_argument("--min-views", type=int, default=0,
                    help="Drop videos below this view count (default 0 = no filter)")
    ap.add_argument("--min-duration", type=int, default=180,
                    help="Drop videos shorter than this many seconds (default 180; "
                         "filters out shorts and trailers)")
    ap.add_argument("--max-duration", type=int, default=0,
                    help="Drop videos longer than this many seconds (default 0 = no cap)")
    ap.add_argument("--json", action="store_true",
                    help="Emit JSON instead of a markdown table")
    args = ap.parse_args()

    if shutil.which("yt-dlp") is None:
        raise SystemExit("yt-dlp is not installed. Install with `pip install --user yt-dlp`.")

    topics_all = load_topics(Path(args.topics_file))
    if args.topics:
        wanted = {t.strip() for t in args.topics.split(",") if t.strip()}
        topics = {k: v for k, v in topics_all.items() if k in wanted}
        unknown = wanted - set(topics_all)
        if unknown:
            print(f"[discover] unknown topic(s): {sorted(unknown)}", file=sys.stderr)
        if not topics:
            raise SystemExit("No matching topics after --topics filter.")
    else:
        topics = topics_all

    dateafter = f"now-{args.days}days"
    now = datetime.now(timezone.utc)

    seen: dict[str, dict] = {}
    for topic, queries in topics.items():
        for q in queries:
            print(f"[discover] {topic} :: {q}", file=sys.stderr)
            videos = search_query(q, args.per_query, dateafter)
            for v in videos:
                vid = v.get("id") or v.get("display_id")
                if not vid:
                    continue
                dur = v.get("duration") or 0
                if args.min_duration and dur < args.min_duration:
                    continue
                if args.max_duration and dur > args.max_duration:
                    continue
                if args.min_views and (v.get("view_count") or 0) < args.min_views:
                    continue
                # Dedupe by video ID; keep the entry that gives the best score (or
                # first-seen with topic tag if scores tie).
                v["_topic"] = topic
                v["_query"] = q
                v["_score"] = score(v, now)
                if vid in seen:
                    if v["_score"] > seen[vid]["_score"]:
                        # Keep the higher-ranking entry but accumulate topic tags
                        seen[vid]["_topic"] = topic
                else:
                    seen[vid] = v

    ranked = sorted(seen.values(), key=lambda v: v["_score"], reverse=True)[: args.top]

    if args.json:
        out = []
        for v in ranked:
            out.append({
                "id": v.get("id"),
                "title": v.get("title"),
                "url": v.get("webpage_url") or f"https://www.youtube.com/watch?v={v.get('id')}",
                "channel": v.get("channel") or v.get("uploader"),
                "duration_seconds": v.get("duration"),
                "view_count": v.get("view_count"),
                "upload_date": v.get("upload_date"),
                "topic": v.get("_topic"),
                "query": v.get("_query"),
                "views_per_day": round(v["_score"], 1),
            })
        print(json.dumps(out, indent=2, ensure_ascii=False))
        return 0

    print()
    print(f"# Discover — top {len(ranked)} videos across {len(topics)} topics, last {args.days} days")
    print()
    print(f"_Ranked by views/day. Pipe any URL through `/watch <url>` for a content summary._")
    print()
    print("| # | Topic | Title | Channel | Dur | Age | Views | v/day | URL |")
    print("|---|---|---|---|---|---|---|---|---|")
    for i, v in enumerate(ranked, 1):
        upload = parse_upload_date(v.get("upload_date"))
        url = v.get("webpage_url") or f"https://www.youtube.com/watch?v={v.get('id')}"
        title = shorten(v.get("title") or "", 70).replace("|", "\\|")
        channel = shorten(v.get("channel") or v.get("uploader") or "?", 25).replace("|", "\\|")
        topic = v.get("_topic", "?")
        print(
            f"| {i} | {topic} | {title} | {channel} | "
            f"{fmt_duration(v.get('duration'))} | {fmt_age(upload, now)} | "
            f"{fmt_views(v.get('view_count'))} | {fmt_views(int(v['_score']))} | "
            f"{url} |"
        )
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
