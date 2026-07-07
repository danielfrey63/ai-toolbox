# Import / Export — Roundtrip, Klassifikation, ZIP, Merge, Szenarien

## Grundmuster Roundtrip (alle Stufen)

- **Export:** kompletten `state` (oder Mandanten-Inhalt) als `Blob` → `URL.createObjectURL` → programmatischer `<a download>` → `revokeObjectURL`. Dateiname mit Datum stempeln (`<app>-status-YYYY-MM-DD.json`); berechnete Felder dürfen dokumentierend mit exportiert werden, werden beim Import aber ignoriert (Stundentracker: `*_soll`-Arrays).
- **Import:** `<input type="file" accept="application/json">` + `FileReader.readAsText` + `JSON.parse` in try/catch; Parse-Fehler → verständliche Meldung, nie stiller Abbruch. Zusätzlich Drag&Drop (unten). `escapeHtml()` auf alle importierten Strings — Import ist die Trust-Boundary.
- **Datei-Discriminator statt Format-Raterei:** die Dateiart am Inhalt erkennen, nicht am Namen — nem-wochenplan: `data.slots` ist Array → Plan; `data.plan.slots` existiert → Status-Export; orggraph generalisiert das zu `classifyFile()` mit `looksLike*`-Prüfungen pro Art (env/data/snapshot/registry/legacy/unknown).
- **Legacy-Formate erkennen und ABLEHNEN** mit Migrations-Hinweis, statt sie still in neue Datenbestände zu mischen (orggraph lehnt v1-Dateien mit Verweis aufs Migrationsskript ab).
- **Import-Report zurückgeben:** `{stored, unknown, missing, ignored, rejected}` — der User sieht, was mit jedem File passiert ist.

## Drag & Drop + ZIP (Stufe L, orggraph)

- Window-weites `installGlobalDrop`; Escape/Backdrop schliesst den Drop-Dialog nur, wenn bereits Daten geladen sind.
- Ordner-Drops via `getAsFileSystemHandle()` / `webkitGetAsEntry()`; unter `file://` fehlen die Ordner-APIs teils → **nie still enden**, sondern Hinweis «als ZIP packen und droppen».
- **ZIP-Reader ohne Library:** natives `DecompressionStream('deflate-raw')`, EOCD/Central-Directory selbst parsen, rekursiv für verschachtelte ZIPs. Kein JSZip — hält das Deliverable dependency-frei.
- **Producer/Consumer teilen den Reader:** das Packaging-Skript (`scripts/package-tenants.mjs`, eigener minimaler ZIP-Writer mit CRC32 + `deflateRawSync`) liest jedes erzeugte ZIP mit dem App-eigenen `readZipEntries` + `classifyFile` zurück und vergleicht die erkannten Arten — Self-Check gegen Format-Drift.
- **Ein-Drop-Bootstrap:** ein ZIP mit Registry + Env + Snapshots + Pseudo bootet einen kompletten Mandanten in einem Drop.

## Autoritative Konfiguration

Wenn eine Config-Datei (env.json) Referenzen auf Daten-Dateien enthält: die Config **gewinnt** — nur von ihr referenzierte Snapshots werden gespeichert, unreferenzierte ignoriert statt bestehende Daten zu klobbern.

## Schema-Validierung

- JSON-Schema-Dateien (`*.schema.json`) neben die Datenformate legen; Datenfiles referenzieren sie per `$schema` (Editor-Tooling).
- In Tests mit `ajv` streng validieren; **zur Laufzeit mindestens die Pflichtfelder prüfen** — ein beiliegendes, nie angewandtes Schema verhindert keine stille Fehlkonfiguration (Lücke in nem-wochenplan).
- Formatspezifikationen als Markdown: eine **normative** Spec fürs aktuelle Format, Legacy-Specs explizit als «keine normative Kraft» markiert.
- Ein Versionsfeld-Schema am Tag 1 festlegen (z.B. `schemaVersion` + `contentVersion`) und in ALLEN Datenfiles gleich benennen — nem-wochenplan trägt `version`, `planVersion`+`schemaVersion` und `metadata.version` quer durch die Files.

## Merge & Dedup (temporale Daten, orggraph og2-Engine)

Für Apps, die Datenstände aus mehreren Quellen/Zeitpunkten zusammenführen:

- **Snapshot-Identität über Content-Hash** (fnv1a64 über kanonisches JSON): gleicher Import → no-op; gleiche Identität mit anderem Inhalt → Konflikt, wird **abgelehnt** statt gemischt; neuerer Stand → Chronologie-Merge.
- **Property-Timelines** statt letzter-gewinnt: Werte als `{from, to, value, source}`-Intervalle; Merge mit Quellen-Präzedenz zuerst, dann deterministischem Tie-Breaker; unauflösbare Fälle als offene `conflicts` persistieren und im UI zeigen, nicht verschlucken.
- **Kanonische Identitäts-Keys** als kanonisches JSON über die identitätsstiftenden Felder (`[type, source, target, ...identityProps]`) — nie zusammengesetzte Strings mit Trennzeichen-Kollisionsrisiko.

## Szenario-Dateien (Stufe M, Stundentracker)

Ein Szenario-JSON transportiert nicht nur Daten, sondern **überschreibt das Berechnungsmodell**: ein `basis`-Block (Pensen, Bestellwerte, Feiertage) wird beim Import in die Modell-Konstanten geschrieben (die deshalb `let` statt `const` sind), danach `recomputeBudgets()`. Konvention: sprechende Dateinamen für What-ifs (`www-65` = What-if 65%), ein `scenario`-Beschreibungsfeld im JSON, und pro Szenario ein eigener Persistenz-Key (siehe persistence.md). Alte Feld-Schreibweisen beim Import tolerieren (camelCase UND snake_case lesen), solange Migrationen fehlen.
