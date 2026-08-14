# cpu-watchdog

Dreistufiger CPU-Temperatur-Watchdog für headless Linux-Maschinen (entstanden auf dem ThinkPad P50, nachdem lokale Embedding-Läufe den Laptop stundenlang überhitzt hatten; nach dem Hardware-Not-Aus vom 10.08.2026 um eine globale Drossel-Stufe erweitert). Hardware-Schutz bleibt Sache von thermald — dieser Watchdog macht Überhitzung sichtbar, wirft eigene Batch-Last ab und deckelt notfalls die ganze CPU.

## Funktionsweise

Ein systemd-User-Timer ruft das Skript minütlich auf; es liest den **heissesten** aller Sensoren: sämtliche Thermal-Zones (inkl. `acpitz`, dem EC-/Board-Sensor, der den Kernel-Not-Aus auslöst) plus NVIDIA-GPU via `nvidia-smi`. Kein bevorzugter Einzelsensor mehr — beim Not-Aus vom 10.08.2026 kletterte `acpitz` auf 128°C, während das gedrosselte CPU-Package harmlose 78°C meldete und der Watchdog fälschlich Entwarnung gab.

1. **Stufe 1 (ab 85°C):** Eine Meldung über alle Kanäle — `wall` an alle Terminals/tmux-Panes, E-Mail (curl-smtps, Credentials in `~/.config/cpu-watchdog/smtp.env`), `notify-send` als Best-Effort. Die Meldung nennt den Momentan-Top-Prozess (2-Sekunden-Delta via `top -bn2`, keine Lifetime-Durchschnitte).
2. **Stufe 2 (nur wenn die Warnung wirkungslos blieb):** Steigt die Temperatur nach 180 s Grace weiter — oder erreicht sofort 92°C — stoppt der Watchdog pro Tick den obersten noch aktiven Eintrag aus `~/.config/cpu-watchdog/stop-list.conf` (Reihenfolge = Priorität; Formate `user-unit <name>` und `pkill <pattern>`). Interaktives gehört nicht auf die Liste.
3. **Stufe 3 (ab 95°C sofort, oder wenn die Stop-Liste erschöpft ist):** Globale CPU-Drossel auf 30% via Root-Helper `/usr/local/sbin/cpu-throttle` (`intel_pstate max_perf_pct`, Fallback cpufreq `scaling_max_freq`). Trifft jeden Verursacher, ohne ihn zu kennen — auch Prozesse, die auf keiner Stop-Liste stehen.
4. **Entwarnung (unter 80°C):** Drossel aufheben, Meldung, State-Reset. Chronik in `~/.cache/cpu-watchdog.log`.

Im heissen Zustand bleibt ein Lauf resident und misst alle 15 s nach (max. 16 Fast-Ticks, dann übernimmt nahtlos der nächste Timer-Tick) — das 1-Minuten-Raster war zu grob für den 50°C-Sprint in 6 Minuten vom 10.08.2026. Wird ein gedrosselter Dauer-Verursacher nach der Entwarnung wieder heiss, beginnt der Zyklus von vorn; die Meldungen zeigen dann, dass manuelles Eingreifen nötig ist.

## Installation

`./install.sh` — idempotent: Skript und Units werden auf den Repo-Stand gebracht, `stop-list.conf` und `smtp.env` nur beim Erstlauf gesät und danach nie überschrieben (dort stehen maschinenspezifische Prioritäten und Zugangsdaten; `smtp.env` chmod 600, gehört nicht ins Repo). Der Root-Teil (Helper `cpu-throttle` nach `/usr/local/sbin`, sudoers-Whitelist `/etc/sudoers.d/cpu-watchdog` nur für dieses eine Kommando) läuft, wenn sudo verfügbar ist; ohne sudo degradiert der Watchdog sauber auf Stufe 1+2. Danach Kanaltest: `cpu-watchdog.sh test-notify`.

## Tuning

Schwellen per Env in der Service-Unit übersteuerbar: `WARN_C` (85), `CRIT_C` (92), `EMERG_C` (95), `HYST_C` (5), `GRACE_S` (180), `THROTTLE_PCT` (30), `FAST_INTERVAL_S` (15), `FAST_TICKS_MAX` (16). Zum Testen versteht das Skript `TEMP_OVERRIDE`, `CONF`, `STATE_DIR`, `LOG`, `THROTTLE_HELPER`. Achtung bei pkill-Tests: das Muster nie wörtlich in die eigene Shell-Kommandozeile schreiben, sonst trifft `pkill -f` die Test-Shell selbst.
