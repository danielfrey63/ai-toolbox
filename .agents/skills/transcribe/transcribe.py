#!/usr/bin/env python3
"""Portable CLI entrypoint, valid in the toolbox, split repository and skill bundle."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from command import main

if __name__ == "__main__":
    raise SystemExit(main())
