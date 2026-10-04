# Codex as auditor (`auditor=codex`)

Read this file only when the user passes `auditor=codex`. Cross-model setup: Codex finds, Claude fixes, and loop rounds resume the same Codex session so the reviewer remembers its earlier findings.

## Prerequisites (verify once, fast)

- `codex --version` ≥ 0.130 and a prior `codex login` (or a provider in `~/.codex/config.toml`). Surface an auth/model error, never retry silently.
- Do not pin `-m`. Read the active `model` line from `~/.codex/config.toml` and echo it with the resolved arguments so the user can veto before a round costs anything.
- Enforce read-only per call, never trust it from config: `codex exec -s read-only` on the first round, `codex exec resume <thread> -c sandbox_mode="read-only"` on every later round (`resume` rejects `-s`; a `config.toml` with `sandbox_mode = "danger-full-access"` + `approval_policy = "never"` would otherwise let the auditor write mid-loop).
- On Windows there is no OS sandbox behind `-s read-only`; it is Codex's own policy. Therefore snapshot `git status --porcelain` before every Codex call and compare after it – any difference means the auditor wrote, and the round is failed (revert its diff, tell the user). Prefer running in a worktree.
- Every Codex call runs under a 10-minute ceiling (`timeout: 600000` on the Bash tool; `timeout 600` in a plain shell). A tripped ceiling is a failed round, not a retry.

## First round

Write the Codex preamble plus the filled audit prompt (both in [audit-prompt.md](audit-prompt.md)) to a temp file with the Write tool – never inline-quote it, the prompt contains backticks and quotes. Then launch Codex from the repo root with stdin fed from that file (this also gives the immediate EOF `codex exec` needs under a non-TTY driver):

```bash
P=<temp prompt file>; OUT=$(mktemp)
git status --porcelain > "$P.before"
codex exec -s read-only --json -o "$OUT" - <"$P" 2>/dev/null | grep '"type":"thread.started"'
git status --porcelain | diff -q "$P.before" - || echo "AUDITOR WROTE – failed round"
```

Parse `thread_id` from the `thread.started` line and keep it as `THREAD_ID` for the loop. The punch list is Codex's last message in `$OUT`; read that file, not the JSONL stream. No `thread.started` line and no `$OUT` content = failed run (auth/model): stop and tell the user.

## Rounds 2..N

Resume the SAME session so the reviewer checks the fixes instead of re-litigating, with the same `git status --porcelain` guard around it:

```bash
codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --json -o "$OUT" - <"$P2"
```

`$P2` holds the short re-audit prompt from [audit-prompt.md](audit-prompt.md). Do not resend the whole audit prompt – the session has it.

## Arbitration

Claude arbitrates every Codex finding: accept (fix it) or reject with a logged reason in the round's commit body. Accepting everything defeats the cross-model check; ignoring findings defeats the point.
