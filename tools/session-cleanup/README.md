# Session Cleanup

Verschiebt «leere» Claude-Code-Sessions täglich in einen Papierkorb und löscht Papierkorb-Einträge nach Ablauf der Aufbewahrungsfrist endgültig.

## Was als «leer» gilt

Eine Top-Level-Session `~\.claude\projects\<projekt>\<uuid>.jsonl` gilt als leer, wenn Transkript plus Sidecar-Verzeichnis (`<uuid>\` mit Subagent-Transkripten) zusammen kleiner als 250 KB sind und die letzte Aktivität mehr als 3 Tage zurückliegt. Der Alters-Guard verhindert, dass frisch gestartete oder gerade offene Sessions angefasst werden; zusätzlich werden gesperrte (offene) Dateien übersprungen. `memory\`-Verzeichnisse und alle anderen Projekt-Inhalte werden nie berührt.

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
