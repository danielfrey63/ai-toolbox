#!/usr/bin/env python3
"""Publish a reviewed report to Confluence (Server/Data Center REST API).

One page per recording below a parent page: info box (intro, data flow,
redaction), the report from «## Übersicht» on, the compact transcript in an
expand macro; illustrations, compact transcript and full transcript as
attachments. Optionally one row in a hub page table. The video is never
uploaded.

Gate: nothing is written while <base>.review.md has an open box
(review.py). The release box names the target, so changing the target
re-opens the gate.

Target and page texts come from two optional files next to the recording,
read in this order (later keys win):
  transcribe-publish.txt   folder defaults, e.g. parent and hub
  <name>.publish.txt       this recording
Format: one `key: value` per line, `#` comments. Keys:
  parent       page ID the page goes below (or --parent)
  hub          page ID whose first table gets a row (optional)
  title        page title (default: "YYYY-MM-DD Thema" from the file name)
  intro        paragraph of the info box, Markdown inline; repeat for more
  hub_topic, hub_recording, hub_summary, presenter
               cells of the hub row (topic, note under the page link,
               content summary, presenter)

Connection in ~/.config/transcribe/.env (or the environment):
  CONFLUENCE_URL          e.g. https://confluence.example.com
  CONFLUENCE_TOKEN        personal access token
  CONFLUENCE_VERIFY_TLS   0 for a local tunnel with a foreign certificate

Idempotent: <base>.publish.json remembers page ID, version and the hashes of
body and attachments as last written; a re-run uploads only what changed.
Without that file the remote attachments are downloaded and hashed once.

  python publish.py "<base or recording>" [--parent ID] [--dry-run] [--no-hub]
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import html
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import cli
from companions import Paths, read_protocol, read_speakers, resolve_base

KEYS = ("parent", "hub", "title", "intro", "hub_topic", "hub_recording", "hub_summary", "presenter")
IMG_WIDTH = 900


# --- configuration -------------------------------------------------------------

def config_files(p: Paths) -> list[Path]:
    return [p.base.parent / "transcribe-publish.txt", p.base.with_name(f"{p.base.name}.publish.txt")]


def load_config(p: Paths, parent: str | None) -> dict:
    cfg: dict = {"intro": []}
    for f in config_files(p):
        if not f.is_file():
            continue
        intro_here: list[str] = []
        for raw in f.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            key, value = (s.strip() for s in line.split(":", 1))
            if key == "intro":
                intro_here.append(value)
            elif key in KEYS:
                cfg[key] = value
        if intro_here:
            cfg["intro"] = intro_here
    if parent:
        cfg["parent"] = parent
    cfg.setdefault("title", default_title(p))
    return cfg


def default_title(p: Paths) -> str:
    m = re.match(r"(\d{4})(\d{2})(\d{2})(?:-\d{4})? - (.+)$", p.base.name)
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)} {m.group(4)}" if m else p.base.name


def describe_target(p: Paths, cfg: dict) -> str:
    hub = f", Zeile in Hub-Tabelle {cfg['hub']}" if cfg.get("hub") else ""
    return f"Seite «{cfg['title']}» unter Confluence-Seite {cfg['parent']}{hub}"


def _setting(name: str) -> str | None:
    from stt import _get_config
    return _get_config(name)


# --- REST client (stdlib only) ---------------------------------------------------

class Confluence:
    def __init__(self, url: str, token: str, verify: bool):
        self.url = url.rstrip("/")
        self.headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        self.ctx = ssl.create_default_context(cafile=_setting("CONFLUENCE_CA_BUNDLE")) if verify else ssl._create_unverified_context()

    def _req(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None,
             params: dict | None = None, raw: bool = False):
        url = self.url + path + (("?" + urllib.parse.urlencode(params)) if params else "")
        req = urllib.request.Request(url, data=body, method=method, headers={**self.headers, **(headers or {})})
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=300) as r:
                data = r.read()
        except urllib.error.HTTPError as e:
            from config import redact
            raise SystemExit(f"[publish] {method} {path}: HTTP {e.code} {redact(e.read().decode(errors='replace'))[:500]}")
        except urllib.error.URLError as e:
            raise SystemExit(f"[publish] cannot reach {self.url} ({e.reason}) - is the server or tunnel up?")
        if raw:
            return data
        return json.loads(data) if data else {}

    def get(self, path: str, **params):
        return self._req("GET", path, params=params)

    def put_json(self, path: str, obj: dict):
        return self._req("PUT", path, json.dumps(obj).encode("utf-8"), {"Content-Type": "application/json"})

    def post_json(self, path: str, obj: dict):
        return self._req("POST", path, json.dumps(obj).encode("utf-8"), {"Content-Type": "application/json"})

    def download(self, path: str) -> bytes:
        return self._req("GET", path, raw=True)

    def upload(self, page_id: str, f: Path, attachment_id: str | None):
        boundary = uuid.uuid4().hex
        parts = [
            f'--{boundary}\r\nContent-Disposition: form-data; name="minorEdit"\r\n\r\ntrue\r\n'.encode(),
            (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{f.name}"\r\n'
             f"Content-Type: application/octet-stream\r\n\r\n").encode("utf-8") + f.read_bytes() + b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
        path = f"/rest/api/content/{page_id}/child/attachment" + (f"/{attachment_id}/data" if attachment_id else "")
        return self._req("POST", path, b"".join(parts),
                         {"Content-Type": f"multipart/form-data; boundary={boundary}", "X-Atlassian-Token": "nocheck"})


# --- Markdown -> storage ---------------------------------------------------------

def _markdown():
    try:
        import markdown
        return markdown
    except ImportError:
        return None


IMAGE_RE = re.compile(r"!\[([^\]]*)\]\((?:<([^>]+)>|([^\s)]+))\)")


def md_to_storage(md_text: str) -> str:
    def img(m):
        source = m.group(2) or m.group(3)
        if source.startswith(("https://", "http://")):
            return m.group(0)
        name = Path(source).name
        return (f'<ac:image ac:width="{IMG_WIDTH}"><ri:attachment ri:filename="{html.escape(name)}" />'
                f"</ac:image>")

    md_text = IMAGE_RE.sub(img, md_text)

    def companion(m):
        text, name = m.group(1).strip("`"), Path(m.group(2)).name
        if name.endswith((".transcript-kompakt.md", ".transcript.md")):
            return (f'<ac:link><ri:attachment ri:filename="{html.escape(name)}" />'
                    f"<ac:plain-text-link-body><![CDATA[{text}]]></ac:plain-text-link-body></ac:link>")
        return f"`{name}`"

    md_text = re.sub(r"\[(.*?)\]\(<?\./(.*?)>?\)", companion, md_text)
    body = _markdown().markdown(md_text, extensions=["tables", "fenced_code", "sane_lists"], output_format="xhtml")
    body = body.replace("&lt;ac:image", "<ac:image").replace("&lt;/ac:image&gt;", "</ac:image>")
    body = re.sub(r"<p>(<ac:image.*?</ac:image>)</p>", r"\1", body, flags=re.S)
    body = body.replace("&lt;ac:link&gt;", "<ac:link>")
    return body.replace("<br>", "<br/>").replace("<hr>", "<hr/>")


def _inline(md: str) -> str:
    out = md_to_storage(md).strip()
    return out[3:-4] if out.startswith("<p>") and out.endswith("</p>") else out


def info_box(p: Paths, cfg: dict) -> str:
    paras = [_inline(t) for t in cfg.get("intro", [])]
    report = p.report.read_text(encoding="utf-8") if p.report.is_file() else ""
    flow = re.search(r"^- \*\*Datenfluss:\*\*\s*(.+)$", report, re.M)
    if flow:
        paras.append("Datenfluss: " + html.escape(flow.group(1).strip()))
    from review import redaction_summary
    k, n = redaction_summary(p)
    if n:
        paras.append(f"Bildausschnitte: {k} von {n} mit geschwärzten Personendaten." if k
                     else f"Bildausschnitte: {n}, ohne Schwärzung.")
    inner = "".join(f"<p>{x}</p>" for x in paras)
    return (f'<ac:structured-macro ac:name="info" ac:schema-version="1"><ac:rich-text-body>{inner}'
            f"</ac:rich-text-body></ac:structured-macro>")


def build_body(p: Paths, cfg: dict) -> str:
    report = p.report.read_text(encoding="utf-8")
    m = re.search(r"^## Übersicht\s*$", report, re.M)
    if not m:
        raise SystemExit(f"[publish] {p.report.name} has no «## Übersicht» - write the report first")
    body = info_box(p, cfg) + md_to_storage(report[m.start():])
    if p.kompakt.is_file():
        k = p.kompakt.read_text(encoding="utf-8")
        k = k[k.index("\n## ") + 1:] if "\n## " in k else k
        k = re.sub(r"^## ", "### ", k, flags=re.M)
        body += ('<h2>Transkript kompakt</h2><ac:structured-macro ac:name="expand" ac:schema-version="1">'
                 '<ac:parameter ac:name="title">Transkript kompakt (sprecherzugeordnet, gekürzt) aufklappen'
                 f"</ac:parameter><ac:rich-text-body>{md_to_storage(k)}</ac:rich-text-body></ac:structured-macro>")
    return body


def publication_images(p: Paths) -> list[Path]:
    """Upload only locally referenced report images, never leftovers from a rerun."""
    images = {}
    for doc in (p.report, p.kompakt):
        if not doc.is_file():
            continue
        for match in IMAGE_RE.finditer(doc.read_text(encoding="utf-8")):
            source = match.group(2) or match.group(3)
            if source.startswith(("https://", "http://")):
                continue
            path = (doc.parent / source).resolve()
            if not path.is_relative_to(p.base.parent.resolve()) or path.suffix.lower() not in (".png", ".jpg", ".jpeg", ".webp", ".gif"):
                raise ValueError(f"Publication image must be an image below the report directory: {source}")
            if not path.is_file():
                raise ValueError(f"Publication image missing: {source}")
            name = path.name.casefold()
            if name in images and images[name] != path:
                raise ValueError(f"Publication images have conflicting attachment names: {path.name}")
            images[name] = path
    return list(images.values())


def attachments(p: Paths) -> list[Path]:
    return publication_images(p) + [f for f in (p.kompakt, p.transcript) if f.is_file()]


# --- hub row ----------------------------------------------------------------------

def _duration(p: Paths) -> str:
    m = re.search(r"\(([\d.]+)s\)", read_protocol(p.protocol).get("Duration", ""))
    return f"{round(float(m.group(1)) / 60)}min" if m else ""


def _presenter(p: Paths, cfg: dict) -> str:
    if cfg.get("presenter"):
        return cfg["presenter"]
    sp = read_speakers(p.speakers) if p.speakers.is_file() else {"labels": []}
    named = [r for r in sp["labels"] if r.get("Name")]
    return named[0]["Name"].replace(" (?)", "") if named else ""


def hub_row(p: Paths, cfg: dict) -> str:
    t = html.escape(cfg["title"])
    link = (f'<ac:link><ri:page ri:content-title="{t}" />'
            f"<ac:plain-text-link-body><![CDATA[{cfg['title']}]]></ac:plain-text-link-body></ac:link>")
    att = (f'<ac:link><ri:page ri:content-title="{t}" /><ri:attachment ri:filename="{html.escape(p.kompakt.name)}" />'
           f"<ac:plain-text-link-body><![CDATA[Transkript kompakt]]></ac:plain-text-link-body></ac:link>"
           if p.kompakt.is_file() else "")
    note = f"<p>{html.escape(cfg['hub_recording'])}</p>" if cfg.get("hub_recording") else ""
    cells = [f"<p>{html.escape(cfg.get('hub_topic', cfg['title']))}</p>", f"<p>{link}</p>{note}",
             f"<p>{html.escape(cfg.get('hub_summary', ''))}</p>", f"<p>{html.escape(_presenter(p, cfg))}</p>",
             f"<p>{cfg['title'][:10]}</p>", f"<p>{_duration(p)}</p>", f"<p>{att}</p>"]
    return "<tr>" + "".join(f"<td>{c}</td>" for c in cells) + "</tr>"


# --- publish ----------------------------------------------------------------------

def sha(data: bytes | str) -> str:
    return hashlib.sha256(data.encode("utf-8") if isinstance(data, str) else data).hexdigest()[:16]


def attachment_state(client, remote: dict, previous) -> dict:
    """Reuse a hash only while the same remote attachment version still exists."""
    identity = {"id": remote["id"], "version": remote.get("version", {}).get("number")}
    if isinstance(previous, dict) and identity["version"] is not None and all(previous.get(k) == v for k, v in identity.items()):
        return previous
    return {**identity, "sha": sha(client.download(remote["_links"]["download"]))}


def state_path(p: Paths) -> Path:
    return p.base.with_name(p.base.name + ".publish.json")


def main() -> int:
    ap = cli.parser(__doc__, exit_codes={0: "published, or nothing changed, or dry run",
                                         2: "configuration missing (parent, URL, token, markdown package)",
                                         5: "review gate open - tick the boxes in <base>.review.md"},
                    examples=['python publish.py "<base>" --dry-run',
                              'python publish.py "<base>" --parent 3243431729',
                              'python publish.py "<base>" --no-hub'])
    ap.add_argument("base", help="<base> stem, the recording, or any companion file")
    ap.add_argument("--parent", default=None, help="Parent page ID (overrides the publish files)")
    ap.add_argument("--dry-run", action="store_true", help="Read remote state and write a local preview; no remote changes")
    ap.add_argument("--no-hub", action="store_true", help="Leave the hub table alone")
    args = cli.parse(ap)

    p = Paths(resolve_base(args.base))
    cfg = load_config(p, args.parent)
    if not cfg.get("parent"):
        print(f"[publish] no parent page: pass --parent ID or put `parent: ID` in "
              f"{' or '.join(f.name for f in config_files(p))}", file=sys.stderr)
        return 2
    if args.no_hub:
        cfg.pop("hub", None)
    target = describe_target(p, cfg)
    print(f"[publish] target: {target}", file=sys.stderr)

    from review import gate, refresh
    path, reset = refresh(p, target)
    for key in reset:
        print(f"[publish] review: {key} changed since it was ticked - box reset", file=sys.stderr)
    is_open, open_items = gate(p, target)
    if is_open:
        for t in open_items:
            print(f"[publish] review open: {t}", file=sys.stderr)
        if not args.dry_run:
            print(f"[publish] gate open - tick the boxes in {path}, then run again", file=sys.stderr)
            return 5
        print("[publish] gate open - dry run continues without remote changes", file=sys.stderr)

    if _markdown() is None:
        print("[publish] Python package `markdown` missing: pip install markdown "
              "(or run via `uv run --with markdown python publish.py ...`)", file=sys.stderr)
        return 2
    url, token = _setting("CONFLUENCE_URL"), _setting("CONFLUENCE_TOKEN")
    if not url or not token:
        print("[publish] CONFLUENCE_URL / CONFLUENCE_TOKEN not set in ~/.config/transcribe/.env", file=sys.stderr)
        return 2
    verify = (_setting("CONFLUENCE_VERIFY_TLS") or "1").lower() not in ("0", "false", "no", "off")
    c = Confluence(url, token, verify)

    body = build_body(p, cfg)
    files = attachments(p)
    state = json.loads(state_path(p).read_text(encoding="utf-8")) if state_path(p).is_file() else {}
    parent = c.get(f"/rest/api/content/{cfg['parent']}", expand="space")
    space = parent["space"]["key"]
    found = c.get("/rest/api/content", spaceKey=space, title=cfg["title"], expand="version,ancestors")["results"]
    page = found[0] if found else None
    if page and str(page["ancestors"][-1]["id"]) != str(cfg["parent"]):
        print(f"[publish] «{cfg['title']}» exists in {space} below {page['ancestors'][-1]['title']} - not below "
              f"{cfg['parent']}; move it or change the title", file=sys.stderr)
        return 2

    # page body
    body_sha = sha(body)
    if not page:
        action = "create"
    elif state.get("page_id") == page["id"] and state.get("body_sha") == body_sha \
            and state.get("version") == page["version"]["number"]:
        action = "unchanged"
    else:
        remote = c.get(f"/rest/api/content/{page['id']}", expand="body.storage")["body"]["storage"]["value"]
        action = "unchanged" if remote == body else "update"
    print(f"[publish] page «{cfg['title']}» in {space} below «{parent['title']}»: {action}"
          + (f" (v{page['version']['number']})" if page else ""), file=sys.stderr)

    # attachments
    remote_att = {}
    if page:
        remote_att = {a["title"]: a for a in
                      c.get(f"/rest/api/content/{page['id']}/child/attachment", limit=500, expand="version")["results"]}
    att_state = dict(state.get("attachments", {})) if state.get("page_id") == (page or {}).get("id") else {}
    plan: list[tuple[Path, str | None]] = []
    for f in files:
        local = sha(f.read_bytes())
        if f.name in remote_att:
            att_state[f.name] = attachment_state(c, remote_att[f.name], att_state.get(f.name))
            if att_state[f.name]["sha"] == local:
                continue
            plan.append((f, remote_att[f.name]["id"]))
        else:
            plan.append((f, None))
    stale = sorted(n for n in remote_att if n.startswith("ill_") and n not in {f.name for f in files})
    print(f"[publish] attachments: {len(files)} local, {len(plan)} to upload"
          + (f", {len(stale)} old crop(s) on the page not referenced any more: {', '.join(stale)}" if stale else ""),
          file=sys.stderr)
    for f, aid in plan:
        print(f"[publish]   {'replace' if aid else 'add'} {f.name}", file=sys.stderr)

    # hub
    hub_action, hub_new, hub_page = "none", None, None
    if cfg.get("hub"):
        hub_page = c.get(f"/rest/api/content/{cfg['hub']}", expand="body.storage,version")
        s = hub_page["body"]["storage"]["value"]
        if f'ri:content-title="{html.escape(cfg["title"])}"' in s:
            hub_action = "row present"
        else:
            m = re.search(r"<table.*?</table>", s, re.S)
            if not m:
                print(f"[publish] hub {cfg['hub']} has no table - row skipped", file=sys.stderr)
                hub_action = "no table"
            else:
                table = m.group(0)
                end = table.rfind("</tr>") + len("</tr>")
                hub_new = s[:m.start()] + table[:end] + hub_row(p, cfg) + table[end:] + s[m.end():]
                hub_action = "append row"
        print(f"[publish] hub «{hub_page['title']}»: {hub_action}", file=sys.stderr)

    if args.dry_run:
        out = p.base.with_name(p.base.name + ".publish-preview.xml")
        out.write_text(body, encoding="utf-8")
        print(f"[publish] dry run - no remote changes; local page body preview: {out}", file=sys.stderr)
        return 0

    # write
    if action == "create":
        page = c.post_json("/rest/api/content", {"type": "page", "title": cfg["title"], "space": {"key": space},
                                                 "ancestors": [{"id": cfg["parent"]}],
                                                 "body": {"storage": {"value": body, "representation": "storage"}}})
    elif action == "update":
        page = c.put_json(f"/rest/api/content/{page['id']}",
                          {"id": page["id"], "type": "page", "title": cfg["title"], "space": {"key": space},
                           "body": {"storage": {"value": body, "representation": "storage"}},
                           "version": {"number": page["version"]["number"] + 1, "minorEdit": True}})
    for f, aid in plan:
        uploaded = c.upload(page["id"], f, aid)
        remote = (uploaded.get("results") or [uploaded])[0]
        att_state[f.name] = {"id": remote.get("id"), "version": remote.get("version", {}).get("number"), "sha": sha(f.read_bytes())}
    if hub_new is not None:
        c.put_json(f"/rest/api/content/{cfg['hub']}",
                   {"id": cfg["hub"], "type": "page", "title": hub_page["title"], "space": {"key": space},
                    "body": {"storage": {"value": hub_new, "representation": "storage"}},
                    "version": {"number": hub_page["version"]["number"] + 1, "minorEdit": True}})
        back = c.get(f"/rest/api/content/{cfg['hub']}", expand="body.storage")["body"]["storage"]["value"]
        print(f"[publish] hub row {'present' if html.escape(cfg['title']) in back else 'MISSING'} after readback",
              file=sys.stderr)
    back = c.get(f"/rest/api/content/{page['id']}", expand="body.storage,version")
    stored = back["body"]["storage"]["value"]
    print(f"[publish] readback: v{back['version']['number']}, {stored.count('<ac:image')} image(s), "
          f"{'identical' if stored == body else 'normalized by Confluence'}", file=sys.stderr)
    state_path(p).write_text(json.dumps({
        "page_id": back["id"], "version": back["version"]["number"], "body_sha": body_sha,
        "attachments": att_state, "parent": cfg["parent"], "hub": cfg.get("hub"),
        "url": c.url + back["_links"]["webui"], "published": _dt.datetime.now().isoformat(timespec="seconds"),
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"[publish] done: {c.url}{back['_links']['webui']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
