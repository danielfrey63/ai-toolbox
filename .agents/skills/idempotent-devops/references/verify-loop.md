# Verify loop

Proves that a setup script is idempotent. Run the target script's own sub-commands (`bash setup-<name>.sh <action>`) in this order and stop at the first failure.

## Base sequence

```
verify           snapshot of the initial state
install
verify           all desired states present
install          second run – no [CHANGING] lines
verify           no drift
cleanup
verify           desired states absent
cleanup          second run – no [CHANGING] lines
verify           no drift
install          restore
verify           back to the installed state
```

## Additional sequence when `purge` exists

```
cleanup
purge            FORCE=1 if the confirmation prompt blocks automation
verify           everything absent
purge            second run – idempotent
install          restore from scratch
verify
```

## Pass and fail

- **Pass:** every step exits 0, and the second `install` and second `cleanup` only print `[CHECKING] ... already correct` / `already absent`.
- **Fail:** a step exits non-zero, or a second run prints `[CHANGING]`. Report the failing step, quote the relevant lines from the output and from `$LOG_FILE`, and propose a fix. The usual cause is a `desired_state` check that is too narrow or has a side effect.

## Fix-then-retry

After a fix, restart the whole loop from the first step. Do not patch and continue mid-loop: the fix may break an earlier step.

## Safety

The loop really installs and removes things. Run it only against a target the user has approved (local dev machine, throwaway VM or container). Ask before running `purge` on anything that holds data.
