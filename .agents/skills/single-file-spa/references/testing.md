# Testing — Unit, E2E, Coverage im Single-File-Kontext

Der Trick der Stufe L: **Sektionen sind in der Entwicklung echte ES-Module** (mit `export`), Tests importieren sie direkt — erst der Build strippt die Modul-Syntax fürs Offline-Artefakt. Dieselbe Quelle ist dev-testbar UND file://-lauffähig; kein Bundler, kein Transpiler.

## Unit-Tests (Vitest)

- Stack: `vitest` + `jsdom` (environment) + `fake-indexeddb` (`import 'fake-indexeddb/auto'` als erste Zeile im Test ersetzt IndexedDB komplett).
- Tests importieren direkt aus den Sektionen: `import { saveState } from '../src/sections/04-storage.js'`.
- `vitest.config.js`: `include: tests/**/*.test.js`, Coverage-Provider v8 über `src/sections/**`, **Line-Gate 80%** (orggraph hält ~91%).
- **Architektur-Voraussetzung:** Engine-Schichten (Datenmodell, Merge, Validierung) DOM-frei und pure halten — sie tragen die Coverage; dünne DOM-Applikatoren sind verzweigungsfrei und werden function-level mit `/* v8 ignore start */` … `/* v8 ignore stop */` markiert (der Build strippt diese Marker aus dem Artefakt).
- Für Schema-Tests `ajv`/`ajv-formats` als devDependencies; Test-Hooks im Code (`_resetProfilesCache()`) für saubere Zustände.

## Stale-Guard und Coverage-Remap

- `npm run verify` (= `node verify.js`): rebuild + EOL-normalisierter Vergleich — fängt «Section geändert, Build vergessen» (Vorlage in build-system.md).
- `npm run test:coverage` = `vitest run --coverage && node build.js && node remap-coverage.js`: das Remap-Skript übersetzt die Sektions-Coverage zeilengenau auf `index.html` (lcov-Record mit absolutem Pfad), damit Coverage-Gutters auch im Artefakt stimmen. Details und Fallstricke in build-system.md.

## E2E (Playwright)

- **Über einen lokalen HTTP-Server fahren, nie über `file://`** — Playwright + file:// ist fragil (Berechtigungen, fetch-Verhalten). Minimaler Node-http-Server (`e2e/serve.mjs`) reicht; `reuseExistingServer: true`.
- Der Server kann **virtuelle Mandanten über denselben Build** mounten (`/` = Fixture-Tenant, `/kunde/` = Referenz-Tenant, env.json dynamisch generiert) — so testet ein Build mehrere Konfigurationen.
- **Zwei Projekte trennen:** `smoke` (läuft immer, Fixture-Daten) und `acceptance` (skippt sauber, wenn lokale Referenz-Daten fehlen — z.B. kundenspezifische Migrationen, die nicht im Repo liegen). `workers: 1` — die Apps teilen sich Browser-Storage.
- Scripts-Konvention: `e2e` = smoke, `e2e:acceptance` = Vollabnahme.

## devDependencies-Baseline (orggraph, geprüft)

`vitest`, `@vitest/coverage-v8`, `jsdom`, `fake-indexeddb`, `@playwright/test`, `ajv`, `ajv-formats` — dazu optional `@babel/parser`/`@babel/traverse`/`@babel/generator`/`@babel/types` für AST-basierte Struktur-Tests. Runtime-Dependencies: **keine**, immer.

## Verifikations-Disziplin

Build-Erfolg ist kein Funktionsbeweis: nach jeder Änderung die App im Browser aus `file://` öffnen (oder mindestens die betroffenen Module per `node`-Smoke-Test treiben) und den geänderten Flow einmal durchklicken. `npm test && npm run verify` ist die Commit-Schwelle; der Komponenten-Contract (`COMPONENT_INVENTORY.md`) lässt sich mit dem `component-audit`-Skill der AI-Toolbox gegen Bypässe prüfen.
