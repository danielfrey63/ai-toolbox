---
name: discover
description: Discover the most interesting recent videos across AI, frontier models, IDEs, programming, antipatterns, skills, MCP servers, and notable GitHub projects. Searches YouTube via yt-dlp across configurable topic queries, dedupes by video ID, ranks by views-per-day, and returns a curated table. Pair with `/transcribe` to summarize the top picks.
allowed-tools: Bash, Read
user-invocable: true
metadata:
  version: "0.2.3"
---

# /discover — curate recent interesting videos

This skill answers "what should I watch this week?" for AI/coding content. It runs a fixed set of YouTube searches across opinionated topic buckets, filters to recent uploads, ranks by views-per-day, and prints a markdown table you can scan in 30 seconds.

## When to use

- The user asks for the latest interesting AI / frontier-model / coding content.
- The user wants a weekly digest of what's trending in their corners of YouTube.
- Pairing with `/transcribe`: discover candidates → read the table → user picks N URLs → invoke `/transcribe <url>` on each for a content summary.

## Setup

Single dependency: `yt-dlp`. Already installed if `/transcribe` is in use. Otherwise:

```bash
pip install --user --break-system-packages -U yt-dlp
```

No API key, no auth. Searches go directly to YouTube via yt-dlp's scraper.

## How to invoke

`${CLAUDE_SKILL_DIR}` refers to this skill's directory (the folder containing this SKILL.md); if the variable is unset, substitute that absolute path. On Windows use `python` instead of `python3`.

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/discover.py"
```

That's the default — runs every topic in `topics.json` against the last 14 days, ranks by views/day, prints the top 20.

### Common flags

| Flag | Default | What it does |
|---|---|---|
| `--days N` | 14 | Recency window (last N days) |
| `--top N` | 20 | Number of rows in the output table |
| `--per-query N` | 15 | Search depth before date filter (raise for more candidates) |
| `--topics A,B,C` | (all) | Restrict to specific topics by name |
| `--min-views N` | 0 | Drop videos below this view count |
| `--min-duration N` | 180 (s) | Drop videos shorter than N seconds (filters shorts/trailers) |
| `--max-duration N` | 0 (no cap) | Drop videos longer than N seconds |
| `--topics-file PATH` | `topics.json` | Use a different topic config |
| `--json` | (off) | Emit JSON instead of markdown |

### Examples

```bash
# Today's hot picks across only frontier models and skills
python3 "${CLAUDE_SKILL_DIR}/scripts/discover.py" --topics "Frontier Models,Skills" --days 3

# Wider net — last month, top 40, no shorts allowed
python3 "${CLAUDE_SKILL_DIR}/scripts/discover.py" --days 30 --top 40 --min-duration 600

# Pipe top 5 URLs into /transcribe for content summaries
python3 "${CLAUDE_SKILL_DIR}/scripts/discover.py" --json --top 5 \
  | jq -r '.[].url'
# (then invoke /transcribe on each URL)
```

## Topic configuration

Edit `${CLAUDE_SKILL_DIR}/scripts/topics.json`. The file is a JSON object: `{"Topic Name": ["query 1", "query 2", ...]}`. Multiple queries per topic broaden coverage — they're all run, results deduped by video ID.

Default topics ship with 2–3 queries each across:
- **AI** — general AI news / Anthropic announcements / Claude releases
- **Frontier Models** — Claude Opus, GPT-5, benchmarks
- **IDEs** — Claude Code, Cursor, Codex CLI
- **Programming** — agentic coding, AI pair programming
- **Antipatterns** — AI coding mistakes, vibe coding pitfalls
- **Skills** — Claude Code skill tutorials, plugin marketplace
- **MCP Server** — model context protocol guides
- **GitHub Projects** — notable open-source AI tooling

Iterate the queries to taste — narrower queries give purer hits, broader queries give more breadth.

## How to use the output

The table has one row per video with: rank, topic, title, channel, duration, age, raw views, **views/day** (the ranking metric), URL.

When the user wants a content summary on one of the rows, **call `/transcribe <url>`** — the transcribe skill downloads the video, extracts frames + transcript, and lets you describe what's in it. Don't re-implement that pipeline here.

## Implementation notes

- Searches use `yt-dlp ytsearchN:query --dateafter now-Ndays` — relevance-ranked, then date-filtered. Per-query cost is ~1 second.
- Default depth: 8 topics × ~3 queries × 15 results = up to 360 candidates before dedupe; total runtime typically 30–90 seconds.
- Ranking: `views / max(1, age_in_days)`. Heavy-tail-friendly; a 100k-view video from 2 days ago beats a 500k-view video from 30 days ago. No engagement-rate signal (likes aren't in the search-page metadata).
- Dedupe: by YouTube video ID. If two queries surface the same video, the topic tag of the higher-scoring entry wins (no double counting).
- No API key — searches are scrape-based. Subject to YouTube's anti-scraping; if it ever throttles, the script just returns fewer rows.
