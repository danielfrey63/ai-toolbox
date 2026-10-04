# Audit checklist

Scan the full script for these patterns. Each finding gets a severity group and a concrete before/after diff using the `idempotent.sh` primitives.

## What to look for

- **Blind mutators** – `apt install`, `systemctl start`, `mkdir`, `useradd`, `ln -s`, `cp`, `chmod`, `chown`, `ufw allow`, `iptables`, `docker run`, `git clone`, `curl ... | bash`, redirects into system paths – without a preceding existence or state check.
- **Missing sub-commands** – no `help`, no `verify`, no `cleanup`. A missing `cleanup` is the canary: the author has not thought about reversal.
- **Non-idempotent patterns** – `>> /etc/hosts` (duplicate lines on re-run), `mkdir` without `-p`, `ln -s` without `-f`, `tee -a`, `useradd` without an `id <user>` guard.
- **Hidden coupling** – relative paths that assume the current directory, hardcoded ports, unquoted variables that break on whitespace.
- **Silent failures** – `command || true` without a reason, missing `set -u` / `set -o pipefail`, log output redirected to `/dev/null`.

## Severity groups

1. **Breaks on re-run** – blind mutations, missing existence checks. Highest priority.
2. **No reversal path** – no `cleanup` sub-command, no `desired_absent` calls.
3. **Brittle** – silent failures, hidden coupling.
4. **Style** – no logging conventions, no header, no help text.

## Example fix

Before:

```bash
echo "10.0.0.5 db.internal" >> /etc/hosts
```

After:

```bash
desired_state "hosts entry db.internal" \
    "grep -qE '^10\.0\.0\.5[[:space:]]+db\.internal$' /etc/hosts" \
    "echo '10.0.0.5 db.internal' >> /etc/hosts"
```

Matching cleanup:

```bash
desired_absent "hosts entry db.internal" \
    "! grep -qE '^10\.0\.0\.5[[:space:]]+db\.internal$' /etc/hosts" \
    "sed -i '/^10\.0\.0\.5[[:space:]]\+db\.internal$/d' /etc/hosts"
```

The check must be side-effect-free and exit 0 exactly when the desired state holds. A check that is too broad (e.g. `grep -q db.internal`) hides drift; one that is too narrow makes the second `install` report `[CHANGING]`.
