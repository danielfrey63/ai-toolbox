# Registers (or removes) the daily scheduled task that trashes empty Claude Code sessions.
# Idempotent: re-running replaces the existing task with the current definition.
[CmdletBinding()]
param(
    [string]$Time = '05:30',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$taskName = 'AI-Toolbox Session Cleanup'
$scriptPath = Join-Path $PSScriptRoot 'cleanup-sessions.ps1'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task '$taskName'."
    } else {
        Write-Host "Scheduled task '$taskName' is not registered - nothing to do."
    }
    return
}

# Prefer pwsh when available; fall back to Windows PowerShell.
$shell = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $shell) { $shell = (Get-Command powershell).Source }

$action = New-ScheduledTaskAction -Execute $shell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description 'Moves empty Claude Code sessions to ~/.claude/projects-trash and purges old trash batches (ai-toolbox tools/session-cleanup).' -Force | Out-Null
Write-Host "Registered scheduled task '$taskName' (daily at $Time, catch-up on missed runs) running $scriptPath"
