# install.ps1 — install AI-Toolbox tools from the catalog.
#
# PowerShell port of tools/install.sh for Codex / Windows. See that file for
# the full description. Reads tools/catalog.json and dispatches per tool TYPE:
#   skill  — junction (Windows) / symlink (Linux/macOS) into a skills/ dir
#   hook   — point a repo's core.hooksPath at the toolbox hook directory
#   plugin — claude plugin marketplace add + install (--target claude); else skill-link
#
# Usage:
#   install.ps1 <install|status|clean> --target <claude|codex|agents>
#               [--scope global|project] [--project PATH] [--what all|<name>|<type>]
#               [--tagstyle plain|namespaced]
#
# --tagstyle applies only to hook installs — it sets the repo's
# bumpversion.tagstyle (plain = v<version> tags for a single-artifact repo).
#
# Idempotent: install re-links cleanly, clean removes only our own links,
# a foreign file/dir at the target is never clobbered.

$APP_VERSION = '0.10.45'
$ErrorActionPreference = 'Stop'

$SelfDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot = (Resolve-Path (Join-Path $SelfDir '..')).Path
$Catalog  = Join-Path $SelfDir 'catalog.json'

function Show-Usage {
    Write-Output @'
install — install AI-Toolbox tools into a Claude Code / Codex / agents setup.

Tools are described in the catalog (tools/catalog.json) and installed by
type-specific handlers. Run `install.ps1 list` to see what is available.

Usage:
  install.ps1 <install|status|clean> --target <claude|codex|agents> [options]
  install.ps1 list
  install.ps1 -h|--help

Commands:
  install  Install the selected tools (idempotent — safe to re-run).
  status   Report whether each selected tool is installed.
  clean    Remove the selected tools (only ever removes our own links/config).
  list     Print the catalog — every installable tool with its type.

Options:
  --target   claude | codex | agents
             Where to install. Required, unless the selection is hook-only.
  --scope    global | project   Default: global.
             global  — install under $HOME (~/.claude, ~/.codex, ~/.agents).
             project — install under --project PATH.
  --project  PATH    Project root for --scope project. Default: current directory.
  --what     all | <tool-name> | <type>   Default: all.
             Select catalog entries by exact name, by type, or all of them.
  --tagstyle plain | namespaced   Hook installs only.
             plain      — tag v<version>         (single-artifact repo)
             namespaced — tag <name>/v<version>  (default; multi-artifact repo)
  -h|--help  Show this help.

Targets:
  claude   Claude Code     — skills link into <scope>/.claude/skills/
  codex    Codex CLI       — skills link into <scope>/.codex/skills/
  agents   agentskills.io  — skills link into <scope>/.agents/skills/
  Hooks ignore --target (they are per-repo git config). Plugins do a real
  `claude plugin` install for --target claude, else fall back to a skill-link.

Catalog (tools/catalog.json):
  The single source of truth for installable tools — each entry has a name,
  a type and a path. Types and their install handlers:
    skill   junction/symlink into a .{claude,codex,agents}/skills/ directory
    hook    point a repo's core.hooksPath at the toolbox git hooks
            (per-repo — needs --scope project; --project defaults to cwd)
    plugin  `claude plugin` marketplace add + install (--target claude),
            else a skill-link
  Run `install.ps1 list` to print the current catalog.

Examples:
  install.ps1 list
  install.ps1 install --target claude   # all tools, global
  install.ps1 install --target codex --what component-audit
  install.ps1 install --what versioning-hooks --scope project   # --project = cwd
  install.ps1 status --target claude
  install.ps1 clean --target claude --what watch

Idempotent: install re-links cleanly, clean removes only our own links/config,
a foreign file or directory at a target is never clobbered.
'@
}

# Print the catalog as a readable table — answers "what can I install?".
function Show-CatalogList {
    Write-Output "install — available tools ($Catalog):`n"
    Write-Output ('  {0,-20} {1,-7} {2}' -f 'NAME', 'TYPE', 'DESCRIPTION')
    foreach ($t in (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).tools) {
        Write-Output ('  {0,-20} {1,-7} {2}' -f $t.name, $t.type, $t.description)
    }
    Write-Output "`nSelect one with --what <name> or a group with --what <type>; default is all."
}

# --- command ------------------------------------------------------------------
$Cmd = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
if ($Cmd -in @('-h', '--help')) { Show-Usage; exit 0 }
if ($Cmd -notin @('install', 'status', 'clean', 'list')) {
    [Console]::Error.WriteLine("install: missing or unknown command (install|status|clean|list)")
    exit 2
}

# --- options ------------------------------------------------------------------
$Scope = 'global'; $Target = ''; $Project = ''; $What = 'all'; $TagStyle = ''
$i = 1
while ($i -lt $args.Count) {
    $opt = [string]$args[$i]
    switch ($opt) {
        { $_ -in '--scope', '--target', '--project', '--what', '--tagstyle' } {
            if ($i + 1 -ge $args.Count) {
                [Console]::Error.WriteLine("install: $opt needs a value"); exit 2
            }
            $val = [string]$args[$i + 1]
            switch ($opt) {
                '--scope'    { $Scope = $val }
                '--target'   { $Target = $val }
                '--project'  { $Project = $val }
                '--what'     { $What = $val }
                '--tagstyle' { $TagStyle = $val }
            }
            $i += 2
        }
        { $_ -in '-h', '--help' } { Show-Usage; exit 0 }
        default { [Console]::Error.WriteLine("install: unknown option: $opt"); exit 2 }
    }
}

# --- validate -----------------------------------------------------------------
# An empty --target is allowed here; whether it is required depends on the
# selected tool types and is checked once the catalog selection is known.
if ($Target -and $Target -notin @('claude', 'codex', 'agents')) {
    [Console]::Error.WriteLine("install: invalid --target: $Target"); exit 2
}
if ($TagStyle -and $TagStyle -notin @('plain', 'namespaced')) {
    [Console]::Error.WriteLine("install: invalid --tagstyle: $TagStyle"); exit 2
}
if ($Scope -eq 'project') {
    # --project defaults to the current directory.
    if (-not $Project) { $Project = $PWD.Path }
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        [Console]::Error.WriteLine("install: --project path not found: $Project"); exit 2
    }
    $Project = (Resolve-Path -LiteralPath $Project).Path
} elseif ($Scope -ne 'global') {
    [Console]::Error.WriteLine("install: invalid --scope: $Scope"); exit 2
}
if (-not (Test-Path -LiteralPath $Catalog)) {
    [Console]::Error.WriteLine("install: catalog not found: $Catalog"); exit 1
}

# "list" just prints the catalog — no scope/target/selection needed.
if ($Cmd -eq 'list') { Show-CatalogList; exit 0 }

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
        'install' {
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

# --- hook handler -------------------------------------------------------------
# Installs the versioning git-hooks into a repo by pointing its core.hooksPath
# at the toolbox hook directory. Per-repo: needs --scope project, ignores --target.

# Printed after a fresh hook install — a README snippet for the target repo so
# contributors know to activate the hooks too (git hooks are never cloned).
function Show-ReadmeHint {
    Write-Output @'
      -> Add a setup note to this repo's README — git hooks are never cloned,
         so every clone must activate them once:

         ## Versioning
         Artifacts here are version-bumped by the AI-Toolbox git hooks.
         Once per clone, from this repo's root:
           git clone https://github.com/danielfrey63/ai-toolbox.git   # if needed
           <ai-toolbox>/tools/install.ps1 install --what versioning-hooks --scope project
'@
}

function Handle-Hook([string]$name, [string]$path) {
    $hooksdir = Join-Path $RepoRoot $path
    if ($Scope -ne 'project') {
        Write-Output "  [.] $name  hooks are per-repo — pass --scope project"
        return
    }
    $prepo = (git -C $Project rev-parse --show-toplevel 2>$null)
    if (-not $prepo) {
        [Console]::Error.WriteLine("  [!] $name  --project is not a git repo: $Project"); return
    }
    $cur = (git -C $prepo config --local core.hooksPath 2>$null)
    switch ($Cmd) {
        'install' {
            if ($cur -and $cur -ne $hooksdir) {
                [Console]::Error.WriteLine("  [!] $name  core.hooksPath already set to $cur — skipped"); return
            }
            $fresh = $false
            if ($cur -eq $hooksdir) {
                Write-Output "  [=] $name  core.hooksPath already set"
            } else {
                git -C $prepo config --local core.hooksPath $hooksdir
                Write-Output "  [+] $name  core.hooksPath -> $hooksdir"
                $fresh = $true
            }
            $curts = (git -C $prepo config --local bumpversion.tagstyle 2>$null)
            if ($TagStyle) {
                if ($curts -eq $TagStyle) {
                    Write-Output "  [=] $name  bumpversion.tagstyle already $TagStyle"
                } else {
                    git -C $prepo config --local bumpversion.tagstyle $TagStyle
                    Write-Output "  [+] $name  bumpversion.tagstyle -> $TagStyle"
                }
            } elseif ($curts) {
                Write-Output "  [i] $name  bumpversion.tagstyle = $curts"
            } else {
                Write-Output "  [i] $name  bumpversion.tagstyle = namespaced (default) — pass --tagstyle plain for a single-artifact repo"
            }
            if ($fresh) { Show-ReadmeHint }
        }
        'status' {
            if ($cur -eq $hooksdir) {
                $curts = (git -C $prepo config --local bumpversion.tagstyle 2>$null)
                if (-not $curts) { $curts = 'namespaced' }
                Write-Output "  [ok] $name  $prepo (tagstyle=$curts)"
            }
            elseif ($cur) { Write-Output "  [? ] $name  core.hooksPath = $cur (not ours)" }
            else { Write-Output "  [  ] $name  not installed in $prepo" }
        }
        'clean' {
            if ($cur -eq $hooksdir) {
                git -C $prepo config --local --unset core.hooksPath
                Write-Output "  [-] $name  core.hooksPath unset ($prepo)"
            } else { Write-Output "  [.] $name  nothing to remove" }
            git -C $prepo config --local --unset bumpversion.tagstyle 2>$null
        }
    }
}

# --- plugin handler -----------------------------------------------------------
# --target claude: real plugin install via the claude CLI. Other targets have
# no plugin system — the tool falls back to a skill-link (a plugin directory
# also carries a SKILL.md).
function Handle-Plugin([string]$name, [string]$path, [string]$marketplace, [string]$plugin) {
    if ($Target -ne 'claude') {
        Handle-Skill $name $path
        return
    }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("  [!] $name  claude CLI not found — cannot install plugin")
        return
    }
    $srcdir = Join-Path $RepoRoot $path
    $ref = "$plugin@$marketplace"
    $pscope = if ($Scope -eq 'project') { 'project' } else { 'user' }
    $pdir = if ($Scope -eq 'project') { $Project } else { $PWD.Path }
    $installed = [bool](claude plugin list 2>$null | Select-String -SimpleMatch $ref -Quiet)
    switch ($Cmd) {
        'install' {
            Push-Location $pdir
            try {
                claude plugin marketplace add $srcdir --scope $pscope 2>$null | Out-Null
                if ($installed) {
                    Write-Output "  [=] $name  $ref already installed"
                } else {
                    claude plugin install $ref --scope $pscope 2>$null | Out-Null
                    if (claude plugin list 2>$null | Select-String -SimpleMatch $ref -Quiet) {
                        Write-Output "  [+] $name  $ref installed (scope $pscope)"
                    } else {
                        [Console]::Error.WriteLine("  [!] $name  install failed: $ref")
                    }
                }
            } finally { Pop-Location }
        }
        'status' {
            if ($installed) { Write-Output "  [ok] $name  $ref installed" }
            else { Write-Output "  [  ] $name  $ref not installed" }
        }
        'clean' {
            Push-Location $pdir
            try {
                if ($installed) {
                    claude plugin uninstall $ref -y 2>$null | Out-Null
                    Write-Output "  [-] $name  $ref uninstalled"
                } else {
                    Write-Output "  [.] $name  $ref not installed"
                }
                claude plugin marketplace remove $marketplace 2>$null | Out-Null
            } finally { Pop-Location }
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
    [Console]::Error.WriteLine("install: nothing in the catalog matches --what $What")
    Show-CatalogList
    exit 1
}

# --target is required unless every selected tool is a hook (hooks ignore it).
if (-not $Target) {
    $needsTarget = $selected | Where-Object { $_.type -ne 'hook' } | Select-Object -First 1
    if ($needsTarget) {
        [Console]::Error.WriteLine("install: --target is required (claude|codex|agents) — `"$($needsTarget.name)`" needs it")
        exit 2
    }
}

foreach ($tool in $selected) {
    switch ($tool.type) {
        'skill' { Handle-Skill $tool.name $tool.path }
        'hook'  { Handle-Hook $tool.name $tool.path }
        'plugin' { Handle-Plugin $tool.name $tool.path $tool.marketplace $tool.plugin }
        default {
            [Console]::Error.WriteLine("  [!] $($tool.name)  unknown type `"$($tool.type)`"")
        }
    }
}
exit 0
