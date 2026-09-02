# HiddenTask.ps1 - dot-source this in a scheduled-task installer, then build the
# task action with New-HiddenTaskAction instead of New-ScheduledTaskAction:
#
#   . "<ai-toolbox>\tools\run-hidden\HiddenTask.ps1"
#   $action = New-HiddenTaskAction -FilePath (Get-TaskShell) -ArgumentList @('-NoProfile', '-File', $script)
#
# The action starts wscript.exe with run-hidden.vbs, which launches the
# executable without any console window (see run-hidden.vbs for why
# -WindowStyle Hidden is not enough). The launcher waits for the process and
# returns its exit code; -Detach returns immediately (long-running watchers).

function New-HiddenTaskAction {
    [CmdletBinding()]
    param(
        # Executable to run without a window (pwsh.exe, powershell.exe, ...).
        [Parameter(Mandatory)][string]$FilePath,
        # Arguments as separate tokens; tokens with whitespace are quoted for the
        # command line, the launcher re-quotes every token again for the child.
        [string[]]$ArgumentList = @(),
        # Return as soon as the process is started instead of waiting for it.
        [switch]$Detach,
        [string]$WorkingDirectory
    )
    $wrapper = Join-Path $PSScriptRoot 'run-hidden.vbs'
    $tokens = @('//B', '//Nologo', "`"$wrapper`"")
    if ($Detach) { $tokens += '--detach' }
    $tokens += "`"$FilePath`""
    foreach ($a in $ArgumentList) {
        if ($a -match '"') { throw "New-HiddenTaskAction: argument must not contain double quotes: $a" }
        $tokens += if ($a -match '\s') { "`"$a`"" } else { $a }
    }
    $params = @{
        Execute  = Join-Path $env:SystemRoot 'System32\wscript.exe'
        Argument = ($tokens -join ' ')
    }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }
    New-ScheduledTaskAction @params
}

# Full path of the shell a task should run: pwsh when installed, else Windows
# PowerShell 5.1. Always a full path - the scheduler resolves a bare name
# against its own PATH, and a bare "powershell.exe" fails with 0x80070002 once
# that PATH loses System32.
function Get-TaskShell {
    [CmdletBinding()]
    param([switch]$WindowsPowerShell)
    if (-not $WindowsPowerShell) {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($pwsh) { return $pwsh.Source }
    }
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
