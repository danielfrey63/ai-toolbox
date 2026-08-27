# Wakeup Guard

Globaler `PreToolUse`-Hook auf `ScheduleWakeup`, der Wakeups abweist, die aus Hook-Anweisungen stammen, welche nicht mehr in Kraft sind. Alle anderen `ScheduleWakeup`-Aufrufe (`/loop`, selbstgewählte Pausen, `stop:true`) passieren unverändert.

## Das Problem

Ein Hook, der dem Modell «rufe ScheduleWakeup auf» aufträgt, überlebt seine eigene Deinstallation. Die Anweisung steht im Transkript, wandert bei jeder Kontext-Kompaktierung ins Summary, und das Modell befolgt sie aus dem Kontext heraus weiter — nach jedem echten Turn ein neuer Wakeup, solange die Session offen ist. So hielt sich der am 18.08.2026 überall deinstallierte **Session-Keepwarm**-Loop bis zum 27.08. selbst am Leben (beobachtet in einer seit 15.08. offenen Session; 31 weitere Sessions tragen die Anweisung im Kontext und können sie bei jedem `/resume` reaktivieren). Eine Doku-Regel allein hilft nicht, weil genau die im Summary verloren geht. Die Gültigkeit muss deshalb deterministisch geprüft werden, auf Harness-Ebene, in jeder Session — auch in alten.

## Der Vertrag für Hook-Autoren

Jede Hook-Anweisung, die einen `ScheduleWakeup`-Aufruf verlangt, trägt im Prompt das Tag

```
[hook:<katalog-name> valid-until:<YYYY-MM-DD>]
```

`<katalog-name>` ist der Name des Tools im Toolbox-Katalog; sein Install-Marker muss in `~/.claude/settings.json` stehen, solange der Hook aktiv ist. `valid-until` begrenzt die Lebensdauer der Anweisung auch dann, wenn die Deinstallation vergessen geht (z.B. auf einer anderen Maschine). Das Datum ist optional, der Name nicht.

## Mechanik

`guard.sh` liest das Hook-JSON von stdin und blockiert mit Exit-Code 2 (die stderr-Meldung geht ans Modell und sagt ihm, einen allfällig noch geplanten Wakeup mit `ScheduleWakeup {"stop": true}` zu beenden), wenn

1. der Input den Keepwarm-Marker trägt (`keepwarm`, Altlast ohne Tag),
2. das Tag einen Hook nennt, der in `~/.claude/settings.json` nicht registriert ist,
3. das `valid-until`-Datum in der Vergangenheit liegt.

Wakeups ohne Tag passieren. Braucht nur `grep`, `sed` und `date`; läuft unter Git Bash (Windows) und bash (Linux).

## Installation

Über die Toolbox (empfohlen, plattformübergreifend):

```
toolbox install --what wakeup-guard
toolbox remove --what wakeup-guard
```

Oder direkt: unter Windows `.\install.ps1` (`-Uninstall` entfernt, `-Status` liefert Exit-Code 0/1), unter Linux `./install.sh` (`--uninstall`/`--status` analog, braucht `jq`). Beide Installer sind idempotent, ersetzen die bestehende Definition und räumen Reste der Vorgänger (`session-keepwarm`-Stop-Hook, `keepwarm-guard`) mit ab. Der Hook greift für neu gestartete Sessions; laufende Sessions laden ihn erst nach Neustart.

## Manuell prüfen

```
echo '{"tool_input":{"prompt":"[keepwarm-tick] Stand?"}}' | bash guard.sh                          # Meldung, Exit 2
echo '{"tool_input":{"prompt":"[hook:ghost valid-until:2099-01-01] tick"}}' | bash guard.sh        # Meldung, Exit 2 (nicht installiert)
echo '{"tool_input":{"prompt":"[hook:wakeup-guard valid-until:2000-01-01] tick"}}' | bash guard.sh # Meldung, Exit 2 (abgelaufen)
echo '{"tool_input":{"prompt":"[hook:wakeup-guard valid-until:2099-01-01] tick"}}' | bash guard.sh # still, Exit 0
echo '{"tool_input":{"stop":true}}' | bash guard.sh                                                 # still, Exit 0
```

## Abgrenzung

Der Guard verhindert nur neue Wakeups. Bereits geplante Wakeups einer laufenden Session verfallen mit dem Prozessende; in einer offenen Session mit aktivem Loop einmal `ScheduleWakeup {"stop": true}` auslösen (z.B. Frage an Claude: «Laufen die Keepwarm-Ticks noch? Stoppe sie.»).
