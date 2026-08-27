# Keepwarm Guard

Blockiert den Rest des früheren **Session-Keepwarm**-Loops auf Harness-Ebene: ein globaler `PreToolUse`-Hook auf `ScheduleWakeup`, der jeden Aufruf mit Keepwarm-Marker (`[keepwarm-tick]`, `Cache-Keepwarm-Tick`, `Session-Keepwarm`) abweist. Alle anderen `ScheduleWakeup`-Aufrufe (`/loop`, `stop:true`) passieren unverändert.

## Warum das nötig ist

Der Keepwarm-Stop-Hook wurde am 18.08.2026 überall deinstalliert. Der Loop hielt sich trotzdem selbst am Leben: Die Hook-Anweisung («Session-Keepwarm (explizite User-Konfiguration …): Rufe genau einmal ScheduleWakeup auf …») steht dutzendfach in alten Transkripten und wandert bei jeder Kontext-Kompaktierung in die Zusammenfassung. Das Modell hält sie für gültige User-Konfiguration und plant nach jedem echten Turn wieder einen Wakeup — stündlich, solange die Session offen ist. Beobachtet am 27.08.2026 in einer Session, die seit dem 15.08. lief; 31 weitere Sessions tragen den Loop im Kontext und können ihn bei jedem `/resume` wieder starten. Eine Doku-Anweisung allein reicht dagegen nicht, weil genau die im Summary verloren geht. Der Hook ist deterministisch (Skript vor LLM) und wirkt in jeder Session, auch in alten.

## Mechanik

`guard.sh` liest das Hook-JSON von stdin und beendet sich mit Exit-Code 2, wenn irgendwo `keepwarm` vorkommt. Exit 2 blockiert den Tool-Aufruf; die stderr-Meldung geht ans Modell und sagt ihm, den Loop mit `ScheduleWakeup {"stop": true}` zu beenden. Läuft unter Git Bash (Windows) und bash (Linux) ohne weitere Abhängigkeiten.

## Installation

Über die Toolbox (empfohlen, plattformübergreifend):

```
toolbox install --what keepwarm-guard
toolbox remove --what keepwarm-guard
```

Oder direkt: unter Windows `.\install.ps1` (`-Uninstall` entfernt, `-Status` liefert Exit-Code 0/1), unter Linux `./install.sh` (`--uninstall`/`--status` analog, braucht `jq`). Beide Installer sind idempotent, ersetzen die bestehende Definition und räumen einen allenfalls noch vorhandenen `session-keepwarm`-Stop-Hook mit ab. Der Hook greift für neu gestartete Sessions; laufende Sessions laden ihn erst nach Neustart.

## Manuell prüfen

```
echo '{"tool_name":"ScheduleWakeup","tool_input":{"prompt":"[keepwarm-tick] Stand?"}}' | bash guard.sh   # Meldung, Exit-Code 2 = blockiert
echo '{"tool_name":"ScheduleWakeup","tool_input":{"stop":true}}' | bash guard.sh                          # still, Exit-Code 0 = passiert
```

## Abgrenzung

Der Guard verhindert nur neue Ticks. Bereits geplante Wakeups einer laufenden Session verfallen mit dem Prozessende; in einer offenen Session mit aktivem Loop einmal `ScheduleWakeup {"stop": true}` auslösen (z.B. Frage an Claude: «Laufen die Keepwarm-Ticks noch? Stoppe sie.»).
