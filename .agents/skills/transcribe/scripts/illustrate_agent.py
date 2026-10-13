#!/usr/bin/env python3
"""Choose, crop and check the key illustrations with the LLM.

Scripted version of «Schlüssel-Illustrationen ausschneiden» in
references/report-writing.md. The deterministic work stays in illustrate.py;
this script only makes the three judgement calls the session used to make:

1. Selection (text model): from the frame descriptions (<base>.frames.json,
   written by report.py's frame pass) and the chapter list, pick the frames
   that carry a diagram, table, code or dialog the speakers discuss - every
   chapter covered or consciously skipped.
2. Bounding box (vision model): on the native-resolution frame, the box of
   the content area without browser bar, taskbar, meeting tiles; plus
   redaction boxes over lists of personal names.
3. Visual check (vision model): frame and crop side by side; a crop that
   misses its caption, shows chrome or an overlay gets a corrected box.
   At most --rounds rounds.

The spec <base>.illustrations.spec.json stays the single source of truth;
illustrate.py renders it. Idempotent: an existing spec is kept unless --force.

  python illustrate_agent.py "<base or any companion>" [--language de]
                             [--force] [--max 12] [--rounds 2]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import llm
from companions import (Paths, fmt_ts, language_rules, read_json, read_protocol, resolve_base, screen_context,
                        ts_seconds,
                        write_json)

HERE = Path(__file__).resolve().parent
SETTLE = 1.5  # cut frames are taken this long after the cut

SELECT_SYSTEM = """You choose the key illustrations for the written report of a recorded meeting or screen share.
An illustration is a frame whose content IS the subject: an architecture or data-flow diagram, a table with substance, code or configuration the speakers walk through, a dialog or mask that is the topic. Never talking heads, title cards, desktops, loading states, or a second near-identical shot of the same screen.
Cover the discussion: every chapter that is about something visible gets at least one illustration; say why when a chapter needs none.
Return ONLY a JSON object {"picks": [{"ts": "MM:SS", "caption": "<what the reader sees and why it matters, canonical names>", "type": "Architektur" | "Diagramm" | "Chart" | "Tabelle" | "Screenshot" | "Slide"}], "skipped_chapters": [{"chapter": "<title>", "why": "<reason>"}]}
Pick between 3 and MAX frames, chronological, ts exactly as listed."""

BBOX_SYSTEM = """You get native-resolution frames of a screen share. For EACH frame return the bounding box of the content area as normalized [x, y, w, h] in 0..1 of the full frame.
Content area = the page body, editor pane, dialog body or slide. Exclude: browser tab bar and address bar (top ~12-14 %), the OS taskbar (bottom ~5 %), meeting participant strip or camera tiles (right or bottom), window title bars, the meeting toolbar. A slightly generous box is fine; uniform margins are trimmed afterwards.
If the content shows a list of real person names, user IDs or e-mail addresses that is not the subject, add "redact": [[x, y, w, h], ...] in the same frame coordinates.
Each frame comes with a DRAFT caption written from a low-resolution thumbnail. Read the native frame and return "caption": the draft corrected so that every name, label, object and application it mentions is spelled exactly as on screen (application names from window titles or logos, not guessed). Name a web application by the host the screen context lists for that time (omada.sbb.ch is Omada, flow.sbb.ch is Jira, confluence.sbb.ch is Confluence), never by a generic «portal». Keep the draft's intent and length.
Return ONLY a JSON object {"boxes": [{"ts": "<as given>", "bbox": [x, y, w, h], "redact": [], "caption": "<corrected caption>"}]}."""

QS_SYSTEM = """You check a cropped illustration against its source frame and caption.
Image 1 is the full frame, image 2 is the crop. Defects: the crop does not show what the caption claims; browser bar, taskbar, meeting tiles or window chrome inside the crop; a transient overlay (tooltip, error dialog, loading spinner) covering the content; content cut off mid-element although it is fully visible in the frame; unredacted lists of person names that are not the subject.
Return ONLY a JSON object {"ok": true|false, "defect": "<short, empty when ok>", "bbox": [x, y, w, h] (corrected box in normalized FULL-FRAME coordinates, only when not ok), "redact": [[x, y, w, h], ...] (only when names must be hidden), "caption": "<corrected caption, only when the crop is right but the caption misnames what it shows>"}.
A caption that names things not visible in the crop is fixed via "caption", not via "bbox"."""


def _run(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(HERE / "illustrate.py"), *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


def video_path(proto: dict, p: Paths) -> Path | None:
    src = proto.get("Source", "")
    cand = [Path(src)] if src else []
    cand += [p.base.with_name(p.base.name + ext) for ext in (".mp4", ".mkv", ".mov", ".webm")]
    return next((c for c in cand if c.is_file()), None)


def select(frames: list[dict], chapters: list[dict], max_n: int, language: str | None,
           context: list[str]) -> dict:
    listing = "\n".join(
        f"- {f.get('ts')} [{f.get('kind', '')}] {f.get('screen', '')}: {f.get('content', '')}"
        + (f" | candidate: {f.get('why')}" if f.get("illustration") else "") for f in frames)
    chap = "\n".join(f"- [{c['start']} – {c['end']}] {c['title']}" for c in chapters) or "- none known"
    prompt = (f"{language_rules(language)} Captions in that language.\nMAX = {max_n}\n\n"
              f"## Chapters\n{chap}\n\n## Screen context (host read off the screen at that time)\n"
              + ("\n".join(context) or "- none") + f"\n\n## Frames\n{listing}\n")
    return llm.ask_json(prompt, system=SELECT_SYSTEM, role="text", max_tokens=3000, label="illustrate-select")


def extract(video: Path, stamps: list[float], out: Path) -> dict[float, Path]:
    r = _run(["--video", str(video), "--extract", *[f"{t:.1f}" for t in stamps], "--out-dir", str(out)])
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
    return {t: out / f"frame_t{int(t):05d}.png" for t in stamps if (out / f"frame_t{int(t):05d}.png").is_file()}


def boxes(frames: dict[float, Path], drafts: dict[float, str], language: str | None,
          context: list[str], redact: bool = False) -> dict[float, dict]:
    out: dict[float, dict] = {}
    items = sorted(frames.items())
    for i in range(0, len(items), 4):
        batch = items[i:i + 4]
        listing = "\n".join(f"{k + 1}. ts={fmt_ts(t)} | DRAFT caption: {drafts.get(t, '')}"
                            for k, (t, _) in enumerate(batch))
        obj = llm.ask_json(f"{language_rules(language)} Captions in that language.\n"
                           "Screen context (host read off the screen at that time):\n"
                           + ("\n".join(context) or "- none") +
                           ("" if redact else f"\n{REDACT_OFF}") +
                           f"\nFrames in this order:\n{listing}", system=BBOX_SYSTEM,
                           images=[p for _, p in batch], role="vision", max_tokens=2000,
                           label=f"illustrate-bbox {i + 1}")
        got = obj.get("boxes", []) or []
        by_ts = {b.get("ts"): b for b in got}
        for k, (t, _) in enumerate(batch):
            # match by the ts we passed; fall back to position in the reply
            b = by_ts.get(fmt_ts(t)) or (got[k] if k < len(got) else None)
            if b and isinstance(b.get("bbox"), list) and len(b["bbox"]) == 4:
                out[t] = b
    return out


def render(video: Path, p: Paths) -> list[dict]:
    r = _run(["--video", str(video), "--spec", str(p.spec), "--out-dir", str(p.illustrations)])
    if r.returncode != 0:
        print(r.stdout[-1500:], r.stderr[-1500:], file=sys.stderr)
    m = read_json(p.manifest) or {}
    return m.get("illustrations", []) if isinstance(m, dict) else []


REDACT_OFF = ("Redaction is OFF for this run: return no redact boxes and do not count visible person "
              "names as a defect.")


def redact_enabled(flag: bool | None) -> bool:
    """--redact / --no-redact win; else TRANSCRIBE_REDACT (1/true/yes/on); default off.
    Off by default because the agent stages run on an approved tenant model; switch it
    on when the crops are published to a wider audience than the recording itself."""
    if flag is not None:
        return flag
    from stt import _get_config
    return (_get_config("TRANSCRIBE_REDACT") or "").strip().lower() in ("1", "true", "yes", "on")


def qs(spec: list[dict], manifest: list[dict], frames: dict[float, Path], p: Paths, language: str | None,
       redact: bool = False) -> int:
    """Check every crop; patch spec entries in place. Returns number fixed."""
    by_id = {e["id"]: e for e in spec}
    fixed = 0
    for ill in manifest:
        e = by_id.get(ill.get("id"))
        crop = p.illustrations / ill.get("path", "")
        frame = frames.get(e["_t"]) if e else None
        if not e or not crop.is_file() or not frame:
            continue
        hint = f" The renderer flagged it as suspect: {ill['suspect']}." if ill.get("suspect") else ""
        try:
            v = llm.ask_json(f"{language_rules(language)} Defect and caption in that language.\n"
                             f"Caption: {e['caption']}.{hint}" + ("" if redact else f"\n{REDACT_OFF}"),
                             system=QS_SYSTEM, images=[frame, crop],
                             role="vision", max_tokens=1200, label=f"illustrate-qs {e['id']}")
        except (RuntimeError, ValueError) as exc:
            print(f"[illustrate-agent] QS {e['id']} failed: {exc}", file=sys.stderr)
            continue
        if v.get("ok"):
            continue
        if v.get("caption") and v["caption"] != e["caption"]:
            e["caption"] = v["caption"]
            fixed += 1
            print(f"[illustrate-agent] caption {e['id']}: {v.get('defect', '')}", file=sys.stderr)
        if isinstance(v.get("bbox"), list) and len(v["bbox"]) == 4:
            e["bbox"] = [round(float(x), 3) for x in v["bbox"]]
            if redact and v.get("redact"):
                e["redact"] = v["redact"]
            fixed += 1
            print(f"[illustrate-agent] fix {e['id']}: {v.get('defect', '')}", file=sys.stderr)
    return fixed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", help="<base> stem or any companion file of the recording")
    ap.add_argument("--language", default=None)
    ap.add_argument("--force", action="store_true", help="Replace an existing spec")
    ap.add_argument("--max", type=int, default=12, help="Maximum illustrations (default 12)")
    ap.add_argument("--rounds", type=int, default=2, help="Visual-check rounds (default 2)")
    ap.add_argument("--redact", dest="redact", action="store_true", default=None,
                    help="Black out lists of person names in the crops (default: TRANSCRIBE_REDACT, else off)")
    ap.add_argument("--no-redact", dest="redact", action="store_false", help="Force redaction off")
    args = ap.parse_args()

    p = Paths(resolve_base(args.base))
    if p.spec.is_file() and not args.force:
        print(f"[illustrate-agent] spec exists - skip (use --force): {p.spec}", file=sys.stderr)
        return 0
    ok, reason = llm.available()
    if not ok:
        print(f"[illustrate-agent] skipped: LLM not configured ({reason})", file=sys.stderr)
        return 3
    proto = read_protocol(p.protocol)
    video = video_path(proto, p)
    if not video:
        print("[illustrate-agent] no video next to the report - nothing to illustrate", file=sys.stderr)
        return 0
    fj = read_json(p.frames_json)
    if not (isinstance(fj, dict) and fj.get("frames")):
        import report  # the frame pass lives there
        frames_desc = report.frame_pass(p, proto, 48, args.language, False)
    else:
        frames_desc = fj["frames"]
    if not frames_desc:
        print("[illustrate-agent] no frame descriptions - nothing to choose from", file=sys.stderr)
        return 0
    analysis = read_json(p.analysis) or {}
    chapters = analysis.get("chapters", []) if isinstance(analysis, dict) else []

    context = screen_context(p.links)
    redact = redact_enabled(args.redact)
    print(f"[illustrate-agent] redaction {'on' if redact else 'off'}", file=sys.stderr)
    sel = select(frames_desc, chapters, args.max, args.language, context)
    picks = [x for x in sel.get("picks", []) if x.get("ts")][: args.max]
    if not picks:
        print("[illustrate-agent] model picked no illustrations", file=sys.stderr)
        return 0
    kinds = {f.get("ts"): f.get("kind") for f in frames_desc}
    for x in picks:
        x["_t"] = ts_seconds(x["ts"]) + (SETTLE if kinds.get(x["ts"]) == "CUT" else 0.0)

    with tempfile.TemporaryDirectory(prefix="transcribe-ill-") as tmp:
        frames = extract(video, [x["_t"] for x in picks], Path(tmp))
        bx = boxes(frames, {x["_t"]: x["caption"] for x in picks}, args.language, context, redact)
        spec = []
        for i, x in enumerate(picks, 1):
            b = bx.get(x["_t"])
            if not b:
                continue
            entry = {"id": i, "timestamp": round(x["_t"], 1), "bbox": [round(float(v), 3) for v in b["bbox"]],
                     "caption": (b.get("caption") or x["caption"]).strip(), "type": x.get("type", "Screenshot"),
                     "_t": x["_t"]}
            if redact and b.get("redact"):
                entry["redact"] = b["redact"]
            spec.append(entry)

        def save():
            write_json(p.spec, [{k: v for k, v in e.items() if not k.startswith("_")} for e in spec])

        save()
        manifest = render(video, p)
        for rnd in range(1, args.rounds + 1):
            n = qs(spec, manifest, frames, p, args.language, redact)
            print(f"[illustrate-agent] QS round {rnd}: {n} fixed", file=sys.stderr)
            if not n:
                break
            save()
            manifest = render(video, p)
    for s in sel.get("skipped_chapters", []) or []:
        print(f"[illustrate-agent] no illustration for «{s.get('chapter')}»: {s.get('why')}", file=sys.stderr)
    print(f"[illustrate-agent] {len(manifest)} illustration(s) -> {p.illustrations}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
