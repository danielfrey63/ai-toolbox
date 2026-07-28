# =============================================================================
# aiprofil — unified backend-profile switcher across three tools (PowerShell):
#   - CC   : Claude Code CLI env vars       (adapter: adapters/cc-profil.ps1)
#   - Kilo : Kilo Code config kilo.jsonc    (adapter: adapters/kilo-profil.ps1)
#   - Codex: Codex CLI ~/.codex/config.toml (adapter: adapters/codex-profil.ps1)
#
# One profile (profiles/<name>.env), three targets. MUST be dot-sourced — the
# CC and Codex targets mutate the current shell's environment. The sourcing
# `aiprofil` function is wired into $PROFILE by `toolbox install --what aiprofil`.
#
# Two orthogonal enums:
#   --target  cc | kilo | codex | both   (also a list: cc,codex)  default: both
#             ('both' and its alias 'all' select every target)
#   --scope   session | user | project                            default: session
#
# Default is 'session': cc writes only the current shell's env (instant). The
# User scope persists across shells but each User-scope env write broadcasts a
# blocking WM_SETTINGCHANGE (~0.5s per variable) — slow for a multi-var switch,
# so opt into it explicitly with --scope user. With the default 'session' the
# kilo target is skipped (it has no session analog).
#
# Scope maps per target (no analog -> skipped with a note):
#                 session          user                  project
#   cc            shell            User scope            (skip)
#   kilo          (skip)           ~/.config/kilo        ./kilo.jsonc
#   codex         shell + config   User scope + config   (skip)
# =============================================================================

$APP_VERSION = '0.7.26'
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
    $profile = $null; $target = 'both'; $scope = 'session'
    for ($i = 0; $i -lt $UseArgs.Count; $i++) {
        $a = $UseArgs[$i]
        if ($a -eq '--target')   { $target = $UseArgs[$i + 1]; $i++ }
        elseif ($a -eq '--scope') { $scope = $UseArgs[$i + 1]; $i++ }
        elseif (-not $a.StartsWith('-')) { $profile = $a }
    }
    if (-not $profile) {
        Write-Host "Usage: aiprofil use <profile> [--target cc|kilo|codex|both] [--scope session|user|project]" -ForegroundColor Yellow
        return
    }

    $parts = $target -split ','
    $wantAll   = ($parts -contains 'both') -or ($parts -contains 'all')
    $wantCc    = $wantAll -or ($parts -contains 'cc')
    $wantKilo  = $wantAll -or ($parts -contains 'kilo')
    $wantCodex = $wantAll -or ($parts -contains 'codex')
    if (-not $wantCc -and -not $wantKilo -and -not $wantCodex) {
        Write-Host "[WARN] --target '$target' selected nothing (use cc|kilo|codex|both)" -ForegroundColor Yellow; return
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
    if ($wantCodex) {
        if ($scope -eq 'project') {
            Write-Host "[aiprofil] codex: scope 'project' has no Codex analog — skipped" -ForegroundColor DarkGray
        } else {
            # Dot-source so AZURE_OPENAI_API_KEY lands in the caller's shell.
            . (Join-Path $_Adapters 'codex-profil.ps1') use $profile --scope $scope
        }
    }
}

$_action = if ($args.Count -gt 0) { $args[0] } else { 'help' }
$_rest   = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

switch ($_action) {
    'use'    { _Ai-Use -UseArgs $_rest }
    'list'   {
        Write-Host "Profiles ($env:PROFILES_DIR):"
        Get-ChildItem "$env:PROFILES_DIR\*.env" -ErrorAction SilentlyContinue | ForEach-Object {
            $name = $_.BaseName
            $markers = '[cc]'
            if (Select-String -Path $_.FullName -Pattern '^KILO_PROVIDER_ID=' -Quiet) { $markers += ' [kilo]' }
            if (Select-String -Path $_.FullName -Pattern '^(CODEX_MODEL_DEPLOYMENT|CODEX_AUTH)=' -Quiet) { $markers += ' [codex]' }
            if ($name -eq $env:CC_PROFILE) {
                Write-Host ("  * {0,-16} {1} (active)" -f $name, $markers) -ForegroundColor Green
            } else {
                Write-Host ("    {0,-16} {1}" -f $name, $markers)
            }
        }
        Write-Host "Switch defaults: --target both | --scope session (kilo needs --scope user)"
    }
    'status' { Write-Host "CC active (session): $($env:CC_PROFILE ?? '<none>')"; & (Join-Path $_Adapters 'kilo-profil.ps1') status @_rest; & (Join-Path $_Adapters 'codex-profil.ps1') status }
    default  {
        Write-Host "aiprofil $APP_VERSION — unified profile switcher (Claude Code + Kilo + Codex)."
        Write-Host ""
        Write-Host "Usage: aiprofil <action> [args]"
        Write-Host ""
        Write-Host "Actions:"
        Write-Host "  list                          profiles + active CC/Kilo state"
        Write-Host "  status [--scope user|project] what each target points at"
        Write-Host "  use <profile> [--target ...] [--scope ...]"
        Write-Host "      --target  cc | kilo | codex | both   (default both = all; list ok: cc,codex)"
        Write-Host "      --scope   session | user | project   (default session; kilo needs user)"
        Write-Host ""
        Write-Host "Installation: toolbox install --what aiprofil"
    }
}

Remove-Item Function:\_Ai-Use -ErrorAction SilentlyContinue
Remove-Variable _ScriptDir, _Adapters, _new, _legacy, _action, _rest -ErrorAction SilentlyContinue
