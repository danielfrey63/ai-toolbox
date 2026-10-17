"""Public CLI. The Python modules remain compatible specialist entrypoints."""
from __future__ import annotations

import argparse
import contextlib
import importlib
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

import config
from state import write, read_json, StageState

ROOT = Path(__file__).resolve().parent.parent
PROFILES = ("local", "local-speakers", "headless", "publish")


def doctor(profile: str, probe: bool = False) -> dict:
    import setup
    import llm
    config.snapshot()
    checks = {}
    if profile != "publish":
        for name in ("ffmpeg", "ffprobe", "yt-dlp"):
            path = setup.find_tool(name)
            checks[name] = {"ready": bool(path), "path": path}
        checks["local_runtime"] = setup.venv_status()
    if profile == "local-speakers":
        checks["speaker_runtime"] = setup.venv_status("speakers")
        checks["speaker_access"] = {"ready": bool(config.get("HF_TOKEN") or config.get("HUGGINGFACE_TOKEN")),
                                     "detail": "Hugging Face token and accepted model licence required; first use verifies access."}
    if probe:
        # The marker records the check made at provisioning; --probe repeats it
        # against what is installed now (e.g. after a manual pip change).
        for key, runtime in (("local_runtime", "whisper"), ("speaker_runtime", "speakers")):
            if checks.get(key, {}).get("ready"):
                with contextlib.redirect_stdout(sys.stderr):
                    error = setup.run_runtime_check(setup.venv_python(runtime), runtime)
                checks[key] = {**checks[key], "ready": error is None, "reason": error or ""}
    if profile == "headless":
        ok, reason = llm.available()
        checks["analysis"] = {"ready": ok, "detail": reason or llm.load_config().describe()}
        if probe and ok:
            with contextlib.redirect_stdout(sys.stderr):
                checks["analysis"]["ready"] = llm._probe(None) == 0
    if profile == "publish":
        import publish
        checks["publication"] = {"ready": bool(config.get("CONFLUENCE_URL") and config.get("CONFLUENCE_TOKEN")),
                                  "detail": "Confluence URL and token"}
        checks["markdown"] = {"ready": publish._markdown() is not None or publisher_ready()}
    checks["secret_file"] = secret_file_status()
    return {"schema": 1, "profile": profile, "ready": all(v.get("ready", False) for v in checks.values()), "checks": checks}


def secret_file_status() -> dict:
    checks = [_secret_file_status(path) for path in config_files()]
    return {"ready": all(c["ready"] for c in checks), "files": checks,
            "detail": "; ".join(c["detail"] for c in checks)}


def config_files() -> list[Path]:
    files = [config.user_dir() / ".env"]
    if os.environ.get("TRANSCRIBE_CONFIG"):
        files.append(Path(os.environ["TRANSCRIBE_CONFIG"]).expanduser())
    return list(dict.fromkeys(p.resolve() for p in files))


def _secret_file_status(path: Path) -> dict:
    if not path.exists():
        return {"ready": True, "detail": "No secrets file; environment configuration is supported."}
    if os.name != "nt":
        return {"ready": not bool(path.stat().st_mode & 0o077), "detail": "Owner-only permissions required", "path": str(path)}
    # Inspect ACLs without displaying principals or any secret values. A missing
    # ACL check is explicit, never presented as proof of owner-only access.
    escaped = str(path).replace("'", "''")
    script = "$a=Get-Acl -LiteralPath '" + escaped + "'; $bad=@($a.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -in @('S-1-1-0','S-1-5-11','S-1-5-32-545') }); if($bad.Count){exit 1}"
    try:
        from state import powershell
        r = powershell("$ErrorActionPreference='Stop'; " + script)
    except (OSError, subprocess.TimeoutExpired):
        return {"ready": False, "detail": "Could not verify secret file ACL", "path": str(path)}
    detail = "Could not verify secret file ACL" if r.stderr else "Broad ACL grants found" if r.returncode else "ACL checked; no broad read grants"
    return {"ready": r.returncode == 0, "detail": detail, "path": str(path)}


def launchers() -> dict[Path, str]:
    entry = ROOT / "transcribe.py"
    if os.name == "nt":
        return {config.bin_dir() / "transcribe.cmd": f'@"{sys.executable}" -X utf8 "{entry}" %*\n'}
    return {config.bin_dir() / "transcribe": f"#!/bin/sh\nexec {shlex.quote(sys.executable)} -X utf8 {shlex.quote(str(entry))} \"$@\"\n"}


def install(profile: str, non_interactive: bool) -> int:
    import setup
    before = doctor(profile)
    if profile != "publish":
        if any(not before["checks"][name]["ready"] for name in ("ffmpeg", "ffprobe", "yt-dlp")):
            rc = setup.cmd_install(non_interactive=non_interactive)
            if rc:
                return rc
        runtimes = ("whisper", "speakers") if profile == "local-speakers" else ("whisper",)
        for runtime in runtimes:
            if not setup.venv_status(runtime)["ready"]:
                rc = setup.cmd_provision_venv(runtime=runtime)
                if rc:
                    return rc
    else:
        import publish
        if publish._markdown() is None and not publisher_ready():
            uv = setup.ensure_uv()
            py = publisher_python()
            if not py.is_file():
                rc = subprocess.run([uv, "venv", str(py.parent.parent), "--python", setup.UV_PYTHON_VERSION]).returncode
                if rc:
                    return rc
            rc = subprocess.run([uv, "pip", "install", "--python", str(py), "markdown==3.8.2"]).returncode
            if rc:
                return rc
    setup._scaffold_env()
    from state import protect_secret
    for path in config_files():
        if path.is_file():
            protect_secret(path)
    for path, content in launchers().items():
        write(path, content)
        if os.name != "nt":
            path.chmod(0o755)
    after = doctor(profile)
    if not after["ready"]:
        show(after, False)
        return 2
    setup._upsert_env_value("SETUP_COMPLETE", "true")
    print(f"[install] verified {profile}; launcher: {next(iter(launchers()))}")
    print("[install] Add its directory to PATH, or keep using python <skill>/transcribe.py.")
    return 0


def publisher_python() -> Path:
    return config.user_dir() / "publisher" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def publisher_ready() -> bool:
    py = publisher_python()
    if not py.is_file():
        return False
    try:
        return subprocess.run([str(py), "-I", "-c", "import markdown"], capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def show(value: dict, structured: bool) -> None:
    if structured:
        print(json.dumps(value, ensure_ascii=False))
        return
    if "checks" in value:
        for name, check in value["checks"].items():
            print(f"{'ready' if check.get('ready') else 'missing'}  {name}: {check.get('reason') or check.get('detail') or check.get('path', '')}")
    else:
        for key, val in value.items():
            print(f"{key}: {val}")


def parameter_reference() -> str:
    lines = ["# Parameterreferenz", "", "Generiert mit `python transcribe.py config docs`. Quelle: `scripts/config.py`.", "",
             "Vorrang: CLI (wo angeboten) → Prozessumgebung → explizite `--config`-Datei → Benutzer-`.env` → Default. Leere Werte sind nicht gesetzt. Das Arbeitsverzeichnis wird nicht durchsucht.", "",
             "`TRANSCRIBE_CONFIG_DIR` und `TRANSCRIBE_BIN_DIR` wählen isolierte Laufzeitverzeichnisse; `TRANSCRIBE_CONFIG` entspricht `--config`. Diese Bootstrap-Pfade kommen ausschliesslich aus der Prozessumgebung.", "",
             "| Parameter | Typ | Default | Bedeutung |", "|---|---|---|---|"]
    for name, spec in config.PARAMETERS.items():
        kind = "Geheimnis" if spec.secret else ", ".join(spec.choices) if spec.choices else spec.kind
        lines.append(f"| `{name}` | {kind} | `{spec.default}` | {spec.description} |")
    return "\n".join(lines) + "\n"


def option_reference() -> str:
    import pipeline
    import run
    lines = ["# CLI-Optionen", "", "Generiert mit `python transcribe.py config options` aus den argparse-Definitionen.", "",
             "Installation: [INSTALL.md](../INSTALL.md). Konfigurationswerte: [parameters.md](parameters.md).", "",
             "`python transcribe.py run --help` zeigt den üblichen Ablauf; `--help-all` ergänzt alle Medienoptionen.", ""]
    seen = set()
    for title, parser in (("Ablauf und Auswertung", pipeline.build_parser()), ("Medienaufbereitung", run.build_parser())):
        lines += ["## " + title, "", "| Option | Default | Bedeutung |", "|---|---|---|"]
        for action in parser._actions:
            if not action.option_strings or action.dest in seen or action.dest == "help":
                continue
            seen.add(action.dest)
            default = "auto/unset" if action.default is None else str(action.default)
            help_text = (action.help or "").replace("|", "/").replace("\n", " ").replace("%%", "%")
            if action.choices:
                help_text += " Choices: " + ", ".join(map(str, action.choices))
            lines.append(f"| `{', '.join(action.option_strings)}` | `{default}` | {help_text} |")
        lines.append("")
    return "\n".join(lines)


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    ap = argparse.ArgumentParser(description="Transcribe media, resume analysis and publish reviewed reports.")
    ap.add_argument("--config", type=Path, help="Explicit .env configuration file; secrets are never printed")
    ap.add_argument("--version", action="store_true")
    subs = ap.add_subparsers(dest="command")
    for name in ("install", "doctor"):
        p = subs.add_parser(name, help="Install and verify a profile" if name == "install" else "Inspect readiness without changing the machine")
        p.add_argument("--profile", choices=PROFILES, default="local",
                       help="Desired state: local runtime, speaker access, headless analysis or publication (default local)")
        if name == "install":
            p.add_argument("--non-interactive", action="store_true",
                           help="Never prompt for keys or confirmations; missing prerequisites fail with exit 2")
        else:
            p.add_argument("--json", action="store_true")
            p.add_argument("--probe", action="store_true", help="Re-run the local runtime checks and call the configured analysis deployment")
    subs.add_parser("cleanup", help="Remove this checkout's CLI launcher; preserve models, configuration and recordings")
    c = subs.add_parser("config", help="Inspect effective parameters or generate their documentation")
    c.add_argument("action", choices=("show", "template", "docs", "options"), default="show", nargs="?")
    c.add_argument("--explain", action="store_true")
    c.add_argument("--json", action="store_true")
    status = subs.add_parser("status", help="Read a recording's saved stage status")
    status.add_argument("base")
    status.add_argument("--json", action="store_true")
    # Delegate complete option parsing, including --help, to each command's parser.
    for name, help_text in (("run", "Process or resume a recording; --plan explains work"), ("review", "Refresh/check the human review list"), ("publish", "Publish reviewed files to Confluence")):
        subs.add_parser(name, help=help_text, add_help=False)
    args, rest = ap.parse_known_args(argv)
    if args.config:
        os.environ["TRANSCRIBE_CONFIG"] = str(args.config.expanduser().resolve())
    try:
        if args.version:
            from version import APP_VERSION
            print(APP_VERSION)
            return 0
        if not args.command:
            ap.print_help()
            return 0
        if args.command in ("run", "review", "publish"):
            if args.command == "publish" and "--help" not in rest and "-h" not in rest:
                import publish
                if publish._markdown() is None and publisher_ready():
                    return subprocess.run([str(publisher_python()), "-X", "utf8", str(ROOT / "scripts/publish.py"), *rest]).returncode
            module = importlib.import_module({"run": "pipeline"}.get(args.command, args.command))
            old = sys.argv
            try:
                sys.argv = [str(ROOT / "transcribe.py") + " " + args.command, *rest]
                return module.main()
            finally:
                sys.argv = old
        if rest:
            ap.error("unrecognized arguments: " + " ".join(rest))
        if args.command == "install":
            return install(args.profile, args.non_interactive)
        if args.command == "doctor":
            result = doctor(args.profile, args.probe)
            show(result, args.json)
            return 0 if result["ready"] else 2
        if args.command == "cleanup":
            for path, expected in launchers().items():
                if path.is_file() and path.read_text(encoding="utf-8") == expected:
                    path.unlink()
            print("[cleanup] this checkout's launcher is absent; configuration, models and recordings retained")
            return 0
        if args.command == "config":
            if args.action == "template":
                print(config.template(), end="")
            elif args.action == "docs":
                print(parameter_reference(), end="")
            elif args.action == "options":
                print(option_reference(), end="")
            else:
                show(config.snapshot(explain=args.explain), args.json)
            return 0
        if args.command == "status":
            from companions import resolve_base
            base = resolve_base(Path(args.base).expanduser())
            show({"schema": 1, "base": str(base), "stages": StageState(base).entries()}, args.json)
            return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print("[transcribe] " + config.redact(str(exc)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
