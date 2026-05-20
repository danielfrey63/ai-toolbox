# bump-version.ps1 — generic per-artifact version bumper for the AI-Toolbox.
#
# PowerShell port of tools/bump-version.sh for Codex / Windows. See that file
# for the full description of artifact types and version-storage rules:
#   skill -> SKILL.md frontmatter metadata.version
#   claude -> CLAUDE.md trailing <!-- APP_VERSION: x.y.z --> marker
#   agent -> *.md (parent dir "agents") frontmatter top-level version
#   script -> *.sh/.ps1/.js/.mjs/.cjs/.py/.html APP_VERSION constant
#
# Dual mode: `bump-version.ps1 <file>` as a CLI, or a Codex / Claude Code
# PostToolUse hook JSON payload on stdin. Always exits 0.

$APP_VERSION = '0.0.2'
$ErrorActionPreference = 'Stop'

$InitVersion = '0.0.1'
$script:Result = ''

if ($args.Count -ge 1 -and ($args[0] -in @('-h', '--help', '-Help', '/?'))) {
    Write-Output @'
bump-version — generic per-artifact version bumper for the AI-Toolbox.

Usage:
  bump-version.ps1 <file>         Bump the version of the artifact owning <file>.
  bump-version.ps1 -h|--help      Show this help.
  <hook-json> | bump-version.ps1  Hook mode: read the edited path from a Codex /
                                  Claude Code PostToolUse JSON payload on stdin.

Artifact types (MAJOR.MINOR.PATCH version; the PATCH segment is bumped):
  skill   file under .agents/skills/<name>/  -> <name>/SKILL.md metadata.version
  claude  CLAUDE.md                          -> trailing <!-- APP_VERSION --> marker
  agent   *.md whose parent dir is "agents"   -> frontmatter version
  script  *.sh .ps1 .js .mjs .cjs .py .html   -> APP_VERSION constant (if present)

A missing version is initialised to 0.0.1. A non-artifact file is a no-op.
'@
    exit 0
}

function Bump-Patch([string]$v) {
    $p = $v -split '\.'
    if ($p.Count -ne 3 -or ($p | Where-Object { $_ -notmatch '^\d+$' })) { return $InitVersion }
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

function Bump-Frontmatter([string]$f, [string]$mode) {
    $lines = @(Get-Content -LiteralPath $f)
    $cur = Get-FmVersion $lines
    $out = New-Object System.Collections.Generic.List[string]
    if ($cur) {
        $new = Bump-Patch $cur
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
            if ($fm -and $mode -eq 'skill' -and $ln -match '^metadata:\s*$') {
                $out.Add($ln); $out.Add("  version: `"$new`""); $ins = $true; continue
            }
            if ($fm -and $ln -eq '---') {
                if (-not $ins) {
                    if ($mode -eq 'skill') { $out.Add('metadata:'); $out.Add("  version: `"$new`"") }
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

function Bump-Marker([string]$f) {
    $content = Get-Content -LiteralPath $f -Raw
    $m = [regex]::Match($content, 'APP_VERSION:\s*(\d+\.\d+\.\d+)')
    if (-not $m.Success) {
        $sep = if ($content.EndsWith("`n")) { '' } else { "`n" }
        [System.IO.File]::AppendAllText($f, "$sep`n<!-- APP_VERSION: $InitVersion -->`n")
        $script:Result = "(init) $InitVersion"
        return
    }
    $cur = $m.Groups[1].Value
    $new = Bump-Patch $cur
    $content = [regex]::Replace($content, 'APP_VERSION:\s*' + [regex]::Escape($cur), "APP_VERSION: $new", 1)
    [System.IO.File]::WriteAllText($f, $content)
    $script:Result = "$cur -> $new"
}

function Bump-Script([string]$f) {
    $content = Get-Content -LiteralPath $f -Raw
    $m = [regex]::Match($content, "APP_VERSION[^0-9]*['`"](\d+\.\d+\.\d+)['`"]")
    if (-not $m.Success) { exit 0 }
    $cur = $m.Groups[1].Value
    $new = Bump-Patch $cur
    $content = [regex]::Replace($content, "(APP_VERSION[^0-9]*['`"])" + [regex]::Escape($cur), "`${1}$new", 1)
    [System.IO.File]::WriteAllText($f, $content)
    $script:Result = "$cur -> $new"
}

# --- resolve target file ------------------------------------------------------
$file = $null
if ($args.Count -ge 1 -and $args[0]) {
    $file = [string]$args[0]
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
    if (Test-Path -LiteralPath "$skillDir/SKILL.md") { $type = 'skill'; $target = "$skillDir/SKILL.md" }
}
if (-not $type) {
    if ($base -eq 'SKILL.md') { $type = 'skill'; $target = $file }
    elseif ($base -eq 'CLAUDE.md') { $type = 'claude'; $target = $file }
    elseif ($parent -eq 'agents' -and $ext -eq 'md') { $type = 'agent'; $target = $file }
    elseif ($ext -in @('sh', 'ps1', 'js', 'mjs', 'cjs', 'py', 'html')) {
        if ((Get-Content -LiteralPath $file -Raw) -match 'APP_VERSION') { $type = 'script'; $target = $file }
    }
}
if (-not $type) { exit 0 }

# --- bump ---------------------------------------------------------------------
switch ($type) {
    'skill'  { Bump-Frontmatter $target 'skill' }
    'agent'  { Bump-Frontmatter $target 'agent' }
    'claude' { Bump-Marker $target }
    'script' { Bump-Script $target }
}

# --- report -------------------------------------------------------------------
try {
    $repo = (git -C (Split-Path -Parent $target) rev-parse --show-toplevel 2>$null)
    if ($repo -and (Test-Path -LiteralPath "$repo/.claude")) {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath "$repo/.claude/hook-log.txt" -Value "[$stamp] $type $target :: $($script:Result)"
    }
} catch { }
Write-Output "bump-version: $type $target :: $($script:Result)"
exit 0
