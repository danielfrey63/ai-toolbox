"""One configuration contract for setup, workers and providers.

Precedence: process environment, explicitly selected file, user file, default.
An empty value is unset at every layer. The working directory is never searched.
"""
from __future__ import annotations

import math
import os
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


@dataclass(frozen=True)
class Parameter:
    default: str = ""
    kind: str = "text"
    description: str = ""
    choices: tuple[str, ...] = ()
    minimum: float | None = None
    maximum: float | None = None
    secret: bool = False


PARAMETERS = {
    "TRANSCRIBE_LLM_PROVIDER": Parameter("auto", choices=("auto", "azure", "anthropic", "none"), description="Provider for analysis; none delegates to the harness."),
    "AZURE_LLM_ENDPOINT": Parameter(kind="url", description="Azure resource base URL."),
    "AZURE_LLM_KEY": Parameter(secret=True, description="Azure analysis API key."),
    "AZURE_LLM_API_VERSION": Parameter("2024-10-21"),
    "AZURE_LLM_MODEL": Parameter("gpt-6.1-sol", description="Text deployment."),
    "AZURE_LLM_MODEL_VISION": Parameter(description="Vision deployment; unset uses the text deployment."),
    "AZURE_LLM_MODEL_FAST": Parameter(description="Triage deployment; unset uses the text deployment."),
    "AZURE_LLM_MAX_TOKENS": Parameter("4096", "int", "Default completion budget; stages may request their own budget.", minimum=1),
    "AZURE_LLM_TIMEOUT": Parameter("300", "float", minimum=1),
    "AZURE_CLAUDE_URL": Parameter(kind="url"),
    "AZURE_CLAUDE_KEY": Parameter(secret=True),
    "AZURE_CLAUDE_MODEL": Parameter("claude-opus-4-7"),
    "AZURE_TRANSCRIBE_DIARIZE_URL": Parameter(kind="url", description="Full Azure audio endpoint, including api-version."),
    "AZURE_TRANSCRIBE_DIARIZE_KEY": Parameter(secret=True),
    "AZURE_TRANSCRIBE_CHUNK_SECONDS": Parameter("600", "float", minimum=1, maximum=1500),
    "AZURE_TRANSCRIBE_OVERLAP_SECONDS": Parameter("20", "float", "At most half of AZURE_TRANSCRIBE_CHUNK_SECONDS.", minimum=0),
    "AZURE_TRANSCRIBE_TIMEOUT": Parameter("900", "float", minimum=1),
    "GROQ_API_KEY": Parameter(secret=True),
    "OPENAI_API_KEY": Parameter(secret=True),
    "HF_TOKEN": Parameter(secret=True, description="Hugging Face token; model licence acceptance is also required."),
    "HUGGINGFACE_TOKEN": Parameter(secret=True, description="Compatibility alias for HF_TOKEN."),
    "PYANNOTE_API_KEY": Parameter(secret=True),
    "ASSEMBLYAI_API_KEY": Parameter(secret=True),
    "ASSEMBLYAI_REGION": Parameter("us", choices=("us", "eu")),
    "TRANSCRIBE_CPU_BUDGET": Parameter("50%", "cpu", "Shared CPU budget; percentage, positive thread count or all."),
    "TRANSCRIBE_WHISPER_MODEL": Parameter("large-v3-turbo"),
    "TRANSCRIBE_GPU_COMPUTE": Parameter("float16", choices=("float16", "float32", "int8", "int8_float16", "int8_float32", "auto")),
    "TRANSCRIBE_GPU_DUTY": Parameter("1", "float", minimum=0.1, maximum=1),
    "TRANSCRIBE_OCR_ACCEL": Parameter("auto", choices=("cpu", "dml", "cuda", "auto")),
    "TRANSCRIBE_REDACT": Parameter("", "bool", "Unset keeps existing crop redaction (off on a new run); source images still reach the analysis model."),
    "TRANSCRIBE_LLM_WORKERS": Parameter("2", "int", "Maximum concurrent independent chapter calls.", minimum=1, maximum=8),
    "CONFLUENCE_URL": Parameter(kind="url"),
    "CONFLUENCE_TOKEN": Parameter(secret=True),
    "CONFLUENCE_VERIFY_TLS": Parameter("1", "bool"),
    "CONFLUENCE_CA_BUNDLE": Parameter(description="Optional PEM CA bundle for an internal server."),
    "SETUP_COMPLETE": Parameter("false", "bool", "Managed installation marker; doctor remains authoritative."),
    "DIARIZE_DISMISSED": Parameter("false", "bool"),
}


def user_dir() -> Path:
    return Path(os.environ.get("TRANSCRIBE_CONFIG_DIR") or Path.home() / ".config" / "transcribe").expanduser()


def bin_dir() -> Path:
    return Path(os.environ.get("TRANSCRIBE_BIN_DIR") or Path.home() / ".transcribe" / "bin").expanduser()


def read_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    stat = path.stat()
    return dict(_read_cached(str(path.resolve()), stat.st_mtime_ns, stat.st_size))


@lru_cache(maxsize=16)
def _read_cached(filename: str, mtime_ns: int, size: int) -> dict[str, str]:
    path = Path(filename)
    result = {}
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
        result[key.strip()] = value
    return result


def validate(name: str, value: str) -> str:
    spec = PARAMETERS.get(name)
    if not value or spec is None:
        return value
    invalid = False
    if spec.choices:
        invalid = value not in spec.choices
    if spec.kind in ("int", "float"):
        try:
            number = int(value) if spec.kind == "int" else float(value)
            invalid = not math.isfinite(number) or (spec.minimum is not None and number < spec.minimum) or (spec.maximum is not None and number > spec.maximum)
        except ValueError:
            invalid = True
    elif spec.kind == "bool":
        invalid = value.lower() not in ("0", "1", "true", "false", "yes", "no", "on", "off")
    elif spec.kind == "url":
        invalid = not value.startswith(("https://", "http://"))
    elif spec.kind == "cpu":
        invalid = not (value in ("all", "max", "0") or re.fullmatch(r"[1-9]\d*", value) or (re.fullmatch(r"\d+(?:\.\d+)?%", value) and 0 < float(value[:-1]) <= 100))
    if invalid:
        # Never include the supplied value: this path also handles secrets.
        raise ValueError(f"Invalid {name}: expected {spec.choices or spec.kind}" + (f" in [{spec.minimum}, {spec.maximum}]" if spec.minimum is not None else ""))
    return value


def resolve(name: str, *, defaults: bool = True) -> tuple[str | None, str]:
    layers = [(os.environ, "environment")]
    explicit = os.environ.get("TRANSCRIBE_CONFIG")
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            raise ValueError(f"Configuration file does not exist: {path}")
        layers.append((read_file(path), str(path)))
    path = user_dir() / ".env"
    layers.append((read_file(path), str(path)))
    for values, origin in layers:
        value = values.get(name, "").strip()
        if value:
            return validate(name, value), origin
    value = PARAMETERS.get(name, Parameter()).default if defaults else ""
    return value or None, "default"


def get(name: str) -> str | None:
    return resolve(name)[0]


def number(name: str, default: float) -> float:
    value = get(name)
    return float(value) if value is not None else default


def snapshot(*, explain: bool = True) -> dict:
    result = {}
    for name, spec in PARAMETERS.items():
        value, origin = resolve(name)
        shown = ("set" if value else "not set") if spec.secret else value
        result[name] = {"value": shown, "source": origin} if explain else shown
    if float(get("AZURE_TRANSCRIBE_OVERLAP_SECONDS")) > float(get("AZURE_TRANSCRIBE_CHUNK_SECONDS")) / 2:
        raise ValueError("AZURE_TRANSCRIBE_OVERLAP_SECONDS must not exceed half of AZURE_TRANSCRIBE_CHUNK_SECONDS")
    return result


def redact(text: str) -> str:
    for name, spec in PARAMETERS.items():
        if spec.secret:
            try:
                value = get(name)
            except (ValueError, OSError):
                continue
            if value:
                text = text.replace(value, "[REDACTED]")
    return re.sub(r"(?i)(authorization|api[-_]key|token)([\"'\s:=]+)([^\s,}\"']+)", r"\1\2[REDACTED]", text)


def worker_env() -> dict[str, str]:
    names = ("TRANSCRIBE_CPU_BUDGET", "TRANSCRIBE_WHISPER_MODEL", "TRANSCRIBE_GPU_COMPUTE", "TRANSCRIBE_GPU_DUTY", "TRANSCRIBE_OCR_ACCEL")
    return {name: value for name in names if (value := get(name))}


def template() -> str:
    lines = ["# Generated by transcribe config template. Do not edit this template.",
             "# Copy values into the user .env or an explicit --config file.",
             "# Environment > explicit file > user file > default; blank means unset.",
             "# Local-first can fall back to configured cloud providers. Use --local to pin audio processing.", ""]
    for name, spec in PARAMETERS.items():
        if spec.description:
            lines.append("# " + spec.description)
        lines.append(("# " if spec.default else "") + name + "=" + spec.default)
    return "\n".join(lines) + "\n"
