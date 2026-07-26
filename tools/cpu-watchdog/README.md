# cpu-watchdog

Zweistufiger CPU-Temperatur-Watchdog für headless Linux-Maschinen (entstanden auf dem ThinkPad P50, nachdem lokale Embedding-Läufe den Laptop stundenlang überhitzt hatten). Hardware-Schutz bleibt Sache von thermald — dieser Watchdog macht Überhitzung sichtbar und wirft gezielt eigene Batch-Last ab.

## Funktionsweise

Ein systemd-User-Timer ruft das Skript minütlich auf; es liest die Package-Temperatur (`x86_pkg_temp`, Fallback: heisseste Zone).

1. **Stufe 1 (ab 85°C):** Eine Meldung über alle Kanäle — `wall` an alle Terminals/tmux-Panes, E-Mail (curl-smtps, Credentials in `~/.config/cpu-watchdog/smtp.env`), `notify-send` als Best-Effort. Die Meldung nennt den Momentan-Top-Prozess (2-Sekunden-Delta via `top -bn2`, keine Lifetime-Durchschnitte).
2. **Stufe 2 (nur wenn die Warnung wirkungslos blieb):** Steigt die Temperatur nach 180 s Grace weiter — oder erreicht sofort 92°C — stoppt der Watchdog pro Minute den obersten noch aktiven Eintrag aus `~/.config/cpu-watchdog/stop-list.conf` (Reihenfolge = Priorität; Formate `user-unit <name>` und `pkill <pattern>`). Interaktives gehört nicht auf die Liste.
3. **Entwarnung (unter 80°C):** Meldung, State-Reset. Chronik in `~/.cache/cpu-watchdog.log`.

## Installation

`./install.sh` — idempotent: Skript und Units werden auf den Repo-Stand gebracht, `stop-list.conf` und `smtp.env` nur beim Erstlauf gesät und danach nie überschrieben (dort stehen maschinenspezifische Prioritäten und Zugangsdaten; `smtp.env` chmod 600, gehört nicht ins Repo). Danach Kanaltest: `cpu-watchdog.sh test-notify`.

## Tuning

Schwellen per Env in der Service-Unit übersteuerbar: `WARN_C` (85), `CRIT_C` (92), `HYST_C` (5), `GRACE_S` (180). Zum Testen versteht das Skript `TEMP_OVERRIDE`, `CONF`, `STATE_DIR`, `LOG`. Achtung bei pkill-Tests: das Muster nie wörtlich in die eigene Shell-Kommandozeile schreiben, sonst trifft `pkill -f` die Test-Shell selbst.
