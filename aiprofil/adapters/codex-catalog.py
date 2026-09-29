#!/usr/bin/env python3
"""codex-catalog — build a Codex model catalog from an Azure OpenAI resource.

Shared helper of codex-profil.{sh,ps1}. Codex cannot list the deployments of a
custom provider, so this script does it at `codex-profil use` time:

  1. GET <root>/deployments?api-version=2022-12-01 on the Azure resource
     (root = base_url without a trailing /v1), keeping succeeded deployments.
  2. For every deployment, copy the full model metadata (reasoning levels,
     shell type, ...) from Codex's own OpenAI catalog cache
     ($CODEX_HOME/models_cache.json): exact match on the deployment's model,
     then on its id, then the highest version of the same variant
     (gpt-6.1-sol -> gpt-6-sol). Deployments without a match (embeddings,
     non-GPT models) are skipped. slug and display_name become the
     deployment id, since Codex sends the slug as model = deployment name.
  3. Write {"models": [...]} to --out, only if the content changed.

If Azure is unreachable, --fallback (comma list of deployment ids) is used
instead. The resulting slugs are printed comma-separated on stdout so the
adapter can create one Codex profile per deployment.

Exit codes: 0 live catalog, 3 fallback catalog, 2 nothing usable (no write).

Environment:
  CODEX_CATALOG_API_KEY  api-key header for Azure (kept out of argv)
  CODEX_CATALOG_FIXTURE  path to a deployments JSON used instead of HTTP (tests)
"""

APP_VERSION = '0.2.2'

import argparse
import json
import os
import re
import sys
import urllib.request

DEPLOYMENTS_API_VERSION = '2022-12-01'
VARIANT_RE = re.compile(r'^(?P<family>[a-z]+)-(?P<version>\d+(?:\.\d+)*)-(?P<variant>.+)$')


def log(msg):
    print(f'[codex-catalog] {msg}', file=sys.stderr)


def fetch_deployments(base_url):
    """Return [(id, model)] of succeeded deployments, or None on failure."""
    fixture = os.environ.get('CODEX_CATALOG_FIXTURE')
    try:
        if fixture:
            with open(fixture, encoding='utf-8') as fh:
                data = json.load(fh)
        else:
            root = re.sub(r'/v1/?$', '', base_url.rstrip('/'))
            req = urllib.request.Request(
                f'{root}/deployments?api-version={DEPLOYMENTS_API_VERSION}',
                headers={'api-key': os.environ.get('CODEX_CATALOG_API_KEY', '')})
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.load(resp)
    except Exception as exc:  # network, auth, JSON — all mean "use the fallback"
        log(f'could not list deployments: {exc}')
        return None
    return [(d['id'], d.get('model') or d['id'])
            for d in data.get('data', [])
            if d.get('status', 'succeeded') == 'succeeded' and d.get('id')]


def version_key(version):
    return tuple(int(p) for p in version.split('.'))


def find_template(models, candidates):
    """First exact slug match among candidates, else the highest version of
    the same family/variant (gpt-6.1-sol -> gpt-6-sol)."""
    by_slug = {m['slug']: m for m in models}
    for c in candidates:
        if c in by_slug:
            return by_slug[c]
    for c in candidates:
        want = VARIANT_RE.match(c)
        if not want:
            continue
        same = [(version_key(got['version']), by_slug[slug])
                for slug in by_slug
                if (got := VARIANT_RE.match(slug))
                and got['family'] == want['family'] and got['variant'] == want['variant']]
        if same:
            return max(same, key=lambda t: t[0])[1]
    return None


def main():
    ap = argparse.ArgumentParser(description='Build a Codex model catalog from Azure deployments.')
    ap.add_argument('--base-url', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--codex-home', required=True)
    ap.add_argument('--fallback', default='')
    args = ap.parse_args()

    cache_file = os.path.join(args.codex_home, 'models_cache.json')
    try:
        with open(cache_file, encoding='utf-8') as fh:
            models = json.load(fh).get('models', [])
    except (OSError, ValueError) as exc:
        log(f'no usable Codex model cache ({cache_file}): {exc} — start codex once to create it')
        return 2

    deployments = fetch_deployments(args.base_url)
    rc = 0
    if deployments is None:
        deployments = [(d, d) for d in (s.strip() for s in args.fallback.split(',')) if d]
        if not deployments:
            return 2
        log('using CODEX_MODEL_DEPLOYMENTS as fallback')
        rc = 3

    catalog = []
    for dep_id, dep_model in sorted(set(deployments)):
        tpl = find_template(models, [dep_model, dep_id])
        if tpl is None:
            log(f'skipped {dep_id} (model {dep_model}): no matching Codex model metadata')
            continue
        entry = json.loads(json.dumps(tpl))
        entry['slug'] = dep_id
        entry['display_name'] = dep_id
        catalog.append(entry)
    if not catalog:
        log('no deployment matched a Codex model')
        return 2

    text = json.dumps({'models': catalog}, indent=2, ensure_ascii=False) + '\n'
    old = None
    if os.path.exists(args.out):
        with open(args.out, encoding='utf-8') as fh:
            old = fh.read()
    if text != old:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(text)
    print(','.join(m['slug'] for m in catalog))
    return rc


if __name__ == '__main__':
    sys.exit(main())
