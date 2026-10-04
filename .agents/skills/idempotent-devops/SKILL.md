---
name: idempotent-devops
description: Scaffolds and audits idempotent, verify-then-mutate DevOps scripts (setup, deploy, install, maintenance, cleanup) with a bundled single-file Bash library (desired_state, desired_absent, parse_action, run_cmd, confirm_destructive) and templates for the setup script, README and config. Also guides a manual verify loop (verify/install/cleanup, each run twice) that proves a script is safe to re-run. Use when the user wants a new setup/deploy/install script, wants an existing script made idempotent or audited for non-idempotent patterns, reports that a script fails on re-run, or writes Bash that mutates system state (apt install, systemctl, useradd, mkdir, ufw, docker run). Trigger: «mach das Skript idempotent», «ist das Skript wirklich idempotent?», «Kampagne durchziehen».
metadata:
  version: "0.4.12"
---

# Idempotent DevOps

Use this skill whenever you write or touch a script that **changes system state** – install, configure, deploy, cleanup, migrate, maintain.

**The rule:** every state change goes through *check → mutate-if-needed → re-verify*. Never mutate blindly. Never assume the previous run finished. Always be safe to re-run.

## When to use

- "make this script idempotent" / «mach das Skript idempotent»
- "create a setup/deploy/install script for X" / "scaffold a new DevOps module"
- "audit this setup script" / «ist das Skript wirklich idempotent?»
- "run the verify loop" / «Kampagne durchziehen»
- "this script keeps failing on re-run"

When the user writes a Bash script that calls `apt install`, `systemctl`, `mkdir`, `useradd`, `ufw allow`, `iptables`, `docker run` or similar mutators, ask whether they want the desired-state pattern applied.

## Bundled files

```
idempotent-devops/
├── SKILL.md
├── lib/idempotent.sh            runtime library – copy into the target project, do not run
├── templates/
│   ├── setup-MODULE.sh.tmpl     single-module setup script – read and render
│   ├── config.json.tmpl         optional declarative parameters – read and render
│   └── README.md.tmpl           module README skeleton – read and render
└── references/
    ├── audit-checklist.md       patterns to scan for and how to fix them
    └── verify-loop.md           step sequence and pass/fail criteria of the verify loop
```

`evals/` holds test scenarios for maintaining the skill; it is not needed at runtime.

Resolve these paths relative to the directory of this SKILL.md. The skill ships no runner scripts: the verify loop is executed step by step with the target script's own sub-commands.

## The three rules (encode them in every generated script)

1. **Desired state, not imperative steps.** Write `desired_state "/foo exists" "test -d /foo" "mkdir -p /foo"`, never a bare `mkdir /foo`. The check phrases the goal; the mutation runs only if the check fails.
2. **Verify after mutate.** Every mutation is followed by re-running the check. A failed re-check reports failure with a log pointer – the script never silently moves on.
3. **Sub-commands as first-class citizens.** Every setup script supports at least `help`, `verify`, `install`, `cleanup`. Add `purge` when `cleanup` keeps artifacts (users, data dirs) that a full reset must also remove.

## Mode 1 – Scaffold a new script

1. **Clarify scope** with one focused question: single script or multi-module project? Target local machine, remote SSH host, or both? For small scripts (fewer than about five `desired_state` calls) default to a single script.
2. **Copy the lib** into the target project: `<project>/lib/idempotent.sh` for multi-module, or `idempotent.sh` next to the setup script for a single module. Copy, don't symlink (symlinks break on remote hosts and in CI).
3. **Render** `templates/setup-MODULE.sh.tmpl` with `{{MODULE}}` substituted. It already sources the lib, dispatches the sub-commands and shows two commented `desired_state` examples. Render `templates/README.md.tmpl` the same way.
4. **Render** `templates/config.json.tmpl` only if the user mentioned declarative parameters.
5. **Check:** `chmod +x`, then `bash -n` for a syntax check.
6. **Smoke-test:** run `bash setup-<name>.sh help` and `bash setup-<name>.sh verify` and report what `verify` said.

## Mode 2 – Audit an existing script

1. Read the full script and scan it with [references/audit-checklist.md](references/audit-checklist.md).
2. Group the findings by severity: breaks on re-run → no reversal path → brittle → style.
3. For each finding, propose a concrete before/after diff using the lib primitives.
4. Audits are advisory: apply the fixes only after the user agrees. Then refactor in place in the same turn (source the lib, wrap mutators in `desired_state`, add missing sub-commands) – a punch list without fixes is dead weight.
5. Validate with `bash -n` and the verify loop (Mode 3).

## Mode 3 – Verify loop

Prove a setup script is idempotent by running its sub-commands in the sequence from [references/verify-loop.md](references/verify-loop.md). **Pass:** every step exits 0, and the second `install` and second `cleanup` print no `[CHANGING]` line. On failure, fix the root cause and restart the whole loop from step 1 – never patch and continue mid-loop.

## Rules for generated scripts

- **No blind mutation.** `mkdir`, `useradd`, `apt install` outside a `desired_state` body get wrapped.
- **Cleanup is mandatory.** Every install path has a cleanup path. Irreversible removal (users, data, databases) belongs in `purge`, gated by `confirm_destructive`.
- **No silent failures.** `command || true` needs a comment explaining why the failure is acceptable.
- **Log to a file, not stdout.** `desired_state` redirects mutation output to `$LOG_FILE`; the human sees only `[INFO]` / `[OK]` / `[WARNING]` / `[ERROR]` lines.
- **Single file, no dependencies.** If `jq` is needed, document it as optional and fall back gracefully.
- **Pin via header.** The lib's `APP_VERSION` sits in its header. When updating the lib in a downstream project, diff first; breaking changes in the primitives need a migration note.

## Lib API

| Function | Purpose |
|---|---|
| `parse_action <arg>` | Normalize the sub-command to `help`/`verify`/`install`/`cleanup`/`purge`. |
| `desired_state "<desc>" "<check>" "<change>"` | Check → mutate-if-needed → re-verify. Core primitive. |
| `desired_absent "<desc>" "<absent-check>" "<remove>"` | Inverse, for cleanup paths. |
| `info` / `ok` / `warn` / `fail <msg>` | Log to stderr with consistent prefix and color. |
| `confirm_destructive "<msg>"` | Interactive yes/no gate. `FORCE=1` bypasses it. |
| `run_cmd "<cmd>"` | Runs locally when `SSH_TARGET` is empty, else via `ssh`. Honors `SSH_PORT` and `SSH_IDENTITY`. |
| `run_scp <args...>` | Thin `scp` wrapper that injects `-P` and `-i`. |
| `show_header "<title>"` | Banner with the local or remote target line. |

All log output goes to **stderr**, so `ACTION=$(parse_action "$1")` captures only the intended value.
