# Moves "empty" Claude Code sessions (small transcripts) and redundant duplicate copies into a trash
# folder and purges trash entries past retention. Desired-state and idempotent: re-runs only act on
# sessions that currently match the criteria.
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

$todayBatch = Join-Path $trashDir (Get-Date -Format 'yyyy-MM-dd')

# Moves a transcript plus its sidecar directory into today's trash batch. Returns $true on success;
# a locked transcript means the session is open right now and is left alone.
function Move-SessionToTrash([System.IO.FileInfo]$transcript, [string]$label) {
    $sessionId = [IO.Path]::GetFileNameWithoutExtension($transcript.Name)
    $sidecar = Join-Path $transcript.DirectoryName $sessionId
    $target = Join-Path $todayBatch $transcript.Directory.Name
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    try {
        Move-Item -LiteralPath $transcript.FullName -Destination $target -Force
        if (Test-Path $sidecar -PathType Container) {
            $sidecarTarget = Join-Path $target $sessionId
            if (Test-Path $sidecarTarget) { Remove-Item -LiteralPath $sidecarTarget -Recurse -Force -Confirm:$false }
            Move-Item -LiteralPath $sidecar -Destination $target -Force
        }
        Write-Log "trashed $($transcript.Directory.Name)\$($transcript.Name) ($label)"
        return $true
    } catch {
        Write-Log "skipped $($transcript.Directory.Name)\$($transcript.Name): $($_.Exception.Message)"
        return $false
    }
}

# Last activity of a transcript: the newest inner "timestamp" beats the file mtime, because resume
# pickers, cloud bridges and sync tools touch files without adding content - mtime alone would
# re-protect old sessions forever. Files without inner timestamps (bridge stubs) fall back to mtime.
# Byte-based tail read: Get-Content -Tail is prohibitively slow on multi-MB single-line transcripts.
function Get-LastActivity([System.IO.FileInfo]$file) {
    try {
        $fs = [IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $len = [int][Math]::Min(262144, $fs.Length)
            $fs.Seek(-$len, 'End') | Out-Null
            $buf = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) {
                $n = $fs.Read($buf, $read, $len - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        } finally { $fs.Close() }
        $m = [regex]::Matches([Text.Encoding]::UTF8.GetString($buf), '"timestamp"\s*:\s*"([^"]+)"')
        if ($m.Count -gt 0) { return ([datetime]$m[$m.Count - 1].Groups[1].Value).ToLocalTime() }
    } catch {}
    return $file.LastWriteTime
}

# True when $small's full content is a byte prefix of $big (identical files included).
function Test-PrefixOf([System.IO.FileInfo]$small, [System.IO.FileInfo]$big) {
    if ($small.Length -gt $big.Length) { return $false }
    $bufS = [IO.File]::ReadAllBytes($small.FullName)
    $fs = [IO.File]::Open($big.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        $bufB = New-Object byte[] $bufS.Length
        $read = 0
        while ($read -lt $bufS.Length) {
            $n = $fs.Read($bufB, $read, $bufS.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } finally { $fs.Close() }
    if ($read -ne $bufS.Length) { return $false }
    return [Linq.Enumerable]::SequenceEqual($bufS, $bufB)
}

# --- Phase 1: duplicate copies of the same session across project dirs -------------------------------
# Tree moves keep the old-path copy (transfer-cc-sessions). A copy that is byte-identical to - or a
# strict prefix of - the kept copy carries no extra information and goes to trash. Diverged copies are
# reported and left alone.
$deduped = 0
# Liveness per project dir - among equal-content copies the copy in the dir the user works in today
# must survive, or the session disappears from the resume picker. Neither the cwd recorded inside a
# copy (may point one or two migrations back) nor the file mtime (touched by pickers and sync tools)
# identifies the current location. The munged dir name itself is the only ground truth: walk existing
# directories from the drive root and match munged component names to see whether the dir still
# corresponds to an openable path.
function Test-LiveProjectDir([string]$name) {
    if ($name -notmatch '^([A-Za-z])--(.+)$') { return $false }
    $root = "$($matches[1]):\"
    if (-not (Test-Path -LiteralPath $root)) { return $false }
    $stack = [Collections.Generic.Stack[object[]]]::new()
    $stack.Push(@($root, $matches[2]))
    while ($stack.Count -gt 0) {
        $cur, $rest = $stack.Pop()
        foreach ($child in Get-ChildItem -LiteralPath $cur -Directory -Force -ErrorAction SilentlyContinue) {
            $m = $child.Name -replace '[^A-Za-z0-9]', '-'
            if ($rest -ieq $m) { return $true }
            # Munged names are ambiguous ("-" may be "\", " ", "." ...), so follow every child whose
            # munged name is a component prefix of the remainder.
            if ($rest.Length -gt $m.Length -and $rest.StartsWith("$m-", 'OrdinalIgnoreCase')) {
                $stack.Push(@($child.FullName, $rest.Substring($m.Length + 1)))
            }
        }
    }
    return $false
}
$dirScore = @{}
foreach ($d in Get-ChildItem $projectsDir -Directory) {
    $dirScore[$d.Name] = if (Test-LiveProjectDir $d.Name) { 1 } else { 0 }
}
$dupGroups = Get-ChildItem "$projectsDir\*\*.jsonl" -File | Group-Object Name | Where-Object Count -gt 1
foreach ($g in $dupGroups) {
    $ranked = @($g.Group | Sort-Object -Property `
        @{ Expression = { $dirScore[$_.Directory.Name] }; Descending = $true },
        @{ Expression = 'Length'; Descending = $true },
        @{ Expression = 'LastWriteTime'; Descending = $true })
    $keeper = $ranked[0]
    foreach ($other in ($ranked | Select-Object -Skip 1)) {
        if (Test-PrefixOf $other $keeper) {
            if ($DryRun) {
                Write-Log "DRYRUN would trash duplicate $($other.Directory.Name)\$($other.Name) (contained in $($keeper.Directory.Name))"
            } elseif (Move-SessionToTrash $other "duplicate, contained in $($keeper.Directory.Name)") {
                $deduped++
            }
        } else {
            Write-Log "kept diverged copy $($other.Directory.Name)\$($other.Name) (differs from $($keeper.Directory.Name) - review manually)"
        }
    }
}

# --- Phase 2: empty sessions -------------------------------------------------------------------------
$cutoff = (Get-Date).AddDays(-$MinAgeDays)
$moved = 0
foreach ($projectDir in Get-ChildItem $projectsDir -Directory) {
    foreach ($transcript in Get-ChildItem $projectDir.FullName -Filter '*.jsonl' -File) {
        $sessionId = [IO.Path]::GetFileNameWithoutExtension($transcript.Name)
        $sidecar = Join-Path $projectDir.FullName $sessionId

        $totalSize = $transcript.Length
        $lastActivity = Get-LastActivity $transcript
        if (Test-Path $sidecar -PathType Container) {
            $sidecarFiles = Get-ChildItem $sidecar -Recurse -File
            $totalSize += ($sidecarFiles | Measure-Object Length -Sum).Sum
            $sidecarLast = ($sidecarFiles | Measure-Object LastWriteTime -Maximum).Maximum
            if ($sidecarLast -and $sidecarLast -gt $lastActivity) { $lastActivity = $sidecarLast }
        }

        if ($totalSize -ge $MaxSizeBytes) { continue }
        if ($lastActivity -ge $cutoff) { continue }

        $sizeKB = [math]::Round($totalSize / 1KB, 1)
        $label = "${sizeKB}KB, last activity $($lastActivity.ToString('yyyy-MM-dd'))"
        if ($DryRun) {
            Write-Log "DRYRUN would trash $($projectDir.Name)\$($transcript.Name) ($label)"
        } elseif (Move-SessionToTrash $transcript $label) {
            $moved++
        }
    }
}

# --- Phase 3: purge trash batches past retention. Batch folders are named yyyy-MM-dd (trash date). ---
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

Write-Log "done: $deduped duplicate(s) and $moved empty session(s) trashed, $purged batch(es) purged"

if (-not $DryRun) {
    Add-Content -LiteralPath $logFile -Value $script:logLines
    # Keep the log bounded.
    $log = Get-Content -LiteralPath $logFile
    if ($log.Count -gt 5000) { $log | Select-Object -Last 2000 | Set-Content -LiteralPath $logFile }
}
