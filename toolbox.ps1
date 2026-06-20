# toolbox.ps1 — install AI-Toolbox tools from the catalog.
#
# PowerShell port of toolbox.sh for Codex / Windows. See that file for
# the full description. Reads tools/catalog.json and dispatches per tool TYPE:
#   skill  — junction (Windows) / symlink (Linux/macOS) into a skills/ dir
#   hook   — insert a managed version-bump block into a repo's pre/post-commit
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

$APP_VERSION = '0.33.205'
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
  reconcile Discover existing links into this repo (e.g. hand-made symlinks)
            and register any that are missing, so status/remove see them.

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

  Config/bin entries ignore --target. Hooks honour --target claude (also
  patches the project's .claude/settings.json with an edit-bump PostToolUse
  hook); --target codex|agents is not yet supported for the edit-bump path.
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
    hook    Git hooks installed as a managed line in a repo's pre/post-commit.
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
    Write-Output 'Usage: toolbox <install|status|remove|list|reconcile> [--target claude|codex|agents] [--scope global|project] [--project PATH] [--what all|<name>|<type>] [--tagstyle plain|namespaced] [--all] [-h|--help]'
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
if ($Cmd -notin @('install', 'status', 'remove', 'list', 'reconcile')) {
    [Console]::Error.WriteLine("toolbox: missing or unknown command (install|status|remove|list|reconcile)")
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
            if ($item -and (Test-SamePath (@($item.Target)[0]) $src)) {
                Write-Output "  [=] $name  already linked"; return
            }
            if ($item -and $item.LinkType) {
                if ($isDir) { [System.IO.Directory]::Delete($link, $false) }
                else        { [System.IO.File]::Delete($link) }
            } elseif ($item) {
                [Console]::Error.WriteLine("  [!] $name  exists and is not a link — skipped"); return
            }
            # $IsWindows is a PS6+ automatic; in Windows PowerShell 5.1 it is
            # $null/undefined. Use $env:OS, which is reliably "Windows_NT" on
            # all PowerShell editions when running on Windows. Junctions need
            # no admin rights, while SymbolicLink does unless Developer Mode
            # is on — Junction is the right default for directory links here.
            if ($env:OS -eq 'Windows_NT' -and $isDir) {
                New-Item -ItemType Junction -Path $link -Target $src | Out-Null
            } else {
                New-Item -ItemType SymbolicLink -Path $link -Target $src | Out-Null
            }
            Write-Output "  [+] $name  -> $link"
        }
        'status' {
            if ($item -and (Test-SamePath (@($item.Target)[0]) $src)) {
                Write-Output "  [ok] $name  $link"
                $script:State = 'ok'
            } elseif ($item) {
                Write-Output "  [? ] $name  $link (exists, not our link)"
            } else {
                Write-Output "  [ ] $name  not installed"
            }
        }
        'remove' {
            if ($item -and (Test-SamePath (@($item.Target)[0]) $src)) {
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
# Installs the versioning git-hooks into a repo by adding a single self-marked
# shim line to the active hooks dir's pre-commit/post-commit (core.hooksPath if
# the repo sets one, else .git/hooks). The line calls the toolbox impl; we never
# touch core.hooksPath, so existing hooks coexist and only our line is
# added/removed. Per-repo: needs --scope project.

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

# ── Claude-Code PostToolUse helpers (used by Handle-Hook when --target claude) ──
# Mirror of the Bash helpers in toolbox.sh — same two-stage heuristic:
#   1. command-string contains 'bump-version.sh'
#   2. the script behind that path carries an APP_VERSION= declaration at line
#      start (the AI-Toolbox self-marker). Skipped if the file is unreachable.

function Get-ClaudeHookCommand { 'bash "$(git rev-parse --show-toplevel)/../ai-toolbox/tools/bump-version.sh"' }

function Test-ClaudeHookMarker([string]$prepo) {
    $guess = Join-Path $prepo '../ai-toolbox/tools/bump-version.sh'
    if (-not (Test-Path -LiteralPath $guess)) { return $true }   # unreachable → accept stage-1
    return [bool](Select-String -LiteralPath $guess -Pattern '^\$?APP_VERSION\s*=' -Quiet)
}

function _Read-ClaudeSettings([string]$prepo) {
    $settings = Join-Path $prepo '.claude/settings.json'
    if (-not (Test-Path -LiteralPath $settings)) { return $null }
    try { return Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json -Depth 20 } catch { return $null }
}

function _Write-ClaudeSettings([string]$prepo, $obj) {
    $settings = Join-Path $prepo '.claude/settings.json'
    # PS 5.1 splits Split-Path's parameter sets — `-LiteralPath` + `-Parent` is
    # rejected ("Parameter set cannot be resolved"). -Parent is the default, so
    # drop it; works on both 5.1 and 7.x.
    $claudeDir = Split-Path -LiteralPath $settings
    if (-not (Test-Path -LiteralPath $claudeDir)) { New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null }
    ($obj | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $settings -Encoding UTF8
}

# Echo 'yes' | 'no' | 'no-settings' for the project's PostToolUse state.
function Get-ClaudeHookState([string]$prepo) {
    $json = _Read-ClaudeSettings $prepo
    if (-not $json) { return 'no-settings' }
    if (-not $json.PSObject.Properties.Match('hooks').Count) { return 'no' }
    if (-not $json.hooks.PSObject.Properties.Match('PostToolUse').Count) { return 'no' }
    foreach ($entry in @($json.hooks.PostToolUse)) {
        if ($entry.PSObject.Properties.Match('hooks').Count) {
            foreach ($h in @($entry.hooks)) {
                if ($h.command -match 'bump-version\.sh') { return 'yes' }
            }
        }
    }
    return 'no'
}

# Idempotent install of our PostToolUse:Edit|Write hook.
function Install-ClaudeHook([string]$name, [string]$prepo) {
    if ((Get-ClaudeHookState $prepo) -eq 'yes') {
        Write-Output "  [=] $name  claude PostToolUse already present"
        return
    }
    $json = _Read-ClaudeSettings $prepo
    if (-not $json) { $json = [pscustomobject]@{} }
    if (-not $json.PSObject.Properties.Match('hooks').Count) {
        $json | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $json.hooks.PSObject.Properties.Match('PostToolUse').Count) {
        $json.hooks | Add-Member -NotePropertyName PostToolUse -NotePropertyValue @() -Force
    }
    $entry = [pscustomobject]@{
        matcher = 'Edit|Write'
        hooks   = @([pscustomobject]@{
            type          = 'command'
            command       = Get-ClaudeHookCommand
            statusMessage = 'Version-Bump (AI-Toolbox)...'
        })
    }
    $json.hooks.PostToolUse = @(@($json.hooks.PostToolUse) + @($entry))
    _Write-ClaudeSettings $prepo $json
    $settings = Join-Path $prepo '.claude/settings.json'
    Write-Output "  [+] $name  claude PostToolUse -> $settings"
}

# Remove our PostToolUse entries — guarded by the two-stage marker check.
function Remove-ClaudeHook([string]$name, [string]$prepo) {
    $settings = Join-Path $prepo '.claude/settings.json'
    if (-not (Test-Path -LiteralPath $settings)) { return }
    if (-not (Test-ClaudeHookMarker $prepo)) {
        Write-Output "  [!] $name  claude PostToolUse: target script lacks APP_VERSION marker, refusing to remove"
        return
    }
    $json = _Read-ClaudeSettings $prepo
    if (-not $json -or -not $json.PSObject.Properties.Match('hooks').Count -or
        -not $json.hooks.PSObject.Properties.Match('PostToolUse').Count) { return }
    $kept = @()
    foreach ($entry in @($json.hooks.PostToolUse)) {
        $hasOurs = $false
        if ($entry.PSObject.Properties.Match('hooks').Count) {
            foreach ($h in @($entry.hooks)) {
                if ($h.command -match 'bump-version\.sh') { $hasOurs = $true; break }
            }
        }
        if (-not $hasOurs) { $kept += $entry }
    }
    if ($kept.Count -eq 0) {
        $json.hooks.PSObject.Properties.Remove('PostToolUse')
        if ($json.hooks.PSObject.Properties.Name.Count -eq 0) {
            $json.PSObject.Properties.Remove('hooks')
        }
    } else {
        $json.hooks.PostToolUse = $kept
    }
    _Write-ClaudeSettings $prepo $json
    Write-Output "  [-] $name  claude PostToolUse removed ($settings)"
}

# True when two paths denote the same target regardless of format. Two distinct
# format mismatches bite here and both used to make `status` prune a live
# install: (1) core.hooksPath is stored verbatim by git, so a hook set by the
# bash port (forward-slash MSYS form) never string-matches the backslash form
# this port computes; (2) a skill symlink's .Target is pure backslashes while
# Join-Path leaves the catalog's forward-slash subpath intact, yielding a mixed
# "…\ai-toolbox\.agents/skills/x" that never equals the all-backslash target.
# The separator-normalised compare catches both; Resolve-Path is the fallback
# that also folds drive-letter case and 8.3 names when the paths exist; the -eq
# fast path covers the same-format case (and unresolvable paths).
function Test-SamePath([string]$a, [string]$b) {
    if (-not $a) { return $false }
    if ($a -eq $b) { return $true }
    if ((($a -replace '\\', '/').TrimEnd('/')) -eq (($b -replace '\\', '/').TrimEnd('/'))) { return $true }
    $ra = (Resolve-Path -LiteralPath $a -ErrorAction SilentlyContinue)
    $rb = (Resolve-Path -LiteralPath $b -ErrorAction SilentlyContinue)
    if ($ra -and $rb) { return ($ra.Path -eq $rb.Path) }
    return $false
}

# ── managed-line helpers ─────────────────────────────────────────────────────
# Mirrors the sh port: we add a single, self-marked shim line to the repo's own
# hook scripts instead of hijacking core.hooksPath, so existing hooks coexist and
# only our line is ever added or removed. The trailing marker comment tags
# ownership. Git runs hook scripts but never rewrites them, so it is safe.
#
# The shim line is path-free: it calls `toolbox-bump <hook>` — a tiny launcher on
# PATH (~/.local/bin, generated per machine), so the committed/tracked hook
# carries no machine-specific path and stays portable.
$script:HookMark = '# ai-toolbox:versioning-hooks (managed - do not edit)'

# ~/.local/bin is on git's `sh` PATH on both Linux and Windows git-bash, so git
# hooks can call the launchers by name (unlike PowerShell-$PROFILE bins).
$script:LauncherDir = Join-Path $env:USERPROFILE '.local/bin'

# The toolbox path in a form git's sh understands: D:\x -> /d/x.
function Get-ShToolboxPath {
    $p = ($RepoRoot -replace '\\', '/')
    if ($p -match '^([A-Za-z]):(.*)$') { $p = '/' + $matches[1].ToLower() + $matches[2] }
    return $p
}

# Generate (idempotently) the two POSIX launchers git hooks call by name:
#   toolbox-bump <pre-commit|post-commit>  -> the staged-artifact bump impl
#   bump-version <args...>                 -> the atomic per-file bumper
# Toolbox path baked in (machine-local; these live under $HOME).
function Ensure-Launchers {
    $tb = Get-ShToolboxPath
    New-Item -ItemType Directory -Force -Path $script:LauncherDir | Out-Null
    $bump = @"
#!/bin/sh
# bump-version — AI-Toolbox per-file version bumper, on PATH for git hooks.
# Generated by ``toolbox install``; regenerated on every hook install.
exec sh "$tb/tools/bump-version.sh" "`$@"
"@
    $hook = @"
#!/bin/sh
# toolbox-bump — AI-Toolbox git-hook entry point, on PATH so repo hooks invoke
# the versioning impl by name (no path baked into the committed hook).
# Generated by ``toolbox install``; regenerated on every hook install.
[ -n "`$1" ] || { echo 'usage: toolbox-bump <pre-commit|post-commit> [args]' >&2; exit 2; }
hook=`$1; shift
exec sh "$tb/tools/githooks/`$hook" "`$@"
"@
    Write-Launcher (Join-Path $script:LauncherDir 'bump-version') ($bump -replace "`r`n", "`n")
    Write-Launcher (Join-Path $script:LauncherDir 'toolbox-bump') ($hook -replace "`r`n", "`n")
    $shPath = (& sh -c 'printf %s "$PATH"' 2>$null)
    $shDir = ($script:LauncherDir -replace '\\', '/'); if ($shDir -match '^([A-Za-z]):(.*)$') { $shDir = '/' + $matches[1].ToLower() + $matches[2] }
    if ($shPath -and (":${shPath}:" -notlike "*:${shDir}:*")) {
        Write-Output "  [i] versioning-hooks   note: $shDir is not on git's sh PATH — add it so hooks find the launcher"
    }
}

# Write a launcher only if missing or changed (idempotent), LF, no BOM.
function Write-Launcher([string]$path, [string]$body) {
    $cur = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllText($path) } else { $null }
    if ($cur -ne $body) {
        [System.IO.File]::WriteAllText($path, $body)
    }
}

# A legacy install pointed core.hooksPath at our SHARED toolbox dir (pre-block
# era). We must never write a per-repo block there; such installs need migrating.
function Test-LegacyHookPath([string]$prepo) {
    $cur = (git -C $prepo config --local core.hooksPath 2>$null)
    return [bool]($cur -and (Test-SamePath $cur (Join-Path $RepoRoot 'tools/githooks')))
}

# Active hooks dir: core.hooksPath if set (and not our shared toolbox dir), else
# the default .git/hooks. A legacy pointer at the toolbox dir is treated as unset
# so we never write our block into the toolbox itself.
function Get-ActiveHooksDir([string]$prepo) {
    $cur = (git -C $prepo config --local core.hooksPath 2>$null)
    if ($cur -and -not (Test-SamePath $cur (Join-Path $RepoRoot 'tools/githooks'))) {
        if ([System.IO.Path]::IsPathRooted($cur)) { return $cur }
        return (Join-Path $prepo $cur)
    }
    return (Join-Path $prepo '.git/hooks')
}

# The self-marked, path-free shim line for which=pre|post. Calls the on-PATH
# `toolbox-bump` launcher, so the committed hook carries no machine-specific path.
function Get-HookShimLine([string]$which) {
    ('toolbox-bump {0}-commit   {1}' -f $which, $script:HookMark)
}

# True when the repo's installed pre-commit shim is the portable (toolbox-bump)
# form. A marked line still hard-coding a path is a pre-launcher install to migrate.
function Test-HookShimPortable([string]$prepo) {
    $file = Join-Path (Get-ActiveHooksDir $prepo) 'pre-commit'
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $line = @(Get-HookLines $file | Where-Object { $_.Contains($script:HookMark) })[0]
    return [bool]($line -and $line.Contains('toolbox-bump'))
}

# Read a hook file as LF lines (one trailing newline trimmed); @() if missing.
function Get-HookLines([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $t = ([System.IO.File]::ReadAllText($file) -replace "`r`n", "`n")
    if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
    if ($t -eq '') { return @() }
    # Split already yields an array; callers re-wrap with @(...). Do NOT use the
    # ,(...) array-wrap here — it nests the array and collapses on flatten.
    return $t.Split("`n")
}

# Write hook lines as LF text with exactly one trailing newline (no BOM/CRLF).
function Set-HookFile([string]$file, [string[]]$lines) {
    [System.IO.File]::WriteAllText($file, ($lines -join "`n") + "`n")
}

# Install/refresh our line in <active>/<which>-commit. Returns 'added'|'refreshed'.
function Install-HookBlock([string]$prepo, [string]$which) {
    $dir = Get-ActiveHooksDir $prepo
    $file = Join-Path $dir "$which-commit"
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $line = Get-HookShimLine $which
    $lines = @(Get-HookLines $file)
    if ($lines.Count -eq 0) { $lines = @('#!/bin/sh') }
    if ($lines | Where-Object { $_.Contains($script:HookMark) }) {
        # Replace our marked line in place (first match wins; others dropped).
        $new = @(); $done = $false
        foreach ($l in $lines) {
            if ($l.Contains($script:HookMark)) { if (-not $done) { $new += $line; $done = $true } }
            else { $new += $l }
        }
        Set-HookFile $file $new
        return 'refreshed'
    }
    Set-HookFile $file (@($lines) + @($line))
    return 'added'
}

# Strip our marked line from <active>/<which>-commit; delete the file if only a
# shebang (or blank lines) remains. Returns 'removed'|'absent'.
function Remove-HookBlock([string]$prepo, [string]$which) {
    $dir = Get-ActiveHooksDir $prepo
    $file = Join-Path $dir "$which-commit"
    $lines = @(Get-HookLines $file)
    if ($lines.Count -eq 0 -or -not ($lines | Where-Object { $_.Contains($script:HookMark) })) { return 'absent' }
    $kept = @($lines | Where-Object { -not $_.Contains($script:HookMark) })
    while ($kept.Count -gt 0 -and $kept[-1].Trim() -eq '') {
        if ($kept.Count -eq 1) { $kept = @() } else { $kept = $kept[0..($kept.Count - 2)] }
    }
    $nontrivial = @($kept | Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^#!' })
    if ($nontrivial.Count -eq 0) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    } else {
        Set-HookFile $file $kept
    }
    return 'removed'
}

# True when our marked line is present in the active pre-commit.
function Test-HookBlockPresent([string]$prepo) {
    $file = Join-Path (Get-ActiveHooksDir $prepo) 'pre-commit'
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    return [bool](@(Get-HookLines $file) | Where-Object { $_.Contains($script:HookMark) })
}

function Handle-Hook([string]$name, [string]$path) {
    if ($Scope -ne 'project') {
        Write-Output "  [.] $name  hooks are per-repo — pass --scope project"
        return
    }
    $prepo = (git -C $Project rev-parse --show-toplevel 2>$null)
    if (-not $prepo) {
        [Console]::Error.WriteLine("  [!] $name  --project is not a git repo: $Project"); return
    }
    $hd = Get-ActiveHooksDir $prepo
    switch ($Cmd) {
        'install' {
            # Migrate a legacy install: drop the core.hooksPath that pointed at
            # our shared toolbox dir, so git uses .git/hooks where the block goes.
            if (Test-LegacyHookPath $prepo) {
                git -C $prepo config --local --unset core.hooksPath
                Write-Output "  [-] $name  legacy core.hooksPath unset — migrating to managed line"
            }
            # Ensure the on-PATH launchers exist (the shim line calls them).
            Ensure-Launchers
            $fresh = $false
            $vpre = Install-HookBlock $prepo 'pre'
            $vpost = Install-HookBlock $prepo 'post'
            if ($vpre -eq 'added') { Write-Output "  [+] $name  pre-commit block added -> $hd/pre-commit"; $fresh = $true }
            else { Write-Output "  [=] $name  pre-commit block refreshed ($hd/pre-commit)" }
            if ($vpost -eq 'added') { Write-Output "  [+] $name  post-commit block added -> $hd/post-commit"; $fresh = $true }
            else { Write-Output "  [=] $name  post-commit block refreshed ($hd/post-commit)" }
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
            # The post-commit hook creates tags; push.followTags makes the
            # next `git push` carry them along, so tags never silently lag
            # behind commits on the remote.
            $curft = (git -C $prepo config --local push.followTags 2>$null)
            if ($curft -eq 'true') {
                Write-Output "  [=] $name  push.followTags already true"
            } else {
                git -C $prepo config --local push.followTags true
                Write-Output "  [+] $name  push.followTags -> true"
            }
            # --target claude: also install the Claude-Code PostToolUse hook
            # so per-edit BUILD bumps work. The "claude was requested" bit is
            # tracked in git config (bumpversion.claudehook) so status knows
            # to expect the settings hook on later runs.
            switch ($Target) {
                'claude' {
                    Install-ClaudeHook $name $prepo
                    git -C $prepo config --local bumpversion.claudehook true | Out-Null
                }
                'codex'  { Write-Output "  [.] $name  edit-bump PostToolUse not yet supported for --target codex" }
                'agents' { Write-Output "  [.] $name  edit-bump PostToolUse not yet supported for --target agents" }
            }
            if ($fresh) { Show-ReadmeHint }
        }
        'status' {
            # Single-line status: the claude PostToolUse verdict is folded
            # into the `(tagstyle=…)` suffix when the bumpversion.claudehook
            # flag is set on this repo. Missing entries flip the row marker
            # to [! ] and bump $script:State to 'partial' (not 'gone' — the
            # primary git-hook is fine, just the secondary aspect is incomplete).
            $clSuffix = ''
            $clState = ''
            $wantsClaude = (git -C $prepo config --local --bool bumpversion.claudehook 2>$null)
            if ($wantsClaude -eq 'true') {
                $clState = Get-ClaudeHookState $prepo
                switch ($clState) {
                    'yes'         { $clSuffix = ', claude=present' }
                    'no'          { $clSuffix = ', claude=missing-from-settings' }
                    'no-settings' { $clSuffix = ', claude=missing-no-settings' }
                }
            }
            if (Test-HookBlockPresent $prepo) {
                $curts = (git -C $prepo config --local bumpversion.tagstyle 2>$null)
                if (-not $curts) { $curts = 'namespaced' }
                if (-not (Test-HookShimPortable $prepo)) {
                    Write-Output "  [! ] $name  $prepo (old shim path — re-install to migrate to toolbox-bump$clSuffix)"
                    $script:State = 'partial'
                } elseif ($clState -eq 'no' -or $clState -eq 'no-settings') {
                    Write-Output "  [! ] $name  $prepo (tagstyle=$curts$clSuffix)"
                    $script:State = 'partial'
                } else {
                    Write-Output "  [ok] $name  $prepo (tagstyle=$curts$clSuffix)"
                    $script:State = 'ok'
                }
            }
            elseif (Test-LegacyHookPath $prepo) {
                Write-Output "  [! ] $name  $prepo (legacy core.hooksPath — re-install to migrate$clSuffix)"
                $script:State = 'partial'
            }
            else { Write-Output "  [ ] $name  not installed in $prepo$clSuffix" }
        }
        'remove' {
            $migrated = $false
            if (Test-LegacyHookPath $prepo) {
                git -C $prepo config --local --unset core.hooksPath
                Write-Output "  [-] $name  legacy core.hooksPath unset ($prepo)"
                $migrated = $true
            }
            $vpre = Remove-HookBlock $prepo 'pre'
            $vpost = Remove-HookBlock $prepo 'post'
            if ($vpre -eq 'removed') { Write-Output "  [-] $name  pre-commit block removed ($hd/pre-commit)" }
            if ($vpost -eq 'removed') { Write-Output "  [-] $name  post-commit block removed ($hd/post-commit)" }
            if (-not $migrated -and $vpre -eq 'absent' -and $vpost -eq 'absent') { Write-Output "  [.] $name  nothing to remove" }
            git -C $prepo config --local --unset bumpversion.tagstyle 2>$null
            git -C $prepo config --local --unset push.followTags 2>$null
            # Remove the claude PostToolUse hook if the flag says we installed it.
            if ((git -C $prepo config --local --bool bumpversion.claudehook 2>$null) -eq 'true') {
                Remove-ClaudeHook $name $prepo
                git -C $prepo config --local --unset bumpversion.claudehook 2>$null
            }
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
    # config/bin are always global, repo-agnostic; their target is meaningless.
    # hook keeps target in the key — the claude PostToolUse patching in
    # .claude/settings.json is target-specific even though core.hooksPath is
    # repo-wide, so the same repo can legitimately carry several hook entries
    # (target="" = bare git-hook, target="claude" = git-hook + claude patch).
    switch ($type) {
        'config' { $scope.Value = 'global'; $target.Value = ''; $project.Value = '' }
        'bin'    { $scope.Value = 'global'; $target.Value = ''; $project.Value = '' }
    }
    # Path keys: '/' separators + no trailing slash. Resolve-Path on Windows
    # gives backslashes, `git rev-parse --show-toplevel` gives forward slashes,
    # raw user input may have a trailing slash — without normalization the
    # same repo would get keyed multiple ways. Symmetric with the sh port.
    if ($project.Value) {
        $project.Value = ($project.Value -replace '\\', '/') -replace '/+$', ''
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
    # Heal legacy entries:
    #   (1) Re-apply per-type field normalization for config/bin (they are
    #       repo-agnostic and always global) so any legacy non-empty target/
    #       project/scope on them collapses. Hook entries are left alone — for
    #       hooks `target` is meaningful (the claude PostToolUse patching is
    #       target-specific) and stays in the key.
    #   (2) Normalize project paths to forward slashes, no trailing slash, so
    #       `D:\foo` and `D:/foo/` pairs collapse to one entry. Symmetric with
    #       _Registry-Normalize.
    #   (3) Dedup by exact key.
    #   (4) Hook-target conflict resolution: same repo with both target="" and
    #       target="claude" picks the entry that matches reality (probed via
    #       Get-ClaudeHookState). The other entry is the artifact.
    # Mirrors the jq pipeline + _heal_hook_targets in registry_sweep (sh port).
    $raw = @(Registry-Read)
    foreach ($e in $raw) {
        switch ($e.type) {
            'config' { $e.scope = 'global'; $e.target = ''; $e.project = '' }
            'bin'    { $e.scope = 'global'; $e.target = ''; $e.project = '' }
        }
        if ($e.PSObject.Properties.Match('project').Count -and $e.project) {
            $e.project = ($e.project -replace '\\', '/') -replace '/+$', ''
        }
    }
    $seen = @{}
    $deduped = @()
    foreach ($e in $raw) {
        $key = '{0}|{1}|{2}|{3}|{4}' -f $e.tool, $e.type, $e.scope, $e.target, $e.project
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $deduped += $e
        }
    }
    # Hook-target conflict resolution. Group same-repo hook entries (same
    # tool/scope/project, differing only in target). For each group probe
    # reality — does the project carry our claude PostToolUse? — and produce
    # one winner whose target matches reality. Falls back to first entry if
    # no exact match exists, and re-stamps its target to the expected value,
    # so a lone legacy entry with the wrong target gets healed in place.
    $entries = @($deduped | Where-Object { $_.type -ne 'hook' })
    $hookGroups = $deduped | Where-Object { $_.type -eq 'hook' } |
        Group-Object { "$($_.tool)|$($_.scope)|$($_.project)" }
    foreach ($g in $hookGroups) {
        $group = @($g.Group)
        $proj = $group[0].project
        $state = if ($proj) { Get-ClaudeHookState $proj } else { 'no' }
        $wantTarget = if ($state -eq 'yes') { 'claude' } else { '' }
        $match = @($group | Where-Object { $_.target -eq $wantTarget })
        $winner = if ($match.Count -gt 0) { $match[0] } else { $group[0] }
        $winner.target = $wantTarget
        $entries += $winner
    }
    $entries = @($entries | Sort-Object tool, scope, target, project)
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
            # `partial` means the primary install (e.g. git-hook) is intact
            # but a secondary aspect (claude PostToolUse) is missing — keep
            # the entry so the user has a punch-list, don't prune it.
            if ($script:State -eq 'ok' -or $script:State -eq 'partial' -or $e.type -eq 'bin') { $kept += $e }
            else { Write-Output '      -> pruned from registry (no longer installed)' }
        }
    }
    if ($Cmd -eq 'remove') { Registry-Write @() }
    else { Registry-Write @($kept) }
}

# True when an entry with this exact key already lives in the registry.
function Registry-Has([string]$tool, [string]$type, [string]$scope, [string]$target, [string]$project) {
    return [bool](@(Registry-Read | Where-Object {
                $_.tool -eq $tool -and $_.type -eq $type -and $_.scope -eq $scope -and
                $_.target -eq $target -and $_.project -eq $project
            }).Count)
}

# Adopt one symlink if it points into this repo and matches a catalog tool.
$script:reconcileAdopted = 0
function Reconcile-Adopt([string]$link, [string]$regtype, [string]$sc, [string]$tg) {
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') { return }
    $tgt = (@($item.Target)[0] -replace '\\', '/')
    $prefix = (($RepoRoot -replace '\\', '/').TrimEnd('/')) + '/'
    if (-not $tgt.StartsWith($prefix)) { return }
    $rel = $tgt.Substring($prefix.Length)
    $cat = (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).tools |
        Where-Object { $_.path -eq $rel } | Select-Object -First 1
    if (-not $cat) { return }
    $tgLabel = if ($tg) { ", $tg" } else { '' }
    if (Registry-Has $cat.name $regtype $sc $tg '') {
        Write-Output ("  [=] {0,-18} already registered ({1}{2})" -f $cat.name, $regtype, $tgLabel)
    } else {
        Registry-Add $cat.name $regtype $rel $sc $tg ''
        Write-Output ("  [+] {0,-18} adopted ({1}{2}) -> {3}" -f $cat.name, $regtype, $tgLabel, $link)
        $script:reconcileAdopted++
    }
    if ($cat.type -ne $regtype) {
        Write-Output "      catalog declares type=$($cat.type); recorded as $regtype to match the on-disk link"
    }
}

# Adopt one repo's versioning hook if our managed line sits in the active hooks
# dir's pre-commit but the registry has no matching entry. The recorded target
# mirrors reality: claude when the repo carries our claudehook flag, else bare.
# Repos without our block are silently skipped. Mirrors _adopt_repo_hook (sh).
function Reconcile-AdoptRepoHook([string]$repo) {
    $cat = (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).tools |
        Where-Object { $_.type -eq 'hook' } | Select-Object -First 1
    if (-not $cat) { return }
    $prepo = (git -C $repo rev-parse --show-toplevel 2>$null)
    if (-not $prepo) { return }
    if (-not (Test-HookBlockPresent $prepo)) { return }
    $proj = ($prepo -replace '\\', '/').TrimEnd('/')
    $tg = if ((git -C $prepo config --local --bool bumpversion.claudehook 2>$null) -eq 'true') { 'claude' } else { '' }
    $tgLabel = if ($tg) { ", $tg" } else { '' }
    if (Registry-Has $cat.name 'hook' 'project' $tg $proj) {
        Write-Output ("  [=] {0,-18} already registered (hook{1}) {2}" -f $cat.name, $tgLabel, $proj)
    } else {
        Registry-Add $cat.name 'hook' $cat.path 'project' $tg $proj
        Write-Output ("  [+] {0,-18} adopted (hook{1}) -> {2}" -f $cat.name, $tgLabel, $proj)
        $script:reconcileAdopted++
    }
}

# Discover AI-Toolbox installs that exist on disk but were never recorded — e.g.
# a skill symlinked by hand, outside `toolbox install`. Walks the global link
# destinations (per-target skills dirs, the ~/.claude config dir, ~/.local/bin),
# finds every symlink pointing into THIS repo, matches it to a catalog tool by
# the linked path, and upserts a registry entry for any that is missing — so
# `status --all` / `remove --all` see them. Always records the on-disk form (a
# symlink => type "skill"); when the catalog declares a different type it says so
# but still adopts reality. Project-scope installs (per-repo hooks/skills) can't
# be found by a global scan — pass `--project PATH` to also adopt project-scoped
# versioning hooks: if PATH is a git repo its hook is adopted, otherwise every
# immediate child repo of PATH is scanned. Mirrors registry_reconcile in the sh port.
function Reconcile-Registry {
    Write-Output "toolbox reconcile — discovering links into $RepoRoot"
    $script:reconcileAdopted = 0
    foreach ($target in @('claude', 'codex', 'agents')) {
        $dir = Join-Path $HOME ".$target/skills"
        if (Test-Path -LiteralPath $dir) {
            foreach ($l in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                Reconcile-Adopt $l.FullName 'skill' 'global' $target
            }
        }
    }
    $dir = Join-Path $HOME '.claude'
    if (Test-Path -LiteralPath $dir) {
        foreach ($l in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            Reconcile-Adopt $l.FullName 'config' 'global' ''
        }
    }
    $dir = Join-Path $HOME '.local/bin'
    if (Test-Path -LiteralPath $dir) {
        foreach ($l in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            Reconcile-Adopt $l.FullName 'bin' 'global' ''
        }
    }
    # Project-scoped versioning hooks (--project PATH). A global scan cannot
    # find these — git config is per-repo. PATH itself a repo => adopt it;
    # otherwise scan its immediate children for repos carrying our hook.
    if ($Project) {
        $root = (Resolve-Path -LiteralPath $Project -ErrorAction SilentlyContinue)
        if ($root) {
            Write-Output "  scanning project hooks under $($root.Path)"
            if (Test-Path -LiteralPath (Join-Path $root.Path '.git')) {
                Reconcile-AdoptRepoHook $root.Path
            } else {
                foreach ($d in (Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue)) {
                    if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) {
                        Reconcile-AdoptRepoHook $d.FullName
                    }
                }
            }
        } else {
            [Console]::Error.WriteLine("  [!] reconcile --project path not found: $Project")
        }
    }
    Write-Output ("  {0} new install(s) adopted`n`n-- registry status after reconcile --" -f $script:reconcileAdopted)
    $script:Cmd = 'status'
    Registry-Sweep
}

# `status` with no selection arguments shows the registry — bare `toolbox
# status` answers "what is installed?" without needing a --target.
if ($Cmd -eq 'status' -and -not $All -and -not $Target `
        -and $What -eq 'all' -and $Scope -eq 'global') {
    $All = $true
}

# reconcile is a global discovery sweep — no selection/target needed.
if ($Cmd -eq 'reconcile') { Reconcile-Registry; exit 0 }

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
    # Prefix-match fallback: if --what is an unambiguous prefix of exactly one
    # name or type (or "all"), resolve to that. Ambiguity is reported back so
    # the user can re-issue the command with a longer prefix. Exact matches
    # always win above and never reach this branch.
    $pool = @($tools.name + $tools.type + 'all' | Sort-Object -Unique)
    $candidates = @($pool | Where-Object { $_.StartsWith($What) })
    if ($candidates.Count -eq 0) {
        [Console]::Error.WriteLine("toolbox: nothing in the catalog matches --what $What")
        Show-CatalogList
        exit 1
    }
    if ($candidates.Count -gt 1) {
        [Console]::Error.WriteLine("toolbox: --what $What is ambiguous — candidates:")
        foreach ($c in $candidates) { [Console]::Error.WriteLine("  $c") }
        exit 2
    }
    Write-Output "  [i] --what $What -> $($candidates[0])"
    $What = $candidates[0]
    $selected = $tools | Where-Object {
        $What -eq 'all' -or $_.name -eq $What -or $_.type -eq $What
    }
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
