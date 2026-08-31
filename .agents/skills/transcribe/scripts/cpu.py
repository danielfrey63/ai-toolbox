#!/usr/bin/env python3
"""Shared CPU budget for the pipeline's CPU-bound stages.

Every CPU-bound stage used to help itself to the whole machine. ffmpeg
defaults to `-threads 0`, which means "one thread per core", and the frame
stage ran up to 8 of those *in parallel* - on a 16-core box that is 8
processes each asking for 16 threads. The result is a stage that pins every
core at 100 %, followed by a near-idle stretch while the GPU stages (whisper,
pyannote) run, followed by the next CPU stage. That alternation is what shows
up as fans surging up and down several times per transcription.

This module is the single place that answers "how much CPU may we use?", so
the stages divide one budget instead of each grabbing everything:

    scdet pass          one ffmpeg  -> the whole budget
    frame extraction    N ffmpegs   -> budget split across the workers
    audio extraction    one ffmpeg  -> the whole budget
    whisper CPU fallback            -> the whole budget

Resolution order: explicit set_budget() (the --cpu-budget flag) >
TRANSCRIBE_CPU_BUDGET in the environment or ~/.config/transcribe/.env >
DEFAULT_SHARE of the machine's cores. set_budget() also exports the resolved
value into os.environ, so subprocesses that re-resolve it independently - the
whisper/pyannote workers, which run in the managed venv - inherit the same
budget without needing a flag threaded through.

Accepted spec forms: "50%" (share of cores), "6" (absolute threads), "all"
(no limit - the old behaviour).
"""
from __future__ import annotations

import os

ENV_VAR = "TRANSCRIBE_CPU_BUDGET"

# Leave a quarter of the machine idle by default. Enough headroom that the box
# stays responsive and the CPU stages stop hitting the thermal ceiling, while
# still using most of the silicon - transcription is slow enough already.
DEFAULT_SHARE = 0.75

_override: int | None = None


def cores() -> int:
    """Cores this process may actually run on.

    os.cpu_count() reports the machine's CPUs, not the ones we are allowed to
    use. On Linux a process can be restricted by CPU affinity (taskset, a
    systemd slice, a container's cpuset), and sched_getaffinity is the only
    call that reflects that - budgeting off cpu_count() there would hand out
    threads for cores the scheduler will never give us, which is precisely the
    oversubscription this module exists to prevent. Not available on Windows
    or macOS, where cpu_count() is the right answer anyway.
    """
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count() or 4


def parse_spec(spec: str) -> int | None:
    """Parse a budget spec into a thread count. None when unparseable."""
    spec = (spec or "").strip().lower()
    if not spec:
        return None
    if spec in ("all", "max", "0"):
        return cores()
    try:
        if spec.endswith("%"):
            share = float(spec[:-1]) / 100.0
            return max(1, min(cores(), round(cores() * share)))
        return max(1, min(cores(), int(spec)))
    except ValueError:
        return None


def _from_env() -> int | None:
    value = os.environ.get(ENV_VAR)
    if not value:
        # Same .env lookup the rest of the skill uses; imported lazily so this
        # module stays dependency-free for the venv workers.
        try:
            from diarize import _load_env_value
        except Exception:  # noqa: BLE001 - worker context without diarize.py
            return None
        value = _load_env_value(ENV_VAR)
    return parse_spec(value) if value else None


def budget() -> int:
    """Total threads the CPU-bound stages may use together."""
    if _override is not None:
        return _override
    from_env = _from_env()
    if from_env is not None:
        return from_env
    return max(1, round(cores() * DEFAULT_SHARE))


def set_budget(spec: str | None) -> int:
    """Pin the budget for this process *and* its children. Returns the value."""
    global _override
    if spec:
        parsed = parse_spec(spec)
        if parsed is not None:
            _override = parsed
    resolved = budget()
    # Children (venv workers) re-resolve from the environment.
    os.environ[ENV_VAR] = str(resolved)
    return resolved


def per_process(parallel: int) -> int:
    """Threads for each of `parallel` concurrent ffmpeg processes.

    Splitting rather than repeating the budget is the whole point: N workers
    each running with the full budget is exactly the oversubscription this
    module exists to prevent.
    """
    return max(1, budget() // max(1, parallel))


def ffmpeg_flags(parallel: int = 1) -> list[str]:
    """`-threads N` for an ffmpeg command line."""
    return ["-threads", str(per_process(parallel))]


# Threads each frame worker should get. Measured on a 16-core box extracting
# 24 frames from 1080p with a budget of 12: 8 workers x 1 thread took 13.8 s,
# 6 x 2 took 11.1 s, 4 x 3 took 11.3 s, 3 x 4 took 11.5 s (ungoverned
# reference: 9.7 s). Spreading the budget over as many workers as possible is
# therefore the worst way to spend it - a lone thread cannot overlap its own
# seek and decode, so the process spends most of its life waiting. Two is
# where the curve flattens.
MIN_THREADS_PER_WORKER = 2


def frame_workers() -> int:
    """Parallel ffmpeg processes for per-frame extraction.

    Derived from the budget so that each worker still gets
    MIN_THREADS_PER_WORKER, and capped at 8 - beyond that the instances
    contend for L3 and disk seeks and the wall-clock curve flattens anyway.
    """
    return max(1, min(8, budget() // MIN_THREADS_PER_WORKER))
