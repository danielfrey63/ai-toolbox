"""Per-recording job lock with priority hand-over.

Two ways lead to the same transcription: the scheduled watcher (runs in the
background at low priority) and a manual `/transcribe` on the same file. They
must not compete for the GPU. The lock next to the output settles it:

- background run finds a live lock       -> leaves quietly ("busy")
- manual run finds a live BACKGROUND run -> boosts that process tree to normal
  priority and waits for it, then continues with the cached intermediates
  ("taken-over"); nothing is computed twice
- stale lock (dead pid or older than 12 h) -> removed, run proceeds

Windows-first (ctypes, no psutil); POSIX gets the same semantics minus
boosting foreign processes (needs root to lower a nice value).
"""
from __future__ import annotations

import atexit
import json
import os
import sys
import time
from pathlib import Path

STALE_HOURS = 12.0
POLL_SECONDS = 5.0

_WIN = os.name == "nt"
if _WIN:
    import ctypes
    from ctypes import wintypes

    _k32 = ctypes.windll.kernel32
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    PROCESS_SET_INFORMATION = 0x0200
    STILL_ACTIVE = 259
    NORMAL_PRIORITY_CLASS = 0x0020
    BELOW_NORMAL_PRIORITY_CLASS = 0x4000
    TH32CS_SNAPPROCESS = 0x0002

    class PROCESSENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD),
            ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD),
            ("th32DefaultHeapID", ctypes.c_size_t),
            ("th32ModuleID", wintypes.DWORD),
            ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD),
            ("pcPriClassBase", wintypes.LONG),
            ("dwFlags", wintypes.DWORD),
            ("szExeFile", ctypes.c_char * 260),
        ]

    _k32.OpenProcess.restype = wintypes.HANDLE
    _k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if _WIN:
        h = _k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return False
        try:
            code = wintypes.DWORD()
            ok = _k32.GetExitCodeProcess(h, ctypes.byref(code))
            return bool(ok) and code.value == STILL_ACTIVE
        finally:
            _k32.CloseHandle(h)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _process_tree(root_pid: int) -> list[int]:
    """root pid plus all descendants (Windows Toolhelp snapshot)."""
    if not _WIN:
        return [root_pid]
    snap = _k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == wintypes.HANDLE(-1).value or not snap:
        return [root_pid]
    parents: dict[int, int] = {}
    try:
        e = PROCESSENTRY32()
        e.dwSize = ctypes.sizeof(PROCESSENTRY32)
        if _k32.Process32First(snap, ctypes.byref(e)):
            while True:
                parents[e.th32ProcessID] = e.th32ParentProcessID
                if not _k32.Process32Next(snap, ctypes.byref(e)):
                    break
    finally:
        _k32.CloseHandle(snap)
    tree, frontier = [root_pid], [root_pid]
    while frontier:
        cur = frontier.pop()
        for pid, ppid in parents.items():
            if ppid == cur and pid not in tree:
                tree.append(pid)
                frontier.append(pid)
    return tree


def set_priority(pid: int, low: bool) -> bool:
    """Below-normal (low=True) or normal priority for one process."""
    if _WIN:
        h = _k32.OpenProcess(PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return False
        try:
            cls = BELOW_NORMAL_PRIORITY_CLASS if low else NORMAL_PRIORITY_CLASS
            return bool(_k32.SetPriorityClass(h, cls))
        finally:
            _k32.CloseHandle(h)
    try:
        os.setpriority(os.PRIO_PROCESS, pid, 10 if low else 0)
        return True
    except (PermissionError, ProcessLookupError, AttributeError):
        return False


def lower_own_priority() -> None:
    """Background runs step aside for interactive work. Child workers
    (whisper/pyannote subprocesses) inherit the class on Windows."""
    set_priority(os.getpid(), low=True)


def boost_tree(pid: int) -> int:
    """Normal priority for a process and everything it spawned. Returns count."""
    return sum(1 for p in _process_tree(pid) if set_priority(p, low=False))


class JobLock:
    def __init__(self, path: Path, background: bool = False):
        self.path = Path(path)
        self.background = background
        self.owned = False

    # -- state --------------------------------------------------------
    def read(self) -> dict | None:
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    def _live(self) -> dict | None:
        info = self.read()
        if not info:
            if self.path.exists():
                self._remove()  # unreadable -> treat as stale
            return None
        age_h = (time.time() - float(info.get("started", 0))) / 3600
        if not pid_alive(int(info.get("pid", 0))) or age_h > STALE_HOURS:
            print(f"[transcribe] verwaisten Lock entfernt ({self.path.name})", file=sys.stderr)
            self._remove()
            return None
        return info

    def _remove(self) -> None:
        try:
            self.path.unlink()
        except OSError:
            pass

    # -- lifecycle ----------------------------------------------------
    def acquire(self) -> str:
        """'acquired' | 'taken-over' | 'busy' (background run, someone else is on it)."""
        other = self._live()
        if other:
            pid = int(other["pid"])
            if self.background:
                print(f"[transcribe] läuft bereits (PID {pid}) - übersprungen", file=sys.stderr)
                return "busy"
            n = boost_tree(pid) if other.get("background") else 0
            how = f"auf normale Priorität gehoben ({n} Prozesse)" if n else "normale Priorität"
            print(f"[transcribe] Lauf auf derselben Aufnahme aktiv (PID {pid}, {how}) - "
                  f"übernommen: warte auf Abschluss, Zwischenstände werden wiederverwendet", file=sys.stderr)
            self._wait(pid)
            outcome = "taken-over"
        else:
            outcome = "acquired"
        self.path.write_text(json.dumps({
            "pid": os.getpid(), "started": time.time(), "background": self.background,
            "argv": sys.argv[1:],
        }), encoding="utf-8")
        self.owned = True
        atexit.register(self.release)
        if self.background:
            lower_own_priority()
        return outcome

    def _wait(self, pid: int) -> None:
        t0 = time.time()
        while pid_alive(pid) and self.read():
            time.sleep(POLL_SECONDS)
            if int((time.time() - t0) % 60) < POLL_SECONDS:
                print(f"[transcribe] ... warte ({int((time.time() - t0) / 60)} min)", file=sys.stderr)
        self._remove()

    def release(self) -> None:
        if not self.owned:
            return
        info = self.read()
        if info and int(info.get("pid", 0)) == os.getpid():
            self._remove()
        self.owned = False
