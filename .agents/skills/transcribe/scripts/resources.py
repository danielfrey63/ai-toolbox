#!/usr/bin/env python3
"""Extract URLs from video description and transcript, group by category.

Sources:
- Video description (yt-dlp's `info_dict["description"]`) — explicit links the
  uploader put under the video.
- Transcript segments — URLs that appear in the spoken/captioned text.

Output: a dict {category: [items]} suitable for rendering as a markdown
``## Resources`` section. Items are de-duplicated by normalized URL (lowercased
host, stripped tracking params, dropped fragment, normalized trailing slash).

Categorization is heuristic and intentionally narrow — false positives in
"project" hurt more than misses do, so when in doubt items go to "other".
"""
from __future__ import annotations

import re
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse


URL_RE = re.compile(r'https?://[^\s<>"\'\)\]\}]+', re.UNICODE)

TRAILING_PUNCT = '.,;:!?)]}>"\''

TRACKING_PARAMS = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "fbclid", "gclid", "mc_cid", "mc_eid", "igshid",
    "feature", "si", "ref", "ref_src", "ref_url",
    "_ga", "_gid", "yclid", "trk",
}

PROJECT_HOSTS = {"github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "sr.ht"}
PACKAGE_HOSTS = {
    "npmjs.com", "pypi.org", "crates.io", "rubygems.org",
    "pkg.go.dev", "packagist.org", "nuget.org",
}
MODEL_HOSTS = {"huggingface.co"}
VIDEO_HOSTS = {"youtube.com", "youtu.be", "vimeo.com", "twitch.tv"}
SOCIAL_HOSTS = {
    "twitter.com", "x.com", "linkedin.com", "mastodon.social",
    "bsky.app", "reddit.com", "t.me", "telegram.me", "discord.gg", "discord.com",
    "instagram.com", "facebook.com", "threads.net", "tiktok.com",
}
ARTICLE_HOSTS_SUFFIX = (".substack.com",)
ARTICLE_HOSTS = {"medium.com", "dev.to", "hashnode.dev", "blog.google", "stratechery.com"}
PAPER_HOSTS = {
    # Preprints / academic-search aggregators
    "arxiv.org", "openreview.net", "papers.ssrn.com", "scholar.google.com",
    "biorxiv.org", "medrxiv.org",
    # Medical journals
    "nejm.org", "thelancet.com", "bmj.com", "jamanetwork.com",
    # General-science journals + publishers
    "cell.com", "nature.com", "science.org", "sciencedirect.com",
    "pnas.org", "frontiersin.org", "mdpi.com",
    # NIH / PubMed
    "pmc.ncbi.nlm.nih.gov", "pubmed.ncbi.nlm.nih.gov", "ncbi.nlm.nih.gov",
    # Royal Society + IEEE + ACM
    "royalsocietypublishing.org", "ieeexplore.ieee.org", "dl.acm.org",
}
TECH_DOCS_HOSTS = {
    # Vendor reference docs that don't follow the `docs.*` subdomain convention
    "learn.microsoft.com", "msdn.microsoft.com",
    "developer.mozilla.org", "developer.apple.com", "developer.android.com",
    "developer.chrome.com",
    "kubernetes.io", "react.dev", "nextjs.org",
}
DATE_PATH_RE = re.compile(r"/\d{4}/\d{1,2}(?:/|$)")

CATEGORY_ORDER = ["project", "docs", "article", "video", "social", "other"]
CATEGORY_LABELS = {
    "project": "Projects",
    "docs": "Docs",
    "article": "Articles",
    "video": "Videos",
    "social": "Social",
    "other": "Other",
}


def extract_urls(text: str) -> list[str]:
    """Find URLs in a blob of text. Strips trailing punctuation that's almost
    never part of the URL (.,;:!? and closing brackets)."""
    if not text:
        return []
    out: list[str] = []
    for raw in URL_RE.findall(text):
        u = raw
        while u and u[-1] in TRAILING_PUNCT:
            u = u[:-1]
        if u:
            out.append(u)
    return out


def _strip_www(host: str) -> str:
    return host[4:] if host.startswith("www.") else host


def normalize_url(url: str) -> str:
    """Canonicalize for dedup: lowercase host (sans `www.`), drop tracking params,
    drop fragment, normalize trailing slash. Returns the input unchanged if it
    can't be parsed."""
    try:
        p = urlparse(url)
        if not p.scheme or not p.netloc:
            return url
    except ValueError:
        return url

    host = _strip_www(p.netloc.lower())

    query = ""
    if p.query:
        kept = [(k, v) for k, v in parse_qsl(p.query, keep_blank_values=True)
                if k.lower() not in TRACKING_PARAMS]
        query = urlencode(kept)

    path = p.path
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/")

    return urlunparse((p.scheme, host, path, "", query, ""))


def display_url(url: str) -> str:
    """Compact form for tables: drop protocol + `www.`, keep path/query."""
    try:
        p = urlparse(url)
    except ValueError:
        return url
    host = _strip_www(p.netloc.lower())
    s = host + (p.path or "")
    if p.query:
        s += "?" + p.query
    if s.endswith("/") and len(s) > 1:
        s = s.rstrip("/")
    return s


def categorize(url: str) -> str:
    try:
        p = urlparse(url)
    except ValueError:
        return "other"
    host = _strip_www(p.netloc.lower())
    path = p.path or ""
    parts = [x for x in path.strip("/").split("/") if x]

    if host in PROJECT_HOSTS:
        return "project" if len(parts) >= 2 else "other"
    if host in PACKAGE_HOSTS:
        return "project"
    if host in MODEL_HOSTS and len(parts) >= 2:
        return "project"

    if host in VIDEO_HOSTS:
        return "video"
    if host in SOCIAL_HOSTS:
        return "social"

    if (
        host.startswith("docs.")
        or host in TECH_DOCS_HOSTS
        or "/docs" in path
        or "/documentation" in path
    ):
        return "docs"
    if host.endswith(ARTICLE_HOSTS_SUFFIX) or host in ARTICLE_HOSTS:
        return "article"
    if host in PAPER_HOSTS:
        return "article"
    if host.startswith("blog.") or path.startswith("/blog") or "/blog/" in path:
        return "article"
    if DATE_PATH_RE.search(path):
        # /YYYY/... or /YYYY/MM/... or /YYYY/MM/DD/... is a strong "this is a
        # dated post" signal across news sites and personal blogs alike.
        return "article"

    return "other"


def _fmt_ts(seconds: float) -> str:
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


def collect(description: str, transcript_segments: list[dict]) -> dict[str, list[dict]]:
    """Returns ``{category: [items]}`` where items have keys
    ``url`` (normalized), ``display`` (short form), ``sources`` (list of
    "description" or "transcript@MM:SS")."""
    groups: dict[str, dict[str, dict]] = {}

    def add(url: str, source: str) -> None:
        norm = normalize_url(url)
        cat = categorize(norm)
        bucket = groups.setdefault(cat, {})
        item = bucket.get(norm)
        if item is None:
            item = {"url": norm, "display": display_url(norm), "sources": []}
            bucket[norm] = item
        if source not in item["sources"]:
            item["sources"].append(source)

    for u in extract_urls(description or ""):
        add(u, "description")

    for seg in transcript_segments or []:
        text = seg.get("text", "") or ""
        if "http" not in text:
            continue
        for u in extract_urls(text):
            add(u, f"transcript@{_fmt_ts(seg.get('start', 0) or 0)}")

    out: dict[str, list[dict]] = {}
    for cat in CATEGORY_ORDER:
        if cat in groups:
            out[cat] = sorted(groups[cat].values(), key=lambda r: r["display"])
    return out


def format_section(grouped: dict[str, list[dict]]) -> str:
    """Render the dict from `collect()` as a markdown ``## Resources`` block."""
    if not grouped:
        return ""
    total = sum(len(v) for v in grouped.values())
    lines = [
        "## Resources",
        "",
        f"_Aggregated from video description and transcript ({total} unique URLs)._",
        "",
    ]
    for cat in CATEGORY_ORDER:
        items = grouped.get(cat)
        if not items:
            continue
        lines.append(f"### {CATEGORY_LABELS[cat]}")
        lines.append("")
        for item in items:
            sources = item["sources"]
            shown = ", ".join(sources[:3])
            if len(sources) > 3:
                shown += f", +{len(sources) - 3} more"
            lines.append(f"- [{item['display']}]({item['url']}) - _{shown}_")
        lines.append("")
    return "\n".join(lines).rstrip()


if __name__ == "__main__":
    import json
    import sys

    if len(sys.argv) < 2:
        print(
            "usage: resources.py <info.json> [<vtt-or-transcript-json>]",
            file=sys.stderr,
        )
        raise SystemExit(2)

    info = json.loads(open(sys.argv[1]).read())
    description = info.get("description", "") or ""

    segments: list[dict] = []
    if len(sys.argv) >= 3:
        path = sys.argv[2]
        if path.endswith(".json"):
            segments = json.loads(open(path).read())
        else:
            from transcribe import parse_vtt
            segments = parse_vtt(path)

    grouped = collect(description, segments)
    print(format_section(grouped))
