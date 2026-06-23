---
name: oracle-mcp
description: Set up and use an Oracle MCP server for natural-language SQL data queries against an Oracle database. Uses Oracle SQLcl 25.x's built-in MCP server (`sql -mcp`), which exposes named, saved connections so the model can run SQL WITHOUT ever seeing the database password. Use when the user wants to query an Oracle DB, set up Oracle data access for an agent, register an Oracle MCP server, or test Oracle connectivity. Idempotent verify/install/cleanup setup; connection config supports both Easy Connect (on-prem) and wallet/TNS (Autonomous DB).
argument-hint: "[verify|install|cleanup] or a natural-language question about the data"
allowed-tools: Bash, Read, AskUserQuestion
homepage: https://github.com/danielfrey63/ai-toolbox
repository: https://github.com/danielfrey63/ai-toolbox
license: MIT
user-invocable: true
metadata:
  version: "0.3.27"
---

# oracle-mcp — query an Oracle database via the SQLcl MCP server

This skill gives you SQL access to an Oracle database. Oracle SQLcl 25.x ships a
built-in **MCP server** (`sql -mcp`) that exposes SQLcl's *saved, named
connections*. The key property: **the password never reaches the model** — it
lives in SQLcl's secure store, and you query through the connection name.

## Step 0 — Preflight (every invocation, silent on success)

On **Windows** use `pwsh` + `setup.ps1`; on macOS/Linux use `bash` + `setup.sh`.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/setup.sh" verify
```

On exit 0 → ready, proceed. On non-zero, surface what `verify` reported and
walk the user through `install` (see below). Do **not** announce success on
every turn.

## Setup (idempotent: verify → install → cleanup)

| Action | Effect |
|---|---|
| `verify`  | Read-only: SQLcl on PATH? JVM? config present? connection saved? MCP registered? |
| `install` | Scaffold `config/oracle.env`, save the SQLcl connection (guarded — see below), register the `sql -mcp` server with the chosen client. |
| `cleanup` | Unregister the MCP server; optionally drop the saved connection. |

**Prerequisites are not auto-installed** (Oracle download + license acceptance):
SQLcl 25.x on PATH (`sql`) and a JVM. If missing, `verify`/`install` tell the
user exactly what to get.

**Config** lives in `config/oracle.env` (copy from `oracle.env.tmpl`,
gitignored). Pick one connection style:
- **Easy Connect** (on-prem): `ORACLE_HOST` / `ORACLE_PORT` / `ORACLE_SERVICE`
- **Wallet / TNS** (Autonomous DB): `TNS_ADMIN` + `ORACLE_TNS_ALIAS`

`ORACLE_MCP_CLIENT` selects the registration target: `print` (default, emits the
snippet only), `claude` (`claude mcp add`, idempotent), or `kilo` (insert/remove
a self-marked `oracle` block in Kilo's `kilo.jsonc` idempotently, preserving
comments — no jq; path via `ORACLE_KILO_CONFIG`, else `~/.config/kilo/kilo.jsonc`,
else `~/.config/kilo.jsonc`; a `.bak` is written before each change).

## Querying

Once the `oracle` MCP server is registered and its tools are available, answer
data questions by issuing SQL through the MCP tools against the saved
connection. Prefer read-only queries; confirm with the user before any DML/DDL.

## Security

- Never write a real password into `config/oracle.env` in the repo — it is
  consumed once at connection-save time and stored by SQLcl. The committed
  artifact is `oracle.env.tmpl` (placeholders only).
- The MCP client config (e.g. `kilo.jsonc`) holds **no** Oracle credentials —
  only the connection name and the `sql -mcp` launch command.

## Open verification

The credential-bearing connection-save and the connection-drop are **deferred**
(printed as guarded instructions, not auto-run) until the exact
`connect -save` / `conn -delete` syntax is confirmed against the target SQLcl
build. See `README.md` → "Offene Verifikation".
