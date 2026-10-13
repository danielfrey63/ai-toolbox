# Build-System (Sections + Build) – Vorlagen und Regeln

Kanonische Fassung aus rain und avers, hervorgegangen aus orggraph. Alles Zero-Dependency (`node:fs`, `node:vm`), kein Bundler, kein npm-install für den Build.

## Inhalt

- [assemble.js – die einzige Montage](#assemblejs--die-einzige-montage)
- [build.js – Parse-Check und Schreiben](#buildjs--parse-check-und-schreiben)
- [Platzhalter im Template](#platzhalter-im-template)
- [verify.js – Stale-Guard](#verifyjs--stale-guard)
- [Coverage auf dem Artefakt](#coverage-auf-dem-artefakt)

## assemble.js – die einzige Montage

`assemble.js` weiss als einzige Datei, wie die `index.html` zusammengesetzt wird. `build.js` und die Coverage-Tools importieren sie, damit Zeilennummern der Sections im Artefakt nie auseinanderlaufen (orggraph hatte die Strip-Logik in `build.js` und `remap-coverage.js` doppelt).

```js
// Assembly of the single-file deliverable, shared by build.js and the
// coverage tools: one place knows how index.html is put together.
// Zero dependencies.
import { readFileSync, readdirSync, existsSync } from 'node:fs';

const read = (path) => readFileSync(path, 'utf8').replace(/\r\n?/g, '\n');
const countLines = (s) => (s.match(/\n/g) || []).length;

// Sections are ES modules for dev/tests; the deliverable inlines them as one
// classic script. Convention: imports are single-line, export keywords sit at
// column 0 – both are stripped here, which exactly reverses the module syntax.
// Coverage-ignore markers are dev/test-only and stripped as well.
export const isStrippedLine = (line) =>
  /^import .*$/.test(line) || /^export \{[^}]*\};?$/.test(line) || /^\/\* v8 ignore (start|stop) \*\/$/.test(line);

export const stripModuleSyntax = (code) =>
  code
    .replace(/^import .*\n/gm, '')
    .replace(/^export \{[^}]*\};?\n/gm, '')
    .replace(/^export (?=(const|let|var|function|async function|class)\b)/gm, '')
    .replace(/^\/\* v8 ignore (start|stop) \*\/\n/gm, '');

// Pictures travel inline as data URIs, so the single file stays offline-ready.
const MIME = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', svg: 'image/svg+xml', webp: 'image/webp' };
export function asset(name) {
  const type = MIME[name.split('.').pop().toLowerCase()];
  if (!type) throw new Error(`unknown asset type: ${name}`);
  return `data:${type};base64,${readFileSync(`src/assets/${name}`).toString('base64')}`;
}

// Generated data is inlined; missing data is not fatal – the app shows an
// empty state instead.
const inlineJson = (path) => (existsSync(path) ? read(path).trim() : 'null');

// → { html, app, sections: [{ file, src, start }] } with `start` the 1-based
// line of the section's first kept line in index.html.
export function assemble() {
  const sections = readdirSync('src/sections').filter((f) => f.endsWith('.js')).sort()
    .map((file) => ({ file, src: read(`src/sections/${file}`) }));
  const app = sections.map((s) => stripModuleSyntax(s.src)).join('');
  // Replacer functions: "$&" and friends in the sources must stay literal.
  let html = read('index.template.html')
    .replace('@@CSS@@', () => read('src/styles.css'))
    .replace('@@DATA@@', () => inlineJson('data/app/data.json'))
    .replace(/@@ASSET:([\w.-]+)@@/g, (_, name) => asset(name));
  const appAt = html.indexOf('@@APP@@');
  let line = countLines(html.slice(0, appAt)) + 1;
  for (const s of sections) {
    s.start = line;
    line += countLines(stripModuleSyntax(s.src));
  }
  return { html: html.slice(0, appAt) + app + html.slice(appAt + '@@APP@@'.length), app, sections };
}
```

Nicht benötigte Platzhalter weglassen (avers hat kein `@@DATA@@`, rain keine Assets). `sections[].start` und `isStrippedLine` braucht nur die Coverage; ohne Coverage-Tooling reicht `{ html, app }`.

Load-bearing Details, die man beim Nachbauen verliert:

- **Replace mit Funktions-Callback** (`() => read(...)`) – sonst interpretiert `String.replace` `$`-Sequenzen im eingesetzten Code oder in Daten als Replacement-Pattern und korrumpiert das Artefakt still.
- **EOL beim Lesen normalisieren** (`\r\n?` → `\n`) – sonst hängt das Artefakt unter autocrlf vom Checkout ab.
- **stripModuleSyntax ist nur unter zwei Konventionen exakt reversibel:** Imports einzeilig, `export` auf Spalte 0. Diese Konventionen im Projekt-`CLAUDE.md` festhalten.
- Sektions-Nummerierung `NN-` zweistellig; Lücken sind erlaubt und gewollt (rain: `00`–`12`, dann `20`, `99`) – nie nachverdichten, das bricht Diff-Historie.
- Vendor-Libs liegen geprüft in `vendor/` und werden über einen eigenen Platzhalter (`@@VENDOR@@`) inlined – nie zur Laufzeit geladen.
- `.gitattributes`: `* text=auto eol=lf`; `vendor/**`, `src/assets/**`, `*.pdf` und andere Binär- oder Referenzdaten `-text` (byte-exakt).

## build.js – Parse-Check und Schreiben

```js
// Assemble the single-file deliverable index.html from template + sources.
// Zero dependencies – runs with plain `node build.js`, no npm install needed.
import { writeFileSync } from 'node:fs';
import vm from 'node:vm';
import { assemble } from './assemble.js';

// The build never reads or stamps a version: APP_VERSION lives in
// index.template.html and the header renders it at runtime.
const { html, app } = assemble();

// The sections share ONE classic-script scope: a duplicate top-level name or a
// missed import line would only surface as a blank app – parse here instead.
try {
  new vm.Script(app, { filename: 'index.html (app sections)' });
} catch (err) {
  console.error(`BUILD ABORTED – the concatenated app does not parse: ${err.message}`);
  process.exit(1);
}

writeFileSync('index.html', html);
console.log(`index.html written (${html.length} bytes)`);
```

Baut ein Server die App mit eigenem Datenstand (rain), steuern Umgebungsvariablen Quelle und Ziel, lokal mit Repo-Defaults: `const STATE = process.env.RAIN_STATE || 'data'; const OUT = process.env.RAIN_OUT || 'index.html';` und `assemble(STATE)`.

## Platzhalter im Template

`index.template.html` trägt Markup und das Inline-Script mit der Version; die Platzhalter sitzen an festen Stellen:

```html
<style>
@@CSS@@
</style>
…
<script>
const APP_VERSION = '0.1.0';
document.getElementById('appVersion').textContent = `v${APP_VERSION}`;
const APP_DATA = @@DATA@@;
@@APP@@
</script>
```

- `@@CSS@@`, `@@APP@@` – immer.
- `@@VENDOR@@` – geprüfte Libs aus `vendor/` (orggraph: D3).
- `@@DATA@@` und weitere benannte JSON-Platzhalter – Pipeline-Output, als Konstante vor `@@APP@@` (rain: `@@GEO@@`, `@@DATA@@`, `@@FLAGS@@`). Fehlt die Datei, wird `null` eingesetzt.
- `@@ASSET:name@@` – Bild aus `src/assets/` als Data-URI, direkt im `src`-Attribut (avers). Bilder vorher auf die Anzeigegrösse zuschneiden; `width`/`height` setzen, `loading="lazy"` unterhalb des ersten Bildschirms.
- Mehrseitige Apps (avers) legen statische Seiteninhalte als `<section data-page="…">` direkt ins Template – Text bleibt Markup, nicht JS-Strings.

## verify.js – Stale-Guard

Re-buildet und vergleicht EOL-normalisiert; meldet die erste Divergenz. Fängt den Klassiker «Section editiert, Build vergessen, Artefakt verkauft alten Stand».

```js
// Stale guard: rebuild and compare against the committed index.html.
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
      console.error(`OUT OF SYNC at line ${i + 1} – index.html was stale; the build regenerated it.`);
      console.error(`now: ${JSON.stringify((b[i] ?? '<missing>').slice(0, 160))}`);
      console.error(`old: ${JSON.stringify((a[i] ?? '<missing>').slice(0, 160))}`);
      console.error('Review the diff and commit the rebuilt index.html.');
      break;
    }
  }
  process.exit(1);
}
```

Wird die `index.html` committet, gehört `node build.js` in den Commit-Ablauf des Projekts, damit Artefakt und Quellen nie auseinanderliegen; `verify.js` prüft das nachträglich (CI, Deploy).

## Coverage auf dem Artefakt

Wer Coverage auch in der konkatenierten `index.html` sehen will (Coverage Gutters), nutzt `assemble()` und `sections[].start`, um Sektions-Zeilen auf Artefakt-Zeilen abzubilden – keine eigene Strip-Kopie. Vorher prüfen, dass `assemble().html` exakt der `index.html` auf der Platte entspricht, sonst abbrechen (die Gutters würden lügen). Der lcov-Record für `index.html` braucht einen absoluten Pfad (`SF:<abs>/index.html`), bare Pfade matchen die Gutters nicht. Kombinierte Unit- und E2E-Coverage: siehe [testing.md](testing.md).
