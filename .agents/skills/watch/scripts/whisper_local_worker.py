#!/usr/bin/env python3
"""Local Whisper worker - runs INSIDE the managed ML venv (setup.py --venv).

Never import this from the host process; launch it via setup.run_venv_worker.
Contract: argv[1] = audio path, optional argv[2] = language code (e.g. "de";
omit for auto-detect). JSON segments [{start, end, text}] on stdout,
progress on stderr.

faster-whisper rides on ctranslate2 (torch-free), so it coexists with the
pyannote stack in the same venv and uses the GPU when CUDA libs are present.
large-v3 on GPU transcribes ~8x realtime; the CPU fallback drops to the
medium model with int8 quantization to stay usable.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def log(msg: str) -> None:
    print(f"[watch] {msg}", file=sys.stderr, flush=True)


def main() -> int:
    audio_path = Path(sys.argv[1])
    language = sys.argv[2] if len(sys.argv) > 2 else None

    from faster_whisper import WhisperModel

    try:
        model = WhisperModel("large-v3", device="cuda", compute_type="float16")
        desc = "large-v3 / cuda float16"
    except Exception as exc:  # noqa: BLE001 - any CUDA failure -> CPU
        log(f"CUDA unavailable ({type(exc).__name__}) - CPU fallback (medium/int8)")
        threads = max(1, (os.cpu_count() or 4) - 2)
        model = WhisperModel("medium", device="cpu", compute_type="int8",
                             cpu_threads=threads)
        desc = f"medium / cpu int8 ({threads} threads)"

    log(f"transcribing {audio_path.name} with faster-whisper {desc} "
        f"(first run downloads the model)...")
    segments, info = model.transcribe(str(audio_path), language=language,
                                      vad_filter=True)
    out = [
        {
            "start": round(float(seg.start), 2),
            "end": round(float(seg.end), 2),
            "text": seg.text.strip(),
        }
        for seg in segments
    ]
    log(f"transcription done: {len(out)} segments, "
        f"language={info.language} ({info.language_probability:.0%})")
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
