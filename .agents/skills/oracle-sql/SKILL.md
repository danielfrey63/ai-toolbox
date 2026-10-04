---
name: oracle-sql
description: Answers natural-language data questions against an Oracle database through the Oracle SQLcl MCP server (`sql -mcp`) and sets that server up idempotently (verify/install/cleanup). The model queries saved, named SQLcl connections and never sees the database password. Supports Easy Connect (on-prem) and wallet/TNS (Autonomous DB) and registers the server with Claude Code or Kilo, or prints the snippet for VS Code Copilot. Use when the user wants to query an Oracle database, set up Oracle data access for an agent, register an Oracle MCP server, or test Oracle connectivity. Trigger: «Oracle abfragen», «Oracle-MCP einrichten», «SQLcl MCP».
argument-hint: "[verify|install|cleanup] or a natural-language question about the data"
allowed-tools: Bash, Read, AskUserQuestion
homepage: https://github.com/danielfrey63/ai-toolbox
repository: https://github.com/danielfrey63/ai-toolbox
license: MIT
user-invocable: true
metadata:
  version: "0.8.42"
---

# oracle-sql – query an Oracle database via the SQLcl MCP server

Oracle SQLcl 25.x/26.x ships a built-in **MCP server** (`sql -mcp`) that exposes SQLcl's *saved, named connections*. The password lives in SQLcl's secure store and **never reaches the model**; you query through the connection name.

## Step 0 – Preflight (every invocation, silent on success)

Run the setup script (do not read it first). On Windows use `powershell -File` (or `pwsh -File`) with `scripts/setup.ps1`, on macOS/Linux `bash` with `scripts/setup.sh`:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/setup.sh" verify
```

Exit 0 → ready, proceed without announcing it. Non-zero → surface what `verify` reported and walk the user through `install`.

## Setup (idempotent: verify → install → cleanup)

| Action | Effect |
|---|---|
| `verify`  | Read-only: SQLcl on PATH? JVM? config present? connection saved? MCP server registered? |
| `install` | Scaffold `config/oracle.env`, print the guarded connection-save command, register the `sql -mcp` server with the chosen client. |
| `cleanup` | Unregister the MCP server; print the command to drop the saved connection. |

- **Prerequisites are not auto-installed** (Oracle download and license acceptance): SQLcl 25.x/26.x on PATH (`sql`) and a JVM. `verify` and `install` tell the user what is missing.
- **Config** lives in `config/oracle.env` (copied from `config/oracle.env.tmpl`, gitignored). Leave `ORACLE_PASSWORD` empty. Connection styles: **Easy Connect** (`ORACLE_HOST` / `ORACLE_PORT` / `ORACLE_SERVICE`) or **wallet/TNS** (`TNS_ADMIN` + `ORACLE_TNS_ALIAS`).
- **Registration target** via `ORACLE_MCP_CLIENT`: `print` (default, snippet only), `claude` (`claude mcp add`), or `kilo` (comment-preserving managed block in `kilo.jsonc`; path via `ORACLE_KILO_CONFIG`, a `.bak` is written before each change).
- **Saving the connection** needs the password, so the user types it in an attached terminal. The script only prints the command. Details: [README.md](README.md), sections 4 and "Deferred mutations".

## Querying

Once the `oracle` MCP server is registered and its tools are available, answer data questions by issuing SQL through the MCP tools against the saved connection. Run read-only SQL (`SELECT`, `EXPLAIN`, `DESC`) freely; confirm with the user before any DML/DDL. If the MCP tools are not visible, use the terminal fallback in [README.md](README.md), section 6.

## Security

- Never write a real password into `config/oracle.env` in the repo – it is consumed once at connection-save time and stored by SQLcl. Only `config/oracle.env.tmpl` (placeholders) is committed.
- The MCP client config (e.g. `kilo.jsonc`) holds **no** Oracle credentials, only the `sql -mcp` launch command.
- Never log, echo or relay a password through a tool call.

## Reference

[README.md](README.md) covers placement per host, step-by-step installation, the Copilot/Claude Code/Kilo registration variants, known issues and the file layout. `lib/idempotent.sh` is a vendored copy of `idempotent-devops/lib/idempotent.sh` and must stay byte-identical with it.
