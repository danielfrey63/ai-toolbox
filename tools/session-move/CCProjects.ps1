# Shared helpers for tools that work on Claude Code project dirs (~/.claude/projects).
# Dot-source it:  . (Join-Path $PSScriptRoot 'CCProjects.ps1')
#
# A project dir name is the project path with every non-alphanumeric char
# replaced by "-". The encoding is lossy ("-" may stand for "\", " ", ".", an
# umlaut ...), so decoding needs either the real file system or the "cwd"
# fields recorded inside the session transcripts.

function Get-CCProjectName([string]$path) {
    return ($path -replace '[^A-Za-z0-9]', '-')
}

# Decodes a project dir name against the REAL file system: walk existing
# directories from the drive root and match munged component names. Returns
# the existing folder, or $null when the dir no longer corresponds to an
# openable path. Neither the cwd recorded inside a transcript (may point one or
# two migrations back) nor the file mtime (touched by pickers and sync tools)
# identifies the current location – the munged name is the only ground truth.
function Resolve-ProjectDir([string]$name) {
    if ($name -notmatch '^([A-Za-z])--(.+)$') { return $null }
    $root = "$($matches[1]):\"
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $stack = [Collections.Generic.Stack[object[]]]::new()
    $stack.Push(@($root, $matches[2]))
    while ($stack.Count -gt 0) {
        $cur, $rest = $stack.Pop()
        foreach ($child in Get-ChildItem -LiteralPath $cur -Directory -Force -ErrorAction SilentlyContinue) {
            $m = Get-CCProjectName $child.Name
            if ($rest -ieq $m) { return $child.FullName }
            # Munged names are ambiguous, so follow every child whose munged
            # name is a component prefix of the remainder.
            if ($rest.Length -gt $m.Length -and $rest.StartsWith("$m-", 'OrdinalIgnoreCase')) {
                $stack.Push(@($child.FullName, $rest.Substring($m.Length + 1)))
            }
        }
    }
    return $null
}

# Last activity of a transcript: the newest inner "timestamp" beats the file
# mtime, because resume pickers, cloud bridges and sync tools touch files
# without adding content. Files without inner timestamps (bridge stubs) fall
# back to mtime. Byte-based tail read: Get-Content -Tail is prohibitively slow
# on multi-MB single-line transcripts.
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

# Session files can be hundreds of MB – only a 256 KB chunk is read from
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

# The project root as recorded by the sessions themselves – works for dirs
# whose folder no longer exists. Scan the file END of the newest session
# first: lines appended after a move hold the current path, a copied file
# carries the old one only in its head.
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

# Copies every file below $source into the same relative place below $dest.
# Additive: existing files are never overwritten. Returns how many were kept.
function Copy-TreeAdditive([string]$source, [string]$dest) {
    $kept = 0
    foreach ($f in Get-ChildItem -LiteralPath $source -Recurse -File) {
        $target = Join-Path $dest $f.FullName.Substring($source.TrimEnd('\').Length + 1)
        if (Test-Path -LiteralPath $target) { $kept++; continue }
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item -LiteralPath $f.FullName $target
    }
    return $kept
}
