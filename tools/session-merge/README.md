# Session Merge

Fügt zwei oder mehr Claude-Code-Sessions desselben Projekts zu einer neuen Session zusammen. Anwendungsfall: Ein Thema ist über mehrere `/rename`-Sessions verstreut (z.B. «NextGenPF@WORK» und «NextGenPortfolio») und soll unter einem Namen (z.B. «LPM») als eine durchgehende Konversation weitergeführt werden.

## Was das Skript tut

Eine Session liegt unter `~/.claude/projects/<projekt-slug>/` als `<session-id>.jsonl` plus optionalem Sidecar-Ordner `<session-id>/` (custom-title.json, tool-results, Subagents). Die Nachrichten bilden über `uuid`/`parentUuid` einen Baum; Claude Code lädt beim `/resume` die Kette vom neuesten Blatt zurück zur Wurzel. Damit nach dem Merge alles sichtbar bleibt, hängt das Skript die Wurzel jeder späteren Quelle an das Blatt der vorherigen. Konkret:

1. Quellen chronologisch nach dem ersten Nachrichten-Timestamp ordnen (`--keep-order` übernimmt die angegebene Reihenfolge).
2. `sessionId` jeder Zeile auf die neue Session-ID umschreiben; `uuid`/`parentUuid` bleiben unverändert (Kollisionen werden geprüft und brechen ab).
3. Sessiongebundene Zeilen verwerfen (`bridge-session`, `custom-title`, `agent-name`), einen einzigen Titel voranstellen, `cost-state` über alle Quellen summieren, nur den letzten `last-prompt` behalten.
4. Sidecar-Ordner der Quellen in den neuen Sidecar kopieren (tool-results usw.), `custom-title.json` mit dem neuen Titel schreiben.

Die Quellen werden weder verändert noch gelöscht. Das Aufräumen übernimmt bei Bedarf `session-cleanup` (Quellen per `/rename DELETE` markieren).

## Verwendung

```
python tools/session-merge/merge-sessions.py --project D--Meine-Ablage-Develop-sem --title LPM <session-id-1> <session-id-2> [...]
```

Optionen: `--dry-run` zeigt Reihenfolge, Blätter und Zeilenzahl ohne zu schreiben. `--new-id <uuid>` setzt die Ziel-ID fest. `--force` überspringt den Frische-Schutz (Quellen, die in den letzten zwei Minuten geschrieben wurden, gelten als noch offen).

## Desired-State

Existiert im Projekt bereits eine Session mit dem gewünschten Titel (`custom-title.json` im Sidecar), meldet das Skript deren ID und beendet sich mit Exit 0. Ein Re-Run erzeugt also keine zweite Kopie. Ein explizit gesetztes `--new-id` bricht ab, falls die Zieldatei schon existiert.

## Grenzen

- Quellen müssen genau eine Wurzelnachricht haben (`parentUuid: null`). Sessions mit mehreren Wurzeln (z.B. nach Kompaktierungs-Sonderfällen) werden abgelehnt statt still verkettet.
- Offene Quellen dürfen nicht gemergt werden: Der Writer hängt laufend an, die Kopie wäre unvollständig.
- `~/.claude/history.jsonl` (Prompt-Historie für die Pfeiltasten) wird nicht angepasst; die Einträge zeigen weiterhin auf die alten Session-IDs.
