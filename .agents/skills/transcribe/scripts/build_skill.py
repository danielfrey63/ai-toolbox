#!/usr/bin/env python3
"""Build the committed skill as a deterministic, portable upload archive."""
from __future__ import annotations

import argparse
import io
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def bundle(data: bytes) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(data)) as source, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as target:
        files = {i.filename: source.read(i) for i in source.infolist() if not i.is_dir()}
        version = json.loads(files[".claude-plugin/plugin.json"])["version"]
        files[".build-version"] = (version + "\n").encode()
        kept = {n: content for n, content in files.items()
                if not n.startswith(("hooks/", "commands/", ".claude-plugin/"))}
        required = {"SKILL.md", "INSTALL.md", "transcribe.py", "scripts/command.py", "scripts/config.py"}
        if not required <= kept.keys() or len(kept) > 200:
            raise ValueError("Archive entrypoints missing or upload file limit exceeded")
        if sum(Path(n).name == "SKILL.md" for n in kept) != 1:
            raise ValueError("Archive must contain exactly one SKILL.md")
        for name, content in sorted(kept.items()):
            if Path(name).is_absolute() or ".." in Path(name).parts:
                raise ValueError("Unsafe archive path")
            info = zipfile.ZipInfo("transcribe/" + name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            target.writestr(info, content)
    return out.getvalue()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", type=Path, default=ROOT / "dist/transcribe.skill")
    args = ap.parse_args()
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=ROOT)
    if git("status", "--porcelain", "--", ".").strip():
        ap.error("Skill has uncommitted files; commit them before building")
    prefix = git("rev-parse", "--show-prefix").decode().strip().rstrip("/")
    tree = "HEAD:" + prefix if prefix else "HEAD"
    data = bundle(git("archive", "--format=zip", tree))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.output.is_file() or args.output.read_bytes() != data:
        args.output.write_bytes(data)
    print(f"Built {args.output} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
