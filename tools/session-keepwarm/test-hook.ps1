# Manual smoke test for stop-hook.ps1: exercises skip/block/pending/tick-chain paths with fake transcripts.
$ErrorActionPreference = 'Stop'
$hookScript = Join-Path $PSScriptRoot 'stop-hook.ps1'
$testDir = Join-Path $env:TEMP 'session-keepwarm-test'
New-Item -ItemType Directory -Force $testDir | Out-Null

function Invoke-Hook([hashtable]$HookInput) {
    ($HookInput | ConvertTo-Json -Compress) | powershell -NoProfile -ExecutionPolicy Bypass -File $hookScript
}

$sid = 'aaaaaaaa-1111-2222-3333-444444444444'
$stateFile = Join-Path $env:LOCALAPPDATA "ai-toolbox\session-keepwarm\$sid.json"
if (Test-Path $stateFile) { Remove-Item $stateFile -Force }

$filler = ('{"type":"assistant","message":{"role":"assistant","content":"' + ('x' * 2000) + '"}}' + "`n") * 110
$real = '{"type":"user","message":{"role":"user","content":"Bitte bau mir das Feature."}}'
$big = Join-Path $testDir 'big.jsonl'
Set-Content $big ($filler + $real)

$out = Invoke-Hook @{ session_id = $sid; transcript_path = $big; stop_hook_active = $false }
"T1 big+real -> blocked: $([bool]$out) (expect True)"
$out = Invoke-Hook @{ session_id = $sid; transcript_path = $big; stop_hook_active = $false }
"T2 repeat while pending fresh -> blocked: $([bool]$out) (expect False)"

# Real activity while the pending wakeup is older than rescheduleAfterSeconds -> push it forward.
$state = Get-Content $stateFile -Raw | ConvertFrom-Json
@{ lastScheduledAt = (Get-Date).AddMinutes(-20).ToString('o'); tickCount = $state.tickCount } | ConvertTo-Json -Compress | Set-Content $stateFile
$out = Invoke-Hook @{ session_id = $sid; transcript_path = $big; stop_hook_active = $false }
"T2b real activity, pending 20min old -> blocked: $([bool]$out) (expect True: reschedule)"

$small = Join-Path $testDir 'small.jsonl'
Set-Content $small $real
$out = Invoke-Hook @{ session_id = 'bbbbbbbb-1111-2222-3333-444444444444'; transcript_path = $small; stop_hook_active = $false }
"T3 small -> blocked: $([bool]$out) (expect False)"

$out = Invoke-Hook @{ session_id = $sid; transcript_path = $big; stop_hook_active = $true }
"T4 stop_hook_active -> blocked: $([bool]$out) (expect False)"

# Tick chain: last user message is a tick (hook feedback after it must be skipped by the parser).
$tick = '{"type":"user","message":{"role":"user","content":"[keepwarm-tick] Stand? Antworte in einem Satz mit dem aktuellen Stand der Session. Keine Tools verwenden."}}'
$feedback = '{"type":"user","message":{"role":"user","content":"Stop hook feedback:\nSession-Keepwarm ... [keepwarm-tick] ..."}}'
$tickFile = Join-Path $testDir 'tick.jsonl'
Set-Content $tickFile ($filler + $tick + "`n" + $feedback)
foreach ($n in 1..4) {
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    @{ lastScheduledAt = (Get-Date).AddHours(-2).ToString('o'); tickCount = $state.tickCount } | ConvertTo-Json -Compress | Set-Content $stateFile
    $out = Invoke-Hook @{ session_id = $sid; transcript_path = $tickFile; stop_hook_active = $false }
    $count = (Get-Content $stateFile -Raw | ConvertFrom-Json).tickCount
    "T5.$n tick turn -> blocked: $([bool]$out), tickCount: $count (expect blocked until tickCount reaches 3)"
}

Remove-Item $testDir -Recurse -Force
Remove-Item $stateFile -Force
'done'
