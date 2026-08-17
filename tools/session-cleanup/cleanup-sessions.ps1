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
    # Never touch sessions with activity within this window (0 = no age guard). Sessions worth
    # keeping carry a /rename title and are protected regardless of age; open sessions are skipped
    # via their file lock.
    [int]$MinAgeHours = 0,
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

# Human-readable session label: the first real user message (what the resume picker shows). Injected
# meta messages (caveats, command wrappers, hook feedback, keepwarm ticks) are skipped.
function Get-SessionTitle([System.IO.FileInfo]$file) {
    try {
        foreach ($line in Get-Content -LiteralPath $file.FullName -TotalCount 50) {
            if ($line -notmatch '"type"\s*:\s*"user"') { continue }
            try { $entry = $line | ConvertFrom-Json } catch { continue }
            $content = $entry.message.content
            if ($content -isnot [string]) { continue }
            if ($content -match '^(Caveat:|<|\[keepwarm-tick\]|Stop hook feedback:)') { continue }
            $t = ($content -replace '\s+', ' ').Trim()
            if ($t.Length -gt 60) { $t = $t.Substring(0, 57) + '...' }
            return $t
        }
    } catch {}
    return '(no user message)'
}

# Timestamp of the last entry two diverged copies still share - the fork happened after this moment.
function Get-ForkPoint([System.IO.FileInfo]$a, [System.IO.FileInfo]$b) {
    try {
        $bytesA = [IO.File]::ReadAllBytes($a.FullName)
        $bytesB = [IO.File]::ReadAllBytes($b.FullName)
        $max = [Math]::Min($bytesA.Length, $bytesB.Length)
        $common = 0
        # Block compare first, then byte-scan inside the first differing block.
        while ($common -lt $max) {
            $len = [int][Math]::Min(65536, $max - $common)
            $segA = [ArraySegment[byte]]::new($bytesA, $common, $len)
            $segB = [ArraySegment[byte]]::new($bytesB, $common, $len)
            if (-not [Linq.Enumerable]::SequenceEqual($segA, $segB)) { break }
            $common += $len
        }
        $end = [Math]::Min($common + 65536, $max)
        while ($common -lt $end -and $bytesA[$common] -eq $bytesB[$common]) { $common++ }
        if ($common -eq 0) { return $null }
        $m = [regex]::Matches([Text.Encoding]::UTF8.GetString($bytesA, 0, $common), '"timestamp"\s*:\s*"([^"]+)"')
        if ($m.Count -gt 0) { return ([datetime]$m[$m.Count - 1].Groups[1].Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    } catch {}
    return $null
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
    # Compare each copy against ALL kept ones, not only the keeper: two identical old copies that both
    # diverge from the keeper still contain each other.
    $kept = [Collections.Generic.List[System.IO.FileInfo]]::new()
    $kept.Add($keeper)
    foreach ($other in ($ranked | Select-Object -Skip 1)) {
        $container = $kept | Where-Object { Test-PrefixOf $other $_ } | Select-Object -First 1
        if ($container) {
            if ($DryRun) {
                Write-Log "DRYRUN would trash duplicate $($other.Directory.Name)\$($other.Name) (contained in $($container.Directory.Name))"
            } elseif (Move-SessionToTrash $other "duplicate, contained in $($container.Directory.Name)") {
                $deduped++
            }
        } else {
            $sizeMB = [math]::Round($other.Length / 1MB, 1)
            $info = "`"$(Get-SessionTitle $other)`", ${sizeMB}MB, last activity $((Get-LastActivity $other).ToString('yyyy-MM-dd'))"
            $fork = Get-ForkPoint $other $keeper
            $forkTxt = if ($fork) { ", forked from $($keeper.Directory.Name) copy after $fork" } else { '' }
            Write-Log "kept diverged copy $($other.Directory.Name)\$($other.Name) ($info$forkTxt - review manually)"
            $kept.Add($other)
        }
    }
}

# --- Phase 1b: sessions sharing (or containing) a custom title ---------------------------------------
# /rename titles live as "custom-title" entries inside the transcript and survive forks and bridge
# continuations, so different session files can show the same name in the resume picker. For every
# pair whose titles are equal or literal substrings of each other, a merge is attempted: with the own
# sessionId neutralized (every entry embeds it, so raw bytes can never match across files), an exact
# prefix overlap proves one file carries nothing beyond the other and it goes to trash. Pairs without
# exact overlap are genuinely different conversations - those are only reported for a manual rename
# or trash decision.
foreach ($projectDir in Get-ChildItem $projectsDir -Directory) {
    $titled = @()
    foreach ($transcript in Get-ChildItem $projectDir.FullName -Filter '*.jsonl' -File) {
        $hits = @(Select-String -LiteralPath $transcript.FullName -Pattern '"type"\s*:\s*"custom-title"')
        if (-not $hits) { continue }
        # The last entry wins: a session can be renamed multiple times.
        try { $title = ($hits[-1].Line | ConvertFrom-Json).customTitle } catch { continue }
        if (-not $title) { continue }
        $titled += ,@{ File = $transcript; Title = $title }
    }
    $gone = @{}
    for ($i = 0; $i -lt $titled.Count; $i++) {
        for ($j = $i + 1; $j -lt $titled.Count; $j++) {
            if ($gone[$i] -or $gone[$j]) { continue }
            $ti = $titled[$i].Title; $tj = $titled[$j].Title
            if ($ti -ne $tj -and -not $ti.Contains($tj) -and -not $tj.Contains($ti)) { continue }
            $pair = @($titled[$i], $titled[$j]) | Sort-Object { $_.File.Length }
            $small = $pair[0]; $big = $pair[1]
            try {
                $ns = [IO.File]::ReadAllText($small.File.FullName).Replace($small.File.BaseName, 'SID')
                $nb = [IO.File]::ReadAllText($big.File.FullName).Replace($big.File.BaseName, 'SID')
            } catch { continue }
            if (-not $nb.StartsWith($ns)) { continue }
            $label = "titled `"$($small.Title)`", content prefix of $($big.File.Name.Substring(0, 8)) `"$($big.Title)`""
            if ($DryRun) {
                Write-Log "DRYRUN would trash duplicate $($projectDir.Name)\$($small.File.Name) ($label)"
                $gone[$(if ($small -eq $titled[$i]) { $i } else { $j })] = $true
            } elseif (Move-SessionToTrash $small.File $label) {
                $deduped++
                $gone[$(if ($small -eq $titled[$i]) { $i } else { $j })] = $true
            }
        }
    }
    $titles = @{}
    for ($i = 0; $i -lt $titled.Count; $i++) {
        if ($gone[$i]) { continue }
        $t = $titled[$i].Title
        if (-not $titles.ContainsKey($t)) { $titles[$t] = [Collections.Generic.List[object]]::new() }
        $titles[$t].Add($titled[$i].File)
    }
    foreach ($t in $titles.GetEnumerator()) {
        if ($t.Value.Count -lt 2) { continue }
        $list = ($t.Value | ForEach-Object {
            "$($_.Name.Substring(0, 8)) ($([math]::Round($_.Length / 1MB, 1))MB, last $((Get-LastActivity $_).ToString('yyyy-MM-dd')))"
        }) -join ', '
        Write-Log "same title `"$($t.Key)`" in $($projectDir.Name): $list - no exact overlap, rename or trash manually"
    }
}

# --- Phase 2: empty sessions -------------------------------------------------------------------------
$cutoff = (Get-Date).AddHours(-$MinAgeHours)
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
        # A /rename title marks a session the user intends to keep - never auto-trash those.
        if (Select-String -LiteralPath $transcript.FullName -Pattern '"type"\s*:\s*"custom-title"' -Quiet) { continue }

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
