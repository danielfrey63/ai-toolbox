# Transcribe

Transcribe verarbeitet Audio- und Videoaufnahmen, erkennt Sprecher und erstellt Berichte mit Zeitstempeln und optionalen Bildausschnitten. Die lokale Medienverarbeitung funktioniert ohne Cloud-Key; eine Harness oder ein konfiguriertes Modell übernimmt die Auswertung.

**Installation für Menschen und Harnesses: [INSTALL.md](INSTALL.md).** Die Anleitung gilt im eigenständigen Repository, im Toolbox-Unterordner und im Skill-Bundle. Der Skill-Ordner enthält immer `transcribe.py` und `SKILL.md`.

## Schnellstart

Im Skill-Ordner; unter macOS/Linux gegebenenfalls `python3` verwenden:

```text
python transcribe.py install --profile local --non-interactive
python transcribe.py doctor --profile local --json
python transcribe.py run "aufnahme.m4a" --local --no-diarize --analysis harness --json
```

`--analysis harness` liefert Begleitdateien zur Auswertung durch den aufrufenden Agenten. `--analysis none` endet nach der Medienaufbereitung. Für automatische Berichtserstellung einen geeigneten Modell-Endpunkt konfigurieren, Profil `headless` prüfen und `--analysis model` verwenden.

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

Die JSON-Ausgabe nennt die tatsächlichen Pfade für Transkript, Protokoll, Bericht und Review. Je nach Inhalt kommen Sprecherdatei, Kompaktfassung, OCR-Referenzen und Illustrationen dazu. URL-Ergebnisse liegen unter `./transcribe/`; ein Index ermöglicht Wiederaufnahme.

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
