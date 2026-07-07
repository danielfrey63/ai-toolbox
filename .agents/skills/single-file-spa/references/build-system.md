# Build-System (Stufe L) — Vorlagen und Regeln

Kanonische Fassung aus orggraph. Alles Zero-Dependency (`node:fs`), kein Bundler, kein npm-install für den Build.

## build.js — kanonische Vorlage

```js
// Assemble the single-file deliverable index.html from template + sources.
// Zero dependencies — runs with plain `node build.js`, no npm install needed.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';

const read = (path) => readFileSync(path, 'utf8');

// Sections are ES modules for dev/tests; the deliverable inlines them as one
// classic script. Convention: imports are single-line, export keywords sit at
// column 0 — both are stripped here, which exactly reverses the module syntax.
// Coverage-ignore markers (function-level demarcation of decision-free DOM
// applicators) are dev/test-only and stripped from the deliverable as well.
const stripModuleSyntax = (code) =>
  code
    .replace(/^import .*\n/gm, '')
    .replace(/^export \{[^}]*\};?\n/gm, '')
    .replace(/^export (?=(const|let|var|function|async function|class)\b)/gm, '')
    .replace(/^\/\* v8 ignore (start|stop) \*\/\n/gm, '');

// App sections are concatenated in lexicographic order (numeric prefixes).
const app = readdirSync('src/sections')
  .filter((f) => f.endsWith('.js'))
  .sort()
  .map((f) => stripModuleSyntax(read(`src/sections/${f}`)))
  .join('');

// The build is fully independent of versioning: it only inlines CSS, vendor
// libs and the app sections. The app version lives solely in the template's
// APP_VERSION constant (bumped by the AI-Toolbox hooks) and the header renders
// it at runtime — build.js never reads or stamps a version.
const out = read('index.template.html')
  .replace('@@CSS@@', () => read('src/styles.css'))
  .replace('@@VENDOR@@', () => read('vendor/<lib>.min.js'))
  .replace('@@APP@@', () => app);

writeFileSync('index.html', out);
console.log(`index.html written (${out.length} bytes)`);
```

Load-bearing Details, die man beim Nachbauen verliert:

- **Replace mit Funktions-Callback** (`() => read(...)`) — sonst interpretiert `String.replace` `$`-Sequenzen im eingesetzten Code als Replacement-Pattern und korrumpiert das Artefakt still.
- **stripModuleSyntax ist nur unter zwei Konventionen exakt reversibel:** Imports einzeilig, `export` auf Spalte 0. Diese Konventionen im Repo-CLAUDE.md festhalten.
- Sektions-Nummerierung `NN-` zweistellig; Lücken sind erlaubt (orggraph: `17` fehlt) — nie nachverdichten, das bricht Diff-Historie und Coverage-Remap.
- Vendor-Libs liegen geprüft in `vendor/` und werden inlined — nie zur Laufzeit geladen. In `.gitattributes`: `vendor/** -text` (byte-exakt), Rest `* text=auto` + `eol=lf` für reproduzierbare Builds unter autocrlf.

## verify.js — Stale-Guard

Re-buildet und vergleicht EOL-normalisiert; meldet die erste Divergenz. Fängt den Klassiker «Section editiert, Build vergessen, Artefakt verkauft alten Stand».

```js
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const norm = (s) => s.replace(/\r\n?/g, '\n');

const before = norm(readFileSync('index.html', 'utf8'));
execSync('node build.js', { stdio: 'inherit' });
const after = norm(readFileSync('index.html', 'utf8'));

if (before === after) {
  console.log('OK: index.html is in sync with the sources (modulo line endings)');
} else {
  const a = before.split('\n');
  const b = after.split('\n');
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      console.error(`OUT OF SYNC at line ${i + 1} — index.html was stale; the build regenerated it.`);
      console.error(`now: ${JSON.stringify((b[i] ?? '<missing>').slice(0, 160))}`);
      console.error(`old: ${JSON.stringify((a[i] ?? '<missing>').slice(0, 160))}`);
      console.error('Review the diff and commit the rebuilt index.html.');
      break;
    }
  }
  process.exit(1);
}
```

## Git-pre-commit — Bump, dann Build, dann Re-Stage

Das Bumpen gehört der AI-Toolbox (`toolbox install --what versioning-hooks --scope project`); der Projekt-Hook ergänzt nur Build + Re-Stage. Portabel über den `bump-version`-Launcher auf PATH (von `toolbox install` erzeugt), Fallback auf das Nachbar-Repo:

```sh
#!/bin/sh
# Bump first, then build, so index.html always carries the freshly bumped version.
set -e
if command -v bump-version >/dev/null 2>&1; then
    bump-version --commit index.template.html
else
    sh "$(git rev-parse --show-toplevel)/../ai-toolbox/tools/bump-version.sh" --commit index.template.html
fi
node build.js
git add index.template.html index.html
```

Aktivierung via `package.json`: `"prepare": "git config core.hooksPath .githooks"`. Der Per-Edit-BUILD-Bump läuft separat als Claude-Code-PostToolUse-Hook (matcher `Edit|Write`) in der Projekt-`.claude/settings.json`.

## Coverage-Remap (nur wenn Coverage-Gutters im Artefakt gewünscht)

v8/Vitest misst Coverage gegen `src/sections/*.js`; wer die Gutters auch in der konkatenierten `index.html` sehen will, braucht ein Remap-Skript (orggraph `remap-coverage.js`, ~107 Zeilen): es replayt die exakte Build-Assemblierung, übersetzt Sektions-Zeilennummern auf Artefakt-Zeilen und hängt einen `SF:<absoluter Pfad>/index.html`-Record an `coverage/lcov.info`. Zwei Fallstricke: Sanity-Abort wenn Replay ≠ Build (sonst lügen die Gutters), und absoluter Pfad im SF-Record (Gutters matchen keine bare Pfade). Die Strip-Logik ist dort dupliziert — bei Änderungen an `stripModuleSyntax` beide Stellen anfassen oder in ein gemeinsames Modul ziehen.
