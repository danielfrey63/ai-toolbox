# Session Keepwarm

Hält den Prompt-Cache grosser interaktiver Claude-Code-Sessions während Idle-Phasen warm, damit die 1h-Cache-TTL nicht abläuft und der nächste echte Prompt Cache-Read-Preise (10%) statt voller Re-Write-Preise (125%) zahlt.

## Warum ein Stop-Hook und kein externer Ping

Empirisch verifiziert (2026-08-08): Ein externer Ping via `claude -p --resume <id> --fork-session` erzeugt einen kompletten Cache-Miss (`cache_read_input_tokens: 0`), weil der Print-Mode-Systemprompt vom interaktiven abweicht und der Prefix damit ab Token 0 divergiert. Ein solcher Ping würde pro Aufruf den vollen Kontextpreis kosten, ohne die interaktive Session zu wärmen. Die Warmhalte-Anfrage muss deshalb aus der Session selbst kommen — nur dort ist der Prompt-Prefix identisch.

## Mechanik

Ein globaler Stop-Hook (`~/.claude/settings.json`) läuft nach jedem Turn-Ende:

1. Er greift nur bei Sessions, deren Transkript grösser als `minTranscriptKB` (Default 200 KB, ca. 60k+ Tokens) ist — bei kleinen Sessions lohnt sich Warmhalten nicht.
2. Höchstens einmal pro `delaySeconds`-Fenster blockiert er den Stop und weist das Modell an, per `ScheduleWakeup` in 55 Minuten (Default) einen Tick zu planen. Während der Arbeit entsteht dadurch praktisch kein Overhead (ein Mini-Turn pro 55 Minuten).
3. Der Tick feuert kurz vor Ablauf der 1h-TTL als normale Session-Anfrage: identischer Prefix, echter Cache-Refresh. Der erste Tick fragt einen Ein-Satz-Stand ab («Stand?»), alle weiteren sind ein minimales Ping («antworte nur mit Pong»), damit praktisch keine Output-Kosten anfallen.
4. Liegt der Kontext beim Planen über `compactAtPercent` des Fensters (`contextWindowTokens`), wird statt des Ticks `/compact` als Wakeup geplant — die Idee: Das Compact liefe noch auf dem warmen Cache (~10% Read-Kosten statt 125% Cold-Rewrite später). **Achtung, aktuell deaktiviert (`compactAtPercent: 0`)**: Live-Test 2026-08-09 zeigt, dass ein injizierter `/compact`-Wakeup als literaler Text ankommt statt ausgeführt zu werden — Wakeups können nur Skills auslösen, keine Built-in-Commands. Als Ersatz für das Kosten-Ziel dient das harness-native Autocompact (`--autocompact <tokens>`), das beim Überschreiten der Schwelle ohnehin auf warmem Cache läuft. Der Code bleibt drin, falls Wakeup-Prompts künftig Built-ins ausführen können; ein Guard verhindert wiederholte Compact-Versuche innerhalb von 2×`delaySeconds`.
5. Tick-Turns re-schedulen sich selbst über denselben Hook. Nach `maxTicks` (Default 3) aufeinanderfolgenden Ticks ohne echte User-Aktivität endet die Kette — eine verlassene Session wird also maximal ca. 3 Stunden warmgehalten.
6. Echte User-Aktivität setzt den Tick-Zähler zurück und zieht den Timer nach: Ist der pending Wakeup älter als `rescheduleAfterSeconds` (Default 15 min), wird er beim nächsten Turn-Ende auf +55 min neu gesetzt (ein neuer `ScheduleWakeup`-Aufruf ersetzt den pending Wakeup). Die Schwelle begrenzt den Overhead auf maximal einen Mini-Turn pro 15 Minuten Arbeit.

Kosten-Nutzen: Ein Tick kostet ca. 10% des Kontextpreises (Cache-Read), der vermiedene Cold-Restart 125%. Bei einer 200k-Token-Session: Tick ca. $0.30, ersparter Re-Write ca. $3.40.

## Installation

Über die Toolbox (empfohlen, plattformübergreifend):

```
toolbox install --what session-keepwarm
toolbox remove --what session-keepwarm
```

Oder direkt: unter Windows `.\install.ps1` (`-Uninstall`/`-Status`), unter Linux `./install.sh` (`--uninstall`/`--status`; braucht `jq`). Beide registrieren den plattformeigenen Stop-Hook (`stop-hook.ps1` bzw. `stop-hook.sh`) in `~/.claude/settings.json`.

Gilt für neu gestartete Sessions. Der Hook-State liegt unter `%LOCALAPPDATA%\ai-toolbox\session-keepwarm\` (Windows) bzw. `~/.local/state/ai-toolbox/session-keepwarm/` (Linux).

## Konfiguration

`config.json` neben dem Hook-Skript:

- `enabled` — globaler Schalter.
- `minTranscriptKB` (200) — Mindestgrösse des Transkripts, darunter kein Keepwarm.
- `delaySeconds` (3300) — Tick-Abstand; muss unter der Cache-TTL (1h) liegen.
- `maxTicks` (3) — maximale aufeinanderfolgende Ticks ohne echte User-Aktivität.
- `rescheduleAfterSeconds` (900) — ab diesem Alter des pending Wakeups zieht echte Aktivität den Timer wieder auf volle 55 min nach.
- `compactAtPercent` (40) / `contextWindowTokens` (1'000'000 im Checked-in-Config, Code-Default 200'000) — über dieser Kontext-Auslastung wird `/compact` statt eines Ticks geplant; `0` schaltet das Compact-Verhalten ab.
- `quietFrom` / `quietTo` (leer = aus) — Ruhefenster im Format `HH:mm`, in dem keine neuen Ticks geplant werden, z.B. `23:30`/`06:30`.

## Testen

`.\test-hook.ps1` prüft die Hook-Pfade (Skip bei kleinen Sessions, Block, Pending-Fenster, Tick-Kette mit Abbruch) mit simulierten Transkripten, ohne API-Kosten.

## Grenzen

- Der Hook instruiert das Modell; die Ausführung von `ScheduleWakeup` ist damit sehr zuverlässig, aber nicht hart garantiert (im Test befolgte selbst Haiku die Anweisung exakt).
- Wird das Terminal geschlossen, verfällt der geplante Wakeup — geschlossene Sessions werden nicht warmgehalten (das kann kein lokaler Mechanismus leisten).
- Print-Mode-Läufe (`claude -p`) bleiben wegen der Grössenschwelle normalerweise unberührt.
