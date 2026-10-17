#!/usr/bin/env python3
"""Maintain requirements/*.lock - the exact package sets the installer syncs.

  python scripts/lock.py             re-resolve after editing a .in file; keeps
                                     the locked versions wherever they still fit
  python scripts/lock.py --upgrade   move every package to its newest release
                                     allowed by the .in files and constraints
  python scripts/lock.py --verify    build the committed locks on this machine
                                     and run the runtime check, change nothing

A candidate lock replaces the committed one only after it has been installed
into a throwaway venv and scripts/runtime_check.py passed there. A failing
candidate leaves the committed lock untouched, prints which versions moved and
exits 1: the fix is an entry in requirements/constraints.txt with the reason.

Locks are universal (`uv pip compile --universal`): one file serves Linux,
macOS and Windows. The runtime check here proves the current platform only;
the lock-refresh workflow repeats --verify on the others before publishing.
CUDA builds of torch are not part of the check (setup.TORCH_PINS_GPU).

Exit codes: 0 locks current or updated, 1 resolve/install/check failed,
2 invalid usage.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import setup

ROOT = Path(__file__).resolve().parent.parent
CONSTRAINTS = setup.REQUIREMENTS_DIR / "constraints.txt"
COMPILE_COMMAND = "python scripts/lock.py"


def log(msg: str) -> None:
    print(f"[lock] {msg}", file=sys.stderr, flush=True)


def versions(lock_text: str) -> dict[str, str]:
    """{package: version} of a lock, markers ignored."""
    found = {}
    for line in lock_text.splitlines():
        m = re.match(r"([A-Za-z0-9_.\-]+)==([^\s;]+)", line)
        if m:
            found[m.group(1).lower()] = m.group(2)
    return found


def describe_changes(old: str, new: str) -> list[str]:
    before, after = versions(old), versions(new)
    lines = []
    for name in sorted(before.keys() | after.keys()):
        if before.get(name) != after.get(name):
            lines.append(f"{name}: {before.get(name, '-')} -> {after.get(name, '-')}")
    return lines


def compile_lock(uv: str, runtime: str, out: Path, upgrade: bool) -> bool:
    """Resolve requirements/<runtime>.in into `out`. An existing `out` acts as
    the preference set, so without --upgrade locked versions stay put."""
    cmd = [uv, "pip", "compile", f"requirements/{runtime}.in",
           "--constraint", "requirements/constraints.txt",
           "--universal", "--python-version", setup.UV_PYTHON_VERSION,
           "--custom-compile-command", COMPILE_COMMAND,
           "--quiet", "--output-file", str(out)]
    if upgrade:
        cmd.append("--upgrade")
    return subprocess.run(cmd, cwd=ROOT).returncode == 0


def check_lock(uv: str, runtime: str, lock: Path) -> str | None:
    """Install `lock` into a throwaway venv and run the runtime check there."""
    with tempfile.TemporaryDirectory(prefix=f"transcribe-lock-{runtime}-") as tmp:
        root = Path(tmp) / "venv"
        error = setup.install_runtime(uv, root, lock, gpu=False, recreate=True)
        return error or setup.run_runtime_check(setup.venv_python(root=root), runtime)


def refresh(uv: str, runtime: str, upgrade: bool) -> bool:
    committed = setup.lock_file(runtime)
    old = committed.read_text(encoding="utf-8") if committed.is_file() else ""
    with tempfile.TemporaryDirectory(prefix=f"transcribe-lock-{runtime}-") as tmp:
        candidate = Path(tmp) / committed.name
        if old:
            shutil.copyfile(committed, candidate)
        if not compile_lock(uv, runtime, candidate, upgrade):
            log(f"{runtime}: resolving failed")
            return False
        new = candidate.read_text(encoding="utf-8")
        if new == old:
            log(f"{runtime}: {committed.name} is current")
            return True
        changes = describe_changes(old, new)
        for line in changes:
            log(f"{runtime}: {line}")
        error = check_lock(uv, runtime, candidate)
        if error:
            log(f"{runtime}: candidate rejected, {committed.name} unchanged - {error}")
            return False
        committed.write_text(new, encoding="utf-8")
        log(f"{runtime}: {committed.name} updated ({len(changes)} version changes)")
        return True


def verify(uv: str, runtime: str) -> bool:
    error = check_lock(uv, runtime, setup.lock_file(runtime))
    if error:
        log(f"{runtime}: {setup.lock_file(runtime).name} fails on this platform - {error}")
        return False
    log(f"{runtime}: {setup.lock_file(runtime).name} passes on this platform")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--upgrade", action="store_true", help="Move to the newest compatible releases")
    mode.add_argument("--verify", action="store_true", help="Check the committed locks on this platform")
    ap.add_argument("--runtime", choices=setup.RUNTIMES, action="append",
                    help="Limit to one runtime (repeatable; default all)")
    args = ap.parse_args()
    uv = setup.ensure_uv()
    ok = True
    for runtime in args.runtime or setup.RUNTIMES:
        ok = (verify(uv, runtime) if args.verify else refresh(uv, runtime, args.upgrade)) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
