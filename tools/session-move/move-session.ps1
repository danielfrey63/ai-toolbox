# Move a Claude Code session (transcript + sidecar dir) from one project to another,
# optionally setting a /rename title on the way.
#
# A session lives in ~/.claude/projects/<project-slug>/ as <session-id>.jsonl plus an
# optional <session-id>/ sidecar directory (subagents, tool-results). The project
# association IS the directory - moving both is all it takes. /rename titles are
# "custom-title" JSONL lines inside the transcript (the last one wins), so a title
# can be appended safely once the session is closed.
#
# Desired-state: re-runs are no-ops when the session is already at the target and
# carries the requested title.
#
# Usage:
#   .\move-session.ps1 -SessionId <guid> -From <project-slug> -To <project-slug> [-Title "Name"]
#   Slugs are the directory names under ~/.claude/projects, e.g.
#   D--Meine-Ablage-Develop-danielfrey63-pmo

param(
    [Parameter(Mandatory)] [string]$SessionId,
    [Parameter(Mandatory)] [string]$From,
    [Parameter(Mandatory)] [string]$To,
    [string]$Title,
    [switch]$Force  # skip the freshness guard (e.g. keepwarm ticks touch closed sessions)
)

$ErrorActionPreference = 'Stop'
$projects = Join-Path $env:USERPROFILE '.claude\projects'
$srcDir = Join-Path $projects $From
$dstDir = Join-Path $projects $To

$transcript = Join-Path $srcDir "$SessionId.jsonl"
$sidecar    = Join-Path $srcDir $SessionId
$dstTranscript = Join-Path $dstDir "$SessionId.jsonl"

if (-not (Test-Path -LiteralPath $transcript)) {
    if (Test-Path -LiteralPath $dstTranscript) {
        Write-Host "[OK] transcript already at target project '$To'"
        $transcript = $dstTranscript
        $sidecar = Join-Path $dstDir $SessionId
        $moved = $true
    } else {
        throw "session $SessionId found neither in '$From' nor in '$To'"
    }
}

# Refuse to touch a session that is likely still open (writer appends continuously).
# Note: session-keepwarm ticks re-invoke closed sessions for up to ~3h, so a closed
# session may still look fresh - use -Force once you are sure the window is closed.
$age = (Get-Date) - (Get-Item -LiteralPath $transcript).LastWriteTime
if (-not $Force -and $age.TotalMinutes -lt 2) {
    throw "transcript was written $([int]$age.TotalSeconds)s ago - close the session first, then re-run (or -Force if only keepwarm is touching it)"
}

# --- title (append a custom-title line unless the last one already matches) ---
if ($Title) {
    $hits = @(Select-String -LiteralPath $transcript -Pattern '"type"\s*:\s*"custom-title"')
    $current = $null
    if ($hits) { try { $current = ($hits[-1].Line | ConvertFrom-Json).customTitle } catch {} }
    if ($current -eq $Title) {
        Write-Host "[OK] title already '$Title'"
    } else {
        $line = @{ type = 'custom-title'; customTitle = $Title; sessionId = $SessionId } | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($transcript, "$line`n", [System.Text.UTF8Encoding]::new($false))
        Write-Host "[CHANGED] title set to '$Title' (was: $(if ($current) { "'$current'" } else { 'none' }))"
    }
}

# --- move ---
if (-not $moved) {
    if (-not (Test-Path -LiteralPath $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir | Out-Null
        Write-Host "[CHANGED] created project dir '$To'"
    }
    Move-Item -LiteralPath $transcript -Destination $dstTranscript
    if (Test-Path -LiteralPath $sidecar) {
        Move-Item -LiteralPath $sidecar -Destination (Join-Path $dstDir $SessionId)
        Write-Host "[CHANGED] moved transcript + sidecar dir to '$To'"
    } else {
        Write-Host "[CHANGED] moved transcript to '$To' (no sidecar dir)"
    }
}

Write-Host "[TOTAL] session $($SessionId.Substring(0,8)) lives in '$To'$(if ($Title) { " as '$Title'" })"
