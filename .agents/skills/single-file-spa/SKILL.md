---
name: single-file-spa
description: "Scaffold und Wartung dependency-freier Offline-SPAs nach dem bewährten Archetyp in drei Ausbaustufen: S = Monolith-index.html mit Kommentar-Bändern und localStorage (nem-wochenplan), M = Monolith mit File-System-Access-Auto-Save, Szenario-Dateien und Multi-Tab-Isolation (Stundentracker), L = nummerierte src/sections/*.js als echte ES-Module → build.js konkateniert in eine offline öffnbare index.html, IndexedDB-Mandanten-Stores, Vitest+Playwright, Coverage-Remap (orggraph). Verwenden wenn: eine neue lokale/offline Web-App gebaut werden soll («SPA», «offline-fähig», «ohne Server», «single file»), eine bestehende App dieses Typs (orggraph, nem-wochenplan, Stundentracker) erweitert wird, ein Monolith auf Sections migriert werden soll, oder die Build-Nummer/Hooks nicht greifen."
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
metadata:
  version: "0.2.7"
---

# /single-file-spa — Offline-SPA-Archetyp

Kodifiziert den Archetyp, der in **orggraph**, **nem-wochenplan** und dem **Stundentracker 2026** unabhängig entstanden ist — vereinigt aus den Feature-Inventaren aller drei Implementierungen, damit er nicht bei jedem Projekt neu erfunden wird. Detail-Muster liegen in `references/` (Build: `build-system.md`, Persistenz: `persistence.md`, Import/Export: `data-io.md`, Tests: `testing.md`) — **vor der Arbeit an der jeweiligen Schicht die passende Referenz lesen**, nicht aus dem Gedächtnis bauen.

## Nicht verhandelbar (alle Ausbaustufen)

- **Eine Datei als Deliverable.** `index.html` funktioniert per Doppelklick offline aus `file://`: kein CDN, kein fetch auf externe Hosts, keine Web-Fonts (System-Font-Stack), keine ES-Module-Imports zur Laufzeit (file://-CORS). Vendor-Libs werden **inlined** (orggraph: D3 aus `vendor/`), Icons sind selbst gezeichnete Inline-SVGs. Abschreckendes Beispiel: der Stundentracker lädt Chart.js und html2canvas per CDN — ohne Netz keine Charts und keine Bild-Exporte; beim Übernehmen solcher Apps CDN-Tags als Erstes inlinen.
- **`index.html` nie direkt editieren**, wenn es ein Build-Artefakt ist (Stufe L) — immer `src/sections/`. Bei Stufe S/M ist die `index.html` die Quelle; dann Kommentar-Bänder (`// ── Titel ──`) als Gliederung pflegen.
- **Unidirektionaler Datenfluss:** Event → Mutation → `saveState()` → `render()` (Voll-Re-Render, kein Diffing). Event-Delegation über `data-*`-Attribute + `e.target.closest()`.
- **Import ist eine Trust-Boundary:** `escapeHtml()` konsequent auf alle datei- oder nutzergelieferten Strings vor jedem `innerHTML`.
- **Stabile IDs statt Positions-Indizes** als Persistenz-Keys — positions-basierte Keys (`s{id}-i{idx}`, nem-wochenplan) invalidieren beim Umsortieren den gespeicherten Zustand.
- **Design-Tokens als CSS-Custom-Properties** in `:root`; Dark-Mode automatisch via `@media (prefers-color-scheme: dark)`; Toast-Komponente für Feedback, natives `confirm()` für Destruktives.
- **Kein Service Worker** — bei einer Datei unnötig und unter `file://` ohnehin nicht registrierbar. Optionales `fetch` auf lokale Seeds (`tagesplan.json`, `registry.json`) immer mit stillem file://-Fallback auf manuellen Import.

## Ausbaustufen — welche für welches Projekt

| Stufe | Wann | Struktur | Persistenz | Referenz-App |
|---|---|---|---|---|
| **S — Monolith** | Ein Autor, stabiler Scope, ≲1500 Zeilen | Eine `index.html`, Kommentar-Bänder in CSS+JS | localStorage, ein versionierter Key, Merge-über-Defaults beim Laden | nem-wochenplan |
| **M — Monolith+Dateien** | Daten leben in JSON-Dateien des Users, Szenarien/What-ifs, mehrere Tabs | wie S, plus File-System-Access-Auto-Save und Szenario-Namespacing | localStorage pro Szenario-Key + sessionStorage für Tab-Isolation + IndexedDB für File-Handles | Stundentracker 2026 |
| **L — Sections+Build** | Wächst, braucht Tests, mehrere Mandanten, lange Lebensdauer | `src/sections/NN-*.js` (ES-Module) + `src/styles.css` + `index.template.html` → `build.js` | IndexedDB, ein Object-Store pro Mandant, `__meta__`-Profilverwaltung | orggraph |

Upgrade-Pfade sind Teil des Archetyps: S→M ist additiv (FSA-Layer dazu); S/M→L heisst Monolith in Sections zerlegen, Build aufsetzen, **byte-nah gegen das alte Artefakt verifizieren** (`verify.js`-Muster), dann erst Features bauen.

## Struktur (Stufe L)

```
projekt/
├── src/
│   ├── sections/            # NN-*.js, lexikografische Reihenfolge = Konkatenation
│   │   ├── 01-config.js     # Konstanten, Toast
│   │   ├── 02-icons.js      # Inline-SVG-Icon-Registry (setIcon/hydrateIcons)
│   │   ├── 04-storage.js    # IndexedDB-Layer (DOM-frei)
│   │   ├── 05-dropzone.js   # Drag&Drop + ZIP-Import
│   │   └── NN-…             # Engine-Schichten DOM-frei halten (testbar!)
│   └── styles.css
├── index.template.html      # Rahmen mit @@CSS@@ / @@VENDOR@@ / @@APP@@ + APP_VERSION
├── vendor/                  # geprüfte, zu inlinende Libs (z.B. d3.v7.min.js)
├── build.js                 # konkateniert → index.html (versionsfrei!)
├── verify.js                # Stale-Guard: rebuild + Vergleich
├── tests/                   # Vitest gegen src/sections/*.js (ES-Module)
├── e2e/                     # Playwright über lokalen HTTP-Server (nie file://)
└── package.json             # NUR devDependencies; Runtime hat NULL Dependencies
```

Schicht-Regel aus orggraph: Engine-Sektionen (Datenmodell, Merge, Validierung) sind **DOM-frei und pure** — voll unit-testbar; dünne DOM-Adapter-Sektionen applizieren sie. Formalisierter Komponenten-Contract in `COMPONENT_INVENTORY.md` (Factories, Layout-Contract-Klassen, grep-Bypass-Rezepte) — auditierbar mit dem `component-audit`-Skill der AI-Toolbox.

## Version & Build-Nummer

Version **nur an EINER Stelle**: `const APP_VERSION = 'MAJOR.MINOR.BUILD'` in `index.template.html` (Stufe L) bzw. direkt in der `index.html` (S/M); der Header rendert sie zur Laufzeit. `build.js` ist bewusst versionsfrei — es liest und stempelt keine Version.

Das Bumpen übernimmt das **Versionierungs-System der AI-Toolbox** (nicht hier duplizieren): `toolbox install --what versioning-hooks --scope project` installiert den Per-Edit-BUILD-Bump (PostToolUse auf Edit|Write) und den Pro-Commit-MINOR-Bump. Der Git-`pre-commit` des Projekts ruft danach `node build.js` und `git add index.template.html index.html` — bump zuerst, dann build, damit das Artefakt die frische Version trägt (Vorlage in `references/build-system.md`). Hooks **portabel** über den `bump-version`-Launcher auf PATH ansprechen, nie über harte `../ai-toolbox`-Pfade (Anti-Pattern aus nem-wochenplan). Wenn «die Build-Nummer nicht hochzählt»: prüfen, ob der Hook in der Projekt-`settings.json` registriert ist und auf die richtigen Pfade matcht.

## Vorgehen bei «neue App»

1. Ausbaustufe wählen (Tabelle oben) und dem User nennen; im Zweifel S — der Upgrade-Pfad ist Teil des Archetyps.
2. Bei L: Struktur anlegen, `build.js` zuerst schreiben und sofort verifizieren (`node build.js && node verify.js`). Bei S/M: `index.html` mit Kommentar-Band-Gliederung, Tokens in `:root`, `escapeHtml`, Toast.
3. Kleinste lauffähige Version bauen (Rahmen + eine Section/ein Band), **im Browser aus `file://` öffnen und prüfen**, dann Features iterieren.
4. Persistenz-Schicht nach `references/persistence.md` der Stufe entsprechend aufsetzen; von Anfang an `state.schemaVersion` mitschreiben.
5. Bei L: Vitest sofort einrichten (`fake-indexeddb`, jsdom) und State-/Storage-Logik von Anfang an testen; UI bleibt dünn.
6. Versionierungs-Hooks installieren (siehe oben).

## Vorgehen bei «bestehende App erweitern»

1. `build.js` lesen (falls vorhanden) — Konkatenationsreihenfolge und Platzhalter verstehen, bevor Sections angefasst werden. Kein `build.js`? Dann ist die `index.html` die Quelle (Stufe S/M).
2. Nach jeder Änderung: Build laufen lassen (L) und die App im Browser funktional prüfen — Build-Erfolg allein ist kein Beweis.
3. Beim Übernehmen einer fremden Einzeldatei-App zuerst die Archetyp-Verstösse inventarisieren (CDN-Tags, fehlendes escapeHtml, Positions-Keys, fehlende Schema-Version) und als Erstes beheben.

## Anti-Patterns (alle in den drei Apps real aufgetreten)

- CDN-`<script>`-Tags im Deliverable (Stundentracker) — bricht offline.
- `index.html` direkt editieren, obwohl sie gebaut wird — beim nächsten Build weg.
- Positions-basierte Persistenz-Keys (nem-wochenplan) — Umsortieren zerstört Status.
- JSON-Schema liegt bei, wird aber zur Laufzeit nie geprüft (nem-wochenplan) — mindestens Pflichtfelder validieren, Rest dem Schema-File überlassen.
- Inkonsistente Versionsfelder über Datenfiles (`version` vs. `planVersion`+`schemaVersion`) — ein Feldschema am Tag 1 festlegen.
- Harte Cross-Repo-Pfade in Hooks (`../ai-toolbox/...`) — Launcher auf PATH verwenden.
- Doku-Zähler («19 Sektionen») driften vom Code weg — Zahlen in Doku vermeiden oder generieren.
