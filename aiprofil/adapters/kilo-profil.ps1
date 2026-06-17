# =============================================================================
# kilo-profil — point the Kilo Code config (kilo.jsonc) at a backend profile.
#               PowerShell variant. Mirrors kilo-profil.sh. Reads the SAME
#               profile files as cc-profil (aiprofil/profiles, legacy fallback).
# =============================================================================
# Repoints the top-level "model"/"small_model" to <KILO_PROVIDER_ID>/<model>,
# via a brace-depth-aware editor that preserves // comments, $schema and
# formatting (no JSON reserialize). Missing provider blocks are emitted for
# review, never blind-written.
#
# Scope:  user  -> ~/.config/kilo/kilo.jsonc (default)
#         project -> ./kilo.jsonc or ./.kilo/kilo.jsonc
#
# Usage: pwsh kilo-profil.ps1 <help|list|status|use> [args]
# =============================================================================

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args2)

$AppVersion = '0.1.0'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Resolve-ProfilesDir {
    if ($env:PROFILES_DIR) { return $env:PROFILES_DIR }
    $new    = Join-Path $ScriptDir '..\profiles'
    $legacy = Join-Path $ScriptDir '..\..\cc-profil\profiles'
    if (Test-Path (Join-Path $new '*.env'))    { return (Resolve-Path $new).Path }
    if (Test-Path (Join-Path $legacy '*.env')) { return (Resolve-Path $legacy).Path }
    return $new
}
$ProfilesDir = Resolve-ProfilesDir

function Write-Info { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[OK] $m"   -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }

function Resolve-Target {
    param([string]$Scope = 'user')
    switch ($Scope) {
        'user' {
            $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
            return (Join-Path $base 'kilo\kilo.jsonc')
        }
        'project' {
            # Absolute paths: [System.IO.File] uses the .NET cwd, not the PS
            # location, so a relative '.\kilo.jsonc' would resolve wrong.
            if (Test-Path '.\kilo.jsonc')        { return (Resolve-Path '.\kilo.jsonc').Path }
            if (Test-Path '.\.kilo\kilo.jsonc')  { return (Resolve-Path '.\.kilo\kilo.jsonc').Path }
            return (Join-Path (Get-Location).Path 'kilo.jsonc')
        }
        default { Write-Fail "unknown scope: $Scope (use user|project)"; return $null }
    }
}

function Import-Profile {
    param([string]$Name)
    $f = Join-Path $ProfilesDir "$Name.env"
    if (-not (Test-Path $f)) { Write-Fail "profile not found: $f"; return $false }
    Get-Content $f | Where-Object { $_ -match '^[A-Z_][A-Z0-9_]*=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        [Environment]::SetEnvironmentVariable($k, $v, 'Process')
    }
    return $true
}

# Replace the value of the depth-1 (root) key only; ignore nested keys of the
# same name. Brace counting skips "strings" and // comments. Preserves the
# file's existing newline style and all comments. Returns $true if it changed.
function Set-TopLevel {
    param([string]$File, [string]$Key, [string]$NewVal)
    $text = [System.IO.File]::ReadAllText($File)
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = $text -split "`r?`n"
    $depth = 0; $done = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $lines) {
        $clean = ''; $instr = $false; $i = 0; $n = $raw.Length
        while ($i -lt $n) {
            $c = $raw[$i]
            if (-not $instr -and ($i + 1) -lt $n -and $c -eq '/' -and $raw[$i + 1] -eq '/') { break }
            if ($c -eq '"') { $instr = -not $instr; $i++; continue }
            if (-not $instr) { $clean += $c }
            $i++
        }
        if (-not $done -and $depth -eq 1 -and $raw -match ('^\s*"' + [regex]::Escape($Key) + '"\s*:')) {
            $indent = [regex]::Match($raw, '^\s*').Value
            $comma  = if ($raw -match ',\s*(//.*)?$') { ',' } else { '' }
            $out.Add("$indent`"$Key`": `"$NewVal`"$comma")
            $done = $true
        } else {
            $out.Add($raw)
        }
        foreach ($ch in $clean.ToCharArray()) {
            if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth-- }
        }
    }
    if (-not $done) { return $false }
    [System.IO.File]::WriteAllText($File, ($out -join $nl))
    return $true
}

function Test-ProviderPresent {
    param([string]$File, [string]$Pid2)
    (Get-Content $File -Raw) -match ('"' + [regex]::Escape($Pid2) + '"\s*:')
}

function Get-CurrentModel {
    param([string]$File)
    if (-not (Test-Path $File)) { return $null }
    # top-level model is the first depth<=1 "model" line; good enough to display.
    $m = Select-String -Path $File -Pattern '^\s{0,2}"model"\s*:\s*"([^"]*)"' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Invoke-Help {
@"
kilo-profil $AppVersion — point kilo.jsonc at a backend profile.

Usage: pwsh kilo-profil.ps1 <action> [args]

Actions:
  help                          this message
  list                          profiles (Kilo-capable marked) + active model
  status [--scope user|project] show target file + current model
  use <profile> [--scope ...]   repoint model/small_model (idempotent)

Profiles dir: $ProfilesDir
Profile keys consumed: KILO_PROVIDER_ID, KILO_ACTIVE_MODEL, KILO_SMALL_MODEL
"@ | Write-Host
}

function Invoke-List {
    $active = Get-CurrentModel (Resolve-Target 'user')
    Write-Info "active (user kilo.jsonc) model: $($active ?? '<none>')"
    Write-Host "Profiles ($ProfilesDir):"
    Get-ChildItem "$ProfilesDir\*.env" -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.BaseName
        if (Select-String -Path $_.FullName -Pattern '^KILO_PROVIDER_ID=' -Quiet) {
            Write-Host ("  {0,-16} [kilo-capable]" -f $name)
        } else {
            Write-Host ("  {0,-16} (cc-only)" -f $name)
        }
    }
}

function Invoke-Status {
    param([string]$Scope = 'user')
    $file = Resolve-Target $Scope
    Write-Info "scope: $Scope"
    Write-Info "target: $file"
    if (Test-Path $file) { Write-Ok "current model: $(Get-CurrentModel $file)" }
    else { Write-Warn "target file does not exist yet" }
}

function Invoke-Use {
    param([string[]]$UseArgs)
    $name = $null; $scope = 'user'
    for ($i = 0; $i -lt $UseArgs.Count; $i++) {
        $a = $UseArgs[$i]
        if ($a -eq '--scope') { $scope = $UseArgs[$i + 1]; $i++ }
        elseif (-not $a.StartsWith('-')) { $name = $a }
    }
    if (-not $name) { Write-Fail "usage: use <profile> [--scope user|project]"; return }

    if (-not (Import-Profile $name)) { return }
    if (-not ($env:KILO_PROVIDER_ID -and $env:KILO_ACTIVE_MODEL)) {
        Write-Info "profile '$name' has no KILO_* keys — nothing for the kilo target (cc-only profile)."
        return
    }

    $file = Resolve-Target $scope
    if (-not (Test-Path $file)) {
        Write-Fail "kilo config not found: $file"
        Write-Warn "launch Kilo once (or create the file) so there is something to repoint."
        return
    }

    if (-not (Test-ProviderPresent $file $env:KILO_PROVIDER_ID)) {
        Write-Warn "provider '$($env:KILO_PROVIDER_ID)' not in $file — repoint skipped. Add the provider block first (see README)."
        return
    }

    $targetModel = "$($env:KILO_PROVIDER_ID)/$($env:KILO_ACTIVE_MODEL)"
    if (Set-TopLevel $file 'model' $targetModel) { Write-Ok "model -> $targetModel  ($file)" }
    else { Write-Fail "no top-level `"model`" key in $file — not changed" }

    if ($env:KILO_SMALL_MODEL) {
        $targetSmall = "$($env:KILO_PROVIDER_ID)/$($env:KILO_SMALL_MODEL)"
        if (Set-TopLevel $file 'small_model' $targetSmall) { Write-Ok "small_model -> $targetSmall" }
        else { Write-Warn "no top-level `"small_model`" key — left as is" }
    }
}

$action = if ($Args2.Count -gt 0) { $Args2[0] } else { 'help' }
$rest   = if ($Args2.Count -gt 1) { $Args2[1..($Args2.Count - 1)] } else { @() }

switch ($action) {
    'help'   { Invoke-Help }
    'list'   { Invoke-List }
    'status' { if ($rest.Count -ge 2 -and $rest[0] -eq '--scope') { Invoke-Status $rest[1] } else { Invoke-Status 'user' } }
    'use'    { Invoke-Use -UseArgs $rest }
    default  { Write-Fail "unknown action: $action"; Invoke-Help; exit 1 }
}
