# Unabhängige Evaluation vom 14.10.2026

Geprüft wurde der Stand `336f533` (Skill 1.81.416) mit echten Läufen auf der Windows-Devbox (RTX A4000 Laptop, 16 Kerne). Die Prüfung ergänzt die [Tiefenprüfung vom selben Tag](audit-2026-10-14.md), die auf Cache-Übergänge und Verträge zielte. Hier geht es um die sieben Dimensionen Dokumentation, Skripte, Konsistenz, Einheitlichkeit, Hilfestellung, Installierbarkeit, Einfachheit und Performance – und um den Spiegelweg nach SBB.

## Kurzfazit

Der Skill ist in einem Monat von einem Claude-Skill zu einer eigenständigen CLI mit acht Befehlen, Zustandsverwaltung, Review-Gate und Publikation gewachsen. Die Substanz ist gut: 51 Regressionstests laufen in 19 s grün, Wiederaufnahme ist nachweislich idempotent, der Exit-Code-Vertrag hält, und `doctor` verhält sich in leerer Umgebung korrekt. Der schwerste Befund ist eine heute eingeführte, bereits gepushte Regression, die **jeden Videolauf mit aktivem OCR abbrechen lässt** und die von keinem Test gefangen wird. Dahinter stehen zwei strukturelle Schwächen: die Testsuite deckt den Videopfad nur auf Modulebene ab, und `run.py::execute` ist mit 1163 Zeilen in einer Funktion der Ort, an dem solche Typfehler unbemerkt entstehen. Der Spiegelweg nach SBB existiert in Doku und Repo nicht.

## Was ausgeführt wurde

| Prüfung | Ergebnis |
|---|---|
| `unittest discover -s tests` | 51/51 in 19 s |
| `scripts/repair.py --selftest`, `scripts/transcribe.py --selftest` | 7/7, 6/6 |
| `--help` aller 35 Skripte | alle Exit 0; 6 Module ohne CLI schlucken `--help` stumm |
| `build_skill.py` | 57 Dateien, 1.1 MB, ohne Tests, mit INSTALL.md und 12 Referenzen |
| `doctor --profile local/headless` in isolierter leerer Umgebung | `ready: false`, Exit 2, Ursache benannt |
| Audio 253 s, `--local`, Diarisierung, `--analysis none` | 39 s; Wiederholung 1 s mit vollständiger Wiederverwendung |
| Video 7:09 via URL, gleiche Optionen | **Abbruch Exit 1** in der OCR-Signatur |
| Video 7:09 mit `--no-ocr` | 48 s inklusive Frames, Szenen, Whisper, pyannote |
| Link-Check der Doku | 43 relative Links, alle gültig |
| `config template` gegen `.env.example` | identisch bis auf Zeilenenden |
| Flag-Abgleich Code ↔ Doku | 85 Flags im Code, 23 nur in `--help` der Fachskripte |

## Befunde nach Gewicht

| Gewicht | Befund | Zielort und Vorschlag |
|---|---|---|
| Hoch | `run.py` übergibt `video_path` als `str` an `ocr.cache_key()`, `state.media_identity()` ruft `.stat()` auf dem String: `AttributeError`, jeder Videolauf mit OCR bricht nach der Frame-Extraktion ab. Eingeführt in `336f533`, gepusht. | `state.py::media_identity`: erste Zeile `path = Path(path)`; damit sind alle Aufrufer abgedeckt. Dazu ein Test, der `run.py` mit einem 3-s-`ffmpeg testsrc`-Video wirklich durch Frames und OCR laufen lässt. |
| Hoch | Die Testsuite enthält keinen echten Videolauf. Der CLI-Test nutzt `sample.wav`; Frame- und OCR-Tests prüfen Module mit vorbereiteten `Path`-Objekten. Deshalb blieb der Befund oben grün. | `tests/test_contracts.py`: synthetisches Video erzeugen, `run.py` end-to-end, Artefakte und `state.json` prüfen. Kosten: wenige Sekunden. |
| Hoch | Der SBB-Spiegelweg ist weder dokumentiert noch skriptiert. `maintenance.md` und das Audit nennen einen Export `transcribe-split` mit Tree-Gleichheitsprüfung; es gibt dafür weder Skript noch Test (der einzige Layout-Test baut das `.skill`-Bundle). Bitbucket kommt in keiner Datei vor. `tools/extract-skill` vom September baut ein Submodul-Szenario, nicht einen Branch. | Ein Befehl `python transcribe.py split --dest <pfad>` oder ein Toolbox-Skript, das den Unterordner per `git subtree split` exportiert und die Tree-Gleichheit prüft, plus ein Abschnitt in `maintenance.md` mit Ziel-URL und Ablauf. |
| Mittel | `run.py::execute` hat 1163 Zeilen, `build_parser` 212, `download_url` 179. In `execute` wechseln `str` und `Path` je nach Herkunft (`dl["video_path"]` ist `str`). | Stufen als Funktionen mit typisierten Eingaben herauslösen, beginnend bei Medien, Frames, OCR und Persistenz. |
| Mittel | Zwanzig `subprocess.run(..., text=True)` ohne `encoding` in acht Dateien (`frames.py`, `illustrate.py`, `stt.py` je 4, `setup.py` 3, `download.py`, `ocr.py` je 2, zwei weitere je 1) und `resources.py:289` `open(path)` ohne Encoding. Genau diese Klasse brach im August auf cp1252-Konsolen. | `encoding="utf-8", errors="replace"` ergänzen; ein gemeinsamer Helfer `run_text()` statt 20 Kopien. |
| Mittel | Fünf Implementierungen der Zeitstempel-Formatierung (`fmt_ts` in `companions.py`, `ocr.py`, `speakers.py`; `_fmt_ts` in `illustrate.py`, `resources.py`), dazu je zwei `read_json`/`write_json`, `parse_vtt`, `load_config`, `config_files`, `_dhash`, `_thin`. | Nach `companions.py` bzw. `state.py` konsolidieren; `log` in den Workern bleibt bewusst lokal, weil sie ohne Host-Imports laufen. |
| Mittel | Das Ergebnis-JSON nennt `review` mit Pfad, bei `--analysis none` existiert die Datei nicht. Harnesses, die den Vertrag wörtlich nehmen, scheitern. | `pipeline.py`: nur existierende Pfade melden oder `null` setzen. |
| Mittel | `transcribe.py run` ohne Quelle endet mit Exit 0 und druckt die Usage. INSTALL.md verspricht Exit 2 für ungültige Aufrufe. | `command.py`: fehlendes Argument über argparse-Fehler laufen lassen. |
| Mittel | Das Protokoll weist weder Modell noch Device noch Thread-Zahl aus (`via transcript (whisper-local)`). Die Hitze-Diagnose vom September auf dem Home-Laptop brauchte deshalb SSH und Session-Logs statt eines Blicks ins Protokoll. | `whisper_local_worker.py` gibt `desc` schon aus; als Feld ins Worker-JSON, durch `stt.py` bis in `run.py::_persist_report`. |
| Niedrig | `run --help` zeigt Beispiele mit `python pipeline.py …`, der dokumentierte Einstieg ist `transcribe.py run …`. `install --help` beschreibt seine beiden Optionen nicht. | Epilog in `pipeline.py::build_parser` auf den öffentlichen Einstieg umstellen; `help=` für `--profile` und `--non-interactive`. |
| Niedrig | Fehlermeldung «Source is unavailable for recomputation» für eine Datei, die nie existiert hat. | Erst Existenz prüfen, dann «not found» melden; «unavailable for recomputation» nur bei bekannter Aufnahme. |
| Niedrig | Ein Audio-Lauf legt 15 Begleitdateien neben die Aufnahme, darunter `links.md` und `ocr.json` ohne Inhalt, weil es keine Frames gab. | Leere OCR-Artefakte bei Audio nicht schreiben; `state.json` trägt die Aussage bereits. |
| Niedrig | Sechs Module ohne CLI (`cli.py`, `companions.py`, `config.py`, `cpu.py`, `joblock.py`, `state.py`) beenden `--help` stumm mit Exit 0. | Nicht nötig zu ändern; ein Satz in `maintenance.md`, dass diese Module keine Einstiege sind, reicht. |
| Niedrig | Namenskollision: `transcribe.py` an der Wurzel ist die CLI, `scripts/transcribe.py` der VTT-Formatter mit `--selftest`. | Umbenennen nach `scripts/vtt_format.py` beim nächsten Bruch der Fachskript-Aufrufe; bis dahin ein Hinweis in `maintenance.md`. |
| Niedrig | Sprachmix: `SKILL.md` englisch, INSTALL/README/references deutsch; Laufzeitmeldungen englisch bis auf drei deutsche in `repair.py` und `crosscheck.py`. | Für SBB ist Deutsch in der Nutzerdoku richtig. Die drei deutschen Laufzeitmeldungen auf Englisch ziehen, damit stderr einheitlich ist. |

## Bewertung je Dimension

**Dokumentation.** `SKILL.md` ist auf 750 Wörter geschrumpft und delegiert sauber an INSTALL.md und sieben Referenzen; alle 43 relativen Links sind gültig, `.env.example` und `parameters.md` werden aus `config.py` erzeugt und per Test geprüft. Schwach ist nur, was Doku behauptet und Repo nicht einlöst: der Split-Export und seine Prüfung.

**Skripte.** 14'535 Zeilen in 35 Dateien, Versionsquelle `plugin.json`, `--version` stimmt. Die Fachskripte haben alle eine Hilfe. Der Hotspot ist `run.py::execute`; dort entstand die Regression, und dort ist der Typwechsel `str`/`Path` unübersichtlich.

**Konsistenz und Einheitlichkeit.** Exit-Codes, JSON-Schemata und Stufenzustände sind als Vertrag beschrieben und getestet. Uneinheitlich sind die Zeitstempel-Helfer, das Encoding bei Subprozessen und die Beispiele in `run --help`.

**Hilfestellung.** `run --help` erklärt Plan, Datenfluss und Exit-Codes in zehn Zeilen; `run --help-all` liefert 209 Zeilen. README beginnt mit kopierbaren Aufrufen. Lücken: `install --help`, die Fehlermeldung für fehlende Quellen und der stille Exit 0 ohne Quelle.

**Installierbarkeit.** Profile, `--non-interactive`, `doctor` als Abnahmebeweis und die isolierbaren Verzeichnisse `TRANSCRIBE_CONFIG_DIR`/`TRANSCRIBE_BIN_DIR` sind belastbar; in leerer Umgebung meldet `doctor` korrekt Exit 2 mit Ursache «venv missing». Das Bundle trägt keine Tests und keine Schlüssel. Das Windows-Rollout-Dokument prüft Checkouts und Junctions, bevor es etwas ändert. Nicht geprüft wurde eine frische vollständige ML-Installation.

**Einfachheit.** Acht Befehle, 85 Flags, drei Analysepfade, drei Wiederholungsschalter (`--rerun`, `--fresh`, `--force`). Das ist für eine Harness beherrschbar, für Menschen am Terminal nur dank `--plan`. Die 15 Begleitdateien pro Aufnahme sind der sichtbarste Preis der Nachvollziehbarkeit.

**Performance.** Audio 253 s in 39 s, davon Whisper 13 s und pyannote 7 s; der Rest ist Audio-Extraktion, Modell-Laden und Prozessstarts. Video 7:09 ohne OCR in 48 s. Wiederholungen kosten 1 s. Die CPU-Budgetierung und die Turbo-Entscheidung vom September greifen. Nicht gemessen: OCR, Modell-Stufen und Publikation.

## Stand nach den Korrekturen vom selben Tag

Die Korrekturen folgten direkt auf die Evaluation; die Suite umfasst seither 54 Tests. Was offen bleibt, ist hier mit Grund benannt.

| Befund | Stand |
|---|---|
| Regression Videopfad | Behoben: `state.media_identity` akzeptiert Zeichenketten wie Pfade. `test_video_run_signs_ocr_with_string_media_path` fährt einen drei Sekunden langen `testsrc`-Clip durch Frames und OCR-Signatur und schlägt auf dem alten Stand nachweislich fehl. |
| Kein Videolauf in der Suite | Behoben durch denselben Test; er wird ohne ffmpeg übersprungen. |
| SBB-Spiegelweg | Das Toolbox-Skript `tools/mirror-skill/mirror-skill.sh` mit Katalogeintrag `mirror` (Bitbucket-URL, Branch) kam am selben Tag in Commit `4e21567` dazu; `maintenance.md` beschreibt den Ablauf. Ob der Spiegel bereits auf dem aktuellen Stand ist, wurde hier nicht geprüft (`mirror-skill.sh transcribe --dry-run` zeigt es). |
| `run.py::execute` 1163 Zeilen | Offen, bewusst: die Zerlegung ist eine eigene Änderung. Der neue Videotest macht sie jetzt überhaupt erst absicherbar. |
| Subprozesse ohne Encoding | Behoben: `cli.run_text` ersetzt 15 Aufrufe in sieben Dateien; der yt-dlp-`Popen` und `resources.py` lesen UTF-8. |
| Duplikate | `fmt_ts`, `ts_seconds`, `read_json`, `write_json` leben nur noch in `companions.py` bzw. `state.py`; alle Zeitstempel runden ab wie das Transkript. `publish.py` nennt seine Helfer `load_publication_config` und `publication_config_files`. Bewusst getrennt bleiben `parse_vtt` (Teams-Export ohne Dedupe gegen YouTube-Rolling-Cues mit Dedupe), `_dhash` (PIL-Bild im isolierten OCR-Worker gegen Rohdatei) und `_thin` (Schrittweite gegen gleichmässige Verteilung mit beiden Enden). |
| `review`-Pfad im Ergebnis | Behoben: `null`, solange die Datei fehlt; `report` bleibt der Analyse-Zielpfad. |
| `run` ohne Quelle Exit 0 | Behoben: Exit 2 mit Fehlermeldung; `test_run_without_source_is_a_usage_error`. |
| Protokoll ohne Modell/Device | Behoben: Worker liefert `{"segments", "runtime"}`, `stt.worker_result` liest beide Formen, das Protokoll zeigt `Transcription runtime`, der Segment-Cache führt den Wert mit. |
| Hilfe-Beispiele, `install --help` | Behoben. |
| Fehlermeldung für fehlende Datei | Behoben: «Source not found», «unavailable for recomputation» nur bei bekannter Aufnahme. |
| Leere OCR-Dateien bei Audio | Behoben: ohne Frames entstehen keine neuen `ocr.json`/`links.md`; vorhandene alte Belege werden weiterhin geleert. |
| Module ohne CLI, Namenskollision | In `maintenance.md` dokumentiert; Umbenennung von `scripts/transcribe.py` bewusst verschoben. |
| Deutsche Laufzeitmeldungen | Behoben in `repair.py` und `crosscheck.py`; der generierte `crosscheck.md`-Inhalt bleibt deutsch wie die übrige Nutzerdoku. |

## Grenzen dieser Prüfung

Keine Cloud-Stufen (`--analysis model`, AssemblyAI, Confluence), keine frische ML-Installation, keine Qualitätsbewertung von Spracherkennung oder Sprecherzuordnung über die Stichprobe hinaus. Der SBB-Stand selbst war nicht erreichbar, weil seine Adresse nirgends steht.

## Reproduktion

```text
python -X utf8 -B -m unittest discover -s tests -v
python -X utf8 transcribe.py run "<audio>" --local --language de --analysis none --json
python -X utf8 transcribe.py run "<video-url>" --local --language de --analysis none --json   # Exit 1 auf 336f533
python -X utf8 transcribe.py run "<video-url>" --local --language de --analysis none --no-ocr --json
python -X utf8 transcribe.py run; echo $?   # 0 statt 2
```
