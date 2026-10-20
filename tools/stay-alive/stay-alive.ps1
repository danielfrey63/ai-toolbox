<#
.SYNOPSIS
    Keeps a Windows session awake: no sleep, no display-off, no idle timeout.

.DESCRIPTION
    Holds a SetThreadExecutionState request (system + display required) for as long
    as the script runs and resets the user idle timer with a zero-distance mouse move
    every interval. Unlike SendKeys it does not depend on the foreground window and
    toggles no key state. Prints the idle time before and after each nudge so a
    non-working setup (locked or disconnected session) is visible immediately.

.PARAMETER IntervalSeconds
    Seconds between two nudges. Default 50.

.EXAMPLE
    pwsh -File tools\stay-alive\stay-alive.ps1
    pwsh -File tools\stay-alive\stay-alive.ps1 -IntervalSeconds 30
#>
param([int]$IntervalSeconds = 50)

Add-Type -Namespace Native -Name KeepAwake -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);

[DllImport("user32.dll")]
public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);

[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

[DllImport("user32.dll")]
public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

public static uint IdleMilliseconds() {
    var info = new LASTINPUTINFO();
    info.cbSize = (uint)Marshal.SizeOf(info);
    GetLastInputInfo(ref info);
    return (uint)Environment.TickCount - info.dwTime;
}
'@

$ES_CONTINUOUS       = [uint32]2147483648  # 0x80000000
$ES_SYSTEM_REQUIRED  = [uint32]1
$ES_DISPLAY_REQUIRED = [uint32]2
$MOUSEEVENTF_MOVE    = [uint32]1

Write-Host "Keeping session alive every $IntervalSeconds s (Ctrl+C to stop)" -ForegroundColor Green
try {
    # Prevent sleep and display-off for as long as this thread runs
    [void][Native.KeepAwake]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
    while ($true) {
        $idleBefore = [Native.KeepAwake]::IdleMilliseconds()
        # Zero-distance mouse move: resets the idle timer without moving the cursor
        [Native.KeepAwake]::mouse_event($MOUSEEVENTF_MOVE, 0, 0, 0, [UIntPtr]::Zero)
        $idleAfter = [Native.KeepAwake]::IdleMilliseconds()
        Write-Host ("{0:HH:mm:ss}  idle {1,6:N1}s -> {2,4:N1}s" -f (Get-Date), ($idleBefore / 1000), ($idleAfter / 1000))
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    # Restore normal power management
    [void][Native.KeepAwake]::SetThreadExecutionState($ES_CONTINUOUS)
    Write-Host "Stopped, power management restored." -ForegroundColor Yellow
}
