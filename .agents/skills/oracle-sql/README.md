# oracle-sql

Give an LLM agent read-mostly SQL access to an Oracle database via Oracle SQLcl's built-in MCP server (`sql -mcp`). The password is stored in SQLcl's secure store and **never reaches the model** – the agent queries by *connection name*.

> This README is written so an agent (GitHub Copilot, Claude Code, Kilo Code) can install the skill autonomously. Steps are imperative and ordered. The only human-only step is **typing the DB password** into a terminal in section 4.

## Contents

- [0. Preconditions](#0-preconditions-verify-before-doing-anything)
- [1. Place the skill folder](#1-place-the-skill-folder)
- [2. Configure the connection](#2-configure-the-connection)
- [3. Run verify](#3-run-verify)
- [4. Save the SQLcl connection](#4-save-the-sqlcl-connection-interactive--user-types-password)
- [5. Register the MCP server with the chat host](#5-register-the-mcp-server-with-the-chat-host)
- [6. Querying](#6-querying)
- [7. Cleanup (uninstall)](#7-cleanup-uninstall)
- [Security](#security)
- [Known issues and fixes](#known-issues-and-fixes)
- [Deferred mutations](#deferred-mutations-intentionally-not-automated)
- [Layout](#layout)

---

## 0. Preconditions (verify before doing anything)

| Command | Expected | If missing |
|---|---|---|
| `sql -V` | SQLcl 25.x or 26.x | Install Oracle SQLcl + accept license; put `sql` on PATH |
| `java -version` | any JRE/JDK 11+ | Install a JVM and ensure `java` on PATH |

Stop and tell the user if either is missing – do not auto-install Oracle binaries.

---

## 1. Place the skill folder

All three supported hosts read **the same** `.claude/skills/` convention.

| Scope | Folder |
|---|---|
| User (Win) | `C:\Users\<u>\.claude\skills\oracle-sql\` |
| User (mac/linux) | `~/.claude/skills/oracle-sql/` |
| Workspace | `<workspace>/.claude/skills/oracle-sql/` |

> **Do not** put it in `%APPDATA%\Code\User\prompts\skills\` – that path is for VS Code `.prompt.md` slash-commands, not `SKILL.md` skills, and Copilot will silently ignore it.

After copy: **reload the host**.

- VS Code (Copilot): Command Palette → *Developer: Reload Window*
- Claude Code / Kilo: restart the CLI / extension

---

## 2. Configure the connection

```bash
cp config/oracle.env.tmpl config/oracle.env     # gitignored – never commit
```

Edit `config/oracle.env`. Pick **one** style:

| Field | Style A (Easy Connect, on-prem) | Style B (TNS / Wallet, Autonomous) |
|---|---|---|
| `ORACLE_CONN_NAME` | logical name the MCP server will expose (e.g. `hackathon`) | same |
| `ORACLE_USER` | DB user | DB user |
| `ORACLE_PASSWORD` | leave empty – prompted in section 4 | same |
| `ORACLE_HOST` / `ORACLE_PORT` / `ORACLE_SERVICE` | **set** | leave |
| `TNS_ADMIN` | leave | absolute path to directory with `tnsnames.ora` (+ wallet for Autonomous) |
| `ORACLE_TNS_ALIAS` | leave | TNS alias from that `tnsnames.ora` |
| `ORACLE_MCP_CLIENT` | `print` (Copilot), `claude`, or `kilo` | same |

**`TNS_ADMIN` placement (Style B):** use a stable, non-synced local path such as `~/.oracle/tns/` (on Windows `C:\Users\<u>\.oracle\tns\`). **Avoid OneDrive / Google Drive** – paths break on other machines and may leak `tnsnames.ora` into sync.

---

## 3. Run verify

```powershell
# Windows
powershell -File scripts/setup.ps1 verify
```

```bash
# macOS / Linux
bash scripts/setup.sh verify
```

Expect all `[OK]` except *connection not saved* (fixed in section 4) and the MCP-client line (fixed in section 5). Exit code 0 = ready; non-zero = surface what is missing.

---

## 4. Save the SQLcl connection (interactive – user types password)

The agent must launch this in a **visible, attached terminal** and then hand control to the user for the password prompt. Never relay the password through a tool call or LLM-routed input.

```powershell
# Windows (only for Style B: TNS)
$env:TNS_ADMIN = "C:\Users\<u>\.oracle\tns"
sql /nolog
```

```bash
# macOS / Linux (only for Style B)
export TNS_ADMIN="$HOME/.oracle/tns"
sql /nolog
```

At the `SQL>` prompt:

```
connect -save <ORACLE_CONN_NAME> -savepwd <ORACLE_USER>@<connect-target>
```

where `<connect-target>` is:

- Style A: `host:port/service_name` (matching `oracle.env`)
- Style B: the TNS alias (e.g. `GISATEST`)

SQLcl prints `Kennwort?` / `Password?` – the **user** types it and presses Enter. Then verify and exit:

```
connmgr list                       -- should show <ORACLE_CONN_NAME>
connmgr test <ORACLE_CONN_NAME>    -- "Verbindungstest erfolgreich"
exit
```

---

## 5. Register the MCP server with the chat host

Pick the block that matches your host.

### 5a. GitHub Copilot (VS Code) – manual

Set `ORACLE_MCP_CLIENT=print` in `oracle.env`. Then edit:

| OS | MCP config path |
|---|---|
| Windows | `%APPDATA%\Code\User\mcp.json` |
| macOS | `~/Library/Application Support/Code/User/mcp.json` |
| Linux | `~/.config/Code/User/mcp.json` |

```jsonc
{
  "servers": {
    "oracle": {
      "type": "stdio",
      "command": "sql",
      "args": ["-mcp"]
    }
  },
  "inputs": []
}
```

Start it: Command Palette → *MCP: List Servers* → `oracle` → *Start*. In the chat tool picker, enable the `oracle` server's tools.

### 5b. Claude Code – automated

Set `ORACLE_MCP_CLIENT=claude`. Then `install` (5d) runs `claude mcp add oracle -- sql -mcp` idempotently. Manual equivalent:

```bash
claude mcp add oracle -- sql -mcp
claude mcp list                       # expect 'oracle'
```

### 5c. Kilo Code – automated (comment-preserving)

Set `ORACLE_MCP_CLIENT=kilo` (optionally `ORACLE_KILO_CONFIG` for a custom `kilo.jsonc` path; defaults: `~/.config/kilo/kilo.jsonc`, then `~/.config/kilo.jsonc`). `install` inserts a block marked with `//>>> oracle-sql:managed` / `//<<< oracle-sql:managed` as the first child of the `mcp` object without touching surrounding comments, `$schema` or secrets; `cleanup` removes exactly that block. A `.bak` is written before each mutation.

Blocks written under the skill's former name carry the legacy marker `oracle-skill:managed`. They are still recognised: `verify` reports them as "run install to migrate", `install` replaces them with the current block, `cleanup` removes them. Both scripts (`setup.sh`, `setup.ps1`) behave the same.

### 5d. Run install

```powershell
powershell -File scripts/setup.ps1 install       # Windows
```

```bash
bash scripts/setup.sh install              # macOS / Linux
```

Re-run `verify` – expect `ready`.

---

## 6. Querying

**Preferred** (once the MCP tools are visible in the chat host): call the `oracle` MCP server's tool with the connection name and the SQL.

**Terminal fallback** (always works, scriptable):

```powershell
@"
connect -name <ORACLE_CONN_NAME>
SET SQLFORMAT ANSICONSOLE
<your SQL>;
EXIT
"@ | sql /nolog
```

Only run **read-only** SQL (`SELECT`, `EXPLAIN`, `DESC`) without explicit user confirmation. Any DML/DDL (`INSERT/UPDATE/DELETE/CREATE/ALTER/DROP/TRUNCATE`) requires an explicit *"yes, run it"* from the user, ideally with an estimated row-impact shown first.

---

## 7. Cleanup (uninstall)

```bash
bash scripts/setup.sh cleanup        # or: powershell -File scripts/setup.ps1 cleanup
```

Removes the MCP registration (Claude Code or Kilo, including legacy Kilo blocks) idempotently. Dropping the saved SQLcl connection is **printed as a hint** rather than executed (SQLcl 26.1: `connmgr delete <name>`) – run it by hand if desired. `config/oracle.env` is intentionally left in place.

---

## Security

- `config/oracle.env` is **gitignored**; only `oracle.env.tmpl` is committed.
- `ORACLE_PASSWORD` is consumed once in section 4, then lives in SQLcl's secure store – not in `oracle.env`, not in the MCP client config, never in the model.
- The MCP client config holds only the `sql -mcp` launch command.
- The agent must refuse to log, echo, or `Write-Host` any password it ever sees.

---

## Known issues and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `verify` reports *connection not saved* although `connmgr list` shows it | `connmgr list` colorizes the name with ANSI (`ESC[0;33m…ESC[0m`); surrounding `m`/`[` are word-chars so `\b<name>\b` fails | Strip ANSI then match with alnum-only lookarounds. Applied in `setup.ps1` `Test-ConnExists`. |
| Same as above, on Windows PowerShell 5.1 | PS 5.1 has no `` `e `` escape (PS 6+ only); the literal `` `e `` matches `e`, not ESC (0x1B) | Use `[char]27` in the regex (also applied). |
| `sql /@<name>` → `ORA-12154` | `/@name` treats `<name>` as a TNS alias, not a saved connection | From `sql /nolog`, use `connect -name <name>`. |
| `sql -S <name>` → "Verbindung konnte nicht hergestellt werden" | `-S` is silent-mode for a connect-string arg, not a saved-name lookup | Same – `connect -name` inside `sql /nolog`. |
| `tnsnames.ora` works on dev, not on CI / another box | Path under OneDrive / Google Drive isn't mounted there | Move file to `~/.oracle/tns/` (on Windows `%USERPROFILE%\.oracle\tns\`). |
| Skill invisible to Copilot after install | Placed in `%APPDATA%\Code\User\prompts\skills\` | Move to `~/.claude/skills/oracle-sql/`; reload window. |
| `bash setup.sh` reports connection missing on a working install | The bash detector does not strip ANSI codes like the PowerShell one | Workaround: check `connmgr list` manually. |

---

## Deferred mutations (intentionally not automated)

The credential-bearing **save** (`connect -save … -savepwd …`) and the **drop** (`connmgr delete <name>` on SQLcl 26.1) are printed as guarded hints instead of being run by the script. They can be promoted to `desired_state` mutations once verified end-to-end against the target SQLcl build.

Saved-connection **detection** uses `connmgr list` (verified on SQLcl 26.1.2); `conn -list` is rejected as unknown on 26.x.

---

## Layout

```
oracle-sql/
├── SKILL.md                       skill definition (preflight + query workflow)
├── README.md                      this file
├── lib/idempotent.sh              desired-state runtime (bash), vendored copy
├── scripts/
│   ├── setup.sh                   bash: help|verify|install|cleanup
│   └── setup.ps1                  PowerShell mirror (Win-safe: PS 5.1 + 7)
└── config/
    ├── oracle.env.tmpl            connection template (placeholders)
    └── mcp-registration.jsonc.tmpl  MCP registration snippet (Kilo / print)
```

`lib/idempotent.sh` is a vendored copy of `idempotent-devops/lib/idempotent.sh`. Each skill stays self-contained, so the file exists in both; keep the two copies byte-identical and change them only together.
