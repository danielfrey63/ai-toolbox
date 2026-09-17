"""Log the raw byte stream a terminal delivers to a console app on Windows.

Usage:  python raw_input_logger.py [kitty|plain]

Run it inside the terminal under test, then paste (dictation tool, Ctrl+V, Shift+Insert).
Every chunk read from the console is printed as repr with a timestamp. Escape quits
(auto-quits after 60 s).

  kitty (default): additionally pushes the kitty keyboard protocol flags and
                   modifyOtherKeys, exactly like Claude Code >= 2.1.269 does once the
                   terminal answers its ``CSI ? u`` probe. In VS Code this turns
                   Shift+Insert into the key report ``ESC [ 2 ; 2 ~`` instead of a paste.
  plain:           bracketed paste + focus reporting only (Claude Code 2.1.268 behaviour).
"""
import ctypes
import ctypes.wintypes as wt
import msvcrt
import sys
import time

KITTY = (sys.argv[1] if len(sys.argv) > 1 else "kitty") == "kitty"

k32 = ctypes.windll.kernel32
STD_INPUT_HANDLE = -10
ENABLE_PROCESSED_INPUT = 0x0001
ENABLE_LINE_INPUT = 0x0002
ENABLE_ECHO_INPUT = 0x0004
ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200

hin = k32.GetStdHandle(STD_INPUT_HANDLE)
old_mode = wt.DWORD()
k32.GetConsoleMode(hin, ctypes.byref(old_mode))
new_mode = (old_mode.value | ENABLE_VIRTUAL_TERMINAL_INPUT) & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)
k32.SetConsoleMode(hin, new_mode)

out = sys.stdout
out.write("\x1b[?2004h\x1b[?1004h")  # bracketed paste + focus reporting
if KITTY:
    out.write("\x1b[>5u\x1b[>4;2m")  # kitty keyboard flags + modifyOtherKeys, like Claude Code
out.write("\r\nraw input logger (%s): paste now. Esc quits.\r\n" % ("kitty mode" if KITTY else "plain mode"))
out.flush()

t0 = time.time()
buf = ""
last = None


def flush():
    global buf
    if buf:
        out.write("%7.3f  %r\r\n" % ((last or time.time()) - t0, buf))
        out.flush()
        buf = ""


try:
    while time.time() - t0 < 60:
        if msvcrt.kbhit():
            ch = msvcrt.getwch()
            now = time.time()
            if last is not None and now - last > 0.03:
                flush()
            buf += ch
            last = now
            if buf == "\x1b":
                time.sleep(0.05)
                if not msvcrt.kbhit():
                    break
        else:
            if buf and last is not None and time.time() - last > 0.03:
                flush()
            time.sleep(0.005)
finally:
    flush()
    if KITTY:
        out.write("\x1b[<u\x1b[>4;0m")
    out.write("\x1b[?2004l\x1b[?1004l\r\nlogger done.\r\n")
    out.flush()
    k32.SetConsoleMode(hin, old_mode)
