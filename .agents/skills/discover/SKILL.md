---
name: discover
description: Discovers the most interesting recent YouTube videos on AI, frontier models, coding IDEs, programming, AI antipatterns, Claude skills, MCP servers and notable GitHub projects, ranked by views per day in a markdown table. Use when the user asks what is worth watching, wants a digest of recent AI/coding videos, or looks for candidates to summarize with /transcribe. Trigger: «Was gibt es Neues auf YouTube?», «Video-Digest», «interessante Videos der Woche».
allowed-tools: Bash, Read
user-invocable: true
metadata:
  version: "0.3.4"
---

# /discover – curate recent interesting videos

Answers "what should I watch this week?" for AI/coding content: runs a fixed set of YouTube searches across topic buckets, keeps recent uploads, dedupes by video ID, ranks by views per day and prints a markdown table.

## Setup

Single dependency: `yt-dlp` (already installed if `/transcribe` is in use). No API key, no auth.

```bash
pip install --user --break-system-packages -U yt-dlp
```

## Run the script

Execute `scripts/discover.py` (do not read it unless debugging). `${CLAUDE_SKILL_DIR}` is this skill's directory; if unset, substitute the absolute path. On Windows use `python` instead of `python3`.

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/discover.py"
```

Default: every topic in `topics.json`, last 14 days, top 20 by views/day. Runtime typically 30–90 seconds.

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

Examples:

```bash
# Hot picks across two topics, last 3 days
python3 "${CLAUDE_SKILL_DIR}/scripts/discover.py" --topics "Frontier Models,Skills" --days 3

# Wider net: last month, top 40, no videos under 10 minutes
python3 "${CLAUDE_SKILL_DIR}/scripts/discover.py" --days 30 --top 40 --min-duration 600

# Top 5 URLs as candidates for /transcribe
python3 "${CLAUDE_SKILL_DIR}/scripts/discover.py" --json --top 5 | jq -r '.[].url'
```

## Topic configuration

`scripts/topics.json` is a JSON object `{"Topic Name": ["query 1", "query 2", ...]}`. All queries of a topic run; results are deduped by video ID. Default topics: AI, Frontier Models, IDEs, Programming, Antipatterns, Skills, MCP Server, GitHub Projects, with 2–3 queries each. Narrower queries give purer hits, broader queries give more breadth. Queries that name specific model versions or years go stale – refresh them when the user edits topics.

## Using the output

One row per video: rank, topic, title, channel, duration, age, views, **views/day** (the ranking metric), URL.

For a content summary of a row, call `/transcribe <url>` – do not re-implement that pipeline here.

## Behaviour worth knowing

- Searches use `yt-dlp ytsearchN:query --dateafter now-Ndays`: relevance-ranked, then date-filtered; about one second per query.
- Ranking is `views / max(1, age_in_days)`: a 100k-view video from 2 days ago beats a 500k-view video from 30 days ago. No engagement signal (likes are not in the search metadata).
- When two queries surface the same video, the topic tag of the higher-scoring entry wins.
- Scrape-based: if YouTube throttles, the script returns fewer rows instead of failing.
