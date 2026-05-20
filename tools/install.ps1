# install.ps1 — install AI-Toolbox tools from the catalog.
#
# PowerShell port of tools/install.sh for Codex / Windows. See that file for
# the full description. Reads tools/catalog.json and dispatches per tool TYPE:
#   skill  — junction (Windows) / symlink (Linux/macOS) into a skills/ dir
#   hook   — git-hook shims                              (handler: pending)
#   plugin — claude plugin marketplace add + install      (handler: pending)
#
# Usage:
#   install.ps1 <build|status|clean> --target <claude|codex|agents>
#               [--scope global|project] [--project PATH] [--what all|<name>|<type>]
#
# Idempotent: build re-links cleanly, clean removes only our own links,
# a foreign file/dir at the target is never clobbered.

$APP_VERSION = '0.1.2'
$ErrorActionPreference = 'Stop'

$SelfDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot = (Resolve-Path (Join-Path $SelfDir '..')).Path
$Catalog  = Join-Path $SelfDir 'catalog.json'

function Show-Usage {
    Write-Output @'
install — install AI-Toolbox tools from the catalog (tools/catalog.json).

Usage:
  install.ps1 <build|status|clean> --target <claude|codex|agents> [options]

Options:
  --target  claude | codex | agents     Required. Which CLI/agent to install for.
  --scope   global | project            Default: global ($HOME). project needs --project.
  --project PATH                        Project root; required when --scope project.
  --what    all | <tool-name> | <type>  Default: all. Select catalog entries.
  -h|--help                             Show this help.

Tool types: skill (implemented); hook and plugin handlers are pending.
'@
}

# --- command ------------------------------------------------------------------
$Cmd = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
if ($Cmd -in @('-h', '--help')) { Show-Usage; exit 0 }
if ($Cmd -notin @('build', 'status', 'clean')) {
    [Console]::Error.WriteLine("install: missing or unknown command (build|status|clean)")
    exit 2
}

# --- options ------------------------------------------------------------------
$Scope = 'global'; $Target = ''; $Project = ''; $What = 'all'
$i = 1
while ($i -lt $args.Count) {
    $opt = [string]$args[$i]
    switch ($opt) {
        { $_ -in '--scope', '--target', '--project', '--what' } {
            if ($i + 1 -ge $args.Count) {
                [Console]::Error.WriteLine("install: $opt needs a value"); exit 2
            }
            $val = [string]$args[$i + 1]
            switch ($opt) {
                '--scope'   { $Scope = $val }
                '--target'  { $Target = $val }
                '--project' { $Project = $val }
                '--what'    { $What = $val }
            }
            $i += 2
        }
        { $_ -in '-h', '--help' } { Show-Usage; exit 0 }
        default { [Console]::Error.WriteLine("install: unknown option: $opt"); exit 2 }
    }
}

# --- validate -----------------------------------------------------------------
if ($Target -notin @('claude', 'codex', 'agents')) {
    [Console]::Error.WriteLine("install: --target is required (claude|codex|agents)"); exit 2
}
if ($Scope -eq 'project') {
    if (-not $Project) {
        [Console]::Error.WriteLine("install: --scope project requires --project PATH"); exit 2
    }
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        [Console]::Error.WriteLine("install: --project path not found"); exit 2
    }
    $Project = (Resolve-Path -LiteralPath $Project).Path
} elseif ($Scope -ne 'global') {
    [Console]::Error.WriteLine("install: invalid --scope: $Scope"); exit 2
}
if (-not (Test-Path -LiteralPath $Catalog)) {
    [Console]::Error.WriteLine("install: catalog not found: $Catalog"); exit 1
}

# --- skill handler ------------------------------------------------------------
function Get-SkillDestDir {
    $base = if ($Scope -eq 'global') { $HOME } else { $Project }
    switch ($Target) {
        'claude' { Join-Path $base '.claude/skills' }
        'codex'  { Join-Path $base '.codex/skills' }
        'agents' { Join-Path $base '.agents/skills' }
    }
}

function Handle-Skill([string]$name, [string]$path) {
    $src = Join-Path $RepoRoot $path
    $destdir = Get-SkillDestDir
    $link = Join-Path $destdir $name

    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        [Console]::Error.WriteLine("  [!] $name  source missing: $src"); return
    }
    if ($link -eq $src) {
        Write-Output "  [=] $name  source == target, skipped"; return
    }

    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue

    switch ($Cmd) {
        'build' {
            New-Item -ItemType Directory -Path $destdir -Force | Out-Null
            if ($item -and $item.Target -eq $src) {
                Write-Output "  [=] $name  already linked"; return
            }
            if ($item -and $item.LinkType) {
                [System.IO.Directory]::Delete($link, $false)
            } elseif ($item) {
                [Console]::Error.WriteLine("  [!] $name  exists and is not a link — skipped"); return
            }
            if ($IsWindows) {
                New-Item -ItemType Junction -Path $link -Target $src | Out-Null
            } else {
                New-Item -ItemType SymbolicLink -Path $link -Target $src | Out-Null
            }
            Write-Output "  [+] $name  -> $link"
        }
        'status' {
            if ($item -and $item.Target -eq $src) {
                Write-Output "  [ok] $name  $link"
            } elseif ($item) {
                Write-Output "  [? ] $name  $link (exists, not our link)"
            } else {
                Write-Output "  [  ] $name  not installed"
            }
        }
        'clean' {
            if ($item -and $item.Target -eq $src) {
                [System.IO.Directory]::Delete($link, $false)
                Write-Output "  [-] $name  removed"
            } else {
                Write-Output "  [.] $name  nothing to remove"
            }
        }
    }
}

# --- dispatch -----------------------------------------------------------------
Write-Output "install $Cmd — scope=$Scope target=$Target what=$What"

$tools = (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).tools
$selected = $tools | Where-Object {
    $What -eq 'all' -or $_.name -eq $What -or $_.type -eq $What
}
if (-not $selected) {
    [Console]::Error.WriteLine("install: nothing in the catalog matches --what $What"); exit 1
}

foreach ($tool in $selected) {
    switch ($tool.type) {
        'skill' { Handle-Skill $tool.name $tool.path }
        { $_ -in 'hook', 'plugin' } {
            Write-Output "  [.] $($tool.name)  type `"$($tool.type)`" — handler not yet implemented"
        }
        default {
            [Console]::Error.WriteLine("  [!] $($tool.name)  unknown type `"$($tool.type)`"")
        }
    }
}
exit 0
