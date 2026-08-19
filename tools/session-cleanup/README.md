# Session Cleanup

Verschiebt «leere» Claude-Code-Sessions, explizit zum Löschen markierte Sessions und redundante Duplikat-Kopien dreimal täglich (05:30, 11:30, 17:30) in einen Papierkorb und löscht Papierkorb-Einträge nach Ablauf der Aufbewahrungsfrist endgültig.

## Zum Löschen markierte Sessions (Phase 0)

Ein `/rename`-Titel schützt eine Session sonst dauerhaft, deshalb braucht die umgekehrte Absicht einen eigenen Marker: Wer eine Session auf `DELETE` umbenennt, gibt sie dem nächsten Lauf frei — unabhängig von Grösse und Alter. Verglichen wird der getrimmte Titel als Ganzes und ohne Rücksicht auf Gross-/Kleinschreibung (`DELETE`, `delete`, `  Delete  `); ein Titel, der das Wort nur enthält (`DELETE-Bug`), ist ein echter Name und bleibt. Die Phase läuft vor der Duplikat-Bereinigung, damit jede Kopie einer markierten Session mitgeht und keine davon als Namens-Kollision gemeldet wird. Markierte Sessions wandern wie alles andere in den Papierkorb und bleiben bis zum Ablauf der Aufbewahrungsfrist wiederherstellbar. Der Marker ist über `-DeleteMarker` bzw. `--delete-marker` konfigurierbar. Ist die Session gerade offen, ist ihre Datei gesperrt und sie fliegt beim nächsten Lauf nach dem Schliessen.

## Duplikat-Bereinigung (Phase 1)

Nach einem Projektumzug (z.B. via transfer-cc-sessions) liegt dieselbe Session-UUID in mehreren Projektordnern. Kopien, die byte-identisch mit der behaltenen Kopie sind oder ein striktes Präfix davon, tragen keine Information und wandern in den Papierkorb. Behalten wird die Kopie im «lebendigen» Ordner: Der gemungte Ordnername wird gegen das reale Dateisystem zurückdecodiert (existierende Verzeichnisse ablaufen, Komponenten matchen) — nur so bleibt die Session im `/resume`-Picker des aktuellen Pfads sichtbar. Weder die innere `cwd` (zeigt bei mehrfach migrierten Sessions auf einen Ur-Pfad) noch die mtime (wird von Picker/Sync getoucht) taugen als Signal. Verglichen wird gegen alle behaltenen Kopien, nicht nur den Keeper — zwei identische Alt-Kopien, die beide vom Keeper abweichen, werden so trotzdem dedupliziert.

Kopien, die nicht enthalten sind, haben sich an einem Punkt getrennt — dahinter stecken zwei verschiedene Situationen, die das Skript anhand der eigenen Einträge nach dem Trennpunkt unterscheidet:

- **Umzugs-Rest**: Die alte Kopie endet, bevor der eigene Zweig der neuen Kopie beginnt — nach dem Umzug wurde hier nichts mehr geschrieben. Solche Reste wandern automatisch in den Papierkorb, solange sie höchstens `-MaxHandoverMessages` (Default 10) eigene Nachrichten über den Trennpunkt hinaus tragen. Log: `leftover of "<Name>" after the move to <ziel> - 3 own message(s) up to 2026-08-19 16:56`.
- **Echte Parallelarbeit**: In beiden Kopien wurde nach der Trennung eigenständig weitergearbeitet — beide Seiten tragen einmaligen Verlauf, keine wird angefasst. Die Meldung nennt den Session-Namen (`/rename`-Titel, sonst erste User-Message), den Trennzeitpunkt und pro Kopie die Zahl eigener Nachrichten samt letzter Aktivität, damit entscheidbar ist, welche Kopie behalten wird.

## Gleich- und ähnlich benannte Sessions (Phase 1b)

`/rename`-Titel liegen als `custom-title`-Einträge im Transkript und überleben Forks und Bridge-Fortsetzungen — so können verschiedene Session-Dateien denselben Picker-Namen tragen. Für jedes Paar, dessen Titel gleich sind oder literal ineinander enthalten (Substring), wird ein Merge versucht: Nach Neutralisierung der eigenen sessionId (jede Zeile enthält sie, roh können zwei Dateien nie byte-gleich sein) beweist eine exakte Präfix-Überlappung, dass die kleinere Datei nichts über die grössere hinaus enthält — sie wandert in den Papierkorb. Paare ohne exakte Überlappung sind echt verschiedene Verläufe; die werden nur gemeldet (`same title "…" in <ordner>: … - no exact overlap, rename or trash manually`).

## Was als «leer» gilt (Phase 2)

Eine Top-Level-Session `~\.claude\projects\<projekt>\<uuid>.jsonl` gilt als leer, wenn Transkript plus Sidecar-Verzeichnis (`<uuid>\` mit Subagent-Transkripten) zusammen kleiner als 250 KB sind. Es gibt keinen Alters-Guard (`-MinAgeHours 0`): Was behalten werden soll, trägt einen `/rename`-Titel (`custom-title`-Eintrag) und ist damit unabhängig von Alter und Grösse geschützt — ein Name markiert Behalten-Absicht, ausser er lautet `DELETE` (Phase 0). Unbenannte kleine Sessions fliegen beim nächsten Lauf. Massgeblich für das Alter ist der jüngste innere `"timestamp"` im Transkript, nicht die mtime — Picker, Cloud-Bridge und Sync-Tools touchen Dateien ohne Inhaltsänderung und würden alte Sessions sonst dauerhaft re-protecten. Gesperrte (offene) Dateien werden übersprungen. `memory\`-Verzeichnisse und alle anderen Projekt-Inhalte werden nie berührt.

## Papierkorb statt Hard-Delete

Verschobene Sessions landen unter `~\.claude\projects-trash\<yyyy-MM-dd>\<projekt>\` (Datum = Tag der Verschiebung). Batches, die älter als 30 Tage sind, werden beim nächsten Lauf endgültig gelöscht. Zum Wiederherstellen einfach die Datei (und ggf. das Sidecar-Verzeichnis) zurück in den Projekt-Ordner verschieben. Jeder Lauf protokolliert nach `~\.claude\projects-trash\cleanup.log`. Meldungen, die eine menschliche Entscheidung brauchen (divergierte Kopien, Namens-Kollisionen), landen zusätzlich in `~\.claude\projects-trash\findings.txt` und erscheinen unter Windows als system-modales Popup (topmost, bleibt bis zum Wegklicken; detached gestartet, blockiert den Lauf nicht), unter Linux via `notify-send`, falls vorhanden.

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

Parameter: `-MaxSizeBytes` (Default 250 KB), `-MinAgeHours` (Default 0 = kein Alters-Guard), `-RetentionDays` (Default 30), `-DeleteMarker` (Default `DELETE`), `-MaxHandoverMessages` (Default 10). Die Bash-Variante kennt dieselben Optionen als `--max-size-bytes`, `--min-age-hours`, `--retention-days`, `--delete-marker`, `--max-handover-messages`, `--dry-run`.

## Abgrenzung

Claude Code löscht Sessions selbst nach `cleanupPeriodDays` (in `~\.claude\settings.json` auf 365 gesetzt). Dieses Tool ergänzt das um die grössen-basierte Bereinigung kleiner Wegwerf-Sessions, damit der `/resume`-Picker übersichtlich bleibt.
