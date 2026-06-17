#!/usr/bin/env python3
"""Crop decisive illustrations out of key video frames at native resolution.

This runs *after* Claude has watched the 512px analysis frames and decided
which ones carry an essential diagram / chart / architecture slide. The
deterministic work — re-extracting those moments at full resolution, cropping
to the region Claude marked, trimming the surrounding chrome, and dropping
duplicate slides — lives here so the model only does the genuinely analytical
part (which frame, which region, what caption).

Pipeline per spec entry:
  1. One-pass ffmpeg crop at NATIVE resolution (`crop=in_w*w:in_h*h:...`),
     written as lossless PNG (diagrams/text survive better than JPEG).
  2. Optional margin refinement via Pillow (`uv run --with pillow`): snap the
     crop to its real content edges so it sits on the diagram frame, not a
     slab of slide background. Degrades silently to the raw crop when neither
     an in-process Pillow nor `uv` is available.
  3. Dedup via the existing dHash machinery (`frames._dhash_from_file`): a
     slide shown across several cuts collapses to one crop.
  4. Write `manifest.json` (surviving crops with caption/timestamp/type) for
     Claude to embed into the report and surface via SendUserFile.

Spec JSON (list):
  [ { "id": 1, "timestamp": 734.0, "bbox": [0.08, 0.12, 0.84, 0.76],
      "caption": "Zielarchitektur DfA-GIS", "type": "Architektur" }, ... ]

`bbox` is [x, y, w, h] normalized to 0..1 (resolution-independent, so the
model's rough box works regardless of the source frame size). Omit `bbox`
to keep the whole frame.

Idempotent: the spec is the desired state. Re-running with the same spec
clears prior `ill_*.png` and reproduces identical output.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

from frames import _dhash_from_file, _hash_sidecar_path
from setup import find_tool


def _slug(text: str, max_len: int = 32) -> str:
    """Lowercase ASCII slug for filenames; '' when nothing usable remains."""
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return s[:max_len].strip("-")


def _clamp01(v: float) -> float:
    return max(0.0, min(1.0, float(v)))


def _normalize_bbox(bbox: "list | None") -> tuple[float, float, float, float]:
    """Return a sane (x, y, w, h) in 0..1; default to the full frame."""
    if not bbox or len(bbox) != 4:
        return 0.0, 0.0, 1.0, 1.0
    x, y, w, h = (_clamp01(v) for v in bbox)
    # Keep the crop inside the frame; never let w/h collapse to nothing.
    w = max(0.02, min(w, 1.0 - x))
    h = max(0.02, min(h, 1.0 - y))
    return x, y, w, h


def _crop_one(ffmpeg: str, video: str, t: float, bbox, out_path: Path) -> bool:
    """Single ffmpeg fast-seek + native-resolution crop to PNG. True on success."""
    x, y, w, h = _normalize_bbox(bbox)
    # crop=W:H:X:Y with in_w/in_h expressions -> crop happens at native size,
    # no scaling, so on-screen text stays crisp.
    crop = f"crop=in_w*{w:.5f}:in_h*{h:.5f}:in_w*{x:.5f}:in_h*{y:.5f}"
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-ss", f"{max(0.0, t - 0.05):.3f}",
        "-i", video,
        "-frames:v", "1",
        "-vf", crop,
        str(out_path),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not out_path.exists():
        sys.stderr.write(
            f"[illustrate] WARNING: crop failed at t={t:.1f}s: "
            f"{r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'ffmpeg error'}\n"
        )
        return False
    return True


# --- Refinement (Pillow, isolated) ------------------------------------------

def _refine_worker(paths: list[str], tol: int = 14, pad: int = 6) -> None:
    """Trim near-uniform margins from each PNG in place (runs under Pillow).

    Picks the background colour from the four corners, builds a tolerance mask
    of "pixels that differ from the background", erodes it to kill the speckle
    that H.264/JPEG compression sprays across flat backgrounds (without that
    step a noisy slide's bbox snaps back to the full frame), and crops to the
    mask's bounding box plus a small pad. Only applies the trim when it removes
    a meaningful border (>2% on a side) so a full-bleed diagram is left alone.
    """
    from PIL import Image, ImageChops, ImageFilter  # noqa: PLC0415 — only in worker

    for p in paths:
        try:
            im = Image.open(p).convert("RGB")
        except Exception:  # noqa: BLE001 — a single bad file shouldn't abort the batch
            continue
        w, h = im.size
        corners = [im.getpixel(c) for c in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))]
        # Dominant corner colour = the slide background.
        bg = max(set(corners), key=corners.count)
        diff = ImageChops.difference(im, Image.new("RGB", im.size, bg))
        mask = diff.convert("L").point(lambda v: 255 if v > tol else 0)
        # Erode: an isolated compression-noise pixel (255 amid 0s) drops to 0,
        # while a real ≥2px-wide edge survives. Fall back to the raw mask if
        # erosion wiped everything (thin-line content).
        box = mask.filter(ImageFilter.MinFilter(3)).getbbox() or mask.getbbox()
        if not box:
            continue
        l, u, r, b = box
        # Only trim if at least one side has a real margin to remove.
        if l < w * 0.02 and u < h * 0.02 and r > w * 0.98 and b > h * 0.98:
            continue
        l = max(0, l - pad)
        u = max(0, u - pad)
        r = min(w, r + pad)
        b = min(h, b + pad)
        if r - l < 8 or b - u < 8:
            continue  # degenerate; keep the original crop
        im.crop((l, u, r, b)).save(p)


def _refine(paths: list[Path]) -> str:
    """Refine crops in place. Returns a one-line status for the caller to log."""
    if not paths:
        return "no crops"
    strs = [str(p) for p in paths]
    try:
        import PIL  # noqa: F401, PLC0415
        _refine_worker(strs)
        return f"refined {len(strs)} (in-process Pillow)"
    except ImportError:
        pass
    uv = find_tool("uv") or shutil.which("uv")
    if not uv:
        return "skipped (no Pillow, no uv)"
    cmd = [uv, "run", "--no-project", "--with", "pillow",
           "python", __file__, "--refine-worker", *strs]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"[illustrate] refine worker failed: {r.stderr.strip()}\n")
        return "skipped (uv/Pillow error)"
    return f"refined {len(strs)} (uv --with pillow)"


# --- Dedup (reuses frames.py dHash) -----------------------------------------

def _gray_sidecar(ffmpeg: str, png: Path) -> Path | None:
    """Write a 9x8 grayscale raw sidecar for dHash. Returns its path or None."""
    side = _hash_sidecar_path(png)
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(png),
        "-vf", "scale=9:8,format=gray", "-frames:v", "1",
        "-f", "rawvideo", "-pix_fmt", "gray", str(side),
    ]
    if subprocess.run(cmd, capture_output=True).returncode == 0 and side.exists():
        return side
    return None


def _dedup(ffmpeg: str, items: list[dict], threshold: int) -> list[dict]:
    """Drop crops whose dHash is within `threshold` bits of an already-kept one.

    O(n²) against all kept hashes (illustration counts are tiny, and a slide
    can reappear far apart in time, so last-kept-only would miss it). Removes
    the dropped PNG from disk; cleans up all sidecars at the end.
    """
    for it in items:
        side = _gray_sidecar(ffmpeg, Path(it["_path"]))
        it["_hash"] = _dhash_from_file(side) if side else None

    kept: list[dict] = []
    dropped = 0
    for it in items:
        h = it["_hash"]
        if h is not None and any(
            k["_hash"] is not None and bin(k["_hash"] ^ h).count("1") < threshold
            for k in kept
        ):
            Path(it["_path"]).unlink(missing_ok=True)
            dropped += 1
            continue
        kept.append(it)

    for it in items:
        _hash_sidecar_path(Path(it["_path"])).unlink(missing_ok=True)
    if dropped:
        sys.stderr.write(
            f"[illustrate] dedup: kept {len(kept)} of {len(items)} crops "
            f"(dropped {dropped} near-duplicate slides, threshold {threshold})\n"
        )
    return kept


def _fmt_ts(t: float) -> str:
    m, s = divmod(int(t), 60)
    h, m = divmod(m, 60)
    return f"{h:d}:{m:02d}:{s:02d}" if h else f"{m:d}:{s:02d}"


def main() -> int:
    ap = argparse.ArgumentParser(description="Crop key illustrations out of video frames.")
    ap.add_argument("--refine-worker", nargs="+", metavar="PNG",
                    help="(internal) refine these PNGs in place under Pillow, then exit")
    ap.add_argument("--video", help="source video (local file or downloaded path)")
    ap.add_argument("--spec", help="path to the illustration spec JSON")
    ap.add_argument("--out-dir", help="directory for the cropped PNGs + manifest.json")
    ap.add_argument("--dedup-threshold", type=int, default=6,
                    help="min dHash Hamming distance to treat crops as distinct (default 6)")
    ap.add_argument("--no-refine", action="store_true", help="skip the Pillow margin trim")
    args = ap.parse_args()

    # Internal re-exec path: just refine and exit (runs inside `uv run --with pillow`).
    if args.refine_worker:
        _refine_worker(args.refine_worker)
        return 0

    if not (args.video and args.spec and args.out_dir):
        ap.error("--video, --spec and --out-dir are required")

    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        sys.stderr.write("[illustrate] ERROR: ffmpeg not found. Run setup.py --install-binaries.\n")
        return 2

    video = args.video
    if not Path(video).exists():
        sys.stderr.write(f"[illustrate] ERROR: video not found: {video}\n")
        return 2

    try:
        spec = json.loads(Path(args.spec).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"[illustrate] ERROR: cannot read spec {args.spec}: {exc}\n")
        return 2
    if not isinstance(spec, list) or not spec:
        sys.stderr.write("[illustrate] ERROR: spec must be a non-empty JSON list\n")
        return 2

    out_dir = Path(args.out_dir).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    # Idempotency: the spec is the desired state — wipe prior crops first.
    for old in out_dir.glob("ill_*.png"):
        old.unlink()

    items: list[dict] = []
    for i, entry in enumerate(spec, start=1):
        if not isinstance(entry, dict) or "timestamp" not in entry:
            sys.stderr.write(f"[illustrate] WARNING: skipping malformed spec entry #{i}\n")
            continue
        eid = int(entry.get("id", i))
        t = float(entry["timestamp"])
        caption = str(entry.get("caption", "")).strip()
        etype = str(entry.get("type", "")).strip()
        slug = _slug(caption or etype)
        name = f"ill_{eid:02d}_t{int(t):05d}" + (f"_{slug}" if slug else "") + ".png"
        path = out_dir / name
        if _crop_one(ffmpeg, video, t, entry.get("bbox"), path):
            items.append({
                "id": eid, "timestamp": round(t, 2), "timestamp_label": _fmt_ts(t),
                "caption": caption, "type": etype, "_path": str(path),
            })

    if not items:
        sys.stderr.write("[illustrate] ERROR: no crops were produced\n")
        return 1

    if not args.no_refine:
        sys.stderr.write(f"[illustrate] {_refine([Path(it['_path']) for it in items])}\n")

    items = _dedup(ffmpeg, items, args.dedup_threshold)

    manifest = {
        "video": str(Path(video).resolve()),
        "illustrations": [
            {
                "id": it["id"],
                "timestamp": it["timestamp"],
                "timestamp_label": it["timestamp_label"],
                "caption": it["caption"],
                "type": it["type"],
                "path": Path(it["_path"]).name,
            }
            for it in items
        ],
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")

    # stdout = the manifest path + a human-readable list, so the caller (Claude)
    # knows exactly what to embed and where.
    print(f"[illustrate] wrote {len(items)} illustration(s) -> {out_dir}")
    print(f"[illustrate] manifest: {manifest_path}")
    for it in manifest["illustrations"]:
        print(f"  - [{it['timestamp_label']}] {it['path']}  ({it['type']}) {it['caption']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
