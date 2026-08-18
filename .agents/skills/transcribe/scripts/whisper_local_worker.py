#!/usr/bin/env python3
"""Local Whisper worker - runs INSIDE the managed ML venv (setup.py --venv).

Never import this from the host process; launch it via setup.run_venv_worker.
Contract: argv[1] = audio path, optional argv[2] = language code (e.g. "de";
omit for auto-detect). JSON segments [{start, end, text}] on stdout,
progress on stderr.

Optional flag `--hotwords "term1, term2, ..."` biases decoding toward
domain vocabulary: faster-whisper injects the string into every window's
prompt, so rare proper nouns (product names, people) win over acoustically
similar everyday words. Unlike initial_prompt it applies to ALL windows,
not just the first.

Optional flag `--no-carryover` (anywhere in argv) disables Whisper's
condition_on_previous_text. Whisper normally feeds each 30s window's output
into the next one as a prompt, which keeps sentences and terminology
coherent across window boundaries. The failure mode is that a window which
produced garbage poisons the next one, so the model can lock into a
repetition loop or drift into the wrong language and never recover.
repair.py uses this when re-transcribing a collapsed passage.

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
    print(f"[transcribe] {msg}", file=sys.stderr, flush=True)


def main() -> int:
    argv = list(sys.argv[1:])
    carryover = "--no-carryover" not in argv
    if not carryover:
        argv.remove("--no-carryover")
    hotwords = None
    if "--hotwords" in argv:
        idx = argv.index("--hotwords")
        hotwords = argv[idx + 1]
        del argv[idx:idx + 2]
    audio_path = Path(argv[0])
    language = argv[1] if len(argv) > 1 else None

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

    n_hotwords = len(hotwords.split(",")) if hotwords else 0
    log(f"transcribing {audio_path.name} with faster-whisper {desc}"
        f"{'' if carryover else ' (no context carryover)'}"
        f"{f' ({n_hotwords} hotwords)' if n_hotwords else ''} "
        f"(first run downloads the model)...")
    segments, info = model.transcribe(str(audio_path), language=language,
                                      vad_filter=True,
                                      hotwords=hotwords,
                                      condition_on_previous_text=carryover)
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
