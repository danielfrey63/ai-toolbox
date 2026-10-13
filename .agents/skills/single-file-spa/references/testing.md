# Testing – Unit, E2E, Coverage im Single-File-Kontext

Der Trick bei Sections + Build: **Sektionen sind in der Entwicklung echte ES-Module** (mit `export`), Tests importieren sie direkt – erst der Build strippt die Modul-Syntax fürs Offline-Artefakt. Dieselbe Quelle ist dev-testbar UND file://-lauffähig; kein Bundler, kein Transpiler.

## Unit-Tests (Vitest)

- Minimal reicht `vitest` allein (avers: Tarif-, Saison- und Routen-Engine). Für DOM-nahe Tests `jsdom` als environment, für IndexedDB `fake-indexeddb` (`import 'fake-indexeddb/auto'` als erste Zeile im Test).
- Tests importieren direkt aus den Sektionen: `import { parseRoute } from '../src/sections/04-route.js'`.
- `vitest.config.js`: `include: tests/**/*.test.js`, Coverage-Provider v8 über `src/sections/**`, **Line-Gate 80 %** (orggraph hält ~91 %).
- **Architektur-Voraussetzung:** Engine-Schichten (Datenmodell, Berechnung, Merge, Validierung, Routen) DOM-frei und pure halten – sie tragen die Coverage; dünne DOM-Applikatoren sind verzweigungsfrei und werden function-level mit `/* v8 ignore start */` … `/* v8 ignore stop */` markiert (der Build strippt diese Marker aus dem Artefakt).
- Speicher-Zugriffe injizierbar halten (`loadUi(storage)`, `saveUi(storage, ui)`, rain) – Tests übergeben ein Map-basiertes Fake statt `window.localStorage`.
- Für Schema-Tests `ajv`/`ajv-formats` als devDependencies; Test-Hooks im Code (`_resetProfilesCache()`) für saubere Zustände.

## Komponenten-Contract als Test-Gate

Die einfachen Rezepte aus `.claude/component-inventory.md` laufen als `tests/components.test.js` bei jedem Unit-Lauf mit (rain): Die Tests lesen Sections, Template und Stylesheet als Text und prüfen per grep, dass niemand eine Factory umgeht (z.B. `<svg` nur in `00-icons.js`, kein `alert(`/`confirm(` ausser im Toast). Zusätzlich: jede Klasse und ID im Stylesheet hat einen Erzeuger in Template oder Sections – tote CSS-Regeln fallen sofort auf. Ein Bypass bricht so Commit und Deploy, nicht erst das nächste `component-audit`.

## E2E (Playwright)

- **Über einen lokalen HTTP-Server fahren, nie über `file://`** – Playwright + file:// ist fragil (Berechtigungen, fetch-Verhalten). Minimaler Node-http-Server reicht; `reuseExistingServer: true`.
- Ablage: `tests/e2e/*.e2e.js` mit `testDir: 'tests/e2e'`, `testMatch: '*.e2e.js'` – Vitest (`*.test.js`) und Playwright greifen sich so nicht gegenseitig die Dateien. Gemeinsame Fixtures in `tests/e2e/base.js`.
- Mobile Layouts als eigene Specs bzw. Projekte (rain: `mobile.e2e.js`, `ios.e2e.js` mit Geräte-Emulation) – Touch, Hochformat und Tastatur verhalten sich anders als Desktop.
- Funktionen, die nur über http(s) laufen (Kacheln), brauchen einen eigenen Spec, weil gerade sie unter `file://` nie getestet würden (rain: `tiles.e2e.js`).
- Der Server kann **virtuelle Mandanten über denselben Build** mounten (`/` = Fixture-Tenant, `/kunde/` = Referenz-Tenant, env.json dynamisch generiert, orggraph) – so testet ein Build mehrere Konfigurationen.
- **Zwei Projekte trennen**, wenn Referenzdaten nicht im Repo liegen: `smoke` (läuft immer, Fixture-Daten) und `acceptance` (skippt sauber, wenn lokale Referenz-Daten fehlen). `workers: 1` – die Apps teilen sich Browser-Storage.

## Kombinierte Coverage (rain, `tools/coverage.js`)

Ein Skript (`npm run coverage`) baut, fährt beide Suiten und schreibt alles nach `coverage/lcov.info`:

- Unit: `vitest run --coverage`, gemessen auf `src/sections/*.js`.
- E2E: Playwright mit `E2E_COVERAGE=1`, Chromium-V8-Coverage auf dem Inline-Script der `index.html`; die Roh-Dumps (`coverage-e2e/`) tragen einen Hash des Inline-Skripts statt der ganzen Quelle und werden bei jedem Lauf neu erzeugt (idempotent).
- Merge über `assemble()` (siehe [build-system.md](build-system.md)): eine Zeile gilt als abgedeckt, wenn eine der beiden Suiten sie ausführt. Ergebnis: je ein Record pro Sektion und einer für `index.html` mit absolutem Pfad.
- Der Nenner sind alle Codezeilen der Sektionen im Artefakt, auch die in `v8 ignore`-Blöcken – die Zahl wird nicht durch ungetesteten Code geschönt.
- **CSS-Coverage-Gate:** der E2E-Lauf misst, welche Regeln aus `src/styles.css` greifen; jede Regel muss in mindestens einem Test greifen, sonst scheitert der Lauf. Regeln, die nur bestimmte Daten einschalten, stehen begründet in einer Ausnahmeliste (`DATA_DEPENDENT`).
- Exit-Code ≠ 0, wenn eine Suite scheitert; das Deploy ruft das Skript auf, damit die Coverage nach jedem Release aktuell ist.

## devDependencies-Baseline

Minimal (avers): `vitest`. Voll (orggraph, rain): `vitest`, `@vitest/coverage-v8`, `@playwright/test`, bei Bedarf `jsdom`, `fake-indexeddb`, `ajv`, `ajv-formats`, optional `@babel/*` für AST-basierte Struktur-Tests. Das Deliverable hat **keine** Runtime-Dependencies; eine Daten-Pipeline darf eigene haben (rain: `h5wasm`, installiert mit `npm ci --omit=dev`).

## Verifikations-Disziplin

Build-Erfolg ist kein Funktionsbeweis: nach jeder Änderung die App im Browser aus `file://` öffnen (oder mindestens die betroffenen Module per `node`-Smoke-Test treiben) und den geänderten Flow einmal durchklicken. `npm test && node verify.js` ist die Commit-Schwelle.
