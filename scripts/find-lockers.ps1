# Lists the processes holding open handles under a path - files AND
# directories (a process whose current working directory is inside the tree
# blocks a Move-Item of that tree, which a per-file open test never detects).
#
# Uses Sysinternals handle.exe, downloaded once into %TEMP% on first use.
#
#   pwsh -File find-lockers.ps1 -Path "D:\some\directory"
#
# Note: without elevation, handles of elevated/system processes stay
# invisible. If nothing is found but the move still fails, re-run elevated.

param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$PassThru  # emit objects (Process, Pid, Paths) instead of printing
)

$ErrorActionPreference = 'Stop'

$toolDir = Join-Path $env:TEMP 'sysinternals-handle'
$exe = Join-Path $toolDir 'handle64.exe'
if (-not (Test-Path $exe)) {
    New-Item -ItemType Directory -Force $toolDir | Out-Null
    $zip = Join-Path $toolDir 'Handle.zip'
    Invoke-WebRequest 'https://download.sysinternals.com/files/Handle.zip' -OutFile $zip
    Expand-Archive $zip $toolDir -Force
}

# handle.exe matches the argument as substring against all open handle paths
$out = & $exe -accepteula -nobanner $Path 2>&1

$lockers = [ordered]@{}
foreach ($line in $out) {
    if ($line -match '^(?<proc>.+?)\s+pid:\s*(?<procid>\d+)\s+.*?[0-9A-F]+:\s+(?<hpath>.+)$') {
        $key = '{0} (PID {1})' -f $Matches.proc.Trim(), $Matches.procid
        if (-not $lockers.Contains($key)) { $lockers[$key] = @() }
        $lockers[$key] += $Matches.hpath.Trim()
    }
}

if ($PassThru) {
    foreach ($k in $lockers.Keys) {
        if ($k -match '^(?<proc>.+)\s\(PID\s(?<procid>\d+)\)$') {
            [pscustomobject]@{
                Process = $Matches.proc
                Pid     = [int]$Matches.procid
                Paths   = @($lockers[$k] | Select-Object -Unique)
            }
        }
    }
    return
}

if ($lockers.Count -eq 0) {
    Write-Host "No open handles found under: $Path"
    Write-Host "If a move still fails, the holder may be an elevated process - re-run this script as administrator."
}
else {
    foreach ($k in $lockers.Keys) {
        Write-Host "`n$k"
        $lockers[$k] | Select-Object -Unique -First 5 | ForEach-Object { Write-Host "  $_" }
        if (($lockers[$k] | Select-Object -Unique).Count -gt 5) { Write-Host "  ... and more" }
    }
}
