# Migrates project path references after moving a directory tree, so Claude Code
# and VS Code reopen all projects without re-searching them.
#
# Covers:
#   1. ~/.claude.json                  (project keys, MCP configs, history entries)
#   2. ~/.claude/settings.json         (+ settings.local.json if present)
#   3. ~/.claude/projects/<encoded>    (renames path-encoded project dirs, keeps
#                                       sessions/memory; also fixes paths inside *.md)
#   4. VS Code storage.json            (recently opened, profile associations)
#   5. VS Code global state.vscdb      (recently opened URI list; needs sqlite3)
#   6. VS Code workspaceStorage/*/workspace.json
#   7. *.code-workspace files under the new location
#
# Idempotent: re-runs find nothing left to replace. Each modified file gets a
# one-time backup "<name>.pre-migration.bak" next to it (never overwritten).
#
# IMPORTANT: Close Claude Code AND VS Code before running (both rewrite their
# state files on exit and would undo the migration).
#
# Usage:
#   pwsh -File migrate-project-paths.ps1 -DryRun     # show what would change
#   pwsh -File migrate-project-paths.ps1             # apply

param(
    [string]$OldPrefix = 'D:\Meine Ablage\Develop\github',
    [string]$NewPrefix = 'D:\Develop\github',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:changes = 0

# Build all textual representations of the prefix that tools use on disk:
# escape levels (\ , \\ , \\\\ for JSON nested in JSON), forward slashes,
# URI encoding (%3A / %20), each with upper- and lowercase drive letter.
function Get-Variants([string]$old, [string]$new) {
    $bodyForms = @(
        @{ o = $old.Substring(2); n = $new.Substring(2); drives = @(':') }
        @{ o = $old.Substring(2).Replace('\', '\\'); n = $new.Substring(2).Replace('\', '\\'); drives = @(':') }
        @{ o = $old.Substring(2).Replace('\', '\\\\'); n = $new.Substring(2).Replace('\', '\\\\'); drives = @(':') }
        @{ o = $old.Substring(2).Replace('\', '/'); n = $new.Substring(2).Replace('\', '/'); drives = @(':') }
        @{ o = $old.Substring(2).Replace('\', '/').Replace(' ', '%20');
           n = $new.Substring(2).Replace('\', '/').Replace(' ', '%20'); drives = @(':', '%3A') }
    )
    $result = foreach ($f in $bodyForms) {
        foreach ($sep in $f.drives) {
            foreach ($case in @($old.Substring(0, 1).ToUpper(), $old.Substring(0, 1).ToLower())) {
                , @(($case + $sep + $f.o), ($case + $sep + $f.n))
            }
        }
    }
    $result
}
$variants = Get-Variants $OldPrefix $NewPrefix

function Backup-Once([string]$path) {
    $bak = "$path.pre-migration.bak"
    if (-not (Test-Path $bak)) { Copy-Item $path $bak }
}

function Update-TextFile([string]$path) {
    if (-not (Test-Path $path)) { return }
    $raw = Get-Content $path -Raw
    if ([string]::IsNullOrEmpty($raw)) { return }   # Get-Content -Raw yields $null for empty files
    $updated = $raw
    foreach ($v in $variants) { $updated = $updated.Replace($v[0], $v[1]) }
    if ($updated -eq $raw) { return }
    $script:changes++
    if ($DryRun) { Write-Host "[dry-run] would update: $path"; return }
    Backup-Once $path
    Set-Content $path $updated -NoNewline
    Write-Host "updated: $path"
}

# --- 1+2: Claude Code JSON configs -----------------------------------------
Update-TextFile "$env:USERPROFILE\.claude.json"
Update-TextFile "$env:USERPROFILE\.claude\settings.json"
Update-TextFile "$env:USERPROFILE\.claude\settings.local.json"

# --- 3: Claude Code project dirs (path-encoded names, contain sessions/memory)
$encOld = $OldPrefix -replace '[:\\/ ]', '-'
$encNew = $NewPrefix -replace '[:\\/ ]', '-'
$projRoot = "$env:USERPROFILE\.claude\projects"
if (Test-Path $projRoot) {
    foreach ($dir in Get-ChildItem $projRoot -Directory | Where-Object Name -like "$encOld*") {
        $newName = $encNew + $dir.Name.Substring($encOld.Length)
        $script:changes++
        if (Test-Path (Join-Path $projRoot $newName)) {
            Write-Warning "target exists, NOT renaming: $($dir.Name) -> $newName (merge manually)"
            continue
        }
        if ($DryRun) { Write-Host "[dry-run] would rename: $($dir.Name) -> $newName" }
        else { Rename-Item $dir.FullName $newName; Write-Host "renamed: $($dir.Name) -> $newName" }
    }
    # Fix absolute paths inside memory/session markdown of ALL projects.
    foreach ($md in Get-ChildItem $projRoot -Recurse -Filter *.md -File) { Update-TextFile $md.FullName }
}

# --- 4-6: VS Code (stable and Insiders profiles) ---------------------------
foreach ($codeDir in @("$env:APPDATA\Code", "$env:APPDATA\Code - Insiders")) {
    if (-not (Test-Path $codeDir)) { continue }
    if (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue) {
        Write-Warning "VS Code is running - close it first, then re-run. Skipping $codeDir"
        continue
    }
    Update-TextFile "$codeDir\User\globalStorage\storage.json"

    # Extension storages keep their own path caches (e.g. kilo-code index files).
    foreach ($json in Get-ChildItem "$codeDir\User\globalStorage" -Recurse -Filter *.json -File -ErrorAction SilentlyContinue) {
        Update-TextFile $json.FullName
    }

    function Update-StateDb([string]$vscdb) {
        if (-not (Test-Path $vscdb)) { return }
        $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
        if (-not $sqlite) { Write-Warning "sqlite3 not found - skipped $vscdb"; return }
        $hits = 0
        foreach ($v in $variants) {
            $hits += [int](& $sqlite.Source $vscdb "SELECT COUNT(*) FROM ItemTable WHERE value LIKE '%' || '$($v[0])' || '%';" 2>$null)
        }
        if ($hits -eq 0) { return }
        $script:changes++
        if ($DryRun) { Write-Host "[dry-run] would update ($hits rows): $vscdb"; return }
        Backup-Once $vscdb
        foreach ($v in $variants) {
            & $sqlite.Source $vscdb "UPDATE ItemTable SET value = replace(value, '$($v[0])', '$($v[1])') WHERE value LIKE '%' || '$($v[0])' || '%';"
        }
        Write-Host "updated: $vscdb"
    }

    Update-StateDb "$codeDir\User\globalStorage\state.vscdb"

    foreach ($ws in Get-ChildItem "$codeDir\User\workspaceStorage" -Directory -ErrorAction SilentlyContinue) {
        Update-TextFile (Join-Path $ws.FullName 'workspace.json')
        Update-StateDb (Join-Path $ws.FullName 'state.vscdb')
    }
}

# --- 7: workspace files that moved along with the repos ---------------------
foreach ($wsf in Get-ChildItem $NewPrefix -Recurse -Filter *.code-workspace -File -ErrorAction SilentlyContinue) {
    Update-TextFile $wsf.FullName
}

Write-Host ''
if ($script:changes -eq 0) { Write-Host 'Nothing to migrate - everything already points to the new path.' }
else { Write-Host "$($script:changes) location(s) $(if ($DryRun) { 'would be' } else { 'were' }) migrated." }
