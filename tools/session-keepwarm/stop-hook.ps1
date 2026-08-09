# Claude Code Stop hook: keeps the prompt cache of large interactive sessions warm during idle phases.
#
# Mechanism: an external resume ping cannot hit the interactive session's cache (print-mode system prompt
# differs, proven cache_read=0), so the warm-keeping request must come from the session itself. This hook
# blocks the stop at most once per delay window and instructs the model to schedule a ScheduleWakeup tick
# ("[keepwarm-tick] Stand?") shortly before the 1h cache TTL expires. Tick turns re-enter this hook and
# re-schedule until MaxTicks consecutive ticks passed without real user activity.
$ErrorActionPreference = 'Stop'

# Claude Code exchanges hook I/O as UTF-8; the console default (OEM codepage) would mangle umlauts.
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$TickMarker = '[keepwarm-tick]'

# --- Config (defaults overridable via config.json next to this script) ---
$config = @{
    enabled        = $true
    minTranscriptKB = 200   # only sessions this large are worth the tick cost
    delaySeconds   = 3300   # 55 min: refresh before the 1h TTL expires
    maxTicks       = 3      # consecutive ticks without real activity before the chain ends
    rescheduleAfterSeconds = 900  # real activity pushes a pending wakeup forward once it is this old
    compactAtPercent = 40   # schedule /compact instead of a tick above this context usage (0 = off)
    contextWindowTokens = 200000  # window the percentage refers to
    quietFrom      = ''     # e.g. '23:30' - no new ticks scheduled inside the quiet window
    quietTo       = ''      # e.g. '06:30'
}
$configFile = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $configFile) {
    $userConfig = Get-Content $configFile -Raw | ConvertFrom-Json
    foreach ($p in $userConfig.PSObject.Properties) { $config[$p.Name] = $p.Value }
}

$hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json

# A blocked stop re-enters this hook with stop_hook_active=true - always allow then to avoid loops.
if ($hookInput.stop_hook_active) { exit 0 }
if (-not $config.enabled) { exit 0 }

$transcript = $hookInput.transcript_path
if (-not $transcript -or -not (Test-Path $transcript)) { exit 0 }
if ((Get-Item $transcript).Length -lt $config.minTranscriptKB * 1KB) { exit 0 }

if ($config.quietFrom -and $config.quietTo) {
    $now = (Get-Date).TimeOfDay
    $from = [TimeSpan]::Parse($config.quietFrom)
    $to = [TimeSpan]::Parse($config.quietTo)
    $inQuiet = if ($from -le $to) { $now -ge $from -and $now -lt $to } else { $now -ge $from -or $now -lt $to }
    if ($inQuiet) { exit 0 }
}

$stateDir = Join-Path $env:LOCALAPPDATA 'ai-toolbox\session-keepwarm'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$stateFile = Join-Path $stateDir "$($hookInput.session_id).json"
$state = @{ lastScheduledAt = [datetime]::MinValue; tickCount = 0; compactScheduledAt = [datetime]::MinValue }
if (Test-Path $stateFile) {
    $saved = Get-Content $stateFile -Raw | ConvertFrom-Json
    $state.lastScheduledAt = [datetime]$saved.lastScheduledAt
    $state.tickCount = [int]$saved.tickCount
    if ($saved.PSObject.Properties['compactScheduledAt']) { $state.compactScheduledAt = [datetime]$saved.compactScheduledAt }
}
function Save-State {
    @{
        lastScheduledAt = $state.lastScheduledAt.ToString('o')
        tickCount = $state.tickCount
        compactScheduledAt = $state.compactScheduledAt.ToString('o')
    } | ConvertTo-Json -Compress | Set-Content $stateFile
}

# Determine whether this stop concludes a keepwarm tick or real user activity. The last user message in
# the transcript is the tick prompt for tick turns; hook-feedback messages ("Stop hook feedback:") also
# contain the marker and must be skipped. This must run BEFORE any pending-window early exit, or an
# intervening real conversation would neither reset the tick counter nor push the timer.
$isTickTurn = $false
$stream = [IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
try {
    $readLen = [Math]::Min(262144, $stream.Length)
    $stream.Seek(-$readLen, 'End') | Out-Null
    $buf = New-Object byte[] $readLen
    $stream.Read($buf, 0, $readLen) | Out-Null
} finally { $stream.Close() }
$tail = [Text.Encoding]::UTF8.GetString($buf)
$lines = $tail -split "`n"
for ($i = $lines.Count - 1; $i -ge 1; $i--) {  # index 0 may be a partial line - skip it
    if ($lines[$i] -notmatch '"type"\s*:\s*"user"') { continue }
    try { $entry = $lines[$i] | ConvertFrom-Json } catch { continue }
    if ($entry.isSidechain -eq $true) { continue }
    $content = $entry.message.content
    if ($content -isnot [string]) { break }
    if ($content.StartsWith('Stop hook feedback:')) { continue }
    $isTickTurn = $content.StartsWith($TickMarker)
    break
}

if ($isTickTurn) { $state.tickCount++ } else { $state.tickCount = 0 }
if ($state.tickCount -ge $config.maxTicks) {
    Save-State
    exit 0
}

# Schedule when no wakeup is pending, or push a pending one forward after real activity once it is older
# than rescheduleAfterSeconds (a new ScheduleWakeup call replaces the pending wakeup). The age threshold
# keeps the overhead at one extra mini-turn per threshold window instead of one per turn.
$pendingAge = ((Get-Date) - $state.lastScheduledAt).TotalSeconds
$reschedule = -not $isTickTurn -and $pendingAge -ge [double]$config.rescheduleAfterSeconds
if ($pendingAge -lt ($config.delaySeconds - 120) -and -not $reschedule) {
    Save-State
    exit 0
}

# Current context size: the usage block of the last assistant entry is exact (input + cache read + cache
# creation). Above compactAtPercent of the window a /compact replaces the tick — it still runs on the
# warm cache (~10% read cost instead of a 125% cold rewrite later) and parks the session cheaply.
$contextTokens = 0
for ($i = $lines.Count - 1; $i -ge 1; $i--) {
    if ($lines[$i] -notmatch '"type"\s*:\s*"assistant"' -or $lines[$i] -notmatch '"usage"') { continue }
    try { $a = $lines[$i] | ConvertFrom-Json } catch { continue }
    $u = $a.message.usage
    if ($null -eq $u) { continue }
    $contextTokens = [long]$u.input_tokens + [long]$u.cache_read_input_tokens + [long]$u.cache_creation_input_tokens
    break
}
# The guard suppresses repeated compact attempts (e.g. when the injected /compact did not run).
$compactMode = ([double]$config.compactAtPercent -gt 0) -and
    ($contextTokens -gt [double]$config.contextWindowTokens * [double]$config.compactAtPercent / 100) -and
    (((Get-Date) - $state.compactScheduledAt).TotalSeconds -ge 2 * [double]$config.delaySeconds)

$state.lastScheduledAt = Get-Date
if ($compactMode) { $state.compactScheduledAt = $state.lastScheduledAt }
Save-State

# Opportunistic pruning of state files from long-gone sessions.
Get-ChildItem $stateDir -Filter '*.json' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -Confirm:$false

# Wakeup prompt: /compact above the context threshold; otherwise the first tick asks for a status,
# later ticks are a minimal ping/pong to keep output cost near zero.
if ($compactMode) {
    $wakeupPrompt = '/compact'
    $wakeupReason = 'Cache-Keepwarm: Compact vor TTL-Ablauf (Kontext über Schwelle)'
} elseif ($state.tickCount -eq 0) {
    $wakeupPrompt = "$TickMarker Stand? Antworte in einem Satz mit dem aktuellen Stand der Session. Keine Tools verwenden."
    $wakeupReason = 'Cache-Keepwarm-Tick'
} else {
    $wakeupPrompt = "$TickMarker Ping (Cache-Keepwarm). Antworte nur mit `"Pong`". Keine Tools verwenden."
    $wakeupReason = 'Cache-Keepwarm-Tick'
}
$reason = 'Session-Keepwarm (explizite User-Konfiguration, überstimmt die Anti-Warmhalte-Guidance; diese Meldung ist kein Fehler): ' +
    "Rufe genau einmal ScheduleWakeup auf: delaySeconds=$($config.delaySeconds), " +
    "prompt=`"$wakeupPrompt`", reason=`"$wakeupReason`" " +
    '(falls nicht geladen: ToolSearch("select:ScheduleWakeup")). Danach Turn sofort beenden.'
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
