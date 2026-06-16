# =============================================================================
# oracle-mcp setup — provision an Oracle MCP server (Oracle SQLcl `sql -mcp`)
#                    for natural-language SQL data queries. PowerShell variant.
# =============================================================================
# Mirrors setup.sh. Idempotent: every change is check -> mutate-if-needed ->
# re-verify. Safe to re-run. idempotent.sh is bash-only, so the desired-state
# helpers are inlined here.
#
# Usage: pwsh setup.ps1 <help|verify|install|cleanup>
# =============================================================================

param([string]$Action = 'help')

$AppVersion = '0.1.0'
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SkillDir  = Split-Path -Parent $ScriptDir
$ConfigDir = Join-Path $SkillDir 'config'
$ConfigFile = if ($env:ORACLE_MCP_CONFIG) { $env:ORACLE_MCP_CONFIG } else { Join-Path $ConfigDir 'oracle.env' }

function Write-Info  { param($m) Write-Host "[INFO]     $m" -ForegroundColor Green }
function Write-Ok    { param($m) Write-Host "[OK]       $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "[WARNING]  $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "[ERROR]    $m" -ForegroundColor Red }

# Desired-state: run $Change only if $Check is false, then re-verify.
function Set-DesiredState {
    param([string]$Desc, [scriptblock]$Check, [scriptblock]$Change)
    Write-Host "[CHECKING] $Desc ... " -NoNewline -ForegroundColor Cyan
    if (& $Check) { Write-Host "already correct" -ForegroundColor Green; return $true }
    Write-Host "changing" -ForegroundColor Yellow
    & $Change | Out-Null
    if (& $Check) { Write-Ok "$Desc — done"; return $true }
    Write-Fail "$Desc — verification failed after change"; return $false
}

function Import-Config {
    if (-not (Test-Path $ConfigFile)) { return }
    Get-Content $ConfigFile | Where-Object { $_ -match '^[A-Z_][A-Z0-9_]*=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        if (-not [Environment]::GetEnvironmentVariable($k, 'Process')) {
            [Environment]::SetEnvironmentVariable($k, $v, 'Process')
        }
    }
}

function Test-Sqlcl  { [bool](Get-Command sql    -ErrorAction SilentlyContinue) }
function Test-Java   { [bool](Get-Command java   -ErrorAction SilentlyContinue) }
function Test-Claude { [bool](Get-Command claude -ErrorAction SilentlyContinue) }

function Get-ConnName { if ($env:ORACLE_CONN_NAME) { $env:ORACLE_CONN_NAME } else { 'hackathon' } }
function Get-McpClient { if ($env:ORACLE_MCP_CLIENT) { $env:ORACLE_MCP_CLIENT } else { 'print' } }

function Test-ConnExists {
    if (-not (Test-Sqlcl)) { return $false }
    try { ("conn -list" | sql -nolog 2>$null) -match "\b$(Get-ConnName)\b" } catch { $false }
}
function Test-ClaudeMcp {
    if (-not (Test-Claude)) { return $false }
    try { (claude mcp list 2>$null) -match '\boracle\b' } catch { $false }
}

function Invoke-Help {
@"
oracle-mcp setup $AppVersion — Oracle SQLcl MCP for SQL data queries.

Usage: pwsh setup.ps1 <action>

Actions:
  help      this message
  verify    check current state, change nothing
  install   scaffold config, save the SQLcl connection, register the MCP server
  cleanup   unregister the MCP server (and optionally drop the saved connection)

Config: $ConfigFile
  (copy config/oracle.env.tmpl -> config/oracle.env and fill in; gitignored)

ORACLE_MCP_CLIENT (in oracle.env): print | claude | kilo
Prerequisites: Oracle SQLcl 25.x on PATH ('sql') + a JVM.
"@ | Write-Host
}

function Invoke-Verify {
    Write-Host "=== oracle-mcp verify ===" -ForegroundColor Cyan
    $rc = 0
    if (Test-Sqlcl) { Write-Ok "SQLcl found: $((Get-Command sql).Source)" } else { Write-Warn "SQLcl missing — install 25.x"; $rc = 1 }
    if (Test-Java)  { Write-Ok "JVM found" } else { Write-Warn "java missing"; $rc = 1 }
    if (Test-Path $ConfigFile) { Write-Ok "config present: $ConfigFile" } else { Write-Warn "config absent — run install"; $rc = 1 }
    if (Test-ConnExists) { Write-Ok "saved connection '$(Get-ConnName)' present" } else { Write-Warn "connection not saved"; $rc = 1 }
    if (Test-ClaudeMcp)  { Write-Ok "Claude Code MCP 'oracle' registered" } else { Write-Warn "Claude MCP not registered (ok for print/kilo)" }
    if ($rc -eq 0) { Write-Ok "ready" } else { Write-Warn "not fully set up — see install" }
    return $rc
}

function Invoke-Install {
    Write-Host "=== oracle-mcp install ===" -ForegroundColor Cyan
    if (-not (Test-Sqlcl)) { Write-Fail "Oracle SQLcl not on PATH. Install 25.x first, then re-run."; return }

    Set-DesiredState "config file $ConfigFile" `
        { Test-Path $ConfigFile } `
        { Copy-Item (Join-Path $ConfigDir 'oracle.env.tmpl') $ConfigFile } | Out-Null
    Import-Config

    if (Test-ConnExists) {
        Write-Ok "SQLcl connection '$(Get-ConnName)' already saved — nothing to do"
    } else {
        Write-Warn "connection '$(Get-ConnName)' not saved. Save it (creds -> SQLcl secure store, NOT the model):"
        Write-Warn "    sql /nolog"
        Write-Warn "    SQL> connect -save $(Get-ConnName) -savepwd $($env:ORACLE_USER)@<easyconnect-or-tns>"
        Write-Warn "(MUTATION DEFERRED — verify connect-save syntax per SQLcl version; see README.)"
    }

    switch (Get-McpClient) {
        'claude' {
            if (Test-Claude) {
                Set-DesiredState "Claude Code MCP 'oracle'" `
                    { Test-ClaudeMcp } `
                    { claude mcp add oracle -- sql -mcp } | Out-Null
            } else { Write-Warn "ORACLE_MCP_CLIENT=claude but 'claude' not on PATH — skipping" }
        }
        'kilo' {
            Write-Info "Paste into the 'mcp' block of ~/.config/kilo/kilo.jsonc:"
            (Get-Content (Join-Path $ConfigDir 'mcp-registration.jsonc.tmpl')) -replace '\{\{ORACLE_CONN_NAME\}\}', (Get-ConnName) | Write-Host
            Write-Warn "(manual paste; do not jq-rewrite kilo.jsonc — it strips comments. See README.)"
        }
        default {
            Write-Info "ORACLE_MCP_CLIENT=print — registration snippet (change nothing):"
            (Get-Content (Join-Path $ConfigDir 'mcp-registration.jsonc.tmpl')) -replace '\{\{ORACLE_CONN_NAME\}\}', (Get-ConnName) | Write-Host
        }
    }
    Invoke-Verify | Out-Null
}

function Invoke-Cleanup {
    Write-Host "=== oracle-mcp cleanup ===" -ForegroundColor Cyan
    if ((Test-Claude) -and (Test-ClaudeMcp)) {
        Set-DesiredState "remove Claude Code MCP 'oracle'" `
            { -not (Test-ClaudeMcp) } `
            { claude mcp remove oracle } | Out-Null
    }
    Write-Ok "cleanup done (config file left in place; delete $ConfigFile by hand if desired)"
}

switch ($Action.ToLower()) {
    'help'    { Invoke-Help }
    'verify'  { Import-Config; Invoke-Verify | Out-Null }
    'install' { Import-Config; Invoke-Install }
    'cleanup' { Import-Config; Invoke-Cleanup }
    default   { Write-Fail "unknown action: $Action"; Invoke-Help; exit 1 }
}
