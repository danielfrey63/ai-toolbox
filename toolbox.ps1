# toolbox.ps1 — install AI-Toolbox tools from the catalog.
#
# PowerShell port of toolbox.sh for Codex / Windows. See that file for
# the full description. Reads tools/catalog.json and dispatches per tool TYPE:
#   skill  — junction (Windows) / symlink (Linux/macOS) into a skills/ dir
#   hook   — point a repo's core.hooksPath at the toolbox hook directory
#   plugin — claude plugin marketplace add + install (--target claude); else skill-link
#   config — symlink a global config file (CLAUDE.md) into ~/.claude/
#   bin    — install a CLI as a function in the PowerShell $PROFILE — using
#            `&` (exec) or `.` (sourced, catalog "source: true")
#
# Usage:
#   toolbox.ps1 <install|status|remove> --target <claude|codex|agents>
#               [--scope global|project] [--project PATH] [--what all|<name>|<type>]
#               [--tagstyle plain|namespaced]
#
# --tagstyle applies only to hook installs — it sets the repo's
# bumpversion.tagstyle (plain = v<version> tags for a single-artifact repo).
#
# Idempotent: install re-links cleanly, remove deletes only our own links,
# a foreign file/dir at the target is never clobbered.
#
# Every install is recorded in a per-machine registry (see "Registry" in
# --help) so `status --all` / `remove --all` can sweep every install.

$APP_VERSION = '0.20.136'
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Catalog  = Join-Path $RepoRoot 'tools/catalog.json'

# --- help ---------------------------------------------------------------------
# General overview + per-switch detail. Every screen ends with the same
# switches one-liner so a user can pivot. Dispatched via `Show-Help <topic>`.
function Show-Help([string]$topic = '') {
    switch ($topic) {
        { $_ -in '', '--help', '-h' } {
            Write-Output @'
toolbox — install AI-Toolbox tools (Claude Code / Codex / agentskills).

Usage:
  toolbox <install|status|remove|list> [options]
  toolbox --help [<switch>]

Commands:
  install   Install selected tools (idempotent — safe to re-run).
  status    Report install state; with no args, sweeps the registry.
  remove    Remove selected tools (only ever our own links/config).
  list      Print the catalog (name, type, description).

For switch detail:  toolbox --help <switch>      e.g.  toolbox --help --target

Examples:
  toolbox list
  toolbox install --what cli
  toolbox install --what versioning-hooks --scope project
  toolbox status --all
'@
        }
        { $_ -in '--target', 'target' } {
            Write-Output @'
--target <claude|codex|agents>
  Where to install. Required, unless the selection is hook/config/bin-only.

  claude   Claude Code      skills link into <scope>/.claude/skills/
  codex    Codex CLI        skills link into <scope>/.codex/skills/
  agents   agentskills.io   skills link into <scope>/.agents/skills/

  Hooks (per-repo git config) and config/bin entries ignore --target.
  Plugins do a real `claude plugin` install for --target claude; for other
  targets they fall back to a skill-link.

  Example:
    toolbox install --what component-audit --target claude
'@
        }
        { $_ -in '--scope', 'scope' } {
            Write-Output @'
--scope <global|project>          Default: global.
  Where the install lives.

  global   Under $HOME  (~/.claude, ~/.codex, ~/.agents, ~/.local/bin, …).
  project  Under --project PATH  — for per-repo installs like the
           versioning git-hooks or project-scoped skills.

  Example:
    toolbox install --what versioning-hooks --scope project
'@
        }
        { $_ -in '--project', 'project' } {
            Write-Output @'
--project PATH                    Default: current directory.
  Project root for --scope project. Pass an absolute path to point the
  installer at a specific repo from anywhere.

  Examples:
    cd ~/Develop/myrepo; toolbox install --what versioning-hooks --scope project
    toolbox install --what versioning-hooks --scope project --project ~/Develop/myrepo
'@
        }
        { $_ -in '--what', 'what' } {
            Write-Output @'
--what <all|<tool-name>|<type>>   Default: all.
  Select catalog entries by exact name, by type, or `all`.

  Names are listed by `toolbox list`. Types are:
    skill   Skill directory, linked into a CLI's skills/.
    hook    Git hooks installed via core.hooksPath into a repo.
    plugin  Real `claude plugin` install (target=claude) or skill-link.
    config  Global config file (e.g. CLAUDE.md) into ~/.claude/.
    bin     Make a CLI available system-wide (exec or sourced shell function).

  Examples:
    toolbox install --what cli                     # by name (a bin entry)
    toolbox install --what skill --target claude   # by type
    toolbox install --target claude                # default --what all
'@
        }
        { $_ -in '--tagstyle', 'tagstyle' } {
            Write-Output @'
--tagstyle <plain|namespaced>     Hook installs only.
  Sets the repo's `bumpversion.tagstyle` git config — determines how the
  versioning post-commit hook tags releases.

  plain        Tags `v<version>`           single-artifact repo (one app).
  namespaced   Tags `<name>/v<version>`    default if unset; for repos with
                                           multiple versioned artifacts.

  Example:
    toolbox install --what versioning-hooks --scope project --tagstyle plain
'@
        }
        { $_ -in '--all', 'all' } {
            Write-Output @'
--all                             status / remove only.
  Act on every recorded install (the registry), ignoring --what.
  Bare `toolbox status` is equivalent to `status --all`.

  Registry: ${XDG_CONFIG_HOME:-~/.config}/ai-toolbox/installs.json (per
  machine) — the discovery index for project-scoped installs (hooks in
  arbitrary repos) that cannot otherwise be enumerated.

  `status --all` re-verifies every entry and prunes stale ones; `install`
  runs the same reconcile after each install.

  Examples:
    toolbox status --all
    toolbox remove --all     # uninstall everything recorded
'@
        }
        default {
            [Console]::Error.WriteLine("toolbox: unknown help topic: $topic")
            [Console]::Error.WriteLine('available: --target, --scope, --project, --what, --tagstyle, --all')
            exit 2
        }
    }
    Write-Output ''
    Write-Output 'Switches: --target  --scope  --project  --what  --tagstyle  --all  -h|--help'
}

# Print the catalog as a readable table — answers "what can I install?".
function Show-CatalogList {
    Write-Output "toolbox — available tools ($Catalog)"
    Write-Output 'Usage: toolbox <install|status|remove|list> [--target claude|codex|agents] [--scope global|project] [--project PATH] [--what all|<name>|<type>] [--tagstyle plain|namespaced] [--all] [-h|--help]'
    Write-Output ''
    Write-Output ('  {0,-20} {1,-7} {2}' -f 'NAME', 'TYPE', 'DESCRIPTION')
    foreach ($t in (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).tools) {
        Write-Output ('  {0,-20} {1,-7} {2}' -f $t.name, $t.type, $t.description)
    }
    Write-Output "`nSelect one with --what <name> or a group with --what <type>; default is all."
}

# --- command ------------------------------------------------------------------
$Cmd = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
if ($Cmd -in @('-h', '--help')) { Show-Help ([string]$args[1]); exit 0 }
if ($Cmd -notin @('install', 'status', 'remove', 'list')) {
    [Console]::Error.WriteLine("toolbox: missing or unknown command (install|status|remove|list)")
    exit 2
}

# --- options ------------------------------------------------------------------
$Scope = 'global'; $Target = ''; $Project = ''; $What = 'all'; $TagStyle = ''
$All = $false; $State = ''
$i = 1
while ($i -lt $args.Count) {
    $opt = [string]$args[$i]
    switch ($opt) {
        { $_ -in '--scope', '--target', '--project', '--what', '--tagstyle' } {
            if ($i + 1 -ge $args.Count) {
                [Console]::Error.WriteLine("toolbox: $opt needs a value"); exit 2
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
        '--all' { $All = $true; $i += 1 }
        { $_ -in '-h', '--help' } { Show-Help ([string]$args[$i + 1]); exit 0 }
        default { [Console]::Error.WriteLine("toolbox: unknown option: $opt"); exit 2 }
    }
}

# --- validate -----------------------------------------------------------------
# An empty --target is allowed here; whether it is required depends on the
# selected tool types and is checked once the catalog selection is known.
if ($Target -and $Target -notin @('claude', 'codex', 'agents')) {
    [Console]::Error.WriteLine("toolbox: invalid --target: $Target"); exit 2
}
if ($TagStyle -and $TagStyle -notin @('plain', 'namespaced')) {
    [Console]::Error.WriteLine("toolbox: invalid --tagstyle: $TagStyle"); exit 2
}
if ($Scope -eq 'project') {
    # --project defaults to the current directory.
    if (-not $Project) { $Project = $PWD.Path }
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        [Console]::Error.WriteLine("toolbox: --project path not found: $Project"); exit 2
    }
    $Project = (Resolve-Path -LiteralPath $Project).Path
} elseif ($Scope -ne 'global') {
    [Console]::Error.WriteLine("toolbox: invalid --scope: $Scope"); exit 2
}
if (-not (Test-Path -LiteralPath $Catalog)) {
    [Console]::Error.WriteLine("toolbox: catalog not found: $Catalog"); exit 1
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

# Symlink one artifact (file or directory) into a destination directory.
# Idempotent across install/status/remove; never clobbers a non-link.
# Shared by the skill and config handlers.
function Link-Artifact([string]$name, [string]$src, [string]$destdir) {
    $link = Join-Path $destdir (Split-Path -Leaf $src)
    if ($link -eq $src) {
        Write-Output "  [=] $name  source == target, skipped"; return
    }
    $isDir = Test-Path -LiteralPath $src -PathType Container
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue

    switch ($Cmd) {
        'install' {
            New-Item -ItemType Directory -Path $destdir -Force | Out-Null
            if ($item -and $item.Target -eq $src) {
                Write-Output "  [=] $name  already linked"; return
            }
            if ($item -and $item.LinkType) {
                if ($isDir) { [System.IO.Directory]::Delete($link, $false) }
                else        { [System.IO.File]::Delete($link) }
            } elseif ($item) {
                [Console]::Error.WriteLine("  [!] $name  exists and is not a link — skipped"); return
            }
            if ($IsWindows -and $isDir) {
                New-Item -ItemType Junction -Path $link -Target $src | Out-Null
            } else {
                New-Item -ItemType SymbolicLink -Path $link -Target $src | Out-Null
            }
            Write-Output "  [+] $name  -> $link"
        }
        'status' {
            if ($item -and $item.Target -eq $src) {
                Write-Output "  [ok] $name  $link"
                $script:State = 'ok'
            } elseif ($item) {
                Write-Output "  [? ] $name  $link (exists, not our link)"
            } else {
                Write-Output "  [ ] $name  not installed"
            }
        }
        'remove' {
            if ($item -and $item.Target -eq $src) {
                if ($isDir) { [System.IO.Directory]::Delete($link, $false) }
                else        { [System.IO.File]::Delete($link) }
                Write-Output "  [-] $name  removed"
            } else {
                Write-Output "  [.] $name  nothing to remove"
            }
        }
    }
}

function Handle-Skill([string]$name, [string]$path) {
    $src = Join-Path $RepoRoot $path
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        [Console]::Error.WriteLine("  [!] $name  source missing: $src"); return
    }
    Link-Artifact $name $src (Get-SkillDestDir)
}

# --- config handler -----------------------------------------------------------
# Symlinks a global config file (e.g. CLAUDE.md) into ~/.claude/. Config is
# user-global — global scope only, and --target is ignored.
function Handle-Config([string]$name, [string]$path) {
    $src = Join-Path $RepoRoot $path
    if ($Scope -ne 'global') {
        Write-Output "  [.] $name  config is global-only — use --scope global"
        return
    }
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        [Console]::Error.WriteLine("  [!] $name  source missing: $src"); return
    }
    Link-Artifact $name $src (Join-Path $HOME '.claude')
}

# --- bin handler --------------------------------------------------------------
# Makes a CLI available via a function in the user's $PROFILE (pwsh has no
# ~/.local/bin convention). Two modes (catalog flag `source: true`):
#   exec    (default): `& '<script>' @args`  — runs the script as a subprocess
#   source            : `. '<script>' @args` — dot-sources into the current
#                       shell (needed for env-setting tools like cc-profil)
# Global scope only, ignores --target. The bash port uses a ~/.local/bin
# symlink (exec) or a ~/.bashrc block (source) instead.
function Handle-Bin([string]$name, [string]$path, [string]$command, [bool]$sourced = $false) {
    if ($Scope -ne 'global') {
        Write-Output "  [.] $name  bin is global-only — use --scope global"
        return
    }
    # The PowerShell entry point is the .ps1 sibling of the catalogued script.
    $exe = Join-Path $RepoRoot ($path -replace '\.sh$', '.ps1')
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        [Console]::Error.WriteLine("  [!] $name  source missing: $exe"); return
    }
    $op       = if ($sourced) { '.' } else { '&' }
    $beg      = "# >>> ai-toolbox $command >>>"
    $end      = "# <<< ai-toolbox $command <<<"
    $block    = "$beg`nfunction $command { $op '$exe' @args }`n$end"
    $strip    = "(?s)\r?\n*$([regex]::Escape($beg)).*?$([regex]::Escape($end))"
    $current  = [string]$(if (Test-Path -LiteralPath $PROFILE) { Get-Content -LiteralPath $PROFILE -Raw })
    $hasBlock = [regex]::IsMatch($current, [regex]::Escape($beg))
    $rest     = ($current -replace $strip, '').TrimEnd()

    switch ($Cmd) {
        'install' {
            New-Item -ItemType Directory -Path (Split-Path -Parent $PROFILE) -Force | Out-Null
            Set-Content -LiteralPath $PROFILE -Value $(if ($rest) { "$rest`n`n$block" } else { $block })
            if ($hasBlock) { Write-Output "  [=] $name  $command already in `$PROFILE" }
            else           { Write-Output "  [+] $name  $command -> `$PROFILE" }
        }
        'status' {
            if ($hasBlock) {
                Write-Output "  [ok] $name  $command in `$PROFILE"
                $script:State = 'ok'
            } else {
                Write-Output "  [ ] $name  not installed"
            }
        }
        'remove' {
            if ($hasBlock) {
                Set-Content -LiteralPath $PROFILE -Value $rest
                Write-Output "  [-] $name  $command removed from `$PROFILE"
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
           <ai-toolbox>/toolbox.ps1 install --what versioning-hooks --scope project
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
                $script:State = 'ok'
            }
            elseif ($cur) { Write-Output "  [? ] $name  core.hooksPath = $cur (not ours)" }
            else { Write-Output "  [ ] $name  not installed in $prepo" }
        }
        'remove' {
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
            if ($installed) {
                Write-Output "  [ok] $name  $ref installed"
                $script:State = 'ok'
            }
            else { Write-Output "  [ ] $name  $ref not installed" }
        }
        'remove' {
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

# --- registry -----------------------------------------------------------------
# Records every install so `status --all` / `remove --all` can find them across
# all scopes, targets and projects. The registry is only a discovery index —
# each entry is re-verified against reality before any action, stale ones are
# pruned. Per machine, in the user config dir; never committed.
$cfgBase  = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
$Registry = Join-Path $cfgBase 'ai-toolbox/installs.json'

function Registry-Read {
    if (-not (Test-Path -LiteralPath $Registry)) { return @() }
    try { $raw = Get-Content -LiteralPath $Registry -Raw | ConvertFrom-Json }
    catch { return @() }
    # Heal legacy {value:[...], Count:n} envelopes that PS 5.1 leaves behind
    # when ConvertTo-Json fails to unroll a single-element array. Flatten any
    # such hull into its inner entries; pass real entries through unchanged.
    $flat = @()
    foreach ($e in @($raw)) {
        if ($null -eq $e) { continue }
        $isHull = $e.PSObject.Properties['value'] -and $e.PSObject.Properties['Count'] `
            -and $e.PSObject.Properties.Count -le 2
        if ($isHull) { $flat += @($e.value) } else { $flat += $e }
    }
    # Trim whitespace from every string field — heals pre-fix entries written
    # with stray spaces in tool/type/scope/target/project (e.g. type="bin ").
    $clean = foreach ($e in $flat) {
        if ($null -eq $e) { continue }
        $out = [ordered]@{}
        foreach ($p in $e.PSObject.Properties) {
            if ($p.Value -is [string]) { $out[$p.Name] = $p.Value.Trim() }
            else                       { $out[$p.Name] = $p.Value }
        }
        [pscustomobject]$out
    }
    # Dedup by key — multiple writes with whitespace-divergent fields can have
    # produced functionally identical entries that only differ post-trim.
    $seen = @{}; $uniq = @()
    foreach ($e in $clean) {
        $k = "$($e.tool)|$($e.type)|$($e.scope)|$($e.target)|$($e.project)"
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $uniq += $e }
    }
    return $uniq
}

function Registry-Write([object[]]$entries) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Registry) -Force | Out-Null
    $entries = @($entries) | Where-Object { $_ }
    if ($entries.Count -eq 0) {
        Set-Content -LiteralPath $Registry -Value '[]'
        return
    }
    # Serialise each entry on its own — ConvertTo-Json never gets to see the
    # outer array, so PS 5.1's single-element-unwrap and its {value, Count}
    # nested-array wrap both go away. We assemble the JSON array manually.
    $parts = foreach ($e in $entries) {
        ConvertTo-Json -InputObject $e -Depth 5 -Compress
    }
    Set-Content -LiteralPath $Registry -Value ("[`n  " + ($parts -join ",`n  ") + "`n]")
}

# Normalize scope/target/project for the registry key, per tool type. Handlers
# that ignore --target/--scope must not leak those into the key, or one install
# can be recorded as multiple entries that differ only by an ignored field.
function _Registry-Normalize([string]$type, [ref]$scope, [ref]$target, [ref]$project) {
    switch ($type) {
        'hook'   { $target.Value = '' }
        'config' { $scope.Value = 'global'; $target.Value = ''; $project.Value = '' }
        'bin'    { $scope.Value = 'global'; $target.Value = ''; $project.Value = '' }
    }
}

# Upsert an entry, keyed by tool + scope + target + project.
function Registry-Add([string]$tool, [string]$type, [string]$path,
                      [string]$scope, [string]$target, [string]$project) {
    _Registry-Normalize $type ([ref]$scope) ([ref]$target) ([ref]$project)
    $kept = @(Registry-Read | Where-Object {
        -not ($_.tool -eq $tool -and $_.scope -eq $scope -and
              $_.target -eq $target -and $_.project -eq $project)
    })
    $kept += [pscustomobject]@{
        tool = $tool; type = $type; path = $path
        scope = $scope; target = $target; project = $project
    }
    Registry-Write (@($kept) | Sort-Object tool, scope, target, project)
}

# Drop the entry with this key — used by a non---all remove.
function Registry-Remove([string]$tool, [string]$type, [string]$scope, [string]$target, [string]$project) {
    if (-not (Test-Path -LiteralPath $Registry)) { return }
    _Registry-Normalize $type ([ref]$scope) ([ref]$target) ([ref]$project)
    Registry-Write @(Registry-Read | Where-Object {
        -not ($_.tool -eq $tool -and $_.scope -eq $scope -and
              $_.target -eq $target -and $_.project -eq $project)
    })
}

# Run $Cmd against every registry entry. status: verify, report, prune stale
# entries. remove: uninstall each, then empty the registry. Entries carry
# only install parameters — the handlers re-verify against reality.
function Registry-Sweep {
    $entries = @(Registry-Read)
    if ($entries.Count -eq 0) {
        Write-Output '  (registry empty — nothing recorded)'
        if ($Cmd -eq 'remove') { Registry-Write @() }
        return
    }
    $kept = @()
    foreach ($e in $entries) {
        $script:Scope   = $e.scope
        $script:Target  = $e.target
        $script:Project = $e.project
        $script:State   = 'gone'
        switch ($e.type) {
            'skill'  { Handle-Skill  $e.tool $e.path }
            'hook'   { Handle-Hook   $e.tool $e.path }
            'config' { Handle-Config $e.tool $e.path }
            'bin' {
                $cat = (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).tools |
                    Where-Object { $_.name -eq $e.tool } | Select-Object -First 1
                Handle-Bin $e.tool $e.path $cat.command ([bool]$cat.source)
            }
            'plugin' {
                $cat = (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).tools |
                    Where-Object { $_.name -eq $e.tool } | Select-Object -First 1
                Handle-Plugin $e.tool $e.path $cat.marketplace $cat.plugin
            }
            default {
                [Console]::Error.WriteLine("  [!] $($e.tool)  unknown type `"$($e.type)`"")
            }
        }
        if ($Cmd -eq 'status') {
            # bin entries are kept regardless — the install mechanism is
            # port-specific (bash symlink vs pwsh $PROFILE), so a cross-port
            # check cannot tell "gone" from "installed by the other port".
            if ($script:State -eq 'ok' -or $e.type -eq 'bin') { $kept += $e }
            else { Write-Output '      -> pruned from registry (no longer installed)' }
        }
    }
    if ($Cmd -eq 'remove') { Registry-Write @() }
    else { Registry-Write @($kept) }
}

# `status` with no selection arguments shows the registry — bare `toolbox
# status` answers "what is installed?" without needing a --target.
if ($Cmd -eq 'status' -and -not $All -and -not $Target `
        -and $What -eq 'all' -and $Scope -eq 'global') {
    $All = $true
}

# --- registry sweep (--all) ---------------------------------------------------
if ($All) {
    if ($Cmd -notin @('status', 'remove')) {
        [Console]::Error.WriteLine("toolbox: --all is only valid for status and remove"); exit 2
    }
    Write-Output "toolbox $Cmd --all — sweeping the registry ($Registry)"
    Registry-Sweep
    exit 0
}

# --- dispatch -----------------------------------------------------------------
Write-Output "toolbox $Cmd — scope=$Scope target=$Target what=$What"

$tools = (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).tools
$selected = $tools | Where-Object {
    $What -eq 'all' -or $_.name -eq $What -or $_.type -eq $What
}
if (-not $selected) {
    [Console]::Error.WriteLine("toolbox: nothing in the catalog matches --what $What")
    Show-CatalogList
    exit 1
}

# --target is required unless every selected tool ignores it (hook, config, bin).
if (-not $Target) {
    $needsTarget = $selected | Where-Object { $_.type -ne 'hook' -and $_.type -ne 'config' -and $_.type -ne 'bin' } | Select-Object -First 1
    if ($needsTarget) {
        [Console]::Error.WriteLine("toolbox: --target is required (claude|codex|agents) — `"$($needsTarget.name)`" needs it")
        exit 2
    }
}

foreach ($tool in $selected) {
    switch ($tool.type) {
        'skill'  { Handle-Skill $tool.name $tool.path }
        'hook'   { Handle-Hook $tool.name $tool.path }
        'config' { Handle-Config $tool.name $tool.path }
        'bin'    { Handle-Bin $tool.name $tool.path $tool.command ([bool]$tool.source) }
        'plugin' { Handle-Plugin $tool.name $tool.path $tool.marketplace $tool.plugin }
        default {
            [Console]::Error.WriteLine("  [!] $($tool.name)  unknown type `"$($tool.type)`"")
        }
    }
    if ($tool.type -in @('skill', 'hook', 'config', 'bin', 'plugin')) {
        if ($Cmd -eq 'install') {
            Registry-Add $tool.name $tool.type $tool.path $Scope $Target $Project
        } elseif ($Cmd -eq 'remove') {
            Registry-Remove $tool.name $tool.type $Scope $Target $Project
        }
    }
}

# install reconciles the whole registry afterwards — the same verification as
# `status --all`, so stale entries are pruned on every install.
if ($Cmd -eq 'install') {
    Write-Output "`n-- registry reconcile --"
    $script:Cmd = 'status'
    Registry-Sweep
}
exit 0
