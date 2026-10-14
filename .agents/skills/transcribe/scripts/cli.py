#!/usr/bin/env python3
"""Shared command-line conventions of the transcribe scripts.

Every script shows its full help for -h, --help and a call without
arguments. Two scripts give the bare call its own meaning and say so in
their help: setup.py runs the interactive installer, llm.py prints the
configured deployments. The help lists the exit codes and an example.

run_text() is the one way to capture a child process as text: UTF-8 with
replacement, independent of the console code page, so ffmpeg or yt-dlp
output never raises UnicodeDecodeError on a cp1252 console.
"""
from __future__ import annotations

import argparse
import subprocess
import sys


def run_text(cmd: list, **kwargs) -> subprocess.CompletedProcess:
    """subprocess.run with captured UTF-8 text output; extra keyword
    arguments (timeout, env, ...) pass through unchanged."""
    options = {"capture_output": True, "text": True, "encoding": "utf-8", "errors": "replace"}
    options.update(kwargs)
    return subprocess.run(cmd, **options)


def parser(doc: str | None, *, exit_codes: dict[int, str] | None = None, examples: list[str] | None = None,
           **kwargs) -> argparse.ArgumentParser:
    """ArgumentParser with the module docstring as description and exit codes
    plus examples as epilog, all kept verbatim."""
    epilog: list[str] = []
    if examples:
        epilog += ["examples:", *[f"  {e}" for e in examples], ""]
    if exit_codes:
        epilog += ["exit codes:", *[f"  {code:<3} {text}" for code, text in sorted(exit_codes.items())]]
    return argparse.ArgumentParser(description=doc, epilog="\n".join(epilog) or None,
                                   formatter_class=argparse.RawDescriptionHelpFormatter, **kwargs)


def _help_if_empty(ap: argparse.ArgumentParser, argv: list[str]) -> None:
    if not argv:
        ap.print_help()
        raise SystemExit(0)


def parse(ap: argparse.ArgumentParser, argv: list[str] | None = None) -> argparse.Namespace:
    argv = sys.argv[1:] if argv is None else argv
    _help_if_empty(ap, argv)
    return ap.parse_args(argv)


def help_guard(doc: str | None, usage: str, *, exit_codes: dict[int, str] | None = None,
               argv: list[str] | None = None) -> None:
    """For scripts that parse argv by hand (the venv workers): print usage and
    docstring for -h, --help or no arguments, then exit 0."""
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] not in ("-h", "--help"):
        return
    print(f"usage: {usage}\n\n{(doc or '').strip()}")
    if exit_codes:
        print("\nexit codes:")
        for code, text in sorted(exit_codes.items()):
            print(f"  {code:<3} {text}")
    raise SystemExit(0)


def parse_known(ap: argparse.ArgumentParser, argv: list[str] | None = None) -> tuple[argparse.Namespace, list[str]]:
    argv = sys.argv[1:] if argv is None else argv
    _help_if_empty(ap, argv)
    return ap.parse_known_args(argv)
