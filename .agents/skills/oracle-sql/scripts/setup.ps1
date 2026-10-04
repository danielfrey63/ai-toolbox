# =============================================================================
# oracle-sql setup – provision an Oracle MCP server (Oracle SQLcl `sql -mcp`)
#                    for natural-language SQL data queries. PowerShell variant.
# =============================================================================
# Mirrors setup.sh. Idempotent: every change is check -> mutate-if-needed ->
# re-verify. Safe to re-run. idempotent.sh is bash-only, so the desired-state
# helpers are inlined here.
#
# Usage: pwsh setup.ps1 <help|verify|install|cleanup>
# =============================================================================

param([string]$Action = 'help')

$AppVersion = '0.2.0'
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
    if (& $Check) { Write-Ok "$Desc – done"; return $true }
    Write-Fail "$Desc – verification failed after change"; return $false
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
    # SQLcl 25.x/26.x list saved connections via `connmgr list` (older
    # `conn -list` is rejected as an unknown option on 26.1).
    # NB: `connmgr list` colorizes names with ANSI escapes (e.g. ESC[0;33m...ESC[0m),
    # so a plain `\b<name>\b` fails (the 'm' before the name is \w). Strip ANSI
    # codes first, then match with alnum-only boundaries. Use [char]27 for ESC
    # (PS 5.1 has no `e escape – it would match a literal 'e').
    try {
        $out = (("connmgr list`nexit") | sql -nolog 2>$null) -join "`n"
        $esc = [char]27
        $clean = [regex]::Replace($out, "$esc\[[0-9;]*m", '')
        $clean -match "(?<![A-Za-z0-9])$(Get-ConnName)(?![A-Za-z0-9])"
    } catch { $false }
}
function Test-ClaudeMcp {
    if (-not (Test-Claude)) { return $false }
    try { (claude mcp list 2>$null) -match '\boracle\b' } catch { $false }
}

# --- Kilo Code (~/.config/kilo/kilo.jsonc) ----------------------------------
# $KiloLegacyMarker is the token written by installs made under the skill's
# former name (oracle-skill). It is still recognised: install replaces such a
# block with the current one, cleanup removes it.
$KiloMarker       = 'oracle-sql:managed'
$KiloLegacyMarker = 'oracle-skill:managed'
# Any managed block (current or legacy), markers inclusive; the end marker must
# carry the same token as the start marker.
$KiloBlockRegex = [regex]("(?s)[ \t]*//>>> (?<mk>" + [regex]::Escape($KiloMarker) + '|' + [regex]::Escape($KiloLegacyMarker) + ').*?[ \t]*//<<< \k<mk>.*?(\r?\n)')

function Get-KiloConfig {
    if ($env:ORACLE_KILO_CONFIG) { return $env:ORACLE_KILO_CONFIG }
    $home_ = [Environment]::GetFolderPath('UserProfile')
    foreach ($c in @("$home_/.config/kilo/kilo.jsonc", "$home_/.config/kilo.jsonc")) {
        if (Test-Path $c) { return $c }
    }
    return "$home_/.config/kilo/kilo.jsonc"   # default target if none exists yet
}

# The managed "oracle" block (marker lines inclusive) sliced from the template.
# Markers anchored to start-of-line so the template's descriptive header (which
# quotes the marker text mid-line) is not mistaken for the block.
function Get-KiloManagedBlock {
    $tmpl = Join-Path $ConfigDir 'mcp-registration.jsonc.tmpl'
    # -Encoding UTF8: PS 5.1 would otherwise decode the BOM-less template as ANSI
    # and mangle its non-ASCII characters.
    $lines = Get-Content -LiteralPath $tmpl -Encoding UTF8
    $out = @(); $p = $false
    foreach ($l in $lines) {
        if ($l -match "^//>>> $([regex]::Escape($KiloMarker))") { $p = $true }
        if ($p) { $out += $l }
        if ($l -match "^//<<< $([regex]::Escape($KiloMarker))") { $p = $false }
    }
    return $out
}

function Get-KiloRaw {
    $f = Get-KiloConfig
    if (Test-Path $f) { [IO.File]::ReadAllText($f) } else { $null }
}

# Desired state: the current managed block is present and no legacy block is.
function Test-KiloRegistered {
    $raw = Get-KiloRaw
    ($null -ne $raw) -and $raw.Contains($KiloMarker) -and -not $raw.Contains($KiloLegacyMarker)
}

# Any managed block (current or legacy) present? Drives cleanup.
function Test-KiloAnyBlock {
    $raw = Get-KiloRaw
    ($null -ne $raw) -and ($raw.Contains($KiloMarker) -or $raw.Contains($KiloLegacyMarker))
}

# Insert the managed block as the FIRST child of the `mcp` object. Any existing
# managed block (current or legacy) is removed first, so a legacy install is
# migrated in place.
function Install-Kilo {
    $f = Get-KiloConfig
    if (-not (Test-Path $f)) { Write-Warn "Kilo config not found: $f"; return $false }
    $raw = [IO.File]::ReadAllText($f)
    $nl  = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $block = ((Get-KiloManagedBlock | ForEach-Object { '    ' + $_ }) -join $nl) + $nl
    $stripped = $KiloBlockRegex.Replace($raw, '')
    # insert as FIRST child of the `mcp` object (after its opener line)
    $re = [regex]'(?m)^([ \t]*"mcp"[ \t]*:[ \t]*\{[ \t]*\r?\n)'
    if (-not $re.IsMatch($stripped)) { return $false }
    $new = $re.Replace($stripped, { param($m) $m.Groups[1].Value + $block }, 1)
    if (-not $new.Contains($KiloMarker)) { return $false }
    Copy-Item -LiteralPath $f -Destination "$f.bak" -Force
    [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding $false))
    return $true
}

# Remove every managed block (current and legacy, markers inclusive).
function Remove-Kilo {
    $f = Get-KiloConfig
    if (-not (Test-Path $f)) { return $true }
    $raw = [IO.File]::ReadAllText($f)
    $new = $KiloBlockRegex.Replace($raw, '')
    Copy-Item -LiteralPath $f -Destination "$f.bak" -Force
    [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding $false))
    return $true
}

function Invoke-Help {
@"
oracle-sql setup $AppVersion – Oracle SQLcl MCP for SQL data queries.

Usage: pwsh setup.ps1 <action>

Actions:
  help      this message
  verify    check current state, change nothing
  install   scaffold config, save the SQLcl connection, register the MCP server
  cleanup   unregister the MCP server (and optionally drop the saved connection)

Config: $ConfigFile
  (copy config/oracle.env.tmpl -> config/oracle.env and fill in; gitignored)

ORACLE_MCP_CLIENT (in oracle.env): print | claude | kilo
  kilo inserts/removes the 'oracle' entry in Kilo's kilo.jsonc idempotently,
  preserving comments (no jq). Path: ORACLE_KILO_CONFIG, else
  ~/.config/kilo/kilo.jsonc, else ~/.config/kilo.jsonc.
  Blocks with the legacy marker '$KiloLegacyMarker' are replaced on install
  and removed on cleanup.
Prerequisites: Oracle SQLcl 25.x/26.x on PATH ('sql') + a JVM.
"@ | Write-Host
}

function Invoke-Verify {
    Write-Host "=== oracle-sql verify ===" -ForegroundColor Cyan
    $rc = 0
    if (Test-Sqlcl) { Write-Ok "SQLcl found: $((Get-Command sql).Source)" } else { Write-Warn "SQLcl missing – install 25.x/26.x"; $rc = 1 }
    if (Test-Java)  { Write-Ok "JVM found" } else { Write-Warn "java missing"; $rc = 1 }
    if (Test-Path $ConfigFile) { Write-Ok "config present: $ConfigFile" } else { Write-Warn "config absent – run install"; $rc = 1 }
    if (Test-ConnExists) { Write-Ok "saved connection '$(Get-ConnName)' present" } else { Write-Warn "connection not saved"; $rc = 1 }
    switch (Get-McpClient) {
        'kilo'   {
            if (Test-KiloRegistered) { Write-Ok "Kilo MCP 'oracle' registered in $(Get-KiloConfig)" }
            elseif (Test-KiloAnyBlock) { Write-Warn "legacy '$KiloLegacyMarker' block found – run install to migrate"; $rc = 1 }
            else { Write-Warn "Kilo MCP not registered – run install"; $rc = 1 }
        }
        'claude' { if (Test-ClaudeMcp) { Write-Ok "Claude Code MCP 'oracle' registered" } else { Write-Warn "Claude MCP not registered – run install"; $rc = 1 } }
        default  { if (Test-ClaudeMcp) { Write-Ok "Claude Code MCP 'oracle' registered" } else { Write-Warn "Claude MCP not registered (ok for print)" } }
    }
    if ($rc -eq 0) { Write-Ok "ready" } else { Write-Warn "not fully set up – see install" }
    return $rc
}

function Invoke-Install {
    Write-Host "=== oracle-sql install ===" -ForegroundColor Cyan
    if (-not (Test-Sqlcl)) { Write-Fail "Oracle SQLcl not on PATH. Install 25.x/26.x first, then re-run."; return 1 }

    Set-DesiredState "config file $ConfigFile" `
        { Test-Path $ConfigFile } `
        { Copy-Item (Join-Path $ConfigDir 'oracle.env.tmpl') $ConfigFile } | Out-Null
    Import-Config

    if (Test-ConnExists) {
        Write-Ok "SQLcl connection '$(Get-ConnName)' already saved – nothing to do"
    } else {
        Write-Warn "connection '$(Get-ConnName)' not saved. Save it (creds -> SQLcl secure store, NOT the model):"
        Write-Warn "    sql /nolog"
        Write-Warn "    SQL> connect -save $(Get-ConnName) -savepwd $($env:ORACLE_USER)@<easyconnect-or-tns>"
        Write-Warn "(MUTATION DEFERRED – see README 'Deferred mutations' for the connect-save syntax per SQLcl version.)"
    }

    switch (Get-McpClient) {
        'claude' {
            if (Test-Claude) {
                Set-DesiredState "Claude Code MCP 'oracle'" `
                    { Test-ClaudeMcp } `
                    { claude mcp add oracle -- sql -mcp } | Out-Null
            } else { Write-Warn "ORACLE_MCP_CLIENT=claude but 'claude' not on PATH – skipping" }
        }
        'kilo' {
            $kf = Get-KiloConfig
            if (-not (Test-Path $kf)) {
                Write-Warn "Kilo config not found: $kf"
                Write-Warn "Create it or set ORACLE_KILO_CONFIG, then re-run. Manual snippet for the 'mcp' block:"
                Get-KiloManagedBlock | Write-Host
            } elseif (Test-KiloRegistered) {
                Write-Ok "Kilo MCP 'oracle' already present in $kf – nothing to do"
            } elseif (Install-Kilo) {
                Write-Ok "registered 'oracle' in $kf (backup: $kf.bak)"
            } else {
                Write-Warn "could not auto-insert (no 'mcp' opener line found). Paste this by hand:"
                Get-KiloManagedBlock | Write-Host
            }
        }
        default {
            Write-Info "ORACLE_MCP_CLIENT=print – registration snippet (change nothing):"
            (Get-Content -LiteralPath (Join-Path $ConfigDir 'mcp-registration.jsonc.tmpl') -Encoding UTF8) -replace '\{\{ORACLE_CONN_NAME\}\}', (Get-ConnName) | Write-Host
        }
    }
    return (Invoke-Verify)
}

function Invoke-Cleanup {
    Write-Host "=== oracle-sql cleanup ===" -ForegroundColor Cyan
    if ((Test-Claude) -and (Test-ClaudeMcp)) {
        Set-DesiredState "remove Claude Code MCP 'oracle'" `
            { -not (Test-ClaudeMcp) } `
            { claude mcp remove oracle } | Out-Null
    }
    if (Test-KiloAnyBlock) {
        Set-DesiredState "remove Kilo MCP 'oracle' from $(Get-KiloConfig)" `
            { -not (Test-KiloAnyBlock) } `
            { Remove-Kilo | Out-Null } | Out-Null
    } else {
        Write-Ok "Kilo MCP 'oracle' not present – nothing to remove"
    }
    if (Test-ConnExists) {
        Write-Warn "connection drop deferred – on SQLcl 26.1 run it manually:"
        Write-Warn "    sql /nolog"
        Write-Warn "    SQL> connmgr delete $(Get-ConnName)"
    } else {
        Write-Ok "no saved connection '$(Get-ConnName)' – nothing to drop"
    }
    Write-Ok "cleanup done (config file left in place; delete $ConfigFile by hand if desired)"
}

# Exit code mirrors setup.sh: verify/install return 0 only when fully set up.
function Get-ExitCode { param($Result) [int]($Result | Select-Object -Last 1) }

switch ($Action.ToLower()) {
    'help'    { Invoke-Help }
    'verify'  { Import-Config; exit (Get-ExitCode (Invoke-Verify)) }
    'install' { Import-Config; exit (Get-ExitCode (Invoke-Install)) }
    'cleanup' { Import-Config; Invoke-Cleanup }
    default   { Write-Fail "unknown action: $Action"; Invoke-Help; exit 1 }
}
