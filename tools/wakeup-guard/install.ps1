# Registers (or removes) the wakeup-guard PreToolUse hook in ~/.claude/settings.json and drops
# leftovers of its predecessors (session-keepwarm Stop hook, keepwarm-guard) while at it. Idempotent: re-running replaces the entry.
# -Status reports the install state via exit code (0 = installed, 1 = not).
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
$marker = 'wakeup-guard/guard.sh'
$legacy = 'keepwarm'
# Git Bash takes forward slashes; the hook runs through the same bash the repo hooks already use.
$guard = (Join-Path $PSScriptRoot 'guard.sh').Replace('\', '/')
$command = "bash `"$guard`""

if ($Status) {
    if ((Test-Path $settingsFile) -and ((Get-Content $settingsFile -Raw) -match [regex]::Escape($marker))) { exit 0 } else { exit 1 }
}

$settings = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
foreach ($event in 'PreToolUse', 'Stop') {
    if (-not $settings.hooks.PSObject.Properties[$event]) { $settings.hooks | Add-Member -NotePropertyName $event -NotePropertyValue @() }
}

# Drop our entries and any legacy keepwarm hook (Stop or PreToolUse), then re-add unless uninstalling.
$pre = @($settings.hooks.PreToolUse | Where-Object { -not ($_.hooks | Where-Object { $_.command -like "*$marker*" -or $_.command -like "*$legacy*" }) })
$stop = @($settings.hooks.Stop | Where-Object { -not ($_.hooks | Where-Object { $_.command -like "*$legacy*" }) })
if (-not $Uninstall) {
    $pre += [pscustomobject]@{ matcher = 'ScheduleWakeup'; hooks = @([pscustomobject]@{ type = 'command'; command = $command; timeout = 10 }) }
}
$settings.hooks.PreToolUse = $pre
$settings.hooks.Stop = $stop
foreach ($event in 'PreToolUse', 'Stop') {
    if ($settings.hooks.$event.Count -eq 0) { $settings.hooks.PSObject.Properties.Remove($event) }
}
if ($settings.hooks.PSObject.Properties.Value.Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }

$settings | ConvertTo-Json -Depth 32 | Set-Content $settingsFile -Encoding UTF8

if ($Uninstall) {
    Write-Host "Removed wakeup-guard PreToolUse hook from $settingsFile."
} else {
    Write-Host "Registered wakeup-guard PreToolUse hook in $settingsFile (takes effect for newly started sessions)."
}
