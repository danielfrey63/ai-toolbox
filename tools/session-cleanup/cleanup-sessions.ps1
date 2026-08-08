# Moves "empty" Claude Code sessions (small transcripts) into a trash folder and purges trash entries past retention.
# Desired-state and idempotent: re-runs only act on sessions that currently match the criteria.
#
# Scope: top-level session transcripts %USERPROFILE%\.claude\projects\<project>\<session>.jsonl plus their
# sidecar directory <session>\ (subagent transcripts). Never touches memory\ or any other project content.
[CmdletBinding()]
param(
    # Sessions whose transcript + sidecar total is below this size count as "empty".
    [long]$MaxSizeBytes = 250KB,
    # Never touch sessions with activity within this window (they may still be in use).
    [int]$MinAgeDays = 3,
    # Trash entries older than this are deleted permanently.
    [int]$RetentionDays = 30,
    # Report what would happen without moving or deleting anything.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$projectsDir = Join-Path $env:USERPROFILE '.claude\projects'
$trashDir = Join-Path $env:USERPROFILE '.claude\projects-trash'
$logFile = Join-Path $trashDir 'cleanup.log'

if (-not (Test-Path $projectsDir)) { Write-Host "No projects directory at $projectsDir - nothing to do."; exit 0 }
if (-not (Test-Path $trashDir)) { New-Item -ItemType Directory -Path $trashDir | Out-Null }

$script:logLines = @()
function Write-Log([string]$Message) {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message
    $script:logLines += $line
    Write-Host $line
}

$cutoff = (Get-Date).AddDays(-$MinAgeDays)
$todayBatch = Join-Path $trashDir (Get-Date -Format 'yyyy-MM-dd')
$moved = 0

foreach ($projectDir in Get-ChildItem $projectsDir -Directory) {
    foreach ($transcript in Get-ChildItem $projectDir.FullName -Filter '*.jsonl' -File) {
        $sessionId = [IO.Path]::GetFileNameWithoutExtension($transcript.Name)
        $sidecar = Join-Path $projectDir.FullName $sessionId

        $totalSize = $transcript.Length
        $lastActivity = $transcript.LastWriteTime
        $sidecarExists = Test-Path $sidecar -PathType Container
        if ($sidecarExists) {
            $sidecarFiles = Get-ChildItem $sidecar -Recurse -File
            $totalSize += ($sidecarFiles | Measure-Object Length -Sum).Sum
            $sidecarLast = ($sidecarFiles | Measure-Object LastWriteTime -Maximum).Maximum
            if ($sidecarLast -and $sidecarLast -gt $lastActivity) { $lastActivity = $sidecarLast }
        }

        if ($totalSize -ge $MaxSizeBytes) { continue }
        if ($lastActivity -ge $cutoff) { continue }

        $sizeKB = [math]::Round($totalSize / 1KB, 1)
        if ($DryRun) {
            Write-Log "DRYRUN would trash $($projectDir.Name)\$($transcript.Name) (${sizeKB}KB, last activity $($lastActivity.ToString('yyyy-MM-dd')))"
            continue
        }

        $target = Join-Path $todayBatch $projectDir.Name
        if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        try {
            Move-Item -LiteralPath $transcript.FullName -Destination $target -Force
            if ($sidecarExists) {
                $sidecarTarget = Join-Path $target $sessionId
                if (Test-Path $sidecarTarget) { Remove-Item -LiteralPath $sidecarTarget -Recurse -Force -Confirm:$false }
                Move-Item -LiteralPath $sidecar -Destination $target -Force
            }
            Write-Log "trashed $($projectDir.Name)\$($transcript.Name) (${sizeKB}KB, last activity $($lastActivity.ToString('yyyy-MM-dd')))"
            $moved++
        } catch {
            # A locked transcript means the session is open right now - leave it alone.
            Write-Log "skipped $($projectDir.Name)\$($transcript.Name): $($_.Exception.Message)"
        }
    }
}

# Purge trash batches past retention. Batch folders are named yyyy-MM-dd (their trash date).
$purgeCutoff = (Get-Date).Date.AddDays(-$RetentionDays)
$purged = 0
foreach ($batch in Get-ChildItem $trashDir -Directory) {
    $batchDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($batch.Name, 'yyyy-MM-dd', $null, 'None', [ref]$batchDate)) { continue }
    if ($batchDate -ge $purgeCutoff) { continue }
    if ($DryRun) {
        Write-Log "DRYRUN would purge trash batch $($batch.Name)"
        continue
    }
    Remove-Item -LiteralPath $batch.FullName -Recurse -Force -Confirm:$false
    Write-Log "purged trash batch $($batch.Name)"
    $purged++
}

Write-Log "done: $moved session(s) trashed, $purged batch(es) purged"

if (-not $DryRun) {
    Add-Content -LiteralPath $logFile -Value $script:logLines
    # Keep the log bounded.
    $log = Get-Content -LiteralPath $logFile
    if ($log.Count -gt 5000) { $log | Select-Object -Last 2000 | Set-Content -LiteralPath $logFile }
}
