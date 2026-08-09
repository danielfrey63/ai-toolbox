# Registers (or removes) the session-keepwarm Stop hook in ~/.claude/settings.json.
# Idempotent: re-running updates the existing hook entry in place.
# -Status reports the install state via exit code (0 = installed, 1 = not).
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
$hookScript = Join-Path $PSScriptRoot 'stop-hook.ps1'
$marker = 'session-keepwarm\stop-hook.ps1'

if ($Status) {
    if ((Test-Path $settingsFile) -and ((Get-Content $settingsFile -Raw) -match 'session-keepwarm')) { exit 0 } else { exit 1 }
}

# Prefer pwsh when available; fall back to Windows PowerShell.
$shell = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $shell) { $shell = (Get-Command powershell).Source }
$command = "`"$shell`" -NoProfile -ExecutionPolicy Bypass -File `"$hookScript`""

$settings = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
if (-not $settings.hooks.PSObject.Properties['Stop']) { $settings.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @() }

# Drop any existing keepwarm entries, then re-add unless uninstalling.
$stopHooks = @($settings.hooks.Stop | Where-Object { -not ($_.hooks | Where-Object { $_.command -like "*$marker*" }) })
if (-not $Uninstall) {
    $stopHooks += [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $command; timeout = 30 }) }
}
$settings.hooks.Stop = $stopHooks
if ($settings.hooks.Stop.Count -eq 0) { $settings.hooks.PSObject.Properties.Remove('Stop') }
if ($settings.hooks.PSObject.Properties.Value.Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }

$settings | ConvertTo-Json -Depth 32 | Set-Content $settingsFile -Encoding UTF8

if ($Uninstall) {
    Write-Host "Removed session-keepwarm Stop hook from $settingsFile."
} else {
    Write-Host "Registered session-keepwarm Stop hook in $settingsFile (takes effect for newly started sessions)."
}
