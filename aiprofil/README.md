# aiprofil

Unified **backend-profile switcher** across three tools that all talk to the
same Azure-Foundry backends but configure them very differently:

- **CC** — the Claude Code CLI, via environment variables (`cc-profil`).
- **Kilo** — the Kilo Code config `kilo.jsonc`, via a provider/model edit (`kilo-profil`).
- **Codex** — the Codex CLI config `~/.codex/config.toml` plus `AZURE_OPENAI_API_KEY` (`codex-profil`).

One profile, three tools. A profile (`profiles/<name>.env`) holds the canonical
facts once; each adapter projects them into its tool's native form.

## Layout

```
aiprofil/
├── aiprofil.sh / .ps1         orchestrator (sourced) — calls the adapters
├── adapters/
│   ├── cc-profil.sh / .ps1    CC env adapter (sourced)
│   ├── kilo-profil.sh / .ps1  Kilo kilo.jsonc adapter (plain exec)
│   ├── codex-profil.sh / .ps1 Codex config.toml + env adapter (sourced)
│   └── codex-catalog.py       Azure deployments -> Codex model catalog (shared helper)
├── profiles/                  SHARED profile source
│   ├── <name>.env             real (gitignored — holds live keys)
│   ├── *.env.example          committed templates
│   └── .managed-vars          env vars cc-profil resets on switch
└── README.md
```

## Invocation — two orthogonal enums

```
aiprofil use <profile> [--target cc|kilo|codex|both] [--scope session|user|project]
```

| Switch | Values | Default | Meaning |
|---|---|---|---|
| `--target` | `cc` \| `kilo` \| `codex` \| `both` (alias `all`; list ok: `cc,codex`) | `both` | *which* tool |
| `--scope`  | `session` \| `user` \| `project` | `session` | *how persistent* |

Scope maps per target; where a target has no analog it is **skipped with a note**:

| `--scope` | CC (env) | Kilo (`kilo.jsonc`) | Codex (`config.toml` + env) |
|---|---|---|---|
| `session` | current shell | — skip | env in shell + config (config is per-user by nature) |
| `user`    | User scope (persistent) | global `~/.config/kilo/kilo.jsonc` | env User scope (pwsh) + config |
| `project` | — skip | `./kilo.jsonc` (or `.kilo/kilo.jsonc`) | — skip |

```
aiprofil use sbb-ai-dz --scope user            # CC User scope + Kilo global
aiprofil use sbb-dfa   --target kilo --scope project   # only Kilo, ./kilo.jsonc
aiprofil use max       --scope session --target cc      # only this shell
```

`max` (OAuth) projects to CC via `claude auth login` and to Codex via the
subscription mode below; the Kilo target no-ops with an info line. Profiles
without any `KILO_*`/`CODEX_*` keys skip those targets entirely.

## Profiles — "one profile, three tools"

The shared Foundry facts live once in **generic** keys; each adapter translates
them into its tool's native form. The optional `KILO_*`/`CODEX_*` blocks add
the respective projection (omit them to make a profile CC-only):

```ini
FOUNDRY_RESOURCE=...                           # shared Azure Foundry resource
FOUNDRY_API_KEY=***                            # gitignored, shared key
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-7   # CC tier default
CODEX_MODEL_DEPLOYMENT=gpt-5-codex             # GPT deployment name on the resource
KILO_PROVIDER_ID=ai-dz-anthropic               # must match provider.<id> in kilo.jsonc
KILO_ACTIVE_MODEL=claude-opus-4-7
KILO_SMALL_MODEL=claude-haiku-4-5
```

Adapter translation of the generic keys:

- **cc-profil** exports them as `ANTHROPIC_FOUNDRY_RESOURCE` / `ANTHROPIC_FOUNDRY_API_KEY` (an explicit `ANTHROPIC_FOUNDRY_*` in the profile wins — legacy profiles keep working unchanged).
- **kilo-profil** derives the provider `baseURL` (`https://<resource>.services.ai.azure.com/anthropic/v1`).
- **codex-profil** derives the Azure OpenAI `base_url` (`https://<resource>.openai.azure.com/openai/v1`) and sets `AZURE_OPENAI_API_KEY` — Codex refuses inline keys, its `env_key` must reference an env variable.

`KILO_*`/`CODEX_*` keys are **not** exported into the shell by cc-profil — they
belong to their adapters. A profile without a Foundry backend just omits the
generic keys.

### Codex deployment catalog

A catalog profile (one that sets `CODEX_PROVIDER_ID` or `CODEX_MODEL_DEPLOYMENTS`) lists its deployments **live from Azure** (`<base>/deployments`) at `use` time via the shared helper `adapters/codex-catalog.py` (python3) and registers one Codex profile per deployment as a profile file `$CODEX_HOME/<provider>-<deployment>.config.toml`, selectable via `codex --profile <provider>-<deployment>` (name reduced to `[A-Za-z0-9_-]`, since Codex ≥ 0.15x rejects dots: `gpt-6.1-sol` → `nes-gpt-6_1-sol`). Codex ≥ 0.15x also refuses `--profile` while legacy `[profiles.<name>]` tables exist, so the adapter removes those of its provider. Profile files carry a `# managed by codex-profil: provider=<id>` marker; only marked files are pruned when a deployment disappears. `CODEX_MODEL_DEPLOYMENTS` is only the offline fallback. The default model stays untouched unless the profile also sets `CODEX_MODEL_DEPLOYMENT`, so the catalog coexists with the ChatGPT subscription mode.

The helper also writes `$CODEX_HOME/model-catalogs/<provider>.json`: Codex cannot list a custom provider's models, so its `/model` picker would otherwise show the ChatGPT account's catalog. Each entry copies the full metadata (reasoning levels, …) from Codex's own cache `models_cache.json` – exact model match first, else the highest version of the same variant (`gpt-6.1-sol` → `gpt-6-sol`); deployments without a match (embeddings, non-GPT) are skipped. When the profile repoints the default model, `model_catalog_json` points at that file; `codex-profil use max` removes it again. New Azure deployments appear with the next `use`.

| Key | Effect |
|---|---|
| `CODEX_PROVIDER_ID` | own `[model_providers.<id>]` block (default `azure`); env var `AZURE_<ID>_API_KEY` (`azure` keeps `AZURE_OPENAI_API_KEY`) |
| `CODEX_BASE_URL` | overrides the base URL derived from `FOUNDRY_RESOURCE` (e.g. a `*.cognitiveservices.azure.com/openai` endpoint; Codex appends `/responses`) |
| `CODEX_API_VERSION` | writes `[model_providers.<id>.query_params] api-version` |
| `CODEX_API_KEY` | key for this provider (falls back to `FOUNDRY_API_KEY`); `--scope user` persists it, so it never needs to be set by hand |

Catalog-only profiles carry no CC keys; apply them with `--target codex`, otherwise aiprofil also resets CC (see `profiles/nes.env.example`).

### Codex subscription mode

A profile with `CODEX_AUTH=chatgpt` (e.g. `max`) repoints Codex at the
built-in `openai` provider with the ChatGPT sign-in instead of Azure: the
adapter sets `model_provider = "openai"` and `forced_login_method = "chatgpt"`,
drops the Azure `model` repoint (optional `CODEX_MODEL` pins one), and skips
the API key entirely. The interactive sign-in itself is `codex login` — the
adapter hints at it when `auth.json` is missing. Azure mode conversely removes
`forced_login_method`, so switching between the two profiles is symmetric.

## How the Codex edit stays safe

`codex-profil` patches `${CODEX_HOME:-~/.codex}/config.toml` desired-state:
only the top-level `model` / `model_provider` / `model_catalog_json` keys, the profile's `[model_providers.<id>]` section (plus its `query_params`) are touched and legacy `[profiles."<id>-*"]` tables removed; profile files and `model-catalogs/<id>.json` live next to it, everything else (other providers, foreign profiles, MCP config) is preserved. If nothing deviates, the file is left untouched.

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
toolbox install --what codex-profil  # Codex adapter, standalone command (sourced)
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
