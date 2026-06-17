# aiprofil

Unified **backend-profile switcher** across two tools that both talk to the
same Azure-Foundry-Claude backends but configure them very differently:

- **CC** — the Claude Code CLI, via environment variables (`cc-profil`).
- **Kilo** — the Kilo Code config `kilo.jsonc`, via a provider/model edit (`kilo-profil`).

One profile, two tools. A profile (`profiles/<name>.env`) holds the canonical
facts once; each adapter projects them into its tool's native form.

## Layout

```
aiprofil/
├── aiprofil.sh / .ps1        orchestrator (sourced) — calls both adapters
├── adapters/
│   ├── cc-profil.sh / .ps1   CC env adapter (sourced)
│   └── kilo-profil.sh / .ps1 Kilo kilo.jsonc adapter (plain exec)
├── profiles/                 SHARED profile source
│   ├── <name>.env            real (gitignored — holds live keys)
│   ├── *.env.example         committed templates
│   └── .managed-vars         env vars cc-profil resets on switch
└── README.md
```

## Invocation — two orthogonal enums

```
aiprofil use <profile> [--target cc|kilo|both] [--scope session|user|project]
```

| Switch | Values | Default | Meaning |
|---|---|---|---|
| `--target` | `cc` \| `kilo` \| `both` (list ok: `cc,kilo`) | `both` | *which* tool |
| `--scope`  | `session` \| `user` \| `project` | `user` | *how persistent* |

Scope maps per target; where a target has no analog it is **skipped with a note**:

| `--scope` | CC (env) | Kilo (`kilo.jsonc`) |
|---|---|---|
| `session` | current shell | — skip |
| `user`    | User scope (persistent) | global `~/.config/kilo/kilo.jsonc` |
| `project` | — skip | `./kilo.jsonc` (or `.kilo/kilo.jsonc`) |

```
aiprofil use sbb-ai-dz --scope user            # CC User scope + Kilo global
aiprofil use sbb-dfa   --target kilo --scope project   # only Kilo, ./kilo.jsonc
aiprofil use max       --scope session --target cc      # only this shell
```

`max` (OAuth, no `KILO_*` keys) projects to CC only; the Kilo target no-ops with
an info line.

## Profiles — "one profile, two tools"

Existing CC keys are reused; the optional `KILO_*` block adds the Kilo
projection (omit it to make a profile CC-only):

```ini
ANTHROPIC_FOUNDRY_RESOURCE=...                 # CC + derives Kilo baseURL
ANTHROPIC_FOUNDRY_API_KEY=***                  # gitignored, reused by Kilo
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-7   # CC tier default
KILO_PROVIDER_ID=ai-dz-anthropic               # must match provider.<id> in kilo.jsonc
KILO_ACTIVE_MODEL=claude-opus-4-7
KILO_SMALL_MODEL=claude-haiku-4-5
```

`KILO_*` keys are **not** exported into the shell by cc-profil — they belong to
the kilo adapter.

## How the Kilo edit stays safe

`kilo-profil` repoints only the **top-level** `model` / `small_model` keys via a
brace-depth-aware editor that **preserves `//` comments, `$schema` and
formatting** — no `jq` reserialize, and nested `agent.*.model` keys are left
untouched. A **missing** `provider.<id>` block is emitted for review, never
blind-written into the JSONC.

## Installation & backward compatibility

```
toolbox install --what aiprofil      # orchestrator (sourced into $PROFILE/.bashrc)
toolbox install --what cc-profil     # CC adapter, standalone command
toolbox install --what kilo-profil   # Kilo adapter, standalone command
```

`cc-profil` was relocated here from the old top-level `cc-profil/`. Three things
keep existing installs working:

1. **Self-healing re-link** — `toolbox install` is idempotent and rewrites the
   `$PROFILE`/`.bashrc` function to the new path; no manual unlink needed.
2. **Forwarding shims** — `cc-profil/cc-profil.{sh,ps1}` remain as thin
   deprecated forwarders, so machines that pull before re-installing keep
   working (their wiring still points at the old path).
3. **Profile fallback** — the adapters resolve profiles from `aiprofil/profiles`
   first, then the legacy `cc-profil/profiles`, so locally-held (gitignored)
   profiles at the old path still resolve.

`--global` stays as an alias for `--scope user`.
