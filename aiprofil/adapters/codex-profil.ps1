# =============================================================================
# codex-profil — point the Codex CLI config (~/.codex/config.toml) at a backend
#                profile. PowerShell variant. Mirrors codex-profil.sh. Reads the
#                SAME profile files as cc-profil/kilo-profil.
# =============================================================================
# For a profile that carries CODEX_MODEL_DEPLOYMENT it patches config.toml
# (top-level model + model_provider, [model_providers.azure] block with
# base_url derived from FOUNDRY_RESOURCE) and sets AZURE_OPENAI_API_KEY from
# FOUNDRY_API_KEY — Codex refuses inline keys; env_key must reference an env
# variable. Legacy ANTHROPIC_FOUNDRY_* keys are honoured as fallback.
#
# Subscription mode (CODEX_AUTH=chatgpt) instead targets the built-in openai
# provider with the ChatGPT sign-in (codex login): sets forced_login_method,
# drops the Azure repoint, and uses CODEX_MODEL (or the Codex default) as
# model. No API key involved.
#
# Must be dot-sourced for `use` so AZURE_OPENAI_API_KEY lands in the caller's
# shell — the sourcing function is wired by `toolbox install --what codex-profil`.
#
# Scope:  session  env var in this shell (default; config.toml is per-user)
#         user     like session + persistent User scope for the env var
#         project  no Codex analog -> skipped with a note
# =============================================================================

$APP_VERSION = '0.3.12'

$_CxScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function _Cx-ResolveProfilesDir {
    if ($env:PROFILES_DIR) { return $env:PROFILES_DIR }
    $new    = Join-Path $_CxScriptDir '..\profiles'
    $legacy = Join-Path $_CxScriptDir '..\..\cc-profil\profiles'
    if (Test-Path (Join-Path $new '*.env'))    { return (Resolve-Path $new).Path }
    if (Test-Path (Join-Path $legacy '*.env')) { return (Resolve-Path $legacy).Path }
    return $new
}
$_CxProfilesDir = _Cx-ResolveProfilesDir

function _Cx-Info { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function _Cx-Ok   { param($m) Write-Host "[OK] $m"   -ForegroundColor Green }
function _Cx-Warn { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function _Cx-Fail { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }

function _Cx-ConfigFile {
    $base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    return (Join-Path $base 'config.toml')
}

# First value of KEY= in a profile file ($null if absent).
function _Cx-ProfileVal {
    param([string]$File, [string]$Key)
    $m = Select-String -Path $File -Pattern ('^' + [regex]::Escape($Key) + '=(.*)$') | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

# Replace the key inside the given section ('' = top-level) or insert it,
# creating the section header at EOF if needed. Blank lines are buffered so an
# inserted key lands at the section's end, before the separating blank line.
# Values become TOML strings.
function _Cx-TomlSet {
    param([string[]]$Lines, [string]$Section, [string]$Key, [string]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    $cur = ''; $done = $false; $nb = 0
    foreach ($raw in $Lines) {
        if ($raw -match '^\s*$') { $nb++; continue }
        if ($raw -match '^\[(?<s>[^\]]*)\]') {
            if (-not $done -and $cur -eq $Section) { $out.Add("$Key = `"$Value`""); $done = $true }
            while ($nb -gt 0) { $out.Add(''); $nb-- }
            $cur = $Matches['s']
            $out.Add($raw); continue
        }
        while ($nb -gt 0) { $out.Add(''); $nb-- }
        if (-not $done -and $cur -eq $Section -and $raw -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $out.Add("$Key = `"$Value`""); $done = $true
        } else {
            $out.Add($raw)
        }
    }
    if (-not $done) {
        if ($Section -ne '' -and $cur -ne $Section) {
            while ($nb -gt 0) { $out.Add(''); $nb-- }
            $out.Add(''); $out.Add("[$Section]")
        }
        $out.Add("$Key = `"$Value`"")
    }
    while ($nb -gt 0) { $out.Add(''); $nb-- }
    return ,$out.ToArray()
}

# Drop the key line inside the given section ('' = top-level); everything
# else passes through.
function _Cx-TomlDel {
    param([string[]]$Lines, [string]$Section, [string]$Key)
    $out = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($raw in $Lines) {
        if ($raw -match '^\[(?<s>[^\]]*)\]') { $cur = $Matches['s']; $out.Add($raw); continue }
        if ($cur -eq $Section -and $raw -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) { continue }
        $out.Add($raw)
    }
    return ,$out.ToArray()
}

function _Cx-List {
    Write-Host "Profiles ($_CxProfilesDir):"
    Get-ChildItem "$_CxProfilesDir\*.env" -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.BaseName
        if (Select-String -Path $_.FullName -Pattern '^(CODEX_MODEL_DEPLOYMENT|CODEX_AUTH)=' -Quiet) {
            Write-Host ("  {0,-16} [codex-capable]" -f $name)
        } else {
            Write-Host ("  {0,-16} (no codex block)" -f $name)
        }
    }
}

function _Cx-Status {
    $file = _Cx-ConfigFile
    _Cx-Info "target: $file"
    if (Test-Path $file) {
        $get = {
            param($key)
            $m = Select-String -Path $file -Pattern ('^\s*' + $key + '\s*=\s*"?([^"]*)"?\s*$') | Select-Object -First 1
            if ($m) { $m.Matches[0].Groups[1].Value } else { '<unset>' }
        }
        $provider = & $get 'model_provider'
        $login = & $get 'forced_login_method'
        if ($login -eq '<unset>') { $login = '<default>' }
        _Cx-Ok "model: $(& $get 'model')  provider: $provider  login: $login"
        _Cx-Info "base_url: $(& $get 'base_url')"
    } else {
        _Cx-Warn "config does not exist yet"
        $provider = '<unset>'
    }
    # The env key only matters when the azure provider is active.
    if ($provider -eq 'azure') {
        if ($env:AZURE_OPENAI_API_KEY) { _Cx-Ok "AZURE_OPENAI_API_KEY set (session)" }
        else { _Cx-Warn "AZURE_OPENAI_API_KEY not set in this shell" }
    }
}

function _Cx-Use {
    param([string[]]$UseArgs)
    $name = $null; $scope = 'session'
    for ($i = 0; $i -lt $UseArgs.Count; $i++) {
        $a = $UseArgs[$i]
        if ($a -eq '--scope') { $scope = $UseArgs[$i + 1]; $i++ }
        elseif (-not $a.StartsWith('-')) { $name = $a }
    }
    if (-not $name) { _Cx-Fail "usage: use <profile> [--scope session|user]"; return }

    if ($scope -eq 'project') {
        _Cx-Info "scope 'project' has no Codex analog — skipped."
        return
    }
    if ($scope -notin @('session', 'user')) {
        _Cx-Warn "unknown scope '$scope' — using session."
        $scope = 'session'
    }
    $doGlobal = ($scope -eq 'user')

    $f = Join-Path $_CxProfilesDir "$name.env"
    if (-not (Test-Path $f)) { _Cx-Fail "profile not found: $f"; return }

    # A profile is Codex-capable iff it names an Azure deployment
    # (CODEX_MODEL_DEPLOYMENT) or a subscription login (CODEX_AUTH=chatgpt).
    $auth       = _Cx-ProfileVal $f 'CODEX_AUTH'
    $deployment = _Cx-ProfileVal $f 'CODEX_MODEL_DEPLOYMENT'
    $model      = _Cx-ProfileVal $f 'CODEX_MODEL'
    if (-not $auth -and -not $deployment) {
        _Cx-Info "profile '$name' has no CODEX_* keys — nothing for the codex target."
        return
    }
    if ($auth -eq 'chatgpt') {
        $mode = 'chatgpt'
    } elseif ($auth) {
        _Cx-Fail "profile '$name': unknown CODEX_AUTH '$auth' (use chatgpt, or omit for Azure mode)."
        return
    } else {
        $mode = 'azure'
        $resource = _Cx-ProfileVal $f 'FOUNDRY_RESOURCE'
        if (-not $resource) { $resource = _Cx-ProfileVal $f 'ANTHROPIC_FOUNDRY_RESOURCE' }
        $apiKey = _Cx-ProfileVal $f 'FOUNDRY_API_KEY'
        if (-not $apiKey) { $apiKey = _Cx-ProfileVal $f 'ANTHROPIC_FOUNDRY_API_KEY' }
        if (-not $resource) {
            _Cx-Fail "profile '$name' sets CODEX_MODEL_DEPLOYMENT but no FOUNDRY_RESOURCE."
            return
        }
    }

    # desired-state: patch config.toml only where it deviates.
    $file = _Cx-ConfigFile
    $dir = Split-Path -Parent $file
    New-Item -ItemType Directory -Force $dir | Out-Null
    $oldText = if (Test-Path $file) { [System.IO.File]::ReadAllText($file) } else { '' }
    $nl = if ($oldText -match "`r`n") { "`r`n" } else { "`n" }
    $lines = if ($oldText) { $oldText -split "`r?`n" } else { @() }

    if ($mode -eq 'chatgpt') {
        # Subscription mode: built-in openai provider + ChatGPT sign-in.
        # Without CODEX_MODEL the model key is dropped -> Codex default.
        $lines = _Cx-TomlSet $lines '' 'model_provider' 'openai'
        $lines = _Cx-TomlSet $lines '' 'forced_login_method' 'chatgpt'
        if ($model) { $lines = _Cx-TomlSet $lines '' 'model' $model }
        else { $lines = _Cx-TomlDel $lines '' 'model' }
    } else {
        $lines = _Cx-TomlSet $lines '' 'model' $deployment
        $lines = _Cx-TomlSet $lines '' 'model_provider' 'azure'
        $lines = _Cx-TomlDel $lines '' 'forced_login_method'
        $lines = _Cx-TomlSet $lines 'model_providers.azure' 'name' 'Azure OpenAI'
        $lines = _Cx-TomlSet $lines 'model_providers.azure' 'base_url' "https://$resource.openai.azure.com/openai/v1"
        $lines = _Cx-TomlSet $lines 'model_providers.azure' 'env_key' 'AZURE_OPENAI_API_KEY'
        $lines = _Cx-TomlSet $lines 'model_providers.azure' 'wire_api' 'responses'
    }

    $newText = ($lines -join $nl)
    if (-not $newText.EndsWith($nl)) { $newText += $nl }
    if ($newText -eq $oldText) {
        _Cx-Ok "config already up to date ($file)"
    } elseif ($mode -eq 'chatgpt') {
        [System.IO.File]::WriteAllText($file, $newText)
        $shownModel = if ($model) { $model } else { '<codex default>' }
        _Cx-Ok "model -> $shownModel, provider openai, login chatgpt ($file)"
    } else {
        [System.IO.File]::WriteAllText($file, $newText)
        _Cx-Ok "model -> $deployment, provider azure ($file)"
    }

    if ($mode -eq 'chatgpt') {
        $authFile = Join-Path (Split-Path -Parent $file) 'auth.json'
        if (-not (Test-Path $authFile)) {
            _Cx-Info "no Codex login found — run 'codex login' once to sign in with the ChatGPT account."
        }
    } elseif (-not $apiKey) {
        _Cx-Warn "no FOUNDRY_API_KEY in profile — set AZURE_OPENAI_API_KEY yourself."
    } else {
        [System.Environment]::SetEnvironmentVariable('AZURE_OPENAI_API_KEY', $apiKey, 'Process')
        if ($doGlobal) { [System.Environment]::SetEnvironmentVariable('AZURE_OPENAI_API_KEY', $apiKey, 'User') }
        $scopeLabel = if ($doGlobal) { 'session + user' } else { 'session' }
        _Cx-Ok "AZURE_OPENAI_API_KEY set ($scopeLabel)"
    }
}

$_CxAction = if ($args.Count -gt 0) { $args[0] } else { 'help' }
$_CxRest   = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

switch ($_CxAction) {
    'list'   { _Cx-List }
    'status' { _Cx-Status }
    'use'    { _Cx-Use -UseArgs $_CxRest }
    default  {
        Write-Host "codex-profil $APP_VERSION — point ~/.codex/config.toml at a backend profile."
        Write-Host ""
        Write-Host "Usage: codex-profil <action> [args]"
        Write-Host ""
        Write-Host "Actions:"
        Write-Host "  list                          profiles (Codex-capable marked)"
        Write-Host "  status                        show config target + current model/provider"
        Write-Host "  use <profile> [--scope ...]   write config.toml + set AZURE_OPENAI_API_KEY"
        Write-Host "                                (--scope session|user; idempotent)"
        Write-Host ""
        Write-Host "Profiles dir: $_CxProfilesDir"
        Write-Host "Profile keys consumed:"
        Write-Host "  Azure mode:        FOUNDRY_RESOURCE, FOUNDRY_API_KEY, CODEX_MODEL_DEPLOYMENT"
        Write-Host "  Subscription mode: CODEX_AUTH=chatgpt [CODEX_MODEL]  (sign-in via codex login)"
        Write-Host "Installation: toolbox install --what codex-profil"
    }
}

Remove-Item -Path Function:\_Cx-ResolveProfilesDir, Function:\_Cx-ConfigFile, Function:\_Cx-ProfileVal, `
    Function:\_Cx-TomlSet, Function:\_Cx-TomlDel, Function:\_Cx-List, Function:\_Cx-Status, Function:\_Cx-Use, `
    Function:\_Cx-Info, Function:\_Cx-Ok, Function:\_Cx-Warn, Function:\_Cx-Fail -ErrorAction SilentlyContinue
Remove-Variable -Name _CxScriptDir, _CxProfilesDir, _CxAction, _CxRest -ErrorAction SilentlyContinue
