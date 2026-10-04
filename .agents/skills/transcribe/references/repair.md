# Repair pass (decoder-collapse recovery)

Read this when the protocol lists `**Repaired passages:**`, when a transcript shows repetition loops or foreign script, or before touching a threshold in `scripts/repair.py`.

## Why it exists

Whisper decodes in 30-second windows and feeds each window's output into the next as a prompt (`condition_on_previous_text`). That keeps terminology coherent across windows, and it amplifies failures: a garbage window becomes the context of the next one, so the decoder can lock into a repetition loop (`Ja. Ja. Ja. Ja.`) or drift into another script. Example from a German meeting: `um eben für Krips-C жить классisch durch diese Markenелision zu sein`. Re-running the same model over only that audio window produced clean German – the accumulated context was the problem, not the audio.

## What `repair.py` does (default on, `--no-repair` disables)

After transcription and after a cache resume:

1. **Scan for collapse signatures** – foreign script in a Latin-script language, a token repeated ≥6× in a row, a sentence repeated ≥4×, the identical line in ≥3 consecutive segments, implausible text density. Density: >32 chars/s over a segment of ≥6 s, or <0.7 chars/s over one; a shorter segment counts as flooded only at ≥50 chars/s or with ≥80 chars (timestamp jitter on short VAD segments pushes ordinary fast speech over 32 chars/s). The upper and lower density bounds are gated separately: the lower bound needs a long window to mean anything, the upper one does not.
2. **Merge neighbouring hits into windows** and pad them by 12 s so the decoder gets run-up (4 s of lead-in is not enough).
3. **Re-transcribe each window** from its own audio with a fresh context and `--no-carryover`.
4. **Splice back only through two gates.** The *score gate* rejects a result that still trips the detectors. The *content gate* rejects one whose deduplicated character count fell below 60 % of the original, which catches "fixes" that silently drop real speech. Deduplication works at clause level, because a collapse often stutters inside one sentence. A rejected window keeps its original text.
5. **At most 2 internal passes**, because rewriting a window can expose a mild signature just past its edge. Spans already rewritten (tracked in `<base>.segments.json` under `repaired`) are never touched twice.

The protocol lists every detected passage under `**Repaired passages:**` with reason and whether the rewrite was applied; `<base>.segments.json` keeps the before/after text.

## How to treat repaired passages

The pass is not a truth oracle. It removes catastrophic collapses and often recovers content buried under a loop, but a rewritten window can carry its own misrecognitions. **Treat repaired passages as reviewed-but-not-verified**: in the Konsistenz-Check give their timestamps a second look and cross-check them against any platform transcript (Teams VTT, YouTube captions).

## Standalone use

```bash
# What would it touch? Changes nothing.
python3 "${CLAUDE_SKILL_DIR}/scripts/repair.py" --segments "<base>.segments.json" --language de --dry-run

# Repair in place, cutting audio straight from the source video
python3 "${CLAUDE_SKILL_DIR}/scripts/repair.py" --segments "<base>.segments.json" --video "<video>" --language de
```

The repaired `segments.json` is the input to rendering: afterwards re-run `run.py` (it resumes from the cache in about 1 s) to regenerate transcript and protocol.

## Regression suite

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/repair.py" --selftest
```

Runs the cases distilled from measured collapses – no audio, no venv, under a second. Run it after touching a threshold or a detector.

Rule for new detectors: degenerate *timing*, not repetition alone, tells a decoder loop from audio that really repeats. Benchmark on real recordings only; a synthetic looping fixture can itself trigger a collapse and then measures the failure mode instead of the pipeline.

<details>
<summary>Old patterns</summary>

- **Density blind spot.** A German recording collapsed with whisper no longer advancing its timestamps, emitting full sentences into one-second segments at 89–93 chars/s (the clean run of the same recording sat at 19). The upper density bound was gated behind the six-second minimum duration and missed it; the bounds are now gated separately.
- **Sentence-level deduplication in the content gate.** With sentence-level dedup, echoes inside one sentence counted as real text, so a correct repair looked like it had deleted half the speech and was rejected. Dedup is now clause-level.
- **Cross-transcript "same line anywhere" rule.** Tried and dropped: on genuinely repetitive audio it flagged every segment and demanded 282 s of rework against the 14 s the density rule needs for the same collapse.
- **Short-segment density threshold.** Applying 32 chars/s to 1–2 s segments flagged 48 false suspects on a 37-minute finance video (about 19 min of needless CPU re-transcription); short segments now need ≥50 chars/s or ≥80 chars.

</details>
