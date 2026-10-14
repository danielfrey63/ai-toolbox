# Transcribe

Transcribe verarbeitet Audio- und Videoaufnahmen, erkennt Sprecher und erstellt Berichte mit Zeitstempeln und optionalen Bildausschnitten. Die lokale Medienverarbeitung funktioniert ohne Cloud-Key; eine Harness oder ein konfiguriertes Modell übernimmt die Auswertung.

## CLI: die wichtigsten Aufrufe

Im Skill-Ordner; unter macOS/Linux gegebenenfalls `python3` verwenden:

```sh
# Einmal installieren und prüfen
python transcribe.py install --profile local --non-interactive
python transcribe.py doctor --profile local

# Audio oder Video lokal transkribieren, ohne API-Key
python transcribe.py run "aufnahme.mp4" --local --no-diarize --analysis none

# Vorab zeigen, was berechnet oder wiederverwendet wird
python transcribe.py run "aufnahme.mp4" --local --no-diarize --analysis none --plan

# Wiederaufnehmen, mit den Einstellungen des ersten Laufs
python transcribe.py run "aufnahme.transcript.md" --analysis none

# Gespeicherten Stand und effektive Konfiguration ansehen
python transcribe.py status "aufnahme.transcript.md"
python transcribe.py config show --explain

# Hilfe und sämtliche Medienoptionen
python transcribe.py --help
python transcribe.py run --help-all
```

Das Transkript steht neben der Aufnahme in `aufnahme.transcript.md`. Statt einer Datei kann auch eine Video-URL übergeben werden. `--no-diarize` lässt die Sprechertrennung weg; dafür ist sonst ein Hugging-Face-Zugang nötig. Mit `--json` liefern die Lauf-, Plan-, Status- und Diagnosebefehle maschinenlesbare Ergebnisse.

Für einen Bericht durch die aufrufende Harness:

```sh
python transcribe.py run "aufnahme.mp4" --local --no-diarize --analysis harness --json
```

Für automatische Berichtserstellung einen Analyse-Endpunkt gemäss [INSTALL.md](INSTALL.md) konfigurieren:

```sh
python transcribe.py doctor --profile headless
python transcribe.py run "aufnahme.mp4" --local --no-diarize --analysis model
```

Nach der Installation ist auch `transcribe …` möglich, wenn `~/.transcribe/bin/` im `PATH` liegt. Die portable Form oben funktioniert ohne PATH-Änderung. **[Vollständige Installation für Menschen und Harnesses](INSTALL.md)**, gültig im eigenständigen Repository, im Toolbox-Unterordner und im Skill-Bundle.

## CLI

| Befehl | Zweck |
|---|---|
| `install --profile … --non-interactive` | Gewünschte Laufzeit herstellen und nachprüfen |
| `doctor --profile … --json` | Voraussetzungen ohne Installation prüfen |
| `config show --explain` | Effektive Werte und Herkunft; Keys nur gesetzt/nicht gesetzt |
| `run <source> --plan --json` | Berechnung und Wiederverwendung erklären |
| `run <source> --json` | Verarbeiten oder fortsetzen |
| `status <base> --json` | Gespeicherte Stufenergebnisse lesen |
| `review <base> --check` | Menschliche Freigaben prüfen |
| `publish <base> --dry-run` | Confluence-Änderungen planen und lokale Vorschau schreiben |
| `cleanup` | Den Launcher dieses Checkouts entfernen |

`--help` zeigt die Befehle. `run --help-all` enthält fortgeschrittene Medienoptionen. Bestehende Aufrufe der Fachskripte bleiben möglich.

## Konfiguration und Datenfluss

[Alle Parameter](references/parameters.md) und `.env.example` werden aus `scripts/config.py` erzeugt. Benutzerkonfiguration: `~/.config/transcribe/.env`; eine andere Datei wird mit `--config` ausdrücklich gewählt. Prozessvariablen haben Vorrang. Das Arbeitsverzeichnis wird nicht nach Keys durchsucht. ML und optionale Publikation verwenden isolierte Umgebungen; der Host-Interpreter bleibt unverändert.

`--local` bindet Transkription und Sprechertrennung an lokale Backends. Ohne dieses Flag können konfigurierte Cloud-Anbieter als Fallback verwendet werden. `--analysis model` sendet Text und gegebenenfalls Bilder an das Analysemodell, auch bei lokaler Transkription. `--redact` schwärzt fertige Ausschnitte; Quellbilder werden für die Modellauswertung verwendet.

## Ergebnisse und Korrekturen

Die JSON-Ausgabe nennt die tatsächlichen Pfade für Transkript, Protokoll und Bericht; `review` ist `null`, solange keine Review-Liste existiert (`--analysis none` oder `harness`). Je nach Inhalt kommen Sprecherdatei, Kompaktfassung, OCR-Referenzen und Illustrationen dazu; ein Audio-Lauf legt keine leeren OCR-Dateien an. URL-Ergebnisse liegen unter `./transcribe/`; ein Index ermöglicht Wiederaufnahme.

Sprecher und Wortmeldungen in `.speakers.md` korrigieren und denselben Befehl erneut ausführen. `--fresh` erneuert STT und Sprechertrennung, `--rerun` die Medienaufbereitung, `--force` die Modell-Stufen. Fehlgeschlagene Bild-Batches und Kapitel werden separat fortgesetzt. Vor einer Publikation prüft ein Mensch `.review.md`; geänderte Artefakte setzen Freigaben zurück.

## Harness und Plugin

Harnesses laden [SKILL.md](SKILL.md) und finden dort direkt die Installationsanleitung. Die CLI ist unabhängig vom Skill-Client. Claude Code kann den Skill-Ordner als Marketplace registrieren:

```text
/plugin marketplace add <absolute-skill-directory>
/plugin install transcribe@transcribe
```

Andere Clients installieren oder verknüpfen denselben Ordner in ihren unterstützten Skill-Pfad. Für claude.ai erzeugt `python scripts/build_skill.py` aus dem committeten Stand `dist/transcribe.skill`.

## Weiterführend

- [Installation](INSTALL.md)
- [Parameterreferenz](references/parameters.md)
- [Medienoptionen](references/options.md)
- [Report-Anweisung](references/report-writing.md)
- [Tests, Caches und Spiegelung](references/maintenance.md)
- [Windows-Team-Rollout](references/windows-team-rollout.md)

Lizenz: [MIT](LICENSE).
