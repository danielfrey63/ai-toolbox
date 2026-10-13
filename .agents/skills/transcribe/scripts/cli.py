#!/usr/bin/env python3
"""Shared command-line conventions of the transcribe scripts.

Every script shows its full help for -h, --help and a call without
arguments. Two scripts give the bare call its own meaning and say so in
their help: setup.py runs the interactive installer, llm.py prints the
configured deployments. The help lists the exit codes and an example.
"""
from __future__ import annotations

import argparse
import sys


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


def parse_known(ap: argparse.ArgumentParser, argv: list[str] | None = None) -> tuple[argparse.Namespace, list[str]]:
    argv = sys.argv[1:] if argv is None else argv
    _help_if_empty(ap, argv)
    return ap.parse_known_args(argv)
