#!/usr/bin/env python3
"""Runtime check - runs INSIDE a managed venv right after provisioning.

Never import this from the host process; setup.py launches it with the venv's
interpreter. argv[1] names the runtime: `whisper` or `speakers`. Exit 0 means
the installed packages work together on a real (synthetic) recording; any
exception exits non-zero with the traceback on stderr.

Existence checks cannot catch an incompatible combination of releases:
PyAV 19 installed fine next to faster-whisper 1.2.1, yet every transcription
then died in av.open(). So this check takes the same code paths as the
workers - file decode, model load, VAD and decoding - on one second of audio.

The whisper check loads the `tiny` model (about 75 MB, cached by Hugging Face
after the first run). The speakers check stops short of the gated pyannote
model, which needs a token: it imports the stack and decodes the audio the
way pyannote_worker.py does.
"""
from __future__ import annotations

import math
import struct
import sys
import tempfile
import wave
from pathlib import Path

SAMPLE_RATE = 16000


def log(msg: str) -> None:
    print(f"[runtime-check] {msg}", file=sys.stderr, flush=True)


def write_tone(path: Path, seconds: float = 1.0) -> None:
    """One second of a 440 Hz tone as 16 kHz mono PCM - stdlib only."""
    frames = b"".join(
        struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / SAMPLE_RATE)))
        for i in range(int(SAMPLE_RATE * seconds))
    )
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(frames)


def check_whisper(audio: Path) -> None:
    from faster_whisper import WhisperModel, decode_audio

    samples = decode_audio(str(audio), sampling_rate=SAMPLE_RATE)
    if len(samples) < SAMPLE_RATE // 2:
        raise RuntimeError(f"decode_audio returned {len(samples)} samples")
    model = WhisperModel("tiny", device="cpu", compute_type="int8", cpu_threads=1)
    # Same keyword set as whisper_local_worker.py, once with VAD (onnxruntime)
    # and once without, so the decoder itself runs on the tone.
    for vad in (True, False):
        segments, _ = model.transcribe(str(audio), language="en", vad_filter=vad,
                                       hotwords="Feldenkrais",
                                       condition_on_previous_text=True)
        list(segments)


def check_speakers(audio: Path) -> None:
    import soundfile as sf
    import torch
    from pyannote.audio import Pipeline  # noqa: F401 - import is the check

    data, rate = sf.read(str(audio), dtype="float32", always_2d=True)
    waveform = torch.from_numpy(data.T)
    if rate != SAMPLE_RATE or waveform.shape[-1] != SAMPLE_RATE:
        raise RuntimeError(f"soundfile decoded {tuple(waveform.shape)} at {rate} Hz")


CHECKS = {"whisper": check_whisper, "speakers": check_speakers}


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in CHECKS:
        print(f"usage: runtime_check.py {{{','.join(CHECKS)}}}", file=sys.stderr)
        return 2
    name = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix="transcribe-check-") as tmp:
        audio = Path(tmp) / "tone.wav"
        write_tone(audio)
        CHECKS[name](audio)
    log(f"{name} runtime ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
