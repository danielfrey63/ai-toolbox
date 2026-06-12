#!/usr/bin/env python3
"""Diarization worker - runs INSIDE the managed ML venv (setup.py --venv).

Never import this from the host process; launch it via setup.run_venv_worker.
Contract: argv[1] = audio path, $HF_TOKEN = Hugging Face token.
JSON turns [{start, end, speaker}] on stdout, progress on stderr.

The hardening below is battle-tested on Windows (2026-06):
- token=/use_auth_token= fallback across pyannote/hub version combos
- scoped torch.load weights_only=False for torch>=2.6 checkpoint loads
- GPU placement when CUDA is available (~24x faster than CPU)
- in-memory waveform via soundfile, bypassing fragile torchaudio decoders
- speaker count on auto: forcing num_speakers collapses onto the dominant
  voice on single-mic recordings; surplus clusters are merged later by
  Claude from transcript context
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

PYANNOTE_MODEL = "pyannote/speaker-diarization-3.1"


def log(msg: str) -> None:
    print(f"[watch] {msg}", file=sys.stderr, flush=True)


def main() -> int:
    audio_path = Path(sys.argv[1])
    hf_token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")
    if not hf_token:
        log("ERROR: HF_TOKEN not in environment")
        return 1

    import torch
    from pyannote.audio import Pipeline

    # torch>=2.6 flips torch.load to weights_only=True, which rejects the
    # pyannote 3.x checkpoints (official, trusted HF repos). Restore the
    # legacy behaviour only for the duration of the model load.
    _orig_torch_load = torch.load

    def _load_full(*args, **kwargs):
        kwargs["weights_only"] = False
        return _orig_torch_load(*args, **kwargs)

    log(f"loading {PYANNOTE_MODEL} (first run downloads ~1 GB)...")
    torch.load = _load_full
    try:
        try:
            pipeline = Pipeline.from_pretrained(PYANNOTE_MODEL, token=hf_token)
        except TypeError:
            pipeline = Pipeline.from_pretrained(PYANNOTE_MODEL, use_auth_token=hf_token)
    finally:
        torch.load = _orig_torch_load

    device = "cuda" if torch.cuda.is_available() else "cpu"
    pipeline.to(torch.device(device))

    # In-memory input bypasses pyannote's own (Windows-fragile) decoders.
    audio_input: object = str(audio_path)
    try:
        import soundfile as sf

        data, sample_rate = sf.read(str(audio_path), dtype="float32")
        waveform = torch.from_numpy(data)
        if waveform.ndim == 2:  # (time, channels) -> mono
            waveform = waveform.mean(dim=1)
        audio_input = {"waveform": waveform.unsqueeze(0), "sample_rate": sample_rate}
    except Exception as exc:  # noqa: BLE001 - any decode issue falls back
        log(f"soundfile preload unavailable ({exc}); pyannote decodes the file itself")

    log(f"running pyannote.audio on {audio_path.name} ({device})...")
    diarization = pipeline(audio_input)

    turns = [
        {
            "start": round(float(turn.start), 2),
            "end": round(float(turn.end), 2),
            "speaker": str(speaker),
        }
        for turn, _, speaker in diarization.itertracks(yield_label=True)
    ]
    log(f"diarization done: {len(turns)} turns, "
        f"{len({t['speaker'] for t in turns})} speaker cluster(s)")
    json.dump(turns, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
