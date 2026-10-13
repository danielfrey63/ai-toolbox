#!/usr/bin/env python3
"""Shared LLM client for the agent stages of /transcribe.

Everything that used to need the Claude Code session - speaker naming, the
compact transcript, the report, illustration triage and the visual check of
the crops - goes through this one module, so the model is a configuration
choice and the pipeline runs headless (PMO watcher, cron, another CLI).

Config (real environment variables win over ~/.config/transcribe/.env):

  TRANSCRIBE_LLM_PROVIDER   azure | anthropic | none. Default: azure when
                            AZURE_LLM_ENDPOINT + AZURE_LLM_KEY are set,
                            else anthropic when AZURE_CLAUDE_URL + _KEY are
                            set, else none (the agent stages are skipped and
                            the interactive Claude session does the work).
  AZURE_LLM_ENDPOINT        https://<resource>.openai.azure.com (resource
                            base, no deployment path)
  AZURE_LLM_KEY             api key of that resource
  AZURE_LLM_API_VERSION     default 2024-10-21
  AZURE_LLM_MODEL           deployment for text work (default gpt-6.1-sol)
  AZURE_LLM_MODEL_VISION    deployment for image work (default = MODEL)
  AZURE_LLM_MODEL_FAST      cheap deployment for bulk triage (default = MODEL)
  AZURE_LLM_MAX_TOKENS      default completion cap (default 4096)
  AZURE_LLM_TIMEOUT         per-call read timeout in seconds (default 300)
  AZURE_CLAUDE_URL / _KEY   Anthropic Messages endpoint (Foundry passthrough)
  AZURE_CLAUDE_MODEL        default claude-opus-4-7

Roles: "text" (analysis, writing), "vision" (frames, crops), "fast" (bulk
classification). Each maps to one deployment; the usage ledger records
every call so the protocol can state what left the machine.
"""
from __future__ import annotations

import base64
import json
import mimetypes
import re
import ssl
import sys
import time
import urllib.error
from dataclasses import dataclass, field
from pathlib import Path
from urllib.request import Request, urlopen

from stt import _get_config, _get_config_float

DEFAULT_AZURE_MODEL = "gpt-6.1-sol"
DEFAULT_AZURE_API_VERSION = "2024-10-21"
DEFAULT_ANTHROPIC_MODEL = "claude-opus-4-7"
DEFAULT_MAX_TOKENS = 4096
DEFAULT_TIMEOUT = 300.0
RETRY_STATUSES = {408, 429, 500, 502, 503, 504}
MAX_ATTEMPTS = 4

ROLES = ("text", "vision", "fast")


def log(msg: str) -> None:
    print(f"[llm] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@dataclass
class Config:
    provider: str                      # azure | anthropic | none
    endpoint: str = ""
    key: str = ""
    api_version: str = DEFAULT_AZURE_API_VERSION
    models: dict = field(default_factory=dict)   # role -> deployment/model
    max_tokens: int = DEFAULT_MAX_TOKENS
    timeout: float = DEFAULT_TIMEOUT
    reason: str = ""                   # why provider is none

    def model(self, role: str) -> str:
        return self.models.get(role) or self.models.get("text", "")

    def describe(self) -> str:
        """One line for the protocol: provider and the deployments in use."""
        if self.provider == "none":
            return "none"
        roles = ", ".join(f"{r}={self.models[r]}" for r in ROLES if self.models.get(r))
        return f"{self.provider} ({roles})"


def load_config() -> Config:
    want = (_get_config("TRANSCRIBE_LLM_PROVIDER") or "").strip().lower()
    az_ep, az_key = _get_config("AZURE_LLM_ENDPOINT"), _get_config("AZURE_LLM_KEY")
    an_url, an_key = _get_config("AZURE_CLAUDE_URL"), _get_config("AZURE_CLAUDE_KEY")
    max_tokens = int(_get_config_float("AZURE_LLM_MAX_TOKENS", DEFAULT_MAX_TOKENS))
    timeout = _get_config_float("AZURE_LLM_TIMEOUT", DEFAULT_TIMEOUT)

    if want in ("", "auto"):
        want = "azure" if (az_ep and az_key) else ("anthropic" if (an_url and an_key) else "none")

    if want == "azure":
        if not (az_ep and az_key):
            missing = [n for n, v in (("AZURE_LLM_ENDPOINT", az_ep), ("AZURE_LLM_KEY", az_key)) if not v]
            return Config("none", reason=f"{' + '.join(missing)} not set")
        text = _get_config("AZURE_LLM_MODEL") or DEFAULT_AZURE_MODEL
        return Config(
            "azure", az_ep.rstrip("/"), az_key,
            _get_config("AZURE_LLM_API_VERSION") or DEFAULT_AZURE_API_VERSION,
            {"text": text,
             "vision": _get_config("AZURE_LLM_MODEL_VISION") or text,
             "fast": _get_config("AZURE_LLM_MODEL_FAST") or text},
            max_tokens, timeout,
        )
    if want == "anthropic":
        if not (an_url and an_key):
            missing = [n for n, v in (("AZURE_CLAUDE_URL", an_url), ("AZURE_CLAUDE_KEY", an_key)) if not v]
            return Config("none", reason=f"{' + '.join(missing)} not set")
        model = _get_config("AZURE_CLAUDE_MODEL") or DEFAULT_ANTHROPIC_MODEL
        return Config("anthropic", an_url, an_key, "", {"text": model, "vision": model, "fast": model},
                      max_tokens, timeout)
    if want == "none":
        return Config("none", reason="TRANSCRIBE_LLM_PROVIDER=none")
    return Config("none", reason=f"unknown TRANSCRIBE_LLM_PROVIDER={want!r}")


def available() -> tuple[bool, str]:
    """(configured, reason) - reason names what is missing when not configured."""
    cfg = load_config()
    return cfg.provider != "none", cfg.reason


# ---------------------------------------------------------------------------
# Usage ledger
# ---------------------------------------------------------------------------

@dataclass
class Usage:
    calls: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    images: int = 0
    seconds: float = 0.0
    by_model: dict = field(default_factory=dict)

    def add(self, model: str, prompt: int, completion: int, images: int, seconds: float) -> None:
        self.calls += 1
        self.prompt_tokens += prompt
        self.completion_tokens += completion
        self.images += images
        self.seconds += seconds
        m = self.by_model.setdefault(model, {"calls": 0, "prompt": 0, "completion": 0, "images": 0})
        m["calls"] += 1
        m["prompt"] += prompt
        m["completion"] += completion
        m["images"] += images

    def summary(self) -> str:
        parts = [f"{m}: {v['calls']} calls, {v['prompt']} in / {v['completion']} out"
                 + (f", {v['images']} images" if v["images"] else "")
                 for m, v in self.by_model.items()]
        return "; ".join(parts) if parts else "no calls"


USAGE = Usage()


# ---------------------------------------------------------------------------
# Message building
# ---------------------------------------------------------------------------

def image_part(path: Path | str, provider: str | None = None) -> dict:
    """A content part carrying one image file (base64)."""
    p = Path(path)
    mime = mimetypes.guess_type(p.name)[0] or "image/png"
    data = base64.b64encode(p.read_bytes()).decode("ascii")
    if (provider or load_config().provider) == "anthropic":
        return {"type": "image", "source": {"type": "base64", "media_type": mime, "data": data}}
    return {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}}


def text_part(text: str) -> dict:
    return {"type": "text", "text": text}


@dataclass
class Reply:
    text: str
    model: str
    prompt_tokens: int = 0
    completion_tokens: int = 0
    seconds: float = 0.0
    raw: dict | None = None

    def json(self) -> dict:
        """The first JSON object in the reply (fence-tolerant)."""
        text = self.text.strip()
        if text.startswith("```"):
            text = re.sub(r"^```[a-zA-Z]*\s*|\s*```$", "", text, flags=re.S)
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            pass
        m = re.search(r"\{.*\}", text, re.S)
        if not m:
            raise ValueError(f"no JSON object in reply: {text[:200]!r}")
        return json.loads(m.group(0))


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

def _post(url: str, headers: dict, payload: dict, timeout: float) -> tuple[int, str]:
    data = json.dumps(payload).encode("utf-8")
    req = Request(url, data=data, headers={"content-type": "application/json", **headers}, method="POST")
    ctx = ssl.create_default_context()
    try:
        with urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        retry_after = exc.headers.get("Retry-After") if exc.headers else None
        if retry_after:
            body = json.dumps({"_retry_after": retry_after, "body": body[:500]})
        return exc.code, body
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError) as exc:
        return 0, f"network failure: {type(exc).__name__}: {exc}"


def _count_images(messages: list[dict]) -> int:
    n = 0
    for m in messages:
        c = m.get("content")
        if isinstance(c, list):
            n += sum(1 for p in c if p.get("type") in ("image_url", "image"))
    return n


def chat(messages: list[dict], *, role: str = "text", max_tokens: int | None = None,
         json_mode: bool = False, system: str | None = None, cfg: Config | None = None,
         label: str = "") -> Reply:
    """One chat completion. `messages` use the OpenAI shape
    ({role, content}, content either str or a list of parts from text_part /
    image_part). `system` is prepended as the system/developer message.
    Retries on 408/429/5xx with backoff. Raises RuntimeError on final failure."""
    cfg = cfg or load_config()
    if cfg.provider == "none":
        raise RuntimeError(f"LLM not configured: {cfg.reason}")
    if role not in ROLES:
        raise ValueError(f"unknown role {role!r}")
    model = cfg.model(role)
    max_tokens = max_tokens or cfg.max_tokens
    n_images = _count_images(messages)

    if cfg.provider == "azure":
        url = f"{cfg.endpoint}/openai/deployments/{model}/chat/completions?api-version={cfg.api_version}"
        headers = {"api-key": cfg.key}
        msgs = ([{"role": "system", "content": system}] if system else []) + messages
        payload: dict = {"messages": msgs, "max_completion_tokens": max_tokens}
        if json_mode:
            payload["response_format"] = {"type": "json_object"}
    else:
        url = cfg.endpoint
        headers = {"anthropic-version": "2023-06-01", "x-api-key": cfg.key, "api-key": cfg.key}
        payload = {"model": model, "max_tokens": max_tokens, "messages": messages}
        if system:
            payload["system"] = system

    delay = 5.0
    last = ""
    for attempt in range(1, MAX_ATTEMPTS + 1):
        t0 = time.time()
        status, body = _post(url, headers, payload, cfg.timeout)
        dt = time.time() - t0
        if status == 200:
            data = json.loads(body)
            if cfg.provider == "azure":
                text = data["choices"][0]["message"].get("content") or ""
                usage = data.get("usage", {}) or {}
                p_tok, c_tok = usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0)
                finish = data["choices"][0].get("finish_reason")
                if finish == "length":
                    log(f"WARNING: {model} hit max_completion_tokens={max_tokens} ({label or role})")
            else:
                text = "".join(b.get("text", "") for b in data.get("content", [])
                               if isinstance(b, dict) and b.get("type") == "text")
                usage = data.get("usage", {}) or {}
                p_tok, c_tok = usage.get("input_tokens", 0), usage.get("output_tokens", 0)
            USAGE.add(model, p_tok, c_tok, n_images, dt)
            log(f"{label or role}: {model} {p_tok} in / {c_tok} out"
                + (f", {n_images} image(s)" if n_images else "") + f", {dt:.1f}s")
            return Reply(text, model, p_tok, c_tok, dt, data)
        last = f"HTTP {status}: {body[:300]}"
        if status in RETRY_STATUSES and attempt < MAX_ATTEMPTS:
            wait = delay
            try:
                wait = float(json.loads(body).get("_retry_after", delay))
            except (ValueError, AttributeError, TypeError):
                pass
            log(f"{label or role}: {model} {last} - retry {attempt}/{MAX_ATTEMPTS - 1} in {wait:.0f}s")
            time.sleep(min(wait, 120))
            delay *= 2
            continue
        break
    raise RuntimeError(f"LLM call failed ({label or role}, {model}): {last}")


def ask(prompt: str, *, system: str | None = None, images: list[Path | str] | None = None,
        role: str | None = None, json_mode: bool = False, max_tokens: int | None = None,
        label: str = "") -> Reply:
    """Convenience: one user turn with optional images. Role defaults to
    vision when images are given, text otherwise."""
    cfg = load_config()
    role = role or ("vision" if images else "text")
    if images:
        content: list[dict] = [image_part(p, cfg.provider) for p in images] + [text_part(prompt)]
    else:
        content = prompt  # type: ignore[assignment]
    return chat([{"role": "user", "content": content}], role=role, max_tokens=max_tokens,
                json_mode=json_mode, system=system, cfg=cfg, label=label)


def ask_json(prompt: str, **kw) -> dict:
    """ask() in JSON mode, parsed. One retry with an explicit reminder when
    the reply is not valid JSON."""
    kw.setdefault("json_mode", True)
    reply = ask(prompt, **kw)
    try:
        return reply.json()
    except ValueError as exc:
        log(f"reply was not JSON ({exc}); asking once more")
        reply = ask(prompt + "\n\nReturn ONLY a JSON object, no prose, no markdown fence.", **kw)
        return reply.json()


# ---------------------------------------------------------------------------
# CLI: probe the configured deployments
# ---------------------------------------------------------------------------

def _probe(image: Path | None) -> int:
    cfg = load_config()
    if cfg.provider == "none":
        print(f"LLM not configured: {cfg.reason}")
        return 2
    print(f"provider: {cfg.describe()}")
    seen = set()
    for role in ROLES:
        model = cfg.model(role)
        if model in seen:
            continue
        seen.add(model)
        try:
            r = chat([{"role": "user", "content": "Antworte mit genau einem Wort: welches Modell bist du?"}],
                     role=role, max_tokens=200, cfg=cfg, label=f"probe-text:{role}")
            print(f"  {role:6} {model}: text ok {r.seconds:.1f}s -> {r.text.strip()!r}")
        except RuntimeError as exc:
            print(f"  {role:6} {model}: text FAIL {exc}")
            continue
        if image:
            try:
                r = chat([{"role": "user", "content": [image_part(image, cfg.provider), text_part(
                    "Beschreibe in einem Satz, was dieses Bild zeigt.")]}],
                    role=role, max_tokens=300, cfg=cfg, label=f"probe-image:{role}")
                print(f"  {role:6} {model}: image ok {r.seconds:.1f}s -> {r.text.strip()[:160]!r}")
            except RuntimeError as exc:
                print(f"  {role:6} {model}: image FAIL {exc}")
    print(f"usage: {USAGE.summary()}")
    return 0


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="LLM client for /transcribe - probe the configured deployments.")
    ap.add_argument("--probe", action="store_true", help="Call every configured role once (text, optionally image)")
    ap.add_argument("--image", type=Path, default=None, help="Image file for the vision probe")
    args = ap.parse_args()
    if args.probe:
        return _probe(args.image)
    ok, reason = available()
    print(f"configured: {ok}" + ("" if ok else f" ({reason})") + f" | {load_config().describe()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
