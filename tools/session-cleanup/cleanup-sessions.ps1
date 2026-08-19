# Moves "empty" Claude Code sessions (small transcripts), sessions explicitly marked for deletion and
# redundant duplicate copies into a trash folder and purges trash entries past retention. Desired-state
# and idempotent: re-runs only act on sessions that currently match the criteria.
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
    # A session renamed to exactly this title is trashed on the next run, regardless of size and age.
    [string]$DeleteMarker = 'DELETE',
    # A leftover copy from a project handover is trashed when it carries at most this many own
    # messages beyond the split. Larger leftovers are reported instead.
    [int]$MaxHandoverMessages = 10,
    # Report what would happen without moving or deleting anything.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
# Console output carries German umlauts; without this the default OEM codepage mangles them.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$projectsDir = Join-Path $env:USERPROFILE '.claude\projects'
$trashDir = Join-Path $env:USERPROFILE '.claude\projects-trash'
$logFile = Join-Path $trashDir 'cleanup.log'

if (-not (Test-Path $projectsDir)) { Write-Host "No projects directory at $projectsDir - nothing to do."; exit 0 }
if (-not (Test-Path $trashDir)) { New-Item -ItemType Directory -Path $trashDir | Out-Null }

$script:logLines = @()
# Findings needing a human decision, collected as { Title; Body } for the desktop notification.
$script:findings = @()
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

# The /rename title of a session: $null when it was never renamed, the title otherwise. An entry whose
# title cannot be parsed yields an empty string - still "titled", so the keep-protection below stays
# conservative. The last "custom-title" entry wins, a session can be renamed repeatedly. Cached
# because three phases ask for the same titles.
$script:titleCache = @{}
function Get-CustomTitle([System.IO.FileInfo]$file) {
    if ($script:titleCache.ContainsKey($file.FullName)) { return $script:titleCache[$file.FullName] }
    $title = $null
    $hits = @(Select-String -LiteralPath $file.FullName -Pattern '"type"\s*:\s*"custom-title"')
    if ($hits) {
        $title = ''
        try { $parsed = ($hits[-1].Line | ConvertFrom-Json).customTitle } catch { $parsed = $null }
        if ($parsed) { $title = $parsed }
    }
    $script:titleCache[$file.FullName] = $title
    return $title
}

# What to call a session in a message: its /rename title when it has one, otherwise the first user
# message (what the resume picker falls back to). A renamed session must never be reported under its
# opening line - that line is usually a stale one-off and unrecognizable months later.
function Get-DisplayName([System.IO.FileInfo]$file) {
    $t = Get-CustomTitle $file
    if ($t) { return $t }
    return Get-SessionTitle $file
}

# How two copies of the same session relate: where they split, and what each side carries beyond that
# point. Transcripts are append-only JSONL, so the shared history ends at the last line both files
# have in common. Per side the own entries are counted (messages, and the timestamps that bracket
# them) - that is what tells a handover leftover apart from a branch that was really worked on.
# Message counting is a line match, not a JSON parse: an embedded '"type": "user"' inside a tool
# result can inflate the count, which only ever makes the handover check below more conservative.
function Get-Divergence([System.IO.FileInfo]$a, [System.IO.FileInfo]$b) {
    $la = [IO.File]::ReadAllLines($a.FullName)
    $lb = [IO.File]::ReadAllLines($b.FullName)
    $common = 0
    $min = [Math]::Min($la.Count, $lb.Count)
    while ($common -lt $min -and $la[$common] -ceq $lb[$common]) { $common++ }
    $info = @{ Fork = $null }
    for ($k = $common - 1; $k -ge 0; $k--) {
        $m = [regex]::Match($la[$k], '"timestamp"\s*:\s*"([^"]+)"')
        if ($m.Success) { $info.Fork = ([datetime]$m.Groups[1].Value).ToLocalTime(); break }
    }
    foreach ($side in @(@('A', $la), @('B', $lb))) {
        $key = $side[0]; $lines = $side[1]
        $messages = 0; $first = $null; $last = $null
        for ($k = $common; $k -lt $lines.Count; $k++) {
            if ($lines[$k] -match '"type"\s*:\s*"(user|assistant)"') { $messages++ }
            $m = [regex]::Match($lines[$k], '"timestamp"\s*:\s*"([^"]+)"')
            if ($m.Success) {
                $t = ([datetime]$m.Groups[1].Value).ToLocalTime()
                if (-not $first) { $first = $t }
                $last = $t
            }
        }
        $info["${key}Messages"] = $messages
        $info["${key}First"] = $first
        $info["${key}Last"] = $last
    }
    return $info
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

# --- Phase 0: sessions explicitly marked for deletion ------------------------------------------------
# A /rename title normally protects a session forever, so the opposite intent needs its own marker:
# renaming a session to "DELETE" hands it to the next run, regardless of size and age. Matched against
# the trimmed title as a whole and case-insensitively - a title that merely mentions the word
# ("DELETE-Bug") is a real name and stays. Runs before the duplicate phases so every copy of a marked
# session goes and none of them shows up as a name collision. Marked sessions go to the trash like
# everything else and stay recoverable until retention expires.
$marked = 0
foreach ($projectDir in Get-ChildItem $projectsDir -Directory) {
    foreach ($transcript in Get-ChildItem $projectDir.FullName -Filter '*.jsonl' -File) {
        $title = Get-CustomTitle $transcript
        if (-not $title -or $title.Trim() -ine $DeleteMarker) { continue }
        $label = "marked `"$title`" via /rename"
        if ($DryRun) {
            Write-Log "DRYRUN would trash $($projectDir.Name)\$($transcript.Name) ($label)"
        } elseif (Move-SessionToTrash $transcript $label) {
            $marked++
        }
    }
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
function Resolve-ProjectDir([string]$name) {
    if ($name -notmatch '^([A-Za-z])--(.+)$') { return $null }
    $root = "$($matches[1]):\"
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $stack = [Collections.Generic.Stack[object[]]]::new()
    $stack.Push(@($root, $matches[2]))
    while ($stack.Count -gt 0) {
        $cur, $rest = $stack.Pop()
        foreach ($child in Get-ChildItem -LiteralPath $cur -Directory -Force -ErrorAction SilentlyContinue) {
            $m = $child.Name -replace '[^A-Za-z0-9]', '-'
            if ($rest -ieq $m) { return $child.FullName }
            # Munged names are ambiguous ("-" may be "\", " ", "." ...), so follow every child whose
            # munged name is a component prefix of the remainder.
            if ($rest.Length -gt $m.Length -and $rest.StartsWith("$m-", 'OrdinalIgnoreCase')) {
                $stack.Push(@($child.FullName, $rest.Substring($m.Length + 1)))
            }
        }
    }
    return $null
}
$dirScore = @{}
$dirPath = @{}
foreach ($d in Get-ChildItem $projectsDir -Directory) {
    $dirPath[$d.Name] = Resolve-ProjectDir $d.Name
    $dirScore[$d.Name] = if ($dirPath[$d.Name]) { 1 } else { 0 }
}
# Short, human-readable location of a project dir: the last two components of the decoded repo path
# (the full path does not fit a toast), or the munged dir name when the path no longer exists.
function Get-DirShort([string]$name) {
    if (-not $dirPath[$name]) { return $name }
    $parts = $dirPath[$name].TrimEnd('\') -split '\\'
    if ($parts.Count -ge 2) { return ($parts[-2..-1] -join '\') }
    return $dirPath[$name]
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
            # Not contained, so the copies split at some point. Two very different situations look the
            # same here: a session that was moved to another project (the old copy stops at the move,
            # the new one continues) and a session that was genuinely worked on in both places. The
            # first kind is a leftover and can go; the second holds unique history on both sides.
            $div = Get-Divergence $other $keeper
            $name = Get-DisplayName $other
            $otherDir = Get-DirShort $other.Directory.Name
            $keeperDir = Get-DirShort $keeper.Directory.Name
            $fork = if ($div.Fork) { $div.Fork.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
            # Handover: everything this copy holds beyond the split predates the kept copy's own
            # branch, so nothing was written here after the session moved on.
            $isHandover = -not $div.ALast -or ($div.BFirst -and $div.ALast -le $div.BFirst)
            if ($isHandover -and $div.AMessages -le $MaxHandoverMessages) {
                $until = if ($div.ALast) { $div.ALast.ToString('yyyy-MM-dd HH:mm') } else { $fork }
                $label = "leftover of `"$name`" after the move to $keeperDir - $($div.AMessages) own message(s) up to $until"
                if ($DryRun) {
                    Write-Log "DRYRUN would trash $($other.Directory.Name)\$($other.Name) ($label)"
                } elseif (Move-SessionToTrash $other $label) {
                    $deduped++
                }
                continue
            }
            $lastA = if ($div.ALast) { $div.ALast.ToString('yyyy-MM-dd') } else { '?' }
            $lastB = if ($div.BLast) { $div.BLast.ToString('yyyy-MM-dd') } else { '?' }
            Write-Log ("diverged copies of `"$name`" ($($other.Name.Substring(0, 8))) split on ${fork}: " +
                "$otherDir has $($div.AMessages) own message(s) up to $lastA, " +
                "$keeperDir has $($div.BMessages) up to $lastB - keep one, trash the other")
            $script:findings += ,@{
                Title = "Session `"$name`" liegt zweimal vor"
                Body  = "Seit $fork wurde in beiden Kopien eigenständig weitergearbeitet:`n" +
                    "$otherDir - $($div.AMessages) eigene Nachrichten, zuletzt $lastA`n" +
                    "$keeperDir - $($div.BMessages) eigene Nachrichten, zuletzt $lastB`n" +
                    "Eine Kopie behalten, die andere wegwerfen."
            }
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
        $title = Get-CustomTitle $transcript
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
        Write-Log "same title `"$($t.Key)`" in $($projectDir.Name): $list - different histories, rename or trash manually"
        $script:findings += ,@{
            Title = "Zwei Sessions heissen `"$($t.Key)`""
            Body  = "In $(Get-DirShort $projectDir.Name): $list`n" +
                "Unterschiedlicher Verlauf, keine ist in der anderen enthalten. Eine umbenennen oder wegwerfen."
        }
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
        if ($null -ne (Get-CustomTitle $transcript)) { continue }

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

Write-Log "done: $marked marked, $deduped duplicate(s) and $moved empty session(s) trashed, $purged batch(es) purged"

# --- Findings notification ---------------------------------------------------------------------------
# Findings that need a human decision (diverged copies, title collisions) are written to findings.txt
# and raised as regular Windows toast notifications (one per finding, visible in the Action Center),
# because scheduled runs have no visible console. Toasts from unpackaged scripts need a registered
# AppUserModelID (HKCU, no admin required); pwsh 7 cannot project WinRT types, so the toasts are shown
# via Windows PowerShell 5.1. A failed notification never breaks the run.
if (-not $DryRun -and $script:findings.Count -gt 0) {
    try {
        $findingsFile = Join-Path $trashDir 'findings.txt'
        $header = "Session-Cleanup-Befunde vom $(Get-Date -Format 'yyyy-MM-dd HH:mm') - Auflösung: Session umbenennen (/rename) oder wegwerfen"
        $body = ($script:findings | ForEach-Object { "$($_.Title)`n$($_.Body)" }) -join "`n`n"
        Set-Content -LiteralPath $findingsFile -Value ($header + "`n`n" + $body) -Encoding UTF8

        $appId = 'AIToolbox.SessionCleanup'
        $reg = "HKCU:\Software\Classes\AppUserModelId\$appId"
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        if ((Get-ItemProperty -Path $reg -Name DisplayName -ErrorAction SilentlyContinue).DisplayName -ne 'AI-Toolbox Session Cleanup') {
            New-ItemProperty -Path $reg -Name DisplayName -Value 'AI-Toolbox Session Cleanup' -PropertyType String -Force | Out-Null
        }

        $toastCalls = foreach ($f in ($script:findings | Select-Object -First 5)) {
            $t = [Security.SecurityElement]::Escape($f.Title)
            $b = [Security.SecurityElement]::Escape($f.Body)
            "Show-Toast '<toast duration=`"long`"><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual></toast>'"
        }
        $toastScript = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
function Show-Toast([string]`$xmlText) {
    `$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    `$xml.LoadXml(`$xmlText)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$appId').Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
    Start-Sleep -Milliseconds 500
}
$($toastCalls -join "`n")
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toastScript))
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $encoded | Out-Null
    } catch {
        Write-Log "notification failed: $($_.Exception.Message)"
    }
}

if (-not $DryRun) {
    Add-Content -LiteralPath $logFile -Value $script:logLines
    # Keep the log bounded.
    $log = Get-Content -LiteralPath $logFile
    if ($log.Count -gt 5000) { $log | Select-Object -Last 2000 | Set-Content -LiteralPath $logFile }
}
