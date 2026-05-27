---
name: idempotent-devops
description: Methodology + scaffolding for idempotent, verify-then-mutate DevOps scripts. Use when the user wants to create a new setup/deploy/maintenance script, make an existing script idempotent, audit a script for non-idempotent patterns, or run a setup/cleanup script through the verify-install-cleanup loop. Brings a distilled `idempotent.sh` library (desired_state, desired_absent, parse_action, run_cmd, confirm_destructive) plus templates and audit/loop runners. Works for any project — Linux server, container deployment, local dev-env, CI maintenance.
metadata:
  version: "0.2.5"
---

# Idempotent DevOps Skill

Use this skill whenever you write or touch a script that **changes system state** — install, configure, deploy, cleanup, migrate, maintain. The skill encodes one rule and ships the lib that makes following it cheap.

**The rule:** every state change goes through *check → mutate-if-needed → re-verify*. Never mutate blindly. Never assume the previous run finished. Always be safe to re-run.

## When to invoke

Trigger phrases (German + English):

- "make this script idempotent" / "mach das Skript idempotent"
- "create a setup/deploy/install script for X"
- "audit this setup script" / "ist das Skript wirklich idempotent?"
- "run the verify-install-cleanup loop" / "Kampagne durchziehen"
- "scaffold a new DevOps module"
- "this script keeps failing on re-run"

Also auto-invoke when the user is writing a Bash script that calls `apt install`, `systemctl`, `mkdir`, `useradd`, `ufw allow`, `iptables`, `docker run`, similar mutators — and ask whether they want the desired-state pattern applied.

## What ships with the skill

```
idempotent-devops/
├── SKILL.md                   ← this file
├── lib/
│   └── idempotent.sh          ← the runtime library (sourced by generated scripts)
└── templates/
    ├── setup-MODULE.sh.tmpl   ← single-module setup script
    ├── config.json.tmpl       ← optional declarative parameters
    └── README.md.tmpl         ← module README skeleton
```

The skill resolves these paths relative to its own location — find them via the SKILL.md you are currently reading.

## The Three Rules (encode these in every generated script)

1. **Desired-state, not imperative steps.** Don't write `mkdir /foo`. Write `desired_state "/foo exists" "test -d /foo" "mkdir -p /foo"`. The check phrases the goal; the mutation only runs if the check fails.
2. **Verify after mutate.** Every mutation is followed by re-running the check. If the verification fails, the script reports failure with a log pointer — it does not silently move on.
3. **Sub-commands as first-class citizens.** Every setup script supports at minimum: `help`, `verify`, `install`, `cleanup`. `purge` is added when cleanup keeps any artifacts (users, data dirs) that a full reset must also remove.

## Three Modes

### Mode 1 — Scaffold (new script)

When the user asks for a new DevOps script:

1. **Clarify scope** with one focused question (don't ask three): single-shell-script or multi-module project? Target = local machine, remote SSH host, or both? If unclear, ask once. If the script is small (under ~5 desired_state calls expected), default to single-shell-script.

2. **Copy the lib** into the target project. Default location: `<project>/lib/idempotent.sh` for multi-module, or `./idempotent.sh` next to the setup script for single-module. The lib is self-contained — `cp` from `<skill-dir>/lib/idempotent.sh` to the target. Don't symlink (breaks on remote hosts / CI).

3. **Render the template** `templates/setup-MODULE.sh.tmpl` with the module name substituted. The template already wires `source idempotent.sh`, defines the sub-command dispatch, and shows two `desired_state` examples with comments.

4. **Generate a minimal config.json** (from `templates/config.json.tmpl`) only if the user mentioned declarative parameters. Skip for trivial scripts.

5. **Make the script executable** (`chmod +x`) and run `bash -n` for a syntax check before reporting done.

6. **Smoke-test the dispatch:** run `bash setup-<name>.sh help` and `bash setup-<name>.sh verify` to confirm the scaffold parses and at least the verify path runs end-to-end. Report what verify said.

### Mode 2 — Audit (existing script)

When the user points at an existing setup/deploy/maintenance script:

1. **Read the script** (full file). Scan for:
   - **Blind mutators** — `apt install`, `systemctl start`, `mkdir`, `useradd`, `ln -s`, `cp`, `chmod`, `chown`, `ufw allow`, `iptables`, `docker run`, `git clone`, `curl ... | bash`, redirects to system paths — appearing *without* a preceding existence/state check.
   - **Missing sub-commands** — no `help` block, no `verify`, no `cleanup`. Cleanup is the canary: if there's no cleanup, the author hasn't thought about reversal.
   - **Non-idempotent patterns** — `>> /etc/hosts` (appends duplicate lines on re-run), `mkdir` without `-p`, `ln -s` without `-f`, `tee -a`, `useradd` without `id <user> &>/dev/null || useradd`.
   - **Hidden coupling** — relative paths assumed to be CWD, hardcoded ports, unquoted variables that break on whitespace.
   - **Silent failures** — `command || true` without a reason, missing `set -e` / `set -u`, log redirects to `/dev/null`.

2. **Group findings** by severity:
   - **Breaks on re-run** (blind mutations, missing existence checks) — highest priority.
   - **No reversal path** (no cleanup sub-command, no `desired_absent` calls).
   - **Brittle** (silent failures, hidden coupling).
   - **Style** (no logging conventions, no header, no help text).

3. **For each finding, propose the fix** as a concrete diff snippet using the idempotent.sh primitives. Show before/after, not just "wrap in desired_state".

4. **Offer to apply** (don't apply automatically — audits are advisory unless the user OKs). If the user agrees, refactor in-place: add `source idempotent.sh` if missing, replace mutators with `desired_state` calls, add the missing sub-commands.

5. **Validate** by running `bash -n` + the verify-loop (Mode 3) on the refactored script.

### Mode 3 — Verify Loop (campaign runner)

When the user wants to prove a setup script is idempotent (the "test campaign"):

1. Run the script through this sequence, stopping at the first failure:

   ```
   verify           (snapshot initial state)
   install
   verify           (must report all desired states present)
   install          (second run -- must report 0 changes / "already correct")
   verify           (no drift)
   cleanup
   verify           (must report desired states absent)
   cleanup          (second run -- must report 0 changes / "already absent")
   verify           (no drift)
   install          (restore)
   verify           (back to installed state)
   ```

2. If `purge` exists, run additionally:

   ```
   cleanup
   purge            (with FORCE=1 if interactive prompts block automation)
   verify           (everything absent)
   purge            (second run -- idempotent)
   install          (restore from scratch)
   verify
   ```

3. **Pass condition:** every step exits 0, the second `install` and second `cleanup` produce zero `[CHANGING]` lines (only `[CHECKING] ... already correct` / `already absent`).

4. **Fail condition:** any step exits non-zero OR a second-run shows `[CHANGING]` lines. Report which step failed, copy the relevant lines from the log, suggest a fix (usually: a `desired_state` check that is too narrow or has a side effect).

5. **Fix-then-retry rule:** when the loop fails, fix the root cause in the script, then run the *entire* loop again from step 1. Do not patch and continue mid-loop — a re-run might fail at an earlier step.

## Key Rules (for the generated scripts AND for the skill itself)

- **No blind mutation.** If you find yourself typing `mkdir`, `useradd`, `apt install` outside a `desired_state` body, stop and wrap it.
- **Cleanup is mandatory.** Every install path has a cleanup path. If reversal is irreversible (e.g. dropping a production DB), that's `purge` — gated by `confirm_destructive`.
- **No silent failures.** `command || true` needs a comment explaining why the failure is OK.
- **Log to a file, not stdout.** `desired_state` already redirects mutation output to `$LOG_FILE`. Don't print mutation noise to the human — only `[INFO]` / `[OK]` / `[WARNING]` / `[ERROR]` lines.
- **Refactor in the same turn.** Audits that produce a punch list without applying fixes are dead weight. Apply the fixes, run the verify loop, commit.
- **The lib is single-file, copy-paste.** Don't add dependencies. If `jq` is needed, document it as optional and fall back gracefully.
- **Version-pin via header.** The lib's `APP_VERSION` is in its header. When updating the lib in a downstream project, diff first — breaking changes in the primitives must be migration-noted.

## Lib API Quick Reference

| Function | Purpose |
|---|---|
| `parse_action <arg>` | Normalize sub-command to `help`/`verify`/`install`/`cleanup`/`purge`. |
| `desired_state "<desc>" "<check>" "<change>"` | Check → mutate-if-needed → re-verify. Core primitive. |
| `desired_absent "<desc>" "<absent-check>" "<remove>"` | Inverse, for cleanup paths. |
| `info / ok / warn / fail <msg>` | Log to stderr with consistent prefix + color. |
| `confirm_destructive "<msg>"` | Interactive yes/no gate. Set `FORCE=1` to bypass. |
| `run_cmd "<cmd>"` | Local execution when `SSH_TARGET` empty, else `ssh ...`. Honors `SSH_PORT` + `SSH_IDENTITY`. |
| `run_scp <args...>` | Thin scp wrapper that injects `-P` + `-i`. |
| `show_header "<title>"` | Banner with local-vs-remote target line. |

All log output goes to **stderr** so that `ACTION=$(parse_action "$1")` and similar substitutions capture only the intended value.
