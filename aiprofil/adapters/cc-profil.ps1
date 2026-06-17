# =============================================================================
# cc-profil — local Claude Code profile switcher (PowerShell). CC-env adapter.
# =============================================================================
# Must be dot-sourced — it modifies the current shell's environment. The
# sourcing `cc-profil` function is wired into $PROFILE by:
#   toolbox install --what cc-profil
# (catalog entry: type=bin, source=true).
#
# A profile is a profiles/<name>.env file of KEY=VALUE pairs. `use` clears the
# previously-set "managed vars" (profiles/.managed-vars) and exports the new
# ones. With --scope user (alias --global) the change persists in the User
# scope; otherwise it only affects the current session. POST_ACTIVATE_CMD runs
# after activation.
#
# Relocated under aiprofil/adapters/. Profiles resolve with a legacy fallback
# (env PROFILES_DIR > ..\profiles > ..\..\cc-profil\profiles) so installs that
# still carry profiles under the old path keep working without a re-install.
# =============================================================================

$APP_VERSION = '0.3.2'

$_ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function _Resolve-ProfilesDir {
    if ($env:PROFILES_DIR) { return $env:PROFILES_DIR }
    $new    = Join-Path $_ScriptDir '..\profiles'
    $legacy = Join-Path $_ScriptDir '..\..\cc-profil\profiles'
    if (Test-Path (Join-Path $new '*.env'))    { return (Resolve-Path $new).Path }
    if (Test-Path (Join-Path $legacy '*.env')) { return (Resolve-Path $legacy).Path }
    return $new
}

$_ProfilesDir     = _Resolve-ProfilesDir
$_ManagedVarsFile = Join-Path $_ProfilesDir '.managed-vars'

function _Get-ManagedVars {
    if (Test-Path $_ManagedVarsFile) {
        Get-Content $_ManagedVarsFile | Where-Object { $_ -match '^[A-Z_]' }
    }
}

function _Do-List {
    $activeSession = $env:CC_PROFILE
    $activeGlobal  = [System.Environment]::GetEnvironmentVariable('CC_PROFILE', 'User')
    Write-Host "Profiles ($_ProfilesDir):"
    $found = $false
    Get-ChildItem "$_ProfilesDir\*.env" -ErrorAction SilentlyContinue | ForEach-Object {
        $found = $true
        $name = $_.BaseName
        $isSession = ($name -eq $activeSession)
        $isGlobal  = ($name -eq $activeGlobal)
        if ($isSession -and $isGlobal) {
            Write-Host "  * $name  (active, global)" -ForegroundColor Green
        } elseif ($isSession) {
            Write-Host "  * $name  (active, session)" -ForegroundColor Green
        } elseif ($isGlobal) {
            Write-Host "  * $name  (global)" -ForegroundColor DarkGreen
        } else {
            Write-Host "    $name"
        }
    }
    if (-not $found) { Write-Host "  (no .env profiles found)" }
}

# use <profile> [--scope session|user] [--global]
function _Do-Use {
    param([string[]]$UseArgs)

    $profile  = $null
    $scope    = 'session'
    for ($i = 0; $i -lt $UseArgs.Count; $i++) {
        $a = $UseArgs[$i]
        if ($a -eq '--global') { $scope = 'user' }
        elseif ($a -eq '--scope') { $scope = $UseArgs[$i + 1]; $i++ }
        elseif (-not $a.StartsWith('-')) { $profile = $a }
    }

    if (-not $profile) {
        Write-Host "Usage: cc-profil use <profile> [--scope session|user]" -ForegroundColor Yellow
        return
    }

    if ($scope -eq 'project') {
        Write-Host "[cc-profil] scope 'project' has no CC analog — skipped." -ForegroundColor DarkGray
        return
    }
    if ($scope -notin @('session', 'user')) {
        Write-Host "[WARN] unknown scope '$scope' — using session." -ForegroundColor Yellow
        $scope = 'session'
    }
    $doGlobal = ($scope -eq 'user')

    $envFile = Join-Path $_ProfilesDir "$profile.env"
    if (-not (Test-Path $envFile)) {
        Write-Host "[WARN] profile '$profile' not found: $envFile" -ForegroundColor Yellow
        _Do-List
        return
    }

    # Unset the previous profile's managed vars.
    _Get-ManagedVars | ForEach-Object {
        [System.Environment]::SetEnvironmentVariable($_, $null, 'Process')
        if ($doGlobal) { [System.Environment]::SetEnvironmentVariable($_, $null, 'User') }
    }

    # Load the new profile. KILO_* keys belong to the kilo-profil adapter
    # (they configure a file edit, not the shell env) — don't export them.
    $postCmd = $null
    Get-Content $envFile | Where-Object { $_ -match '^[A-Z_][A-Z0-9_]*=' } | ForEach-Object {
        $key, $val = $_ -split '=', 2
        if ($key -eq 'POST_ACTIVATE_CMD') { $postCmd = $val; return }
        if ($key -eq 'CC_PROFILE') { return }   # set explicitly below
        if ($key -like 'KILO_*') { return }
        [System.Environment]::SetEnvironmentVariable($key, $val, 'Process')
        if ($doGlobal) { [System.Environment]::SetEnvironmentVariable($key, $val, 'User') }
    }

    [System.Environment]::SetEnvironmentVariable('CC_PROFILE', $profile, 'Process')
    if ($doGlobal) { [System.Environment]::SetEnvironmentVariable('CC_PROFILE', $profile, 'User') }

    $scopeLabel = $(if ($doGlobal) { 'session + user' } else { 'session' })
    Write-Host "[cc-profil] profile '$profile' activated ($scopeLabel)." -ForegroundColor Green

    if ($postCmd) {
        Write-Host "[cc-profil] running: $postCmd" -ForegroundColor Cyan
        Invoke-Expression $postCmd
    }
}

# clear --global — remove the global (User-scope) profile.
function _Do-Clear {
    param([string[]]$ClearArgs)

    $doGlobal = $ClearArgs -contains '--global'
    if (-not $doGlobal) {
        Write-Host "Usage: cc-profil clear --global" -ForegroundColor Yellow
        Write-Host "  Removes all managed env vars from the User scope (persistent)."
        return
    }

    $activeGlobal = [System.Environment]::GetEnvironmentVariable('CC_PROFILE', 'User')
    if (-not $activeGlobal) {
        Write-Host "[cc-profil] no global profile set." -ForegroundColor Yellow
        return
    }

    _Get-ManagedVars | ForEach-Object {
        [System.Environment]::SetEnvironmentVariable($_, $null, 'User')
    }
    Write-Host "[cc-profil] global profile '$activeGlobal' removed (User scope cleared)." -ForegroundColor Green
    Write-Host "           Env vars in the current session are unchanged." -ForegroundColor DarkGray
}

$_action    = $(if ($args.Count -gt 0) { $args[0] } else { 'help' })
$_remaining = $(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() })

switch ($_action) {
    'list'  { _Do-List }
    'use'   { _Do-Use -UseArgs $_remaining }
    'clear' { _Do-Clear -ClearArgs $_remaining }
    default {
        Write-Host "cc-profil — local Claude Code profile switcher (CC-env adapter)"
        Write-Host ""
        Write-Host "Usage: cc-profil <action> [args]"
        Write-Host ""
        Write-Host "Actions:"
        Write-Host "  list                          List available profiles"
        Write-Host "  use <profile> [--scope ...]   Activate a profile (--scope session|user; --global == user)"
        Write-Host "  clear --global                Remove the global profile"
        Write-Host ""
        Write-Host "Installation (one-time, wires the sourcing function):"
        Write-Host "  toolbox install --what cc-profil"
    }
}

Remove-Item -Path Function:\_Get-ManagedVars, Function:\_Do-List, Function:\_Do-Use, Function:\_Do-Clear, Function:\_Resolve-ProfilesDir -ErrorAction SilentlyContinue
Remove-Variable -Name _ScriptDir, _ProfilesDir, _ManagedVarsFile, _action, _remaining -ErrorAction SilentlyContinue
