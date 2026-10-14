"""Per-recording job lock with priority hand-over.

Two ways lead to the same transcription: the scheduled watcher (runs in the
background at low priority) and a manual `/transcribe` on the same file. They
must not compete for the GPU. The lock next to the output settles it:

- background run finds a live lock       -> leaves quietly ("busy")
- manual run finds a live BACKGROUND run -> boosts that process tree to normal
  priority and waits for it, then continues with the cached intermediates
  ("taken-over"); nothing is computed twice
- process death releases the OS lock; age never overrides a live owner

Windows-first (ctypes, no psutil); POSIX gets the same semantics minus
boosting foreign processes (needs root to lower a nice value).
"""
from __future__ import annotations

import atexit
from contextlib import contextmanager
import json
import os
import sys
import time
from pathlib import Path

POLL_SECONDS = 5.0


@contextmanager
def workflow_lock(base: Path, background: bool = False):
    """Subprocesses of one pipeline share its lock; unrelated entrypoints wait."""
    name = str(base.resolve())
    previous = os.environ.get("TRANSCRIBE_WORKFLOW_LOCK")
    if previous == name:
        yield True
        return
    job = JobLock(base.with_name(base.name + ".workflow.lock"), background=background)
    if job.acquire() == "busy":
        yield False
        return
    try:
        os.environ["TRANSCRIBE_WORKFLOW_LOCK"] = name
        try:
            yield True
        finally:
            if previous is None:
                os.environ.pop("TRANSCRIBE_WORKFLOW_LOCK", None)
            else:
                os.environ["TRANSCRIBE_WORKFLOW_LOCK"] = previous
    finally:
        job.release()

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
        self._handle = None

    # -- state --------------------------------------------------------
    def read(self) -> dict | None:
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    def _remove(self) -> None:
        try:
            self.path.unlink()
        except OSError:
            pass

    # -- lifecycle ----------------------------------------------------
    def acquire(self) -> str:
        """Hold an OS lock until release; process death releases it automatically.

        The guard file is never removed: unlinking it would allow two live inodes
        to be locked independently. JSON metadata is informational only.
        """
        self.path.parent.mkdir(parents=True, exist_ok=True)
        guard = self.path.with_name(self.path.name + ".guard")
        self._handle = guard.open("a+b")
        if guard.stat().st_size == 0:
            self._handle.write(b"0")
            self._handle.flush()
        waited = False
        while True:
            try:
                self._handle.seek(0)
                if _WIN:
                    import msvcrt
                    msvcrt.locking(self._handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(self._handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if self.background:
                    self._handle.close()
                    self._handle = None
                    return "busy"
                if not waited:
                    other = self.read() or {}
                    if other.get("background"):
                        boost_tree(int(other.get("pid", 0)))
                    print("[transcribe] recording busy; waiting for the active run", file=sys.stderr)
                waited = True
                time.sleep(POLL_SECONDS)
        from state import write_json
        try:
            write_json(self.path, {"pid": os.getpid(), "started": time.time(), "background": self.background})
        except BaseException:
            self._handle.close()
            self._handle = None
            raise
        self.owned = True
        atexit.register(self.release)
        if self.background:
            lower_own_priority()
        return "taken-over" if waited else "acquired"

    def release(self) -> None:
        if not self.owned:
            return
        info = self.read()
        if info and int(info.get("pid", 0)) == os.getpid():
            self._remove()
        if self._handle:
            self._handle.seek(0)
            if _WIN:
                import msvcrt
                msvcrt.locking(self._handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self._handle.fileno(), fcntl.LOCK_UN)
            self._handle.close()
            self._handle = None
        self.owned = False

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *exc):
        self.release()
