# Registers (or removes) the daily scheduled task that trashes empty Claude Code sessions.
# Idempotent: re-running replaces the existing task with the current definition.
# -Status reports the install state via exit code (0 = installed, 1 = not).
[CmdletBinding()]
param(
    [string[]]$Times = @('05:30', '11:30', '17:30'),
    [switch]$Uninstall,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$taskName = 'AI-Toolbox Session Cleanup'
$scriptPath = Join-Path $PSScriptRoot 'cleanup-sessions.ps1'

if ($Status) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }
}

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
$triggers = foreach ($t in $Times) { New-ScheduledTaskTrigger -Daily -At $t }
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Description 'Moves empty Claude Code sessions to ~/.claude/projects-trash and purges old trash batches (ai-toolbox tools/session-cleanup).' -Force | Out-Null
Write-Host "Registered scheduled task '$taskName' (daily at $($Times -join ', '), catch-up on missed runs) running $scriptPath"
