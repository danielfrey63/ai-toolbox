# oracle-skill

Set up and use an **Oracle MCP server** for natural-language SQL data queries.
The skill targets **Oracle SQLcl 25.x/26.x's built-in MCP server** (`sql -mcp`) and
wires it into an MCP client (Claude Code or Kilo) with an idempotent
`verify / install / cleanup` flow.

## Why SQLcl's MCP server (Optionsvergleich)

| Option | What it is | Pro | Contra |
|---|---|---|---|
| **Oracle SQLcl MCP** (chosen) | `sql -mcp`, built into SQLcl 25.x/26.x | Official Oracle; **password never reaches the model** (saved connection in SQLcl's secure store); supports Easy Connect *and* wallet/Autonomous; nothing extra to write | Needs SQLcl + JVM installed (Oracle download, license acceptance) |
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
- `kilo` — insert/remove the `oracle` entry in Kilo's `kilo.jsonc` idempotently,
  comment-preserving (no jq). Path resolution: `ORACLE_KILO_CONFIG`, else
  `~/.config/kilo/kilo.jsonc`, else `~/.config/kilo.jsonc`.

## Connection styles

Connection details live in `config/oracle.env` (copied from `oracle.env.tmpl`,
gitignored). Pick **one** style:

- **Easy Connect** (on-prem): `ORACLE_HOST` / `ORACLE_PORT` / `ORACLE_SERVICE`
- **Wallet / TNS** (Autonomous DB, mTLS): `TNS_ADMIN` → directory holding
  `tnsnames.ora` (+ `sqlnet.ora` / wallet), `ORACLE_TNS_ALIAS` → an entry from
  that `tnsnames.ora` (e.g. `mydb_high`). To switch databases, point
  `TNS_ADMIN` at a different directory or pick a different `ORACLE_TNS_ALIAS`.
  With Easy Connect, `tnsnames.ora` is not used at all — the two styles are
  alternatives.

> **Note (current limitation):** the values in `oracle.env` are *informational*
> today — the skill does **not** yet assemble the connect string for you. When
> you run the deferred `connect -save` step (below), you type the
> `host:port/service` or the TNS alias by hand. `ORACLE_CONN_NAME` *is* used:
> it is the saved-connection name the MCP server exposes.

## Security

- The real `config/oracle.env` is **gitignored**; only `oracle.env.tmpl` (with
  placeholders) is committed.
- The password is consumed once when saving the SQLcl connection and stored in
  SQLcl's secure store — it is **not** persisted in `oracle.env` afterward and
  is **never** exposed to the MCP client or the model.
- The MCP client config holds only the connection name + `sql -mcp` command.

### JSONC handling (Kilo)

`kilo.jsonc` contains `//` comments, a `$schema` line and (in real installs)
plaintext provider secrets — so it must **never** be rewritten with `jq` (it
strips comments, reorders keys, and round-trips the whole file). Instead the
skill inserts a **self-marked block** as the first child of the `mcp` object:

```jsonc
"mcp": {
  //>>> oracle-skill:managed (oracle-skill skill) — remove via: setup.sh|ps1 cleanup >>>
  "oracle": { "type": "local", "command": ["sql", "-mcp"] },
  //<<< oracle-skill:managed <<<
  // ... your other servers, untouched ...
}
```

Only those marker lines are added or removed; the rest of the file is left
byte-for-byte intact (verified by an install→cleanup round-trip). `install` is a
no-op if the marker is already present; `cleanup` deletes exactly the marked
block. A `.bak` copy is written next to the config before each mutation. The
target path is `ORACLE_KILO_CONFIG`, else `~/.config/kilo/kilo.jsonc`, else
`~/.config/kilo.jsonc`.

## Offene Verifikation

Two credential-/state-bearing steps are intentionally **deferred** (the script
prints guarded instructions instead of mutating) until confirmed against the
target SQLcl build:

1. **Saving the connection** — run interactively:
   `connect -save <name> -savepwd <user>@<easyconnect-or-tns>`. The exact flag
   set varies across SQLcl versions; verify before automating. (SQLcl 26.1 also
   exposes `connmgr add` / `connmgr test` as a non-interactive path — a future
   version of this skill may build the connect string from `oracle.env` and use
   it.)
2. **Dropping the connection** in `cleanup` — on SQLcl 26.1 the command is
   `connmgr delete <name>` (the older `conn -delete` no longer applies). Still
   printed as a guarded hint rather than run automatically.

> **Detection (implemented):** the saved-connection check uses
> `connmgr list` — verified against SQLcl 26.1.2. The older `conn -list` is
> rejected as an unknown option on 26.x.

Once the save/drop mutations are verified end-to-end against a real install,
they can be promoted to `desired_state` mutations in `scripts/setup.sh` /
`setup.ps1`.

## Layout

```
oracle-skill/
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
