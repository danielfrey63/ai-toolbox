# Finishes the 2026-07-30 checkout migration: moves the last locked repo
# (dokumentations-tools, held open by the Claude Code session that prepared
# this migration) and then migrates all tool references per moved repo.
#
# Run AFTER closing Claude Code and VS Code:
#   pwsh -File finish-checkout-migration.ps1 [-DryRun]
#
# Idempotent: already-moved repos are skipped, the reference migration
# (migrate-project-paths.ps1) finds nothing on re-runs.
#
# Reference migration runs per repo (full old path as prefix), NOT on the
# parent 'SBB\Develop' prefix: plain directories there stay in Meine Ablage,
# and a parent-level replace would corrupt their references.

param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$migrate = Join-Path $PSScriptRoot 'migrate-project-paths.ps1'

# This process must not itself hold a cwd inside the repo it is about to move.
if ((Get-Location).Path -like 'D:\Meine Ablage\Akros\Kunden\SBB\Develop\dokumentations-tools*') {
    Set-Location $env:USERPROFILE
    Write-Host "moved own working directory out of the repo (was inside it)"
}

$sbbOld = 'D:\Meine Ablage\Akros\Kunden\SBB\Develop'
$sbbNew = 'D:\Develop\sbb'
$repos = @(
    'agent-rollout', 'ai-guardrail-demo', 'azure-api-mcp-registry', 'brain',
    'centralized-agents-experiment', 'contained-agents',
    'poc-esta-dfa-weicheneditor-artefakte', 'timo-sdd', 'dokumentations-tools'
)

# 1: move dokumentations-tools if it is still at the old location
$dtOld = Join-Path $sbbOld 'dokumentations-tools'
$dtNew = Join-Path $sbbNew 'dokumentations-tools'
if (Test-Path $dtOld) {
    if (Test-Path $dtNew) { throw "Both old and new dokumentations-tools exist - resolve manually." }
    if ($DryRun) { Write-Host "[dry-run] would move: $dtOld -> $dtNew" }
    else {
        # Fast path: try the rename directly; scan for lock holders only
        # when it is actually blocked.
        $moved = $false
        try { Move-Item $dtOld $dtNew -ErrorAction Stop; $moved = $true }
        catch { Write-Host "move blocked ($($_.Exception.Message))" }

        if (-not $moved) {
            # Orphaned agent/MCP child processes (uvx, python, node, kilo, ...)
            # survive Claude Code shutdown with their cwd inside the repo and
            # block the rename. Kill those; abort on VS Code and shells; warn
            # about anything else. GoogleDriveFS watch handles do not block
            # renames (proven by the other repo moves) and are ignored.
            $killable = 'claude', 'kilo', 'uv', 'uvx', 'node', 'python', 'cmd', 'bash', 'nohup', 'language_server_windows_x64'
            $ignored = 'GoogleDriveFS', 'crashpad_handler', 'handle64'
            Write-Host "scanning open handles under the repo (system-wide scan, takes up to a minute)..."
            $lockers = & (Join-Path $PSScriptRoot 'find-lockers.ps1') -Path $dtOld -PassThru
            foreach ($l in $lockers) {
                $base = $l.Process -replace '\.exe$', ''
                if ($l.Pid -eq $PID -or $base -in $ignored) { continue }
                if ($base -eq 'Code') { throw "VS Code is still running (PID $($l.Pid)) - close it, then re-run." }
                if ($base -in 'pwsh', 'powershell', 'WindowsTerminal') {
                    throw "A shell (PID $($l.Pid)) has its working directory inside the repo - likely the terminal you started this from. cd out of the repo (e.g. cd ~), then re-run."
                }
                if ($base -in $killable) {
                    Stop-Process -Id $l.Pid -Force -ErrorAction SilentlyContinue
                    Write-Host "killed lingering process: $($l.Process) (PID $($l.Pid))"
                }
                else { Write-Warning "still holding a handle: $($l.Process) (PID $($l.Pid)) - close it if the move fails" }
            }

            foreach ($attempt in 1..5) {
                try { Move-Item $dtOld $dtNew -ErrorAction Stop; $moved = $true; break }
                catch { Write-Host "move attempt $attempt/5 failed, retrying in 3s..."; Start-Sleep 3 }
            }
        }
        if (-not $moved) {
            Write-Warning "Move keeps failing. Processes holding handles under the directory:"
            & (Join-Path $PSScriptRoot 'find-lockers.ps1') -Path $dtOld
            throw "Move failed. Close/kill the processes listed above, then re-run."
        }
        Write-Host "moved: dokumentations-tools"
    }
}
else { Write-Host "dokumentations-tools already moved." }

# 2: migrate references repo by repo (Claude Code projects/settings, VS Code)
$pairs = foreach ($r in $repos) { , @((Join-Path $sbbOld $r), (Join-Path $sbbNew $r)) }
$pairs += , @('D:\Meine Ablage\Akros\Kunden\SEM\Auftrag', 'D:\Develop\sem')
# Re-run the earlier github migration too: the extended variant list and the
# additional targets (workspace state DBs, extension storages) now catch
# references the first pass missed. Parent-level prefix is safe here because
# the whole github tree moved.
$pairs += , @('D:\Meine Ablage\Develop\github', 'D:\Develop\github')

$extra = @{}
if ($DryRun) { $extra['DryRun'] = $true }
foreach ($p in $pairs) {
    Write-Host "--- migrating references: $($p[0])"
    & $migrate -OldPrefix $p[0] -NewPrefix $p[1] @extra
}

# 3: merge the live-session leftover project dir. The Claude session that ran
# this migration kept writing its transcript into the old-encoded project dir
# after the rename, so those files are NEWER than the copies moved in step 2
# and must overwrite them.
$projRoot = "$env:USERPROFILE\.claude\projects"
$oldEnc = Join-Path $projRoot ('D:\Meine Ablage\Akros\Kunden\SBB\Develop\dokumentations-tools' -replace '[:\\/ ]', '-')
$newEnc = Join-Path $projRoot ('D:\Develop\sbb\dokumentations-tools' -replace '[:\\/ ]', '-')
if ((Test-Path $oldEnc) -and (Test-Path $newEnc)) {
    if ($DryRun) { Write-Host "[dry-run] would merge leftover session files: $oldEnc -> $newEnc" }
    else {
        Get-ChildItem $oldEnc | ForEach-Object { Move-Item $_.FullName $newEnc -Force }
        Remove-Item $oldEnc -Force
        Write-Host "merged leftover session files into $newEnc"
    }
}
