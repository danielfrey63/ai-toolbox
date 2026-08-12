# Session Cleanup

Verschiebt «leere» Claude-Code-Sessions und redundante Duplikat-Kopien täglich in einen Papierkorb und löscht Papierkorb-Einträge nach Ablauf der Aufbewahrungsfrist endgültig.

## Duplikat-Bereinigung (Phase 1)

Nach einem Projektumzug (z.B. via transfer-cc-sessions) liegt dieselbe Session-UUID in mehreren Projektordnern. Kopien, die byte-identisch mit der behaltenen Kopie sind oder ein striktes Präfix davon, tragen keine Information und wandern in den Papierkorb. Behalten wird die Kopie im «lebendigen» Ordner: Der gemungte Ordnername wird gegen das reale Dateisystem zurückdecodiert (existierende Verzeichnisse ablaufen, Komponenten matchen) — nur so bleibt die Session im `/resume`-Picker des aktuellen Pfads sichtbar. Weder die innere `cwd` (zeigt bei mehrfach migrierten Sessions auf einen Ur-Pfad) noch die mtime (wird von Picker/Sync getoucht) taugen als Signal. Divergierte Kopien werden nie angefasst, nur im Log gemeldet — präzis benannt mit Session-Titel (erste echte User-Message, wie im Picker), Grösse, letzter Aktivität und Fork-Zeitpunkt (letzter gemeinsamer Timestamp beider Kopien), z.B. `kept diverged copy <ordner>\<uuid>.jsonl ("Titel…", 7.7MB, last activity 2026-08-06, forked from <keeper-ordner> copy after 2026-08-06 22:49 - review manually)`. Verglichen wird gegen alle behaltenen Kopien, nicht nur den Keeper — zwei identische Alt-Kopien, die beide vom Keeper abweichen, werden so trotzdem dedupliziert.

## Gleichnamige Sessions (Phase 1b)

`/rename`-Titel liegen als `custom-title`-Einträge im Transkript und überleben Forks und Bridge-Fortsetzungen — so können inhaltlich völlig verschiedene Sessions denselben Picker-Namen tragen. Das ist nicht zusammenführbar; der Lauf meldet solche Kollisionen pro Projektordner mit UUID-Kurzform, Grösse und letzter Aktivität (`same title "…" in <ordner>: … - rename or trash manually`), damit man sie gezielt umbenennen oder wegwerfen kann.

## Was als «leer» gilt (Phase 2)

Eine Top-Level-Session `~\.claude\projects\<projekt>\<uuid>.jsonl` gilt als leer, wenn Transkript plus Sidecar-Verzeichnis (`<uuid>\` mit Subagent-Transkripten) zusammen kleiner als 250 KB sind und die letzte Aktivität mehr als 3 Tage zurückliegt. Massgeblich ist der jüngste innere `"timestamp"` im Transkript, nicht die mtime — Picker, Cloud-Bridge und Sync-Tools touchen Dateien ohne Inhaltsänderung und würden alte Sessions sonst dauerhaft re-protecten. Der Alters-Guard verhindert, dass frisch gestartete oder gerade offene Sessions angefasst werden; zusätzlich werden gesperrte (offene) Dateien übersprungen. `memory\`-Verzeichnisse und alle anderen Projekt-Inhalte werden nie berührt.

## Papierkorb statt Hard-Delete

Verschobene Sessions landen unter `~\.claude\projects-trash\<yyyy-MM-dd>\<projekt>\` (Datum = Tag der Verschiebung). Batches, die älter als 30 Tage sind, werden beim nächsten Lauf endgültig gelöscht. Zum Wiederherstellen einfach die Datei (und ggf. das Sidecar-Verzeichnis) zurück in den Projekt-Ordner verschieben. Jeder Lauf protokolliert nach `~\.claude\projects-trash\cleanup.log`.

## Installation

Über die Toolbox (empfohlen, plattformübergreifend):

```
toolbox install --what session-cleanup
toolbox remove --what session-cleanup
```

Oder direkt: unter Windows `.\install.ps1` (Scheduled Task «AI-Toolbox Session Cleanup», `-Uninstall` entfernt, `-Status` liefert Exit-Code 0/1), unter Linux `./install.sh` (systemd User-Timer `session-cleanup.timer`, `--uninstall`/`--status` analog). Beide Installer sind idempotent und ersetzen die bestehende Definition.

## Manuell ausführen

```powershell
.\cleanup-sessions.ps1 -DryRun   # zeigt, was verschoben/gelöscht würde
.\cleanup-sessions.ps1           # führt aus
```

Parameter: `-MaxSizeBytes` (Default 250 KB), `-MinAgeDays` (Default 3), `-RetentionDays` (Default 30).

## Abgrenzung

Claude Code löscht Sessions selbst nach `cleanupPeriodDays` (in `~\.claude\settings.json` auf 365 gesetzt). Dieses Tool ergänzt das um die grössen-basierte Bereinigung kleiner Wegwerf-Sessions, damit der `/resume`-Picker übersichtlich bleibt.
