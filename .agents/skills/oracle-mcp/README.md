# oracle-mcp

Set up and use an **Oracle MCP server** for natural-language SQL data queries.
The skill targets **Oracle SQLcl 25.x's built-in MCP server** (`sql -mcp`) and
wires it into an MCP client (Claude Code or Kilo) with an idempotent
`verify / install / cleanup` flow.

## Why SQLcl's MCP server (Optionsvergleich)

| Option | What it is | Pro | Contra |
|---|---|---|---|
| **Oracle SQLcl MCP** (chosen) | `sql -mcp`, built into SQLcl 25.x | Official Oracle; **password never reaches the model** (saved connection in SQLcl's secure store); supports Easy Connect *and* wallet/Autonomous; nothing extra to write | Needs SQLcl + JVM installed (Oracle download, license acceptance) |
| python-oracledb (community) | thin Python MCP over `python-oracledb` | Lightweight; thin mode needs no Oracle client; quick to spin up | Community-maintained; credentials typically passed to the server config (more exposure); you own the query surface/safety |
| DBHub (generic) | bytebase/dbhub, multi-DB MCP | One server for Oracle + Postgres + MySQL …; good when several DBs are in play | Oracle is one backend among many; generic SQL surface; another moving part |

**Decision:** SQLcl wins for a hackathon Oracle test because it is the official
path and keeps the DB password out of the model and out of the client config —
the single most valuable property when handing data access to an agent.

## Quick start

```bash
# 1. preflight
bash scripts/setup.sh verify           # Windows: pwsh scripts/setup.ps1 verify

# 2. configure
cp config/oracle.env.tmpl config/oracle.env   # then edit (gitignored)

# 3. install (scaffolds config, guides connection-save, registers the server)
bash scripts/setup.sh install
```

Set `ORACLE_MCP_CLIENT` in `oracle.env`:
- `print` — emit the registration snippet only (default, safe)
- `claude` — `claude mcp add oracle -- sql -mcp` (idempotent)
- `kilo` — snippet for `~/.config/kilo/kilo.jsonc`

## Connection styles

- **Easy Connect** (on-prem): `ORACLE_HOST` / `ORACLE_PORT` / `ORACLE_SERVICE`
- **Wallet / TNS** (Autonomous DB, mTLS): `TNS_ADMIN` → unzipped wallet dir,
  `ORACLE_TNS_ALIAS` → a `tnsnames.ora` entry (e.g. `mydb_high`)

## Security

- The real `config/oracle.env` is **gitignored**; only `oracle.env.tmpl` (with
  placeholders) is committed.
- The password is consumed once when saving the SQLcl connection and stored in
  SQLcl's secure store — it is **not** persisted in `oracle.env` afterward and
  is **never** exposed to the MCP client or the model.
- The MCP client config holds only the connection name + `sql -mcp` command.

### JSONC caveat (Kilo)

`~/.config/kilo/kilo.jsonc` contains `//` comments and a `$schema` line. Do
**not** rewrite it with `jq` (it strips comments and reorders keys). Add the
`oracle` entry to the existing `mcp` block by hand, or with a
comment-preserving editor.

## Offene Verifikation

Two credential-/state-bearing steps are intentionally **deferred** (the script
prints guarded instructions instead of mutating) until confirmed against the
target SQLcl build:

1. **Saving the connection** — `connect -save <name> -savepwd <user>@<connect>`.
   The exact flag set varies across SQLcl versions; verify before automating.
2. **Dropping the connection** in `cleanup` — `conn -delete <name>` (syntax to
   confirm).

Once verified against a real SQLcl 25.x install, these can be promoted to
`desired_state` mutations in `scripts/setup.sh` / `setup.ps1`.

## Layout

```
oracle-mcp/
├── SKILL.md                       skill definition (preflight + query workflow)
├── README.md                      this file
├── lib/idempotent.sh              desired-state runtime (copied from idempotent-devops)
├── scripts/
│   ├── setup.sh                   bash: help|verify|install|cleanup
│   └── setup.ps1                  PowerShell mirror
└── config/
    ├── oracle.env.tmpl            connection template (placeholders)
    └── mcp-registration.jsonc.tmpl  MCP registration snippet
```
