---
name: single-file-spa
description: "Scaffolds and maintains dependency-free offline single-page apps that ship as one index.html opened via file://, following a proven archetype along two axes (monolith or sections plus build script; persistence from URL hash to IndexedDB tenant stores), optionally fed by a data pipeline and served from the working machine. Use when a new local or offline web app is to be built, an existing app of this type is extended, a monolith is migrated to sections with a build step, or such an app is to be deployed. Trigger: «SPA», «offline-fähig», «ohne Server», «single file», «index.html bauen», «SPA deployen»."
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
metadata:
  version: "0.4.16"
---

# /single-file-spa – Offline-SPA-Archetyp

Kodifiziert den Archetyp, der in **orggraph**, **nem-wochenplan** und dem **Stundentracker** unabhängig entstanden ist und in **rain** und **avers** weiterentwickelt wurde, damit er nicht bei jedem Projekt neu erfunden wird. Wird eine dieser Apps erweitert, gilt dieser Skill ebenfalls.

Detail-Muster liegen in `references/` – **vor der Arbeit an der jeweiligen Schicht die passende Referenz lesen**, nicht aus dem Gedächtnis bauen:

- `assemble.js`, `build.js`, `verify.js`, Platzhalter, Assets, Coverage: [references/build-system.md](references/build-system.md)
- Persistenz (URL-Hash und localStorage bis IndexedDB-Mandanten-Stores): [references/persistence.md](references/persistence.md)
- Import/Export, ZIP, Schema, Merge, Szenarien: [references/data-io.md](references/data-io.md)
- Hash-Routen, Deep-Links, Druck, Funktionen nur über http(s): [references/ui-patterns.md](references/ui-patterns.md)
- Vitest, Playwright, kombinierte Coverage, Komponenten-Gate: [references/testing.md](references/testing.md)
- Betrieb auf der Working-Machine (Container, Quadlet, Deploy, Route), Daten-Pipeline: [references/deployment.md](references/deployment.md)

## Nicht verhandelbar (alle Varianten)

- **Eine Datei als Deliverable.** `index.html` funktioniert per Doppelklick offline aus `file://`: kein CDN, kein fetch auf externe Hosts, keine Web-Fonts (System-Font-Stack), keine ES-Module-Imports zur Laufzeit (file://-CORS). Vendor-Libs, Daten und Bilder werden **inlined** (orggraph: D3 aus `vendor/`; rain: Pipeline-Daten als JSON; avers: Fotos als Data-URI), Icons sind selbst gezeichnete Inline-SVGs. Abschreckendes Beispiel: der Stundentracker lädt Chart.js und html2canvas per CDN – ohne Netz keine Charts und keine Bild-Exporte; beim Übernehmen solcher Apps CDN-Tags als Erstes inlinen.
- **`index.html` nie direkt editieren**, wenn es ein Build-Artefakt ist – immer `src/sections/`, `src/styles.css` oder `index.template.html`. Ist die `index.html` selbst die Quelle (Monolith), Kommentar-Bänder (`// ── Titel ──`) als Gliederung pflegen.
- **Unidirektionaler Datenfluss:** Event → Mutation → `saveState()` → `render()` (Voll-Re-Render, kein Diffing). Event-Delegation über `data-*`-Attribute + `e.target.closest()`.
- **Import ist eine Trust-Boundary:** `escapeHtml()` konsequent auf alle datei- oder nutzergelieferten Strings vor jedem `innerHTML`.
- **Stabile IDs statt Positions-Indizes** als Persistenz-Keys – positions-basierte Keys (`s{id}-i{idx}`, nem-wochenplan) invalidieren beim Umsortieren den gespeicherten Zustand.
- **Design-Tokens als CSS-Custom-Properties** in `:root`; Dark-Mode automatisch via `@media (prefers-color-scheme: dark)`; Toast-Komponente für Feedback, natives `confirm()` für Destruktives.
- **Kein Service Worker** – bei einer Datei unnötig und unter `file://` ohnehin nicht registrierbar. Was nur über http(s) geht (lokale Seeds, Nachlade-Kacheln), hat immer einen stillen Fallback für `file://` (siehe [references/ui-patterns.md](references/ui-patterns.md)).

## Zwei Achsen: Struktur und Persistenz

Struktur und Persistenz sind unabhängige Entscheidungen. avers hat Sections und Build, speichert aber nur eine Checkliste im `localStorage`; nem-wochenplan ist ein Monolith mit versioniertem State.

**Struktur**

| Variante | Wann | Aufbau | Referenz-Apps |
|---|---|---|---|
| **Monolith** | Ein Autor, stabiler Scope, ≲1500 Zeilen, keine Tests nötig | Eine `index.html` ist die Quelle, Kommentar-Bänder in CSS und JS | nem-wochenplan, Stundentracker |
| **Sections + Build** | Wächst, braucht Tests, Assets oder Pipeline-Daten, lange Lebensdauer | `src/sections/NN-*.js` (ES-Module) + `src/styles.css` + `index.template.html` → `assemble.js` → `build.js` → `index.html` | orggraph, rain, avers |

**Persistenz** (Details in [references/persistence.md](references/persistence.md))

| Stufe | Wann | Referenz-App |
|---|---|---|
| **URL-Hash** | Zustand ist eine Eingabe, die man teilen will (Rechner, Ansicht) | avers (Preisrechner), rain (Deep-Links) |
| **localStorage** | Ein Gerät, ein State-Blob oder UI-Einstellungen | nem-wochenplan, rain (UI), avers (Checkliste) |
| **localStorage + FSA-Dateien** | Daten leben in JSON-Dateien des Users, Szenarien, mehrere Tabs | Stundentracker |
| **IndexedDB-Mandanten** | Mehrere Mandanten, grosse Datenstände, Merge | orggraph |

Die Stufen sind kombinierbar. Upgrade-Pfade sind Teil des Archetyps: Persistenz aufstocken ist additiv; Monolith → Sections heisst Datei in Sections zerlegen, Build aufsetzen, **byte-nah gegen das alte Artefakt verifizieren** (`verify.js`-Muster), dann erst Features bauen.

## Struktur (Sections + Build)

```
projekt/
├── src/
│   ├── sections/            # NN-*.js, lexikografische Reihenfolge = Konkatenation
│   │   ├── 01-config.js     # Konstanten, escapeHtml, Toast
│   │   ├── 02-…             # Engine-Schichten DOM-frei und pure (testbar!)
│   │   ├── 20-ui.js         # dünne DOM-Adapter
│   │   └── 99-main.js       # Boot
│   ├── assets/              # Bilder, als Data-URI eingebettet (optional)
│   └── styles.css
├── index.template.html      # Rahmen mit @@CSS@@ / @@APP@@ / @@ASSET:…@@ / Daten-Platzhaltern + APP_VERSION
├── vendor/                  # geprüfte, zu inlinende Libs (optional)
├── assemble.js              # EINZIGE Stelle, die die index.html montiert
├── build.js                 # assemble → Parse-Check → index.html schreiben
├── verify.js                # Stale-Guard: rebuild + Vergleich
├── tests/                   # Vitest gegen src/sections/*.js, tests/e2e/*.e2e.js für Playwright
├── tools/                   # coverage.js, deploy.sh, setup-host.sh, setup-route.sh, lib.sh (optional)
├── server/                  # Containerfile, nginx-Conf, Quadlet (optional, siehe deployment.md)
├── pipeline/                # Daten-Pipeline (optional, siehe deployment.md)
└── package.json             # devDependencies; Runtime des Deliverables hat NULL Dependencies
```

Schicht-Regel: Engine-Sektionen (Datenmodell, Berechnung, Merge, Validierung, Routen) sind **DOM-frei und pure** – voll unit-testbar; dünne DOM-Adapter-Sektionen applizieren sie. Alle Sections teilen im Artefakt EINEN Script-Scope: keine doppelten Top-Level-Namen über alle Sections. Komponenten-Contract in `.claude/component-inventory.md` (Factories, Bypass-Rezepte) – auditierbar mit dem `component-audit`-Skill der AI-Toolbox und als Test-Gate in `tests/components.test.js` (siehe [references/testing.md](references/testing.md)).

## App-Version

Die Version steht **nur an EINER Stelle**: `const APP_VERSION = 'MAJOR.MINOR.BUILD'` im Inline-Script von `index.template.html` (bzw. der Monolith-`index.html`); der Header rendert sie zur Laufzeit. `build.js` ist versionsfrei – es liest und stempelt keine Version. Das Bumpen ist nicht Teil dieses Skills. Deploy-Skripte lesen die Version aus der `index.html` und prüfen, ob der Server sie ausliefert.

## Vorgehen bei «neue App»

1. Struktur und Persistenz wählen (Tabellen oben) und dem User nennen; im Zweifel Monolith mit localStorage – die Upgrade-Pfade sind Teil des Archetyps.
2. Bei Sections + Build: Struktur anlegen, `assemble.js` und `build.js` zuerst schreiben und sofort verifizieren (`node build.js && node verify.js`). Beim Monolith: `index.html` mit Kommentar-Band-Gliederung, Tokens in `:root`, `escapeHtml`, Toast.
3. In `.gitattributes`: `* text=auto eol=lf`, Binäres und Vendor-Libs `-text` (`vendor/**`, `src/assets/**`, `*.pdf`) – reproduzierbare Builds unter autocrlf.
4. Kleinste lauffähige Version bauen (Rahmen + eine Section/ein Band), **im Browser aus `file://` öffnen und prüfen**, dann Features iterieren.
5. Persistenz nach [references/persistence.md](references/persistence.md) aufsetzen; bei versioniertem State von Anfang an `state.schemaVersion` mitschreiben.
6. Bei Sections + Build: Vitest sofort einrichten und die Engine-Sections von Anfang an testen; UI bleibt dünn.
7. Soll die App im Netz erreichbar sein: [references/deployment.md](references/deployment.md).

## Vorgehen bei «bestehende App erweitern»

1. `assemble.js` bzw. `build.js` lesen (falls vorhanden) – Konkatenationsreihenfolge und Platzhalter verstehen, bevor Sections angefasst werden. Kein Build? Dann ist die `index.html` die Quelle.
2. Projekt-`CLAUDE.md` lesen: dort stehen fachliche Regeln, Ports und Betriebsdetails der App.
3. Nach jeder Änderung: Build laufen lassen und die App im Browser funktional prüfen – Build-Erfolg allein ist kein Beweis.
4. Beim Übernehmen einer fremden Einzeldatei-App zuerst die Archetyp-Verstösse inventarisieren (CDN-Tags, fehlendes escapeHtml, Positions-Keys, fehlende Schema-Version) und als Erstes beheben.

## Anti-Patterns (alle in den Apps real aufgetreten)

- CDN-`<script>`-Tags im Deliverable (Stundentracker) – bricht offline.
- `index.html` direkt editieren, obwohl sie gebaut wird – beim nächsten Build weg.
- Montage-Logik doppelt (Build und Coverage-Remap mit je eigener Strip-Logik, orggraph) – Zeilennummern driften; eine `assemble.js` für alle.
- Doppelte Top-Level-Namen über Sections – ohne Parse-Check im Build nur als leere App sichtbar.
- Positions-basierte Persistenz-Keys (nem-wochenplan) – Umsortieren zerstört Status.
- JSON-Schema liegt bei, wird aber zur Laufzeit nie geprüft (nem-wochenplan) – mindestens Pflichtfelder validieren, Rest dem Schema-File überlassen.
- Inkonsistente Versionsfelder über Datenfiles (`version` vs. `planVersion`+`schemaVersion`) – ein Feldschema am Tag 1 festlegen.
- Doku-Zähler («19 Sektionen») driften vom Code weg – Zahlen in Doku vermeiden oder generieren.
- Ein Deploy, den der Browser aus dem Cache nicht sieht – `index.html` mit `Cache-Control: no-cache` ausliefern und nach dem Deploy die servierte `APP_VERSION` prüfen.
