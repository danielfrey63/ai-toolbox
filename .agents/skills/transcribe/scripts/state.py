"""Atomic artefacts and dependency-aware stage records, shared by all entrypoints."""
from __future__ import annotations

import hashlib
import json
import os
import tempfile
import subprocess
import shutil
from pathlib import Path


def powershell(script: str):
    """Avoid inheriting PowerShell 7 module paths into Windows PowerShell 5."""
    env = dict(os.environ)
    env.pop("PSModulePath", None)
    return subprocess.run([shutil.which("pwsh") or "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                          env=env, capture_output=True, timeout=15)


def protect_secret(path: Path) -> None:
    """Keep existing specific ACL grants, remove broad read access before writing."""
    if os.name != "nt":
        path.chmod(0o600)
        return
    escaped = str(path.resolve()).replace("'", "''")
    script = "$ErrorActionPreference='Stop'; $p='" + escaped + "'; $a=Get-Acl -LiteralPath $p; $bad=@($a.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -in @('S-1-1-0','S-1-5-11','S-1-5-32-545') }); if(-not $bad.Count){exit 0}; $a.SetAccessRuleProtection($true,$true); foreach($r in @($a.Access)){ if($r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -in @('S-1-1-0','S-1-5-11','S-1-5-32-545')){ [void]$a.RemoveAccessRuleSpecific($r) } }; $id=[System.Security.Principal.WindowsIdentity]::GetCurrent().User; $rule=New-Object System.Security.AccessControl.FileSystemAccessRule($id,'FullControl','Allow'); $a.SetAccessRule($rule); Set-Acl -LiteralPath $p -AclObject $a"
    result = powershell(script)
    if result.returncode:
        raise OSError(f"Could not restrict secret file permissions: {path}")


def write(path: Path, text: str, *, secret: bool = False) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_text(encoding="utf-8") == text:
        if secret:
            protect_secret(path)
        return
    fd, name = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            if secret:
                protect_secret(Path(name))
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_json(path: Path, value) -> None:
    write(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def read_json(path: Path, default=None):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return default if default is not None and not isinstance(value, type(default)) else value
    except (OSError, ValueError):
        return default


def digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, default=str).encode()).hexdigest()


def file_hash(path: Path) -> str:
    if not path.is_file():
        return "missing"
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def media_identity(path: Path | str) -> dict:
    """Fast media identity; replacing a recording invalidates its intermediates.

    Accepts a string as well: run.py carries the downloaded media path as the
    plain string yt-dlp returns, and every caller shares this one conversion."""
    path = Path(path)
    s = path.stat()
    return {"path": str(path.resolve()), "size": s.st_size, "mtime_ns": s.st_mtime_ns}


def signature(paths=(), options=None) -> str:
    return digest({"files": {str(p): file_hash(Path(p)) for p in paths}, "options": options or {}})


class StageState:
    def __init__(self, base: Path):
        self.path = base.with_name(base.name + ".state.json")

    def entries(self) -> dict:
        data = read_json(self.path, {})
        stages = data.get("stages", {}) if isinstance(data, dict) else {}
        return {k: v for k, v in stages.items() if isinstance(v, dict)} if isinstance(stages, dict) else {}

    def current(self, stage: str, key: str, outputs=()) -> bool:
        entry = self.entries().get(stage, {})
        recorded = entry.get("outputs", [])
        return (entry.get("status") == "complete" and entry.get("input") == key and isinstance(recorded, list)
                and all(isinstance(p, (str, Path)) and Path(p).is_file() for p in [*recorded, *outputs]))

    def record(self, stage: str, key: str, outputs=(), status="complete", detail="") -> None:
        entries = self.entries()
        entries[stage] = {"status": status, "input": key, "outputs": [str(p) for p in outputs], "detail": detail}
        write_json(self.path, {"schema": 1, "stages": entries})


def stage_key(p, stage: str, options=None) -> str:
    import config
    options = dict(options or {})
    if stage == "report" and not options.get("no_frames"):
        options["frame_inputs"] = stage_key(p, "frames", {"language": options.get("language"),
                                                        "max_frames": options.get("max_frames", 48)})
    deps = {
        "speakers": [p.transcript, p.speakers, p.participants_file, p.ocr],
        "speakers_fill": [p.transcript, p.speakers, p.participants_file],
        "kompakt": [p.transcript, p.speakers, p.glossary, p.links],
        "report": [p.transcript, p.speakers, p.glossary, p.participants_file, p.links, p.crosscheck, p.frames_json, p.manifest, p.protocol],
        "illustrate": [p.frames_json, p.analysis, p.links],
    }.get(stage, [])
    if stage == "frames":
        from companions import read_protocol
        deps = [p.ocr, p.protocol] + [Path(f["path"]) for f in read_protocol(p.protocol).get("frames", [])]
        ocr = read_json(p.ocr, {}) or {}
        deps += [Path(f["png"]) for f in ocr.get("frames", []) if f.get("png")]
    scripts = Path(__file__).parent
    deps += [scripts / (stage + ".py"), scripts / "companions.py", scripts / "config.py", scripts / "llm.py", scripts.parent / "references/report-writing.md"]
    if stage == "illustrate":
        deps.append(scripts / "illustrate_agent.py")
    if stage == "frames":
        deps.append(scripts / "report.py")
    settings = {name: config.get(name) for name in config.PARAMETERS if name.startswith(("AZURE_LLM_", "AZURE_CLAUDE_", "TRANSCRIBE_LLM_")) and not config.PARAMETERS[name].secret}
    return signature(deps, {"settings": settings, **options})
