# Transfers Claude Code project data (sessions, memory) after a project tree
# moved on disk. For every dir under ~/.claude/projects the REAL original
# project root is derived from the "cwd" fields inside its session .jsonl
# files (the dir name itself is a lossy encoding – every non-alphanumeric
# char becomes "-", so it cannot be decoded reliably). Projects whose root
# lies under -OldRoot are mirrored to the project dir encoding of the same
# path under -NewRoot.
#
#   pwsh -File transfer-cc-sessions.ps1 -OldRoot "D:\Develop" -NewRoot "D:\Meine Ablage\Develop"
#   ... add -Apply to actually copy (default is a dry-run listing)
#
# Copies are additive and idempotent: existing files in the target project
# are never overwritten, the source project dirs are left untouched.
#
# Claude Desktop keeps its own per-session cwd, which this script does not
# touch – run relocate-desktop-sessions.ps1 afterwards so the Code tab
# sidebar groups (and resumes) the moved sessions under the new folder.

param(
    [Parameter(Mandatory)][string]$OldRoot,
    [Parameter(Mandatory)][string]$NewRoot,
    [string]$ProjectsDir = (Join-Path $env:USERPROFILE ".claude\projects"),
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$OldRoot = $OldRoot.TrimEnd('\')
$NewRoot = $NewRoot.TrimEnd('\')

# Get-CCProjectName, Get-ProjectRoot (recorded-cwd root of a project dir), Copy-TreeAdditive
. (Join-Path $PSScriptRoot 'CCProjects.ps1')

# Fallback when no recorded cwd resolves (e.g. sessions imported from an
# earlier location carry only foreign paths): walk the REAL directory tree
# under $base and find the path whose encoding matches the project name.
# Matching against existing directories rules out sibling-name ambiguity.
function Find-RealPathByEncoding([string]$base, [string]$projectName) {
    $enc = Get-CCProjectName $base
    if ($enc -eq $projectName) { return $base }
    if (-not $projectName.StartsWith("$enc-")) { return $null }
    foreach ($child in Get-ChildItem $base -Directory -Force -ErrorAction SilentlyContinue) {
        $hit = Find-RealPathByEncoding $child.FullName $projectName
        if ($hit) { return $hit }
    }
    return $null
}

# Fallback when the OLD tree is already gone (physically moved): mirror the
# walk through the NEW tree and match the project name against the encoding
# of the corresponding OLD path. Only structure-preserving moves resolve.
function Find-OldPathViaNewTree([string]$newBase, [string]$oldBase, [string]$projectName) {
    $enc = Get-CCProjectName $oldBase
    if ($enc -eq $projectName) { return $oldBase }
    if (-not $projectName.StartsWith("$enc-")) { return $null }
    foreach ($child in Get-ChildItem $newBase -Directory -Force -ErrorAction SilentlyContinue) {
        $hit = Find-OldPathViaNewTree $child.FullName (Join-Path $oldBase $child.Name) $projectName
        if ($hit) { return $hit }
    }
    return $null
}

$moved = 0
$skippedFiles = 0
foreach ($proj in Get-ChildItem $ProjectsDir -Directory) {
    $root = Get-ProjectRoot $proj.FullName $proj.Name
    if (-not $root) { $root = Find-RealPathByEncoding $OldRoot $proj.Name }
    if (-not $root) { $root = Find-OldPathViaNewTree $NewRoot $OldRoot $proj.Name }
    if (-not $root) { continue }
    if (-not ($root.Equals($OldRoot, 'OrdinalIgnoreCase') -or
              $root.StartsWith("$OldRoot\", 'OrdinalIgnoreCase'))) { continue }

    $newPath = $NewRoot + $root.Substring($OldRoot.Length)
    # a physical move must have put the project there - a missing target
    # means this prefix mapping does not apply to the project (moved with a
    # different structure, deleted, ...): report and leave it alone
    if (-not (Test-Path -LiteralPath $newPath -PathType Container)) {
        Write-Host "SKIP (target missing): $($proj.Name)  root: $root  ->  $newPath"
        continue
    }
    $targetName = Get-CCProjectName $newPath
    if ($targetName -eq $proj.Name) { continue }   # encoding collision, nothing to do
    $targetDir = Join-Path $ProjectsDir $targetName

    $files = @(Get-ChildItem $proj.FullName -Recurse -File)
    Write-Host "$($proj.Name)  ->  $targetName  ($($files.Count) file(s), root: $root)"
    if (-not $Apply) { $moved++; continue }

    $skippedFiles += Copy-TreeAdditive $proj.FullName $targetDir
    $moved++
}

$mode = if ($Apply) { "transferred" } else { "would transfer (dry-run, use -Apply)" }
Write-Host "$moved project(s) $mode$(if ($skippedFiles) { "; $skippedFiles existing file(s) kept untouched" })."
