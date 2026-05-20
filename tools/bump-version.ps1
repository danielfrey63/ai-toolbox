# bump-version.ps1 — generic per-artifact version bumper for the AI-Toolbox.
#
# PowerShell port of tools/bump-version.sh for Codex / Windows. See that file
# for the full description of artifact types and version-storage rules.
#
# The version marker is matched in its DECLARATION form only — an APP_VERSION
# assignment at the start of a line, the whole <!-- APP_VERSION: --> comment,
# a version: key inside YAML frontmatter, or the "version" key of plugin.json.
# A mere mention of the word in a comment, help text or prose is never matched.
# A skill directory that ships a Claude Code plugin manifest is versioned via
# plugin.json instead of SKILL.md.
#
# Modes:
#   (default) bump BUILD (3rd) — driven by the per-edit PostToolUse hook
#   --build   bump BUILD (3rd) explicitly
#   --minor   bump MINOR (2nd), BUILD untouched
#   --commit  bump MINOR+BUILD together — driven by the pre-commit hook
#   --target  print the resolved artifact file without bumping
#   --get     print the artifact's current version (type-aware, no mutation)
#
# Dual mode: `bump-version.ps1 [--build|--minor|--commit|--target|--get] <file>`
# as a CLI, or a Codex / Claude Code PostToolUse hook JSON payload on stdin. Always
# exits 0 (except on a usage error).

$APP_VERSION = '0.4.13'
$ErrorActionPreference = 'Stop'

$InitVersion = '0.0.1'
$script:Result = ''
$script:Segment = 'build'

# An APP_VERSION assignment at the start of a line; group 3 is the version.
$DeclRe = '(?m)^[ \t]*((export|const|let|var)[ \t]+)?\$?APP_VERSION[ \t]*=[ \t]*[''"](\d+\.\d+\.\d+)'
# The whole CLAUDE.md / markdown version-marker comment; group 1 is the version.
$MarkerRe = '<!--[ \t]*APP_VERSION:[ \t]*(\d+\.\d+\.\d+)'
# The "version" key of a JSON manifest (plugin.json); group 1 is the version.
$JsonRe = '"version"[ \t]*:[ \t]*"(\d+\.\d+\.\d+)"'

if ($args | Where-Object { $_ -in @('-h', '--help', '-Help', '/?') }) {
    Write-Output @'
bump-version — generic per-artifact version bumper for the AI-Toolbox.

Usage:
  bump-version.ps1 [--build|--minor|--commit|--target|--get] <file>
  bump-version.ps1 -h|--help
  <hook-json> | bump-version.ps1 [--build|--commit]

Options:
  --build   Bump the BUILD segment (3rd). Default. Used by the per-edit hook.
  --minor   Bump the MINOR segment (2nd), leaving BUILD untouched.
  --commit  Bump MINOR and BUILD together. Used by the pre-commit hook.
  --target  Print the resolved artifact file without bumping anything.
  --get     Print the artifact's current version (type-aware, no mutation).
  -h|--help Show this help.

Artifact types (MAJOR.MINOR.BUILD version):
  plugin  skill dir with .claude-plugin/plugin.json -> plugin.json "version"
  skill   file under .agents/skills/<name>/  -> <name>/SKILL.md metadata.version
  claude  CLAUDE.md                          -> trailing <!-- APP_VERSION --> marker
  agent   *.md whose parent dir is "agents"   -> frontmatter version
  script  *.sh .ps1 .js .mjs .cjs .py .html, or any #!-shebang file with an
          APP_VERSION assignment

The version is matched in its declaration form only — an assignment / the
whole marker comment / a frontmatter key / the plugin.json "version" key —
never a bare mention of the word. A missing version is initialised to 0.0.1.
A non-artifact file is a no-op.
'@
    exit 0
}

# --- parse arguments ----------------------------------------------------------
$mode = 'bump'
$positional = @()
foreach ($a in $args) {
    # switch -Regex falls through without break — every branch must break so a
    # matched flag like "--build" does not also hit the "^-." unknown-option rule.
    switch -Regex ([string]$a) {
        '^--build$'  { $script:Segment = 'build'; break }
        '^--minor$'  { $script:Segment = 'minor'; break }
        '^--commit$' { $script:Segment = 'commit'; break }
        '^--target$' { $mode = 'target'; break }
        '^--get$'    { $mode = 'get'; break }
        '^--$'       { break }
        '^-.'        { [Console]::Error.WriteLine("bump-version: unknown option: $a"); exit 2 }
        default      { $positional += $a; break }
    }
}

function Bump-Version([string]$v) {
    $p = $v -split '\.'
    if ($p.Count -ne 3 -or ($p | Where-Object { $_ -notmatch '^\d+$' })) { return $InitVersion }
    switch ($script:Segment) {
        'minor'  { return '{0}.{1}.{2}' -f $p[0], ([int]$p[1] + 1), $p[2] }
        'commit' { return '{0}.{1}.{2}' -f $p[0], ([int]$p[1] + 1), ([int]$p[2] + 1) }
    }
    return '{0}.{1}.{2}' -f $p[0], $p[1], ([int]$p[2] + 1)
}

function Get-FmVersion([string[]]$lines) {
    $fm = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq 0 -and $lines[0] -eq '---') { $fm = $true; continue }
        if ($fm -and $lines[$i] -eq '---') { break }
        if ($fm -and $lines[$i] -match '^\s*version:') {
            $m = [regex]::Match($lines[$i], '\d+\.\d+\.\d+')
            if ($m.Success) { return $m.Value }
        }
    }
    return $null
}

function Get-ScriptVersion([string]$f) {
    $m = [regex]::Match((Get-Content -LiteralPath $f -Raw), $DeclRe)
    if ($m.Success) { return $m.Groups[3].Value }
    return $null
}

function Get-MarkerVersion([string]$f) {
    $m = [regex]::Match((Get-Content -LiteralPath $f -Raw), $MarkerRe)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-PluginVersion([string]$f) {
    $m = [regex]::Match((Get-Content -LiteralPath $f -Raw), $JsonRe)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Bump-Frontmatter([string]$f, [string]$fmode) {
    $lines = @(Get-Content -LiteralPath $f)
    $cur = Get-FmVersion $lines
    $out = New-Object System.Collections.Generic.List[string]
    if ($cur) {
        $new = Bump-Version $cur
        $fm = $false; $done = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $ln = $lines[$i]
            if ($i -eq 0 -and $ln -eq '---') { $fm = $true; $out.Add($ln); continue }
            if ($fm -and $ln -eq '---') { $fm = $false; $out.Add($ln); continue }
            if ($fm -and -not $done -and $ln -match '^\s*version:' -and $ln.Contains($cur)) {
                $ln = $ln -replace [regex]::Escape($cur), $new
                $done = $true
            }
            $out.Add($ln)
        }
        $script:Result = "$cur -> $new"
    } else {
        $new = $InitVersion
        $fm = $false; $ins = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $ln = $lines[$i]
            if ($i -eq 0 -and $ln -eq '---') { $fm = $true; $out.Add($ln); continue }
            if ($fm -and $fmode -eq 'skill' -and $ln -match '^metadata:\s*$') {
                $out.Add($ln); $out.Add("  version: `"$new`""); $ins = $true; continue
            }
            if ($fm -and $ln -eq '---') {
                if (-not $ins) {
                    if ($fmode -eq 'skill') { $out.Add('metadata:'); $out.Add("  version: `"$new`"") }
                    else { $out.Add("version: `"$new`"") }
                }
                $fm = $false; $out.Add($ln); continue
            }
            $out.Add($ln)
        }
        $script:Result = "(init) $new"
    }
    [System.IO.File]::WriteAllLines($f, [string[]]$out)
}

function Set-MatchGroup([string]$content, $group, [string]$new) {
    # Replace exactly the span of a regex group with $new.
    return $content.Substring(0, $group.Index) + $new + $content.Substring($group.Index + $group.Length)
}

function Bump-Marker([string]$f) {
    $content = Get-Content -LiteralPath $f -Raw
    $m = [regex]::Match($content, $MarkerRe)
    if (-not $m.Success) {
        $sep = if ($content.EndsWith("`n")) { '' } else { "`n" }
        [System.IO.File]::AppendAllText($f, "$sep`n<!-- APP_VERSION: $InitVersion -->`n")
        $script:Result = "(init) $InitVersion"
        return
    }
    $cur = $m.Groups[1].Value
    $new = Bump-Version $cur
    [System.IO.File]::WriteAllText($f, (Set-MatchGroup $content $m.Groups[1] $new))
    $script:Result = "$cur -> $new"
}

function Bump-Script([string]$f) {
    $content = Get-Content -LiteralPath $f -Raw
    $m = [regex]::Match($content, $DeclRe)
    if (-not $m.Success) { exit 0 }
    $cur = $m.Groups[3].Value
    $new = Bump-Version $cur
    [System.IO.File]::WriteAllText($f, (Set-MatchGroup $content $m.Groups[3] $new))
    $script:Result = "$cur -> $new"
}

function Bump-Plugin([string]$f) {
    $content = Get-Content -LiteralPath $f -Raw
    $m = [regex]::Match($content, $JsonRe)
    if (-not $m.Success) { exit 0 }
    $cur = $m.Groups[1].Value
    $new = Bump-Version $cur
    [System.IO.File]::WriteAllText($f, (Set-MatchGroup $content $m.Groups[1] $new))
    $script:Result = "$cur -> $new"
}

# --- resolve target file ------------------------------------------------------
$file = $null
if ($positional.Count -ge 1 -and $positional[0]) {
    $file = [string]$positional[0]
} else {
    $raw = [Console]::In.ReadToEnd()
    if ($raw) {
        try {
            $file = ($raw | ConvertFrom-Json).tool_input.file_path
        } catch {
            $m = [regex]::Match($raw, '"file_path"\s*:\s*"([^"]*)"')
            if ($m.Success) { $file = $m.Groups[1].Value }
        }
    }
}
if (-not $file) { exit 0 }
if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { exit 0 }
$file = (Resolve-Path -LiteralPath $file).Path

# --- detect artifact type -----------------------------------------------------
$norm = $file -replace '\\', '/'
$base = Split-Path -Leaf $file
$parent = Split-Path -Leaf (Split-Path -Parent $file)
$ext = ([System.IO.Path]::GetExtension($file)).TrimStart('.').ToLower()
$type = $null
$target = $null

if ($norm -match '/\.agents/skills/([^/]+)/') {
    $skillDir = $norm.Substring(0, $norm.IndexOf('/.agents/skills/')) + '/.agents/skills/' + $Matches[1]
    # A skill that ships a Claude Code plugin manifest is versioned via plugin.json.
    if (Test-Path -LiteralPath "$skillDir/.claude-plugin/plugin.json") {
        $type = 'plugin'; $target = "$skillDir/.claude-plugin/plugin.json"
    } elseif (Test-Path -LiteralPath "$skillDir/SKILL.md") {
        $type = 'skill'; $target = "$skillDir/SKILL.md"
    }
}
if (-not $type) {
    if ($base -eq 'SKILL.md') { $type = 'skill'; $target = $file }
    elseif ($base -eq 'CLAUDE.md') { $type = 'claude'; $target = $file }
    elseif ($parent -eq 'agents' -and $ext -eq 'md') { $type = 'agent'; $target = $file }
    else {
        # A "script" has a known code extension OR a #! shebang, and counts as a
        # versioned artifact only if it carries an APP_VERSION assignment.
        $isScript = $ext -in @('sh', 'ps1', 'js', 'mjs', 'cjs', 'py', 'html')
        if (-not $isScript) {
            $first = Get-Content -LiteralPath $file -TotalCount 1
            if ($first -and $first.StartsWith('#!')) { $isScript = $true }
        }
        if ($isScript -and [regex]::Match((Get-Content -LiteralPath $file -Raw), $DeclRe).Success) {
            $type = 'script'; $target = $file
        }
    }
}
if (-not $type) { exit 0 }

# --- read-only modes ----------------------------------------------------------
if ($mode -eq 'target') {
    Write-Output $target
    exit 0
}
if ($mode -eq 'get') {
    switch ($type) {
        { $_ -in 'skill', 'agent' } { $v = Get-FmVersion @(Get-Content -LiteralPath $target) }
        'claude' { $v = Get-MarkerVersion $target }
        'script' { $v = Get-ScriptVersion $target }
        'plugin' { $v = Get-PluginVersion $target }
    }
    if ($v) { Write-Output $v }
    exit 0
}

# --- bump ---------------------------------------------------------------------
switch ($type) {
    'skill'  { Bump-Frontmatter $target 'skill' }
    'agent'  { Bump-Frontmatter $target 'agent' }
    'claude' { Bump-Marker $target }
    'script' { Bump-Script $target }
    'plugin' { Bump-Plugin $target }
}

# --- report -------------------------------------------------------------------
# When a skill sub-file triggered the bump, $file (the edited file) differs from
# $target (the manifest whose version moved) — log both so the trigger is traceable.
$via = if ($file -ne $target) { " (via $file)" } else { '' }
try {
    $repo = (git -C (Split-Path -Parent $target) rev-parse --show-toplevel 2>$null)
    if ($repo -and (Test-Path -LiteralPath "$repo/.claude")) {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath "$repo/.claude/hook-log.txt" -Value "[$stamp] $type $($script:Segment) $target$via :: $($script:Result)"
    }
} catch { }
Write-Output "bump-version: $type $($script:Segment) $target$via :: $($script:Result)"
exit 0
