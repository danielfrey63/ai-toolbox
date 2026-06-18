# =============================================================================
# aiprofil — unified backend-profile switcher across two tools (PowerShell):
#   - CC  : Claude Code CLI env vars        (adapter: adapters/cc-profil.ps1)
#   - Kilo: Kilo Code config kilo.jsonc     (adapter: adapters/kilo-profil.ps1)
#
# One profile (profiles/<name>.env), two targets. MUST be dot-sourced — the CC
# target mutates the current shell's environment. The sourcing `aiprofil`
# function is wired into $PROFILE by `toolbox install --what aiprofil`.
#
# Two orthogonal enums:
#   --target  cc | kilo | both   (also a list: cc,kilo)   default: both
#   --scope   session | user | project                    default: user
#
# Scope maps per target (no analog -> skipped with a note):
#                 session     user                  project
#   cc            shell       User scope            (skip)
#   kilo          (skip)      ~/.config/kilo         ./kilo.jsonc
# =============================================================================

$APP_VERSION = '0.3.4'
$_ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$_Adapters  = Join-Path $_ScriptDir 'adapters'

# Resolve profiles once and hand it to the adapters via PROFILES_DIR.
$_new    = Join-Path $_ScriptDir 'profiles'
$_legacy = Join-Path $_ScriptDir '..\cc-profil\profiles'
if (Test-Path (Join-Path $_new '*.env'))         { $env:PROFILES_DIR = (Resolve-Path $_new).Path }
elseif (Test-Path (Join-Path $_legacy '*.env'))  { $env:PROFILES_DIR = (Resolve-Path $_legacy).Path }
else                                             { $env:PROFILES_DIR = $_new }

function _Ai-Use {
    param([string[]]$UseArgs)
    $profile = $null; $target = 'both'; $scope = 'user'
    for ($i = 0; $i -lt $UseArgs.Count; $i++) {
        $a = $UseArgs[$i]
        if ($a -eq '--target')   { $target = $UseArgs[$i + 1]; $i++ }
        elseif ($a -eq '--scope') { $scope = $UseArgs[$i + 1]; $i++ }
        elseif (-not $a.StartsWith('-')) { $profile = $a }
    }
    if (-not $profile) {
        Write-Host "Usage: aiprofil use <profile> [--target cc|kilo|both] [--scope session|user|project]" -ForegroundColor Yellow
        return
    }

    $parts = $target -split ','
    $wantCc   = ($parts -contains 'both') -or ($parts -contains 'cc')
    $wantKilo = ($parts -contains 'both') -or ($parts -contains 'kilo')
    if (-not $wantCc -and -not $wantKilo) {
        Write-Host "[WARN] --target '$target' selected nothing (use cc|kilo|both)" -ForegroundColor Yellow; return
    }

    if ($wantCc) {
        if ($scope -eq 'project') {
            Write-Host "[aiprofil] cc:   scope 'project' has no CC analog — skipped" -ForegroundColor DarkGray
        } else {
            # Dot-source so the env lands in the caller's shell.
            . (Join-Path $_Adapters 'cc-profil.ps1') use $profile --scope $scope
        }
    }
    if ($wantKilo) {
        if ($scope -eq 'session') {
            Write-Host "[aiprofil] kilo: scope 'session' has no Kilo analog — skipped" -ForegroundColor DarkGray
        } else {
            & (Join-Path $_Adapters 'kilo-profil.ps1') use $profile --scope $scope
        }
    }
}

$_action = if ($args.Count -gt 0) { $args[0] } else { 'help' }
$_rest   = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

switch ($_action) {
    'use'    { _Ai-Use -UseArgs $_rest }
    'list'   { & (Join-Path $_Adapters 'kilo-profil.ps1') list; Write-Host "CC active (session): $($env:CC_PROFILE ?? '<none>')"; Write-Host "Switch defaults: --target both | --scope user" }
    'status' { Write-Host "CC active (session): $($env:CC_PROFILE ?? '<none>')"; & (Join-Path $_Adapters 'kilo-profil.ps1') status @_rest }
    default  {
        Write-Host "aiprofil $APP_VERSION — unified profile switcher (Claude Code + Kilo)."
        Write-Host ""
        Write-Host "Usage: aiprofil <action> [args]"
        Write-Host ""
        Write-Host "Actions:"
        Write-Host "  list                          profiles + active CC/Kilo state"
        Write-Host "  status [--scope user|project] what each target points at"
        Write-Host "  use <profile> [--target ...] [--scope ...]"
        Write-Host "      --target  cc | kilo | both   (default both; list ok: cc,kilo)"
        Write-Host "      --scope   session | user | project   (default user)"
        Write-Host ""
        Write-Host "Installation: toolbox install --what aiprofil"
    }
}

Remove-Item Function:\_Ai-Use -ErrorAction SilentlyContinue
Remove-Variable _ScriptDir, _Adapters, _new, _legacy, _action, _rest -ErrorAction SilentlyContinue
