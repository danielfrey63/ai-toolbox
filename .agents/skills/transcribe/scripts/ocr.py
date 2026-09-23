#!/usr/bin/env python3
"""Read on-screen references off video frames: URLs, wiki page IDs, ticket
keys, hostnames and share paths that a presenter shows but never dictates.

Presenters walk through a Confluence page with the address bar visible, keep
a Jira key in a tab title, open a SQL client on a named connection - none of
that reaches the audio, so the transcript-based `## Resources` misses it.
This stage closes that gap deterministically (script before LLM): OCR the
frames where the screen changed, regex the references out, and persist them
as `<base>.links.md` with the `[MM:SS]` of the frame they were read from as
the evidence.

Pipeline:
  1. Candidate selection - every scene-cut frame (navigation happens at
     cuts) plus each regular frame whose 256-bit dHash differs from the
     last candidate. The 512px analysis JPEGs are enough to *detect* change;
     they are far too small to *read* (a URL is ~4px high at 512px wide).
  2. Native-resolution re-extraction of just those moments (ffmpeg).
  3. OCR with RapidOCR (PaddleOCR models on ONNX Runtime): scene-text
     detector + recognizer, so nothing needs to know where the address bar
     is. A whole 1080p frame reads in a few seconds on CPU. Tesseract was
     tried first and only worked on a hand-cropped, 4x-upscaled URL line -
     useless without layout knowledge.
  4. Reference extraction + normalisation (tracking params and session
     GUIDs stripped, page IDs lifted out of wiki URLs, OCR slips like
     `https//` repaired) and de-duplication across frames.

The ML side runs in an isolated `uv run --with rapidocr-onnxruntime`
environment - the managed whisper/pyannote venv is pinned tightly and
opencv/onnxruntime have no business in it. Same pattern as the Pillow
refinement in illustrate.py. Without uv the stage is skipped with a hint;
it never sinks the run.

Idempotent: the raw OCR result is cached as `<base>.ocr.json` next to the
recording and reused on re-runs (`--fresh` recomputes), so the derived
`links.md` can be re-rendered for free and later stages (speaker evidence
from name plates, for instance) can read the same text.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qsl, unquote_plus, urlencode, urlparse, urlunparse

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

OCR_PACKAGE = "rapidocr-onnxruntime"
DEFAULT_MIN_SCORE = 0.85
DEFAULT_MAX_FRAMES = 60
# 17x16 sidecar -> 256-bit hash, like illustrate.py: two different wiki
# pages are near-identical under the coarse 9x8 analysis hash.
_HASH_W, _HASH_H = 17, 16
_HASH_BITS = (_HASH_W - 1) * _HASH_H
# Bits that must differ before a regular frame counts as "screen changed".
DHASH_CHANGE_BITS = 24

GUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
# OCR drops the colon or one slash now and then - accept and repair.
URL_RE = re.compile(r"\bhttps?:?/{1,2}[^\s<>\"'()\[\]{}|]+", re.I)
# Bare hosts (DB connection names, sites shown without scheme). Underscores
# are not DNS but are common in Oracle TNS names (dfagis_bc_prod.sbb.ch).
HOST_RE = re.compile(
    r"\b(?:[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\.){1,}"
    r"(?:ch|com|net|org|io|de|at|fr|it|eu|cloud|dev|local|corp)\b"
    r"(?:/[^\s<>\"'()\[\]{}|]*)?",
    re.I,
)
TICKET_RE = re.compile(r"\b([A-Z][A-Z0-9]{1,9})-(\d{1,6})\b")
# Things that look like ticket keys and are not: encodings and standards,
# org-unit codes cut off by the participant tile («IT-I-CEN4» -> «IT-1»),
# and PI labels («PI2026-06» is a program increment, not an issue).
TICKET_STOP = {
    "UTF", "ISO", "SHA", "MD", "RFC", "IPV", "TLS", "SSL", "HTTP", "GPT",
    "COVID", "IEEE", "IEC", "DIN", "EN", "SN", "TCP", "UDP", "IP", "ID", "NR",
    "NO", "CH", "DE", "US", "PC", "CU", "WIN", "IT", "X", "A", "B", "C", "T", "S", "V", "E",
}
TICKET_KEY_YEAR_RE = re.compile(r"\d{4}$")
# A bare host (no path) needs a subdomain to count: `dfagis_bc_prod.sbb.ch`
# is a connection name worth listing, `sbb.ch` or a dotted word pair from
# running text («deutsch.fr») is not.
BARE_HOST_MIN_LABELS = 3
UNC_RE = re.compile(r"\\\\[\w.-]+(?:\\[^\s\\<>\"'|?*]+)+")
PAGE_ID_RE = re.compile(r"(?:/pages/|pageId=)(\d{5,})")
TRAILING_PUNCT = '.,;:!?)]}>"\''

REF_ORDER = ["url", "page", "ticket", "host", "path"]
REF_LABELS = {
    "url": "URLs",
    "page": "Wiki page IDs",
    "ticket": "Ticket keys",
    "host": "Hosts",
    "path": "Share paths",
}


def fmt_ts(seconds: float) -> str:
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


# --- Worker (isolated env: Pillow + RapidOCR) -------------------------------

def _dhash(img) -> int:
    small = img.convert("L").resize((_HASH_W, _HASH_H))
    px = list(small.getdata())
    h = 0
    bit = 0
    for row in range(_HASH_H):
        base = row * _HASH_W
        for col in range(_HASH_W - 1):
            if px[base + col] > px[base + col + 1]:
                h |= 1 << bit
            bit += 1
    return h


def _hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def select_candidates(frames: list[dict], max_frames: int) -> list[dict]:
    """Cuts always qualify; a regular frame qualifies when its dHash moved
    far enough from the last candidate. Over the cap, cuts win and the
    regulars are thinned evenly (chronology preserved)."""
    from PIL import Image  # noqa: PLC0415 - worker env only

    chosen: list[dict] = []
    last_hash: int | None = None
    for f in sorted(frames, key=lambda x: x["t"]):
        try:
            with Image.open(f["jpg"]) as im:
                h = _dhash(im)
        except Exception:  # noqa: BLE001 - unreadable frame: keep to be safe
            h = None
        changed = last_hash is None or h is None or _hamming(h, last_hash) >= DHASH_CHANGE_BITS
        if f.get("kind") == "cut" or changed:
            chosen.append(f)
            if h is not None:
                last_hash = h
    if len(chosen) <= max_frames:
        return chosen
    cuts = [f for f in chosen if f.get("kind") == "cut"]
    regs = [f for f in chosen if f.get("kind") != "cut"]
    room = max(0, max_frames - len(cuts))
    if room == 0:
        cuts = _thin(cuts, max_frames)
        regs = []
    else:
        regs = _thin(regs, room)
    return sorted(cuts + regs, key=lambda x: x["t"])


def _thin(items: list[dict], n: int) -> list[dict]:
    if n <= 0 or not items:
        return []
    if len(items) <= n:
        return items
    step = len(items) / n
    return [items[int(i * step)] for i in range(n)]


def _extract_native(ffmpeg: str, video: str, seek: float, out: Path, threads: int) -> bool:
    if out.exists():
        return True
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-threads", str(threads),
        "-ss", f"{max(0.0, seek):.3f}", "-i", video,
        "-frames:v", "1", str(out),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0 and out.exists()


def worker(args) -> int:
    spec = json.loads(Path(args.frames).read_text(encoding="utf-8"))
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    candidates = select_candidates(spec["frames"], args.max_frames)
    sys.stderr.write(
        f"[ocr] {len(candidates)} candidate frames out of {len(spec['frames'])} "
        f"(cuts + dHash changes >= {DHASH_CHANGE_BITS} bits)\n"
    )
    from rapidocr_onnxruntime import RapidOCR  # noqa: PLC0415 - worker env only
    accel = getattr(args, "accel", "cpu")
    flags = {f"{m}_use_{accel}": True for m in ("det", "cls", "rec")} if accel in ("dml", "cuda") else {}
    engine = RapidOCR(**flags)
    sys.stderr.write(f"[ocr] engine ready ({accel})\n")
    result_frames: list[dict] = []
    for i, f in enumerate(candidates, 1):
        png = out_dir / f"ocr_t{int(f['t']):05d}.png"
        if not _extract_native(spec["ffmpeg"], spec["video"], f.get("seek", f["t"]), png, spec.get("threads", 2)):
            sys.stderr.write(f"[ocr] WARNING: native frame failed at t={f['t']:.1f}s\n")
            continue
        try:
            boxes, _elapsed = engine(str(png))
        except Exception as exc:  # noqa: BLE001 - one bad frame must not sink the stage
            sys.stderr.write(f"[ocr] WARNING: OCR failed at t={f['t']:.1f}s ({exc})\n")
            continue
        lines = [
            {"text": str(txt).strip(), "score": round(float(sc), 3)}
            for _box, txt, sc in (boxes or [])
            if str(txt).strip()
        ]
        result_frames.append({
            "t": round(float(f["t"]), 2), "kind": f.get("kind", "regular"),
            "png": str(png), "lines": lines,
        })
        if i % 10 == 0 or i == len(candidates):
            sys.stderr.write(f"[ocr] {i}/{len(candidates)} frames read\n")
    Path(args.result).write_text(
        json.dumps({"frames": result_frames}, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    return 0


# --- Host side --------------------------------------------------------------

ACCEL_EXTRAS = {"dml": "onnxruntime-directml", "cuda": "onnxruntime-gpu"}


def pick_accel() -> str:
    """Which ONNX Runtime provider to try first. `TRANSCRIBE_OCR_ACCEL` pins
    it (cpu | dml | cuda); `auto` (default) takes DirectML on Windows, where
    it needs no driver setup and read a 1080p frame in 1.5 s against 5.9 s
    on CPU, and stays on CPU elsewhere - CUDA needs matching cuDNN
    libraries and is opt-in until it has been seen working."""
    want = (os.environ.get("TRANSCRIBE_OCR_ACCEL") or "auto").strip().lower()
    if want in ("cpu", "dml", "cuda"):
        return want
    return "dml" if sys.platform == "win32" else "cpu"


def run(video: str, frames: list[dict], work: Path, ffmpeg: str, threads: int,
        max_frames: int = DEFAULT_MAX_FRAMES, accel: str | None = None) -> dict | None:
    """Run the OCR worker in its isolated env. `frames` items: {t, seek, kind, jpg}.
    Returns the raw OCR dict or None when the stage could not run (no uv,
    worker error) - the caller logs and carries on. An accelerated attempt
    that fails falls back to CPU once."""
    from setup import find_uv  # noqa: PLC0415

    uv = find_uv()
    if not uv:
        sys.stderr.write("[ocr] skipped: uv not found (setup.py --install-binaries installs it)\n")
        return None
    out_dir = work / "ocr"
    out_dir.mkdir(parents=True, exist_ok=True)
    spec_path = out_dir / "frames.json"
    result_path = out_dir / "ocr.json"
    spec_path.write_text(json.dumps({
        "video": video, "ffmpeg": ffmpeg, "threads": threads, "frames": frames,
    }, ensure_ascii=False), encoding="utf-8")
    accel = accel or pick_accel()
    attempts = [accel, "cpu"] if accel != "cpu" else ["cpu"]
    for use in attempts:
        cmd = [uv, "run", "--no-project", "--with", OCR_PACKAGE, "--with", "pillow"]
        if use in ACCEL_EXTRAS:
            cmd += ["--with", ACCEL_EXTRAS[use]]
        cmd += [
            "python", str(Path(__file__).resolve()), "--worker",
            "--frames", str(spec_path), "--out-dir", str(out_dir),
            "--result", str(result_path), "--max-frames", str(max_frames), "--accel", use,
        ]
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        for line in (r.stderr or "").splitlines():
            if line.startswith("[ocr]"):
                sys.stderr.write(line + "\n")
        if r.returncode == 0 and result_path.exists():
            return json.loads(result_path.read_text(encoding="utf-8"))
        tail = "\n".join((r.stderr or "").strip().splitlines()[-5:])
        sys.stderr.write(f"[ocr] WARNING: worker failed on {use} (exit {r.returncode}):\n{tail}\n")
        if use != "cpu":
            sys.stderr.write("[ocr] retrying on cpu\n")
    return None


# --- Reference extraction ---------------------------------------------------

def _clean_url(raw: str) -> tuple[str, list[str]]:
    """Repair OCR slips, strip tracking + session state. Returns (url, notes)."""
    notes: list[str] = []
    u = raw.strip().rstrip(TRAILING_PUNCT)
    u = re.sub(r"^(https?):?/{1,2}", r"\1://", u, flags=re.I)
    parts = urlparse(u)
    host = parts.netloc.lower()
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)]
    if any(GUID_RE.search(v) or GUID_RE.search(k) for k, v in query):
        query = [(k, v) for k, v in query if not (GUID_RE.search(v) or GUID_RE.search(k))]
        notes.append("session GUID stripped from query")
    path = parts.path
    if GUID_RE.search(path):
        path = GUID_RE.sub("<guid>", path)
        notes.append("GUID in path is session state")
    from resources import normalize_url  # noqa: PLC0415
    rebuilt = urlunparse((parts.scheme.lower() or "https", host, path, "", urlencode(query), ""))
    return normalize_url(rebuilt), notes


def _page_title(url: str) -> str:
    """`/pages/<id>/Berechtigungen+der+Delphi-Anwendungen` -> readable title."""
    m = re.search(r"/pages/\d+/([^/?#]+)", url)
    return unquote_plus(m.group(1)) if m else ""


def extract_refs(ocr: dict, min_score: float = DEFAULT_MIN_SCORE) -> list[dict]:
    """Flatten the per-frame OCR lines into de-duplicated references.
    Each: {type, value, detail, first, seen, score, png, ok, notes}."""
    refs: dict[tuple[str, str], dict] = {}

    def add(kind: str, value: str, t: float, score: float, png: str, detail: str = "", notes=()):
        key = (kind, value.lower())
        item = refs.get(key)
        if item is None:
            item = refs[key] = {
                "type": kind, "value": value, "detail": detail, "first": t, "seen": [],
                "score": score, "png": png, "notes": list(notes),
            }
        if t not in item["seen"]:
            item["seen"].append(t)
        if score > item["score"]:
            item["score"], item["png"] = score, png
        if detail and not item["detail"]:
            item["detail"] = detail
        for n in notes:
            if n not in item["notes"]:
                item["notes"].append(n)

    for frame in ocr.get("frames", []):
        t, png = frame["t"], frame["png"]
        for line in frame.get("lines", []):
            text, score = line["text"], line["score"]
            covered: list[tuple[int, int]] = []
            for m in URL_RE.finditer(text):
                url, notes = _clean_url(m.group(0))
                covered.append(m.span())
                add("url", url, t, score, png, notes=notes)
                pid = PAGE_ID_RE.search(url)
                if pid:
                    add("page", pid.group(1), t, score, png, detail=_page_title(url) or urlparse(url).netloc)
            for m in HOST_RE.finditer(text):
                if any(a <= m.start() < b for a, b in covered):
                    continue
                raw = m.group(0).rstrip(TRAILING_PUNCT)
                if "/" in raw:
                    url, notes = _clean_url("https://" + raw)
                    add("url", url, t, score, png, notes=["scheme added"] + notes)
                    pid = PAGE_ID_RE.search(url)
                    if pid:
                        add("page", pid.group(1), t, score, png, detail=_page_title(url) or urlparse(url).netloc)
                elif raw.count(".") + 1 >= BARE_HOST_MIN_LABELS:
                    add("host", raw.lower(), t, score, png)
            for m in TICKET_RE.finditer(text):
                if m.group(1) in TICKET_STOP or TICKET_KEY_YEAR_RE.search(m.group(1)):
                    continue
                add("ticket", f"{m.group(1)}-{m.group(2)}", t, score, png)
            for m in UNC_RE.finditer(text):
                add("path", m.group(0).rstrip(TRAILING_PUNCT), t, score, png)

    out = list(refs.values())
    for r in out:
        r["seen"].sort()
        r["ok"] = r["score"] >= min_score
    _flag_ticket_extensions(out)
    _flag_host_lookalikes(out)
    out.sort(key=lambda r: (REF_ORDER.index(r["type"]), r["first"]))
    return out


def _flag_ticket_extensions(refs: list[dict]) -> None:
    """`DFABETRIEB-17668` next to `DFABETRIEB-1766` on the same frame is the
    `&` after the key read as `8`, not a second ticket. A key whose number
    extends a shorter key of the same project seen on a shared frame is
    demoted to (?) with the shorter one named."""
    tickets = [r for r in refs if r["type"] == "ticket"]
    for r in tickets:
        proj, num = r["value"].rsplit("-", 1)
        for o in tickets:
            if o is r:
                continue
            oproj, onum = o["value"].rsplit("-", 1)
            if oproj != proj or len(onum) >= len(num) or not num.startswith(onum):
                continue
            if set(r["seen"]) & set(o["seen"]):
                r["ok"] = False
                r["notes"].append(f"extends {o['value']} on the same frame - likely an OCR slip")
                break


def _levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if abs(len(a) - len(b)) > 1:
        return 2
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _host_of(r: dict) -> str:
    return urlparse(r["value"]).netloc.lower() if r["type"] == "url" else r["value"].lower()


def _flag_host_lookalikes(refs: list[dict]) -> None:
    """`flow.sb.ch` beside `flow.sbb.ch`: a host one edit away from a host
    seen more often is an OCR slip, not a second system. Applies to bare
    hosts and to the host part of URLs."""
    sightings: dict[str, int] = {}
    for r in refs:
        if r["type"] in ("url", "host"):
            sightings[_host_of(r)] = sightings.get(_host_of(r), 0) + len(r["seen"])
    for r in refs:
        if r["type"] not in ("url", "host"):
            continue
        h = _host_of(r)
        for other, n in sightings.items():
            if other != h and n > sightings[h] and _levenshtein(h, other) == 1:
                r["ok"] = False
                r["notes"].append(f"host one edit away from {other} - likely an OCR slip")
                break


def format_links(refs: list[dict], title: str, n_frames: int, min_score: float,
                 version: str = "unknown") -> str:
    """Render `<base>.links.md`. `(?)` marks rows under the score threshold -
    the frame path next to them is what a reviewer (or a vision model) opens."""
    lines = [
        f"# On-screen references: {title}",
        "",
        f"_Read off {n_frames} frame(s) by RapidOCR (scene cuts + visually changed frames, "
        f"re-extracted at native resolution). Score >= {min_score:.2f} counts as read "
        f"verbatim; lower scores are marked `(?)` - open the frame to confirm before citing. "
        f"Tracking parameters and session GUIDs are stripped. Frames live in the run's work "
        f"dir and vanish with it; the `[MM:SS]` is the durable evidence. "
        f"Generated by transcribe {version}; re-runs reuse `<base>.ocr.json`, `--fresh` recomputes._",
        "",
    ]
    if not refs:
        lines.append("_No references found on screen._")
        return "\n".join(lines)
    for kind in REF_ORDER:
        rows = [r for r in refs if r["type"] == kind]
        if not rows:
            continue
        lines.append(f"## {REF_LABELS[kind]}")
        lines.append("")
        lines.append("| Seen at | Reference | Score | Frame |")
        lines.append("|---|---|---|---|")
        for r in rows:
            when = f"[{fmt_ts(r['first'])}]"
            if len(r["seen"]) > 1:
                when += f" (+{len(r['seen']) - 1})"
            ref = r["value"]
            if kind == "url":
                ref = f"<{ref}>"
            elif kind in ("host", "path", "ticket"):
                ref = f"`{ref}`"
            if r.get("detail"):
                ref += f" - {r['detail']}"
            if r.get("notes"):
                ref += f" _({'; '.join(r['notes'])})_"
            mark = "" if r["ok"] else " (?)"
            lines.append(f"| {when} | {ref}{mark} | {r['score']:.2f} | `{Path(r['png']).name}` |")
        lines.append("")
    return "\n".join(lines).rstrip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--worker", action="store_true", help="internal: run inside the uv env")
    ap.add_argument("--frames", help="worker: JSON spec with video/ffmpeg/frames")
    ap.add_argument("--out-dir", help="worker: where native PNGs go")
    ap.add_argument("--result", help="worker: where to write ocr.json")
    ap.add_argument("--max-frames", type=int, default=DEFAULT_MAX_FRAMES)
    ap.add_argument("--accel", default="cpu", choices=["cpu", "dml", "cuda"],
                    help="worker: ONNX Runtime provider to use")
    ap.add_argument("--render", help="re-render links.md from an existing <base>.ocr.json")
    ap.add_argument("--min-score", type=float, default=DEFAULT_MIN_SCORE)
    args = ap.parse_args()
    if args.worker:
        return worker(args)
    if args.render:
        ocr = json.loads(Path(args.render).read_text(encoding="utf-8"))
        refs = extract_refs(ocr, args.min_score)
        print(format_links(refs, Path(args.render).name, len(ocr.get("frames", [])), args.min_score))
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
