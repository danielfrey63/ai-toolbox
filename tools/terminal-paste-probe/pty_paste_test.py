"""Headless reproduction: does a TUI app accept a terminal paste inside a Windows ConPTY?

Spawns the app in a pseudo-terminal, emulates the replies a real terminal emulator
gives to capability probes (DA1, DA2, CPR, OSC 10/11, kitty ``CSI ? u``), waits for the
app's prompt, injects a marker the way a terminal would deliver a paste, and reports
whether the marker shows up on screen. Also reports which input protocols the app
switched on at startup (bracketed paste, kitty keyboard flags, modifyOtherKeys, win32
input mode), which is what distinguishes Claude Code 2.1.268 from 2.1.269 and later.

Usage (PowerShell):
    python pty_paste_test.py --exe C:/path/to/claude.exe --env vscode --mode bracketed
    python pty_paste_test.py --exe claude.exe --env wt --mode typed --responder none

Requires: pywinpty (``pip install pywinpty``), Windows 10 1809+ (ConPTY).
"""
import argparse
import os
import queue
import re
import sys
import threading
import time
import uuid

from winpty import PtyProcess

ANSI = re.compile(
    r"\x1b\[[0-9;?<>=]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[=>()][A-Za-z0-9]?"
    r"|\x1b[PX^_].*?\x1b\\|\x1b\[\?[0-9;]*[hl]"
)

MODES = {
    "bracketed": "single chunk wrapped in CSI 200~ / 201~ (what xterm.js and Windows Terminal send)",
    "plain": "single chunk without brackets",
    "typed": "one character per write, 3 ms apart (simulated typing)",
    "typed-cr": "like typed, followed by Enter",
    "split-bracketed": "brackets and payload in three separate writes",
    "bracketed-cr": "bracketed paste whose payload ends with CR",
    "focus-bracketed": "focus-out, focus-in and the paste in one chunk",
    "focus-split": "focus-out, focus-in, paste as separate writes",
    "reply-bracketed": "a DA1 reply in the same chunk as the paste",
}


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--exe", required=True, help="TUI executable to spawn")
    p.add_argument("--env", choices=["vscode", "wt", "none"], default="vscode", help="terminal identity to emulate via environment variables")
    p.add_argument("--mode", choices=sorted(MODES), default="bracketed", help="; ".join("%s = %s" % kv for kv in MODES.items()))
    p.add_argument("--responder", choices=["xterm", "none"], default="xterm", help="answer capability probes like xterm.js (default) or stay silent")
    p.add_argument("--ready", default=r'Try\s*"|\?\s*for\s*shortcuts|bypass\s*permissions', help="regex on the ANSI-stripped screen that marks the prompt as ready (default matches Claude Code)")
    p.add_argument("--cwd", default=os.getcwd(), help="working directory for the app (Claude Code needs a trusted folder)")
    p.add_argument("--startup-timeout", type=float, default=30.0)
    p.add_argument("--rows", type=int, default=40)
    p.add_argument("--cols", type=int, default=140)
    return p.parse_args()


def build_env(kind):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("TERM", "WT_", "VSCODE", "COLORTERM"))}
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["DISABLE_AUTOUPDATER"] = "1"
    if kind == "vscode":
        env["TERM_PROGRAM"] = "vscode"
        env["TERM_PROGRAM_VERSION"] = "1.138.0"
        env["VSCODE_INJECTION"] = "1"
    elif kind == "wt":
        env["WT_SESSION"] = str(uuid.uuid4())
        env["WT_PROFILE_ID"] = "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}"
    return env


def replies_for(chunk, responder):
    """Emulate what an xterm.js-based terminal answers to capability probes."""
    out = []
    if responder == "none":
        return out
    if "\x1b[c" in chunk or "\x1b[0c" in chunk:
        out.append("\x1b[?1;2c")
    if "\x1b[>c" in chunk or "\x1b[>0c" in chunk:
        out.append("\x1b[>0;276;0c")
    if "\x1b[6n" in chunk:
        out.append("\x1b[40;1R")
    if "\x1b[?u" in chunk:
        out.append("\x1b[?0u")  # xterm.js (VS Code >= 1.138) implements the kitty keyboard protocol
    for m in re.finditer(r"\x1b\]1([01]);\?(?:\x07|\x1b\\)", chunk):
        out.append("\x1b]1%s;rgb:1e1e/1e1e/1e1e\x1b\\" % m.group(1))
    return out


def reader(proc, q):
    while True:
        try:
            data = proc.read(65536)
        except Exception:
            q.put(None)
            return
        if not data:
            time.sleep(0.02)
            continue
        q.put(data)


def drain(q, proc, responder, seconds, until=None):
    """Collect output for a time window, answering probes as they appear."""
    buf = ""
    t_end = time.time() + seconds
    while time.time() < t_end:
        try:
            chunk = q.get(timeout=max(0.01, t_end - time.time()))
        except queue.Empty:
            break
        if chunk is None:
            break
        buf += chunk
        for r in replies_for(chunk, responder):
            proc.write(r)
        if until and until(buf):
            break
    return buf


def inject(proc, mode, marker):
    bracketed = "\x1b[200~" + marker + "\x1b[201~"
    if mode == "bracketed":
        proc.write(bracketed)
    elif mode == "plain":
        proc.write(marker)
    elif mode in ("typed", "typed-cr"):
        for ch in marker + ("\r" if mode == "typed-cr" else ""):
            proc.write(ch)
            time.sleep(0.003)
    elif mode == "split-bracketed":
        for part in ("\x1b[200~", marker, "\x1b[201~"):
            proc.write(part)
            time.sleep(0.03)
    elif mode == "bracketed-cr":
        proc.write("\x1b[200~" + marker + "\r\x1b[201~")
    elif mode == "focus-bracketed":
        proc.write("\x1b[O\x1b[I" + bracketed)
    elif mode == "focus-split":
        for part in ("\x1b[O", "\x1b[I", bracketed):
            proc.write(part)
            time.sleep(0.05)
    elif mode == "reply-bracketed":
        proc.write("\x1b[?1;2c" + bracketed)


def main():
    a = parse_args()
    marker = "PASTEPROBE " + uuid.uuid4().hex[:8]
    ready_re = re.compile(a.ready)
    proc = PtyProcess.spawn([a.exe], cwd=a.cwd, env=build_env(a.env), dimensions=(a.rows, a.cols))
    q = queue.Queue()
    threading.Thread(target=reader, args=(proc, q), daemon=True).start()
    state = {"trust_answered": False}

    def prompt_ready(buf):
        plain = ANSI.sub("", buf)
        if not state["trust_answered"] and "trust" in plain.lower() and "Yes" in plain:
            proc.write("\r")  # Claude Code workspace-trust dialog: first option is "Yes, proceed"
            state["trust_answered"] = True
        return ready_re.search(plain) is not None

    label = "exe=%s env=%s mode=%s responder=%s" % (os.path.basename(a.exe), a.env, a.mode, a.responder)
    buf = drain(q, proc, a.responder, a.startup_timeout, prompt_ready)
    buf += drain(q, proc, a.responder, 3.0)
    probes = [
        ("CSI ? u asked", "\x1b[?u" in buf),
        ("kitty flags pushed", re.search(r"\x1b\[>[0-9]+u", buf) is not None),
        ("modifyOtherKeys", "\x1b[>4;2m" in buf),
        ("win32-input-mode", "\x1b[?9001h" in buf),
        ("bracketed paste", "\x1b[?2004h" in buf),
        ("focus events", "\x1b[?1004h" in buf),
    ]
    print("PROBES %s : %s" % (label, ", ".join("%s=%s" % (k, "yes" if v else "no") for k, v in probes)))
    if not prompt_ready(buf):
        print("RESULT %s : PROMPT NOT SEEN" % label)
        print("  screen tail: " + re.sub(r"\s+", " ", ANSI.sub("", buf))[-600:])
        proc.terminate(True)
        sys.exit(2)
    drain(q, proc, a.responder, 2.0)
    inject(proc, a.mode, marker)
    buf = drain(q, proc, a.responder, 4.0)
    plain = ANSI.sub("", buf)
    found = marker.replace(" ", "") in re.sub(r"\s+", "", plain)
    print("RESULT %s : %s" % (label, "PASTE VISIBLE" if found else "PASTE DROPPED"))
    print("  screen tail: " + re.sub(r"\s+", " ", plain)[-300:])
    for _ in range(2):
        proc.write("\x03")
        time.sleep(0.3)
    proc.terminate(True)
    sys.exit(0 if found else 1)


if __name__ == "__main__":
    main()
