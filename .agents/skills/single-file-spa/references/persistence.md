# Persistenz-Leiter — von localStorage bis Mandanten-Stores

Vier erprobte Schichten; die Stufe der App (S/M/L) bestimmt, welche gebraucht werden. Grundregel überall: **ein** serialisiertes `state`-Objekt, `saveState()` nach jeder Mutation, Laden als Merge über Defaults (`state = { ...defaults, ...JSON.parse(raw) }` in try/catch) — so tolerieren alte Stände neue Felder. Von Anfang an `state.schemaVersion` mitschreiben und beim Laden prüfen; ohne dieses Feld ist später keine sichere Migration möglich (Lücke in nem-wochenplan UND Stundentracker).

## Stufe S — localStorage, ein versionierter Key (nem-wochenplan)

- Genau ein Key: `STORAGE_KEY = "<app>-v1"` — der `-v1`-Suffix ist ein manueller Storage-Schema-Marker (bei inkompatiblem Umbau `-v2`, Migrationscode liest den alten Key einmalig).
- Gesamter State als ein JSON-Blob; kein Feld-Splitting.
- UI-State (Filter, expandierte Panels) darf im selben Blob leben oder als separater Key (`<app>_filter`).

## Stufe M — Szenario-Namespacing + Tab-Isolation + Datei-Verknüpfung (Stundentracker)

Drei Storage-APIs mit je EINER Aufgabe:

- **localStorage** für Nutzdaten, ein Key pro Szenario: `dataKey()` = `<app>` (Basis) bzw. `<app>:<dateiname>` pro geladenem Szenario. Das ist das Mandanten-Analogon auf Datei-Ebene.
- **sessionStorage** für das aktive Szenario des Tabs (`<app>_active`) — zwei parallel offene Tabs arbeiten so an verschiedenen Szenarien, ohne sich zu überschreiben.
- **IndexedDB** (DB `<app>`, ein Store) NICHT für Daten, sondern für **FileSystemFileHandle-Objekte** unter `fh:<dateiname>` — Handles überleben Reloads nur in IDB, nie in localStorage.

**File-System-Access-Auto-Save mit drei Fallback-Stufen** (Chromium: FSA auch unter `file://`; Firefox: kein FSA):

1. `file` — `showOpenFilePicker`/`showSaveFilePicker`, Handle in IDB persistieren; Auto-Save schreibt debounced direkt in die verknüpfte JSON. Beim App-Start `tryReconnectFile()`: Handle aus IDB holen, `queryPermission`/`requestPermission` prüfen, Datei neu einlesen.
2. `download` — Fallback ohne FSA: debounced (~1.5 s) automatischer `<a download>`-Export.
3. `off` — Auto-Save aus.

Den aktiven Modus im UI farbcodiert anzeigen (`linked`/`fallback`) — der User muss sehen, ob seine Datei wirklich geschrieben wird.

## Stufe L — IndexedDB, ein Object-Store pro Mandant (orggraph)

- **Der Store IST der Namespace:** pro Mandant/Profil ein Object-Store `p:<id>`, logische Keys (`env`, `data`, `uiState`, …) roh darin. Vorteil gegenüber Präfix-Keys in einem Store: DevTools zeigen Mandanten als getrennte Knoten, Löschen = Store droppen (`idbClear()` droppt Stores statt nur zu leeren).
- **`__meta__`-Store** mit einem Record `__profiles__` = `{active, list:[{id,name,createdAt,source}]}` für die Profilverwaltung (CRUD + aktiver Mandant).
- **Stores on-demand anlegen:** Object-Stores sind nur im `versionchange`-Event erzeugbar → `ensureStores()` schliesst die Connection und öffnet mit `version+1` neu; `dropStores()` analog. `onversionchange`-Handler schliesst die eigene Connection, wenn ein anderer Tab upgraded — sonst blockiert der Upgrade ewig.
- **Migration idempotent und gated:** Einmal-Umzug von Alt-Layouts (z.B. Single-Store mit Präfix-Keys) hinter einem `_migrated`-Flag; Alt-Store nach erfolgreichem Umzug droppen. Re-Runs müssen no-ops sein.
- **`navigator.storage.persist()`** einmalig anfragen — schützt die IDB vor Browser-Eviction bei Speicherdruck.
- Grosse Blobs chunken (`data::part:N`), damit einzelne Records handhabbar bleiben.
- Test-Hooks vorsehen (`_resetProfilesCache()`), damit Vitest mit `fake-indexeddb` saubere Zustände erzeugen kann.

## Key-Design (alle Stufen)

- Persistenz-Keys aus **stabilen IDs** der Domänen-Objekte bauen, nie aus Array-Positionen — `d{day}-s{slotId}-i{idx}` (nem-wochenplan) verliert beim Umsortieren des Plans allen gespeicherten Status.
- UI-State (aktive Ansicht, Scroll, expandierte Knoten) gehört persistiert (orggraph: `og2UiState`, beim Boot vor dem ersten Render restauriert) — eine Offline-App ohne Session-Restore fühlt sich kaputt an.
