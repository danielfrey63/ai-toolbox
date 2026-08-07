# Transfers Claude Code project data (sessions, memory) after a project tree
# moved on disk. For every dir under ~/.claude/projects the REAL original
# project root is derived from the "cwd" fields inside its session .jsonl
# files (the dir name itself is a lossy encoding - every non-alphanumeric
# char becomes "-", so it cannot be decoded reliably). Projects whose root
# lies under -OldRoot are mirrored to the project dir encoding of the same
# path under -NewRoot.
#
#   pwsh -File transfer-cc-sessions.ps1 -OldRoot "D:\Develop" -NewRoot "D:\Meine Ablage\Develop"
#   ... add -Apply to actually copy (default is a dry-run listing)
#
# Copies are additive and idempotent: existing files in the target project
# are never overwritten, the source project dirs are left untouched.

param(
    [Parameter(Mandatory)][string]$OldRoot,
    [Parameter(Mandatory)][string]$NewRoot,
    [string]$ProjectsDir = (Join-Path $env:USERPROFILE ".claude\projects"),
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$OldRoot = $OldRoot.TrimEnd('\')
$NewRoot = $NewRoot.TrimEnd('\')

function Get-CCProjectName([string]$path) {
    return ($path -replace '[^A-Za-z0-9]', '-')
}

# Session files can be hundreds of MB - only a 256 KB chunk is read from
# each end (raw bytes + regex). Returns the cwd candidates in the chunk,
# nearest-to-the-chunk-border first.
function Get-CwdCandidates([string]$file, [bool]$fromEnd) {
    $fs = [System.IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
    try {
        $size = [int][Math]::Min(262144, $fs.Length)
        if ($size -eq 0) { return @() }
        if ($fromEnd) { [void]$fs.Seek(-$size, 'End') }
        $buf = [byte[]]::new($size)
        [void]$fs.Read($buf, 0, $size)
        $text = [System.Text.Encoding]::UTF8.GetString($buf)
        $vals = @([regex]::Matches($text, '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"') |
            ForEach-Object { '"' + $_.Groups[1].Value + '"' | ConvertFrom-Json })   # JSON-unescape
        if ($fromEnd) { [array]::Reverse($vals) }
        return @($vals | Select-Object -Unique)
    }
    finally { $fs.Dispose() }
}

# A recorded cwd may be a subdirectory (the session cd'ed around) or even a
# foreign path (a session file copied in from another project). The project
# ROOT is the ancestor whose encoding matches the project dir name exactly.
function Resolve-ProjectRoot([string]$cwd, [string]$projectName) {
    while ($cwd) {
        if ((Get-CCProjectName $cwd) -eq $projectName) { return $cwd }
        $parent = Split-Path $cwd -Parent
        if (-not $parent -or $parent -eq $cwd) { return $null }
        $cwd = $parent
    }
    return $null
}

# Scan the file END of the newest session first: lines appended after a move
# hold the current path, a copied file carries the old one only in its head.
function Get-ProjectRoot([string]$projectDir, [string]$projectName) {
    foreach ($jsonl in Get-ChildItem $projectDir -Filter "*.jsonl" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending) {
        foreach ($fromEnd in $true, $false) {
            foreach ($cwd in Get-CwdCandidates $jsonl.FullName $fromEnd) {
                $root = Resolve-ProjectRoot $cwd $projectName
                if ($root) { return $root }
            }
        }
    }
    return $null
}

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

$moved = 0
$skippedFiles = 0
foreach ($proj in Get-ChildItem $ProjectsDir -Directory) {
    $root = Get-ProjectRoot $proj.FullName $proj.Name
    if (-not $root) { $root = Find-RealPathByEncoding $OldRoot $proj.Name }
    if (-not $root) { continue }
    if (-not ($root.Equals($OldRoot, 'OrdinalIgnoreCase') -or
              $root.StartsWith("$OldRoot\", 'OrdinalIgnoreCase'))) { continue }

    $newPath = $NewRoot + $root.Substring($OldRoot.Length)
    $targetName = Get-CCProjectName $newPath
    if ($targetName -eq $proj.Name) { continue }   # encoding collision, nothing to do
    $targetDir = Join-Path $ProjectsDir $targetName

    $files = @(Get-ChildItem $proj.FullName -Recurse -File)
    Write-Host "$($proj.Name)  ->  $targetName  ($($files.Count) file(s), root: $root)"
    if (-not $Apply) { $moved++; continue }

    foreach ($f in $files) {
        $rel = $f.FullName.Substring($proj.FullName.Length + 1)
        $dest = Join-Path $targetDir $rel
        if (Test-Path -LiteralPath $dest) { $skippedFiles++; continue }
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath $f.FullName $dest
    }
    $moved++
}

$mode = if ($Apply) { "transferred" } else { "would transfer (dry-run, use -Apply)" }
Write-Host "$moved project(s) $mode$(if ($skippedFiles) { "; $skippedFiles existing file(s) kept untouched" })."
