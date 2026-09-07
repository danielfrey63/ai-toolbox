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

Hotwords compete for the same 448-token prompt budget as the context
carryover: faster-whisper clamps EACH to max_length//2 - 1 = 223 tokens,
so a long glossary plus a full carryover leaves no decoding room and
ctranslate2 raises "The maximum decoding length must be > 0". We cap the
string at HOTWORDS_CHAR_BUDGET and, as a last resort, retry the whole
transcription without hotwords rather than lose the run.

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
import time
import sys
from pathlib import Path


# Mirrors stt.HOTWORDS_CHAR_BUDGET - the worker is also called directly
# (repair.py, manual runs), so it enforces the same cap independently.
HOTWORDS_CHAR_BUDGET = 300


def log(msg: str) -> None:
    print(f"[transcribe] {msg}", file=sys.stderr, flush=True)


def clamp_hotwords(hotwords: str | None) -> str | None:
    """Trim the glossary to whole terms within the char budget."""
    if not hotwords or len(hotwords) <= HOTWORDS_CHAR_BUDGET:
        return hotwords
    kept: list[str] = []
    used = 0
    for term in (t.strip() for t in hotwords.split(",")):
        if not term:
            continue
        if used + len(term) + 2 > HOTWORDS_CHAR_BUDGET:
            break
        kept.append(term)
        used += len(term) + 2
    dropped = len(hotwords.split(",")) - len(kept)
    log(f"hotwords over budget - keeping the first {len(kept)} terms, "
        f"dropping {dropped} (put the most-misheard terms first)")
    return ", ".join(kept)


def _env_float(name: str, default: float, lo: float, hi: float) -> float:
    """Read a clamped float from the environment; bad input keeps the default."""
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return max(lo, min(hi, float(raw)))
    except ValueError:
        return default


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

    # Both knobs default to the *fastest* setting, which is also the coolest
    # one - measured, against the intuition that a lighter compute type must
    # run cooler. On an RTX A4000 Laptop over 4.2 min of speech:
    #
    #   float16       86 s, 51% util, 61 W -> ~5200 Ws, 72 C peak
    #   int8_float16 125 s, 40% util, 49 W -> ~6100 Ws, 72 C peak
    #
    # int8_float16 lowers instantaneous draw but runs 45% longer, so it emits
    # *more* total heat for an identical peak temperature: the laptop's
    # cooling regulates to the same setpoint either way and simply spins the
    # fan longer. The way to make a laptop run cooler is to finish sooner.
    # Both are overridable for the case where a quieter fan for longer is
    # actually what you want (see TRANSCRIBE_GPU_DUTY too); a compute type the
    # GPU rejects falls back to float16 rather than losing the run.
    model_name = os.environ.get("TRANSCRIBE_WHISPER_MODEL") or "large-v3"
    compute = os.environ.get("TRANSCRIBE_GPU_COMPUTE") or "float16"
    try:
        try:
            model = WhisperModel(model_name, device="cuda", compute_type=compute)
        except (ValueError, RuntimeError) as exc:
            log(f"compute_type={compute} rejected ({type(exc).__name__}) - float16")
            compute = "float16"
            model = WhisperModel(model_name, device="cuda", compute_type=compute)
        desc = f"{model_name} / cuda {compute}"
    except Exception as exc:  # noqa: BLE001 - any CUDA failure -> CPU
        log(f"CUDA unavailable ({type(exc).__name__}) - CPU fallback (medium/int8)")
        # Runs in the managed venv as a separate process, so it re-resolves
        # the budget from the environment run.py exported (see cpu.py) rather
        # than importing it - keeps this worker free of host-side imports.
        budget = os.environ.get("TRANSCRIBE_CPU_BUDGET")
        try:
            threads = max(1, int(budget)) if budget else max(1, (os.cpu_count() or 4) - 2)
        except ValueError:
            threads = max(1, (os.cpu_count() or 4) - 2)
        model = WhisperModel("medium", device="cpu", compute_type="int8",
                             cpu_threads=threads)
        desc = f"medium / cpu int8 ({threads} threads)"

    hotwords = clamp_hotwords(hotwords)
    n_hotwords = len(hotwords.split(",")) if hotwords else 0
    log(f"transcribing {audio_path.name} with faster-whisper {desc}"
        f"{'' if carryover else ' (no context carryover)'}"
        f"{f' ({n_hotwords} hotwords)' if n_hotwords else ''} "
        f"(first run downloads the model)...")

    def run(hw: str | None) -> list[dict]:
        segments, info = model.transcribe(str(audio_path), language=language,
                                          vad_filter=True, hotwords=hw,
                                          condition_on_previous_text=carryover)
        # Generation is lazy - the prompt-budget error surfaces here, not
        # at the transcribe() call, so the list must be built inside.
        #
        # Duty cycling: decoding is a generator, so idling between segments
        # idles the GPU itself. Unlike a cheaper compute_type - which only
        # trades watts for runtime and ends up producing *more* total heat -
        # this actually lowers the sustained temperature, at a runtime cost
        # that is proportional and predictable. 1.0 = no pauses.
        duty = _env_float("TRANSCRIBE_GPU_DUTY", 1.0, lo=0.1, hi=1.0)
        result = []
        # The decode happens inside the `for` statement (the generator is
        # lazy), not in the body - so the interval to measure is the one
        # *ending* at each yield, not the body's own runtime.
        mark = time.monotonic()
        for seg in segments:
            decode = time.monotonic() - mark
            result.append({
                "start": round(float(seg.start), 2),
                "end": round(float(seg.end), 2),
                "text": seg.text.strip(),
            })
            if duty < 1.0:
                # Sleep so that `duty` is the share of wall-clock spent decoding.
                time.sleep(decode * (1.0 / duty - 1.0))
            mark = time.monotonic()
        log(f"transcription done: {len(result)} segments, "
            f"language={info.language} ({info.language_probability:.0%})")
        return result

    try:
        out = run(hotwords)
    except ValueError as exc:
        if not hotwords:
            raise
        # Prompt budget blown despite the clamp - a transcript without
        # glossary biasing beats no transcript at all.
        log(f"hotword biasing failed ({exc}) - retrying without glossary")
        out = run(None)
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
