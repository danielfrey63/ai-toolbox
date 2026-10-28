# Re-points Claude Desktop (Code tab) sessions at the folder their transcript
# actually lives in.
#
# The desktop app keeps its own metadata per session
# (%APPDATA%\Claude\claude-code-sessions\<account>\<org>\local_<id>.json),
# groups the sidebar by its "cwd" and resumes the session there. Tools that
# move transcripts between ~/.claude/projects dirs (transfer-cc-sessions.ps1,
# move-session.ps1) leave that metadata alone, so moved sessions keep showing
# up under – and resuming in – the old folder.
#
# For every desktop session the transcript <cliSessionId>.jsonl is looked up
# in all project dirs. Copies whose project dir decodes to an existing folder
# win, then the newest one (last recorded timestamp); cwd and originCwd are set
# to that copy's folder.
#
# When no copy lives in an existing folder any more (the project folder itself
# was moved or deleted), -Map names the new home. Keys are old folder paths
# (prefix match, longest wins) or desktop session ids (local_..., always win,
# also for sessions that are not orphaned). The transcript and its sidecar dir
# are then copied into the target's project dir – additive like
# transfer-cc-sessions; session-cleanup trashes the old copy once it is a
# redundant duplicate.
#
#   .\relocate-desktop-sessions.ps1                               # dry-run
#   .\relocate-desktop-sessions.ps1 -Only local_<id> -Apply       # try one session first
#   .\relocate-desktop-sessions.ps1 -Map @{ 'D:\old\proj' = 'D:\new\proj' } -Apply
#
# -Map takes a hashtable, so call the script from a pwsh prompt (pwsh -File
# passes strings only).
#
# Claude Desktop must be quit for -Apply: it holds the metadata in memory and
# writes it back. Every changed file is backed up first. Desired-state: a
# re-run changes nothing once all sessions point at their transcript's folder.

[CmdletBinding()]
param(
    # Old folder path or desktop session id -> folder the session belongs in.
    [hashtable]$Map = @{},
    # Restrict the run to these desktop session ids (with or without "local_").
    [string[]]$Only,
    [string]$DesktopDir = (Join-Path $env:APPDATA 'Claude'),
    [string]$ProjectsDir = (Join-Path $env:USERPROFILE '.claude\projects'),
    [string]$BackupDir = (Join-Path $env:TEMP "desktop-sessions-backup\$(Get-Date -Format 'yyyyMMdd-HHmmss')"),
    [switch]$Apply,
    # Allow -Apply while Claude Desktop is running.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# Session titles carry German umlauts; without this the default OEM codepage mangles them.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
# Get-CCProjectName, Resolve-ProjectDir, Get-ProjectRoot, Get-LastActivity, Copy-TreeAdditive
. (Join-Path $PSScriptRoot 'CCProjects.ps1')

$sessionsDir = Join-Path $DesktopDir 'claude-code-sessions'
if (-not (Test-Path -LiteralPath $sessionsDir)) {
    Write-Host "No Claude Desktop sessions at $sessionsDir – nothing to do."
    exit 0
}

# Electron holds its single-instance lockfile open while the app runs.
function Test-DesktopRunning {
    $lock = Join-Path $DesktopDir 'lockfile'
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try { ([IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')).Dispose(); return $false }
    catch { return $true }
}
if ($Apply -and -not $Force -and (Test-DesktopRunning)) {
    throw "Claude Desktop is running – quit it (tray icon > Quit) and re-run. It keeps the session metadata in memory and would write the old folders back."
}

# --- inputs -------------------------------------------------------------------------------------------
$Only = @($Only | Where-Object { $_ } | ForEach-Object { if ($_ -like 'local_*') { $_ } else { "local_$_" } })

$idMap = @{}
$pathMap = @()
foreach ($key in $Map.Keys) {
    $value = ([string]$Map[$key]).TrimEnd('\')
    if ($key -like 'local_*') { $idMap[$key] = $value }
    else { $pathMap += [pscustomobject]@{ Old = ([string]$key).TrimEnd('\'); New = $value } }
}
$pathMap = @($pathMap | Sort-Object { $_.Old.Length } -Descending)

function Get-MappedPath([string]$path) {
    if (-not $path) { return $null }
    foreach ($entry in $pathMap) {
        if ($path.Equals($entry.Old, 'OrdinalIgnoreCase')) { return $entry.New }
        if ($path.StartsWith("$($entry.Old)\", 'OrdinalIgnoreCase')) { return $entry.New + $path.Substring($entry.Old.Length) }
    }
    return $null
}

# All top-level transcripts, indexed once: session uuid -> copies across project dirs.
$copies = @{}
foreach ($f in Get-ChildItem (Join-Path $ProjectsDir '*\*.jsonl') -File -ErrorAction SilentlyContinue) {
    if (-not $copies.ContainsKey($f.BaseName)) { $copies[$f.BaseName] = [Collections.Generic.List[IO.FileInfo]]::new() }
    $copies[$f.BaseName].Add($f)
}

# Project dir name -> existing folder (or $null), decoded lazily against the file system.
$folderOf = @{}
function Get-Folder([string]$projectName) {
    if (-not $folderOf.ContainsKey($projectName)) { $folderOf[$projectName] = Resolve-ProjectDir $projectName }
    return $folderOf[$projectName]
}

function Test-SameFolder([string]$a, [string]$b) {
    return [bool]($a -and $b -and ((Get-CCProjectName $a) -ieq (Get-CCProjectName $b)))
}

$jsonOptions = [System.Text.Json.JsonSerializerOptions]::new()
$jsonOptions.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
$utf8 = [Text.UTF8Encoding]::new($false)

# --- sessions -----------------------------------------------------------------------------------------
$stats = [ordered]@{ ok = 0; moved = 0; copied = 0; orphaned = 0; noTranscript = 0; skipped = 0 }
foreach ($file in Get-ChildItem -LiteralPath $sessionsDir -Filter 'local_*.json' -File -Recurse) {
    $text = [IO.File]::ReadAllText($file.FullName, $utf8)
    $node = [System.Text.Json.Nodes.JsonNode]::Parse($text)
    $sid = [string]$node['sessionId']
    if (-not $sid) { $sid = $file.BaseName }
    if ($Only.Count -and $sid -notin $Only) { continue }

    $cwd = [string]$node['cwd']
    $originCwd = [string]$node['originCwd']
    $title = [string]$node['title']
    $label = "$(if ($title) { $title } else { $sid })$(if ([string]$node['isArchived'] -eq 'true') { ' [archived]' })"
    $cli = [string]$node['cliSessionId']
    $found = if ($cli -and $copies.ContainsKey($cli)) { $copies[$cli] } else { @() }

    if (-not $found.Count) {
        Write-Host "[NO-TRANSCRIPT] $label  ($cwd) – nothing left to resume, archive it in the app"
        $stats.noTranscript++
        continue
    }

    # Live copies first, then the newest; on a tie the copy the session already points at (stable re-runs).
    $curName = Get-CCProjectName $cwd
    $best = @($found | Sort-Object -Property `
        @{ Expression = { [bool](Get-Folder $_.Directory.Name) }; Descending = $true },
        @{ Expression = { Get-LastActivity $_ }; Descending = $true },
        @{ Expression = { $_.Directory.Name -ieq $curName }; Descending = $true },
        @{ Expression = 'Length'; Descending = $true })[0]

    $target = Get-Folder $best.Directory.Name
    $needsCopy = $false
    if ($idMap.ContainsKey($sid)) {
        $target = $idMap[$sid]
        $needsCopy = $true
    } elseif (-not $target) {
        $oldRoot = Get-ProjectRoot $best.Directory.FullName $best.Directory.Name
        $target = Get-MappedPath $oldRoot
        if (-not $target) { $target = Get-MappedPath $cwd }
        if (-not $target) {
            Write-Host "[ORPHAN] $label – transcript in $($best.Directory.Name), folder $(if ($oldRoot) { $oldRoot } else { $cwd }) is gone; name its new home with -Map"
            $stats.orphaned++
            continue
        }
        $needsCopy = $true
    }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        Write-Host "[SKIP] $label – target folder $target does not exist"
        $stats.skipped++
        continue
    }

    # Transcript into the target's project dir (orphans and explicit session moves only).
    $destDir = Join-Path $ProjectsDir (Get-CCProjectName $target)
    if ($needsCopy -and -not ($best.Directory.Name -ieq (Split-Path $destDir -Leaf))) {
        $dest = Join-Path $destDir $best.Name
        $sidecar = Join-Path $best.DirectoryName $best.BaseName
        if (Test-Path -LiteralPath $dest) {
            Write-Host "[KEEP] $label – $(Split-Path $destDir -Leaf) already holds a copy, left untouched"
        } else {
            Write-Host "[COPY] $label – transcript $($best.Directory.Name) -> $(Split-Path $destDir -Leaf)"
            if ($Apply) {
                New-Item -ItemType Directory -Force $destDir | Out-Null
                Copy-Item -LiteralPath $best.FullName $dest
                if (Test-Path -LiteralPath $sidecar) { [void](Copy-TreeAdditive $sidecar (Join-Path $destDir $best.BaseName)) }
            }
            $stats.copied++
        }
    }

    # Metadata: keep the current cwd when it already denotes the target folder.
    $newCwd = if ((Test-SameFolder $cwd $target) -and (Test-Path -LiteralPath $cwd -PathType Container)) { $cwd } else { $target }
    # originCwd differs from cwd only for worktree sessions (cwd = worktree, originCwd = repo) – keep
    # it there unless the folder is gone.
    $newOrigin = $originCwd
    if ($originCwd -and ($originCwd -ieq $cwd -or -not (Test-Path -LiteralPath $originCwd -PathType Container))) { $newOrigin = $newCwd }
    if ($newCwd -ceq $cwd -and $newOrigin -ceq $originCwd) { $stats.ok++; continue }

    Write-Host "[MOVE] $label`n         $cwd`n      -> $newCwd"
    if ($Apply) {
        $backup = Join-Path $BackupDir $file.FullName.Substring($sessionsDir.TrimEnd('\').Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $backup) | Out-Null
        Copy-Item -LiteralPath $file.FullName $backup
        $node['cwd'] = $newCwd
        if ($originCwd) { $node['originCwd'] = $newOrigin }
        $json = $node.ToJsonString($jsonOptions) + $(if ($text.EndsWith("`n")) { "`n" } else { '' })
        $tmp = "$($file.FullName).tmp"
        [IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $file.FullName -Force
    }
    $stats.moved++
}

# --- summary ------------------------------------------------------------------------------------------
$verb = if ($Apply) { 'moved' } else { 'would move' }
$parts = @("$($stats.ok) ok", "$($stats.moved) $verb")
if ($stats.copied) { $parts += "$($stats.copied) transcript cop$(if ($stats.copied -eq 1) { 'y' } else { 'ies' })" }
if ($stats.orphaned) { $parts += "$($stats.orphaned) orphaned (-Map)" }
if ($stats.noTranscript) { $parts += "$($stats.noTranscript) without transcript" }
if ($stats.skipped) { $parts += "$($stats.skipped) skipped" }
Write-Host "[TOTAL] $($parts -join ', ')$(if (-not $Apply) { ' – dry-run, use -Apply' })"
if ($Apply -and $stats.moved) { Write-Host "[BACKUP] $BackupDir" }
