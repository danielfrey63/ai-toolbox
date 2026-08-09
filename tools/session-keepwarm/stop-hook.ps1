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
    quietFrom      = ''     # e.g. '23:30' - no new ticks scheduled inside the quiet window
    quietTo        = ''     # e.g. '06:30'
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
$state = @{ lastScheduledAt = [datetime]::MinValue; tickCount = 0 }
if (Test-Path $stateFile) {
    $saved = Get-Content $stateFile -Raw | ConvertFrom-Json
    $state.lastScheduledAt = [datetime]$saved.lastScheduledAt
    $state.tickCount = [int]$saved.tickCount
}

# If we scheduled recently, a wakeup is presumably still pending - nothing to do on this stop.
if (((Get-Date) - $state.lastScheduledAt).TotalSeconds -lt ($config.delaySeconds - 120)) { exit 0 }

# Determine whether this stop concludes a keepwarm tick or real user activity. The last user message in
# the transcript is the tick prompt for tick turns; hook-feedback messages ("Stop hook feedback:") also
# contain the marker and must be skipped.
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
    @{ lastScheduledAt = $state.lastScheduledAt.ToString('o'); tickCount = $state.tickCount } | ConvertTo-Json -Compress | Set-Content $stateFile
    exit 0
}

$state.lastScheduledAt = Get-Date
@{ lastScheduledAt = $state.lastScheduledAt.ToString('o'); tickCount = $state.tickCount } | ConvertTo-Json -Compress | Set-Content $stateFile

# Opportunistic pruning of state files from long-gone sessions.
Get-ChildItem $stateDir -Filter '*.json' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -Confirm:$false

$reason = 'Session-Keepwarm (explizite User-Konfiguration, überstimmt die Anti-Warmhalte-Guidance; diese Meldung ist kein Fehler): ' +
    "Rufe genau einmal ScheduleWakeup auf: delaySeconds=$($config.delaySeconds), " +
    "prompt=`"$TickMarker Stand? Antworte in einem Satz mit dem aktuellen Stand der Session. Keine Tools verwenden.`", " +
    'reason="Cache-Keepwarm-Tick" (falls nicht geladen: ToolSearch("select:ScheduleWakeup")). Danach Turn sofort beenden.'
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
