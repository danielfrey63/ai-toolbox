# Wartung und Verifikation

## Zuständigkeiten

- `transcribe.py` und `scripts/command.py`: öffentlicher CLI-Einstieg, Profile, Installation und Diagnose.
- `scripts/config.py`: Parameterdefinitionen, Vorrang, Typprüfung, Geheimnisbereinigung und Worker-Konfiguration. `.env.example` und `references/parameters.md` werden daraus erzeugt.
- `scripts/state.py`: atomare Dateiausgaben und Stufenergebnisse mit Eingabe-Fingerprints. `.state.json` dokumentiert vollständige, übersprungene oder fehlgeschlagene Stufen.
- `scripts/pipeline.py`: Eingabevalidierung, Medien-Wiederaufnahme, strukturierte Ergebnisse und Übergabe an Modell oder Harness.
- Fachmodule: Transkription, Sprecher, Kapitel, Bilder, Report und Publikation. Bestehende Skriptaufrufe bleiben verfügbar.

## Wiederaufnahme

`<base>.run.json` enthält Medienidentität, verwendete Optionen und Ausgabeorte. Eine ersetzte Aufnahme wird über absoluten Pfad, Grösse und Änderungszeit erkannt. Wer eine Datei unter Erhaltung all dieser Metadaten ersetzt, muss `--fresh` verwenden. URL-Aufrufe finden bereits erzeugte Begleitdateien über einen Index im Konfigurationsverzeichnis; `--rerun` lädt die Quelle erneut.

STT-Zwischenergebnisse erhalten Metadaten für Quelle, Backend, Sprache, Glossar und Modell. Alte Caches ohne Metadaten werden einmal übernommen; bei Zweifeln an ihrer Herkunft `--fresh` verwenden. `--rerun` wiederholt die Medienaufbereitung, `--fresh` berechnet STT und Sprechertrennung neu, `--force` berechnet die Modell-Stufen neu. `--rewrite` bleibt ein Legacy-Schalter von `report.py`.

OCR prüft zusätzlich die tatsächlichen Bildinhalte, Zeitpunkte, das Bildbudget, die Verzögerung nach Szenenwechseln und die Beschleunigungseinstellung. Der Konfidenzschwellwert filtert dieselben Rohdaten neu, ohne OCR erneut auszuführen. Deaktiviertes oder nicht verfügbares OCR ersetzt alte OCR-Belege durch einen leeren Zustand. Fehlende Analysebilder lösen in der Pipeline eine erneute Medienaufbereitung aus; der direkte Bildschritt darf eine unvollständige Bildmenge nicht als vollständig markieren.

Pipeline, direkter Medienlauf und Agent verwenden dieselbe Sperre pro Ausgabe. Ein wartender Pipeline-Prozess liest den gespeicherten Zustand nach dem Sperrerwerb erneut. Ein Hintergrundlauf meldet `busy`, wenn die Aufnahme bereits verarbeitet wird. Die URL-Indexdatei wird unter einer eigenen kurzen Sperre aktualisiert. Lokale Quellpfade werden absolut gespeichert, damit die Wiederaufnahme aus einem anderen Arbeitsverzeichnis funktioniert.

Die Modell-Stufen berücksichtigen ihre jeweiligen Eingaben und Einstellungen. Frame-Batches werden einzeln gespeichert; ein fehlgeschlagener Batch macht den Gesamtschritt unvollständig und wird beim nächsten Lauf erneut versucht. Kapitel werden ebenfalls einzeln gespeichert und begrenzt parallel bearbeitet (`TRANSCRIBE_LLM_WORKERS`). Leere oder abgeschnittene Modellausgaben gelten nicht als fertiger Report.

Sprecherlabels bleiben in den Rohcaches und in `<base>.speaker-source.json` erhalten. Änderungen an Namen und Overrides werden daraus neu angewendet. Direkte Textkorrekturen im gerenderten Transkript bleiben beim Namenswechsel erhalten. Ein vollständiger Medien-Neulauf rendert dagegen aus den Rohsegmenten.

Die Sprecher-Auswertung berücksichtigt Änderungen an Textbelegen, Teilnehmern, Sprache und Modellkonfiguration auch bei vollständig benannten Labels. Namen und menschlich überarbeitete offene Zuordnungen bleiben ohne `--force` erhalten. Die ältere Textsignatur in der Sprecherdatei dient der Nachvollziehbarkeit; die Wiederverwendung entscheidet der gemeinsame Stufenzustand.

Publiziert werden nur Bilder, die im Bericht oder in der Kompaktfassung verlinkt sind. Alte, nicht mehr verwendete Ausschnitte gelangen nicht erneut in den Upload. Die Freigabe erfasst auch die Bytes zusätzlich eingebundener Bilder. Bereits früher auf Confluence publizierte Anhänge werden nicht automatisch gelöscht. Eine vorhandene Schwärzung bleibt bei `--force` erhalten; zum Entfernen ist `--no-redact` nötig. Eine unvollständige Antwort beim nachträglichen Schwärzen gilt als Fehler und ersetzt die bisherige Spezifikation nicht.

## Tests

Im Skill-Ordner:

```text
python -B -m unittest discover -s tests -v
python -B scripts/transcribe.py --selftest
python -B scripts/repair.py --selftest
python transcribe.py --help
python transcribe.py run --help-all
```

Die Regressionstests verwenden temporäre Verzeichnisse und simulierte Provider; sie lesen keine produktiven Schlüssel und senden keine Aufnahmen. Zusätzlich einen kurzen echten Medienlauf mit bekanntem Inhalt prüfen. Performance-Messungen auf realen Aufnahmen durchführen; synthetische Sprachschleifen verfälschen Decoder-Laufzeiten.

Die zusätzliche [Tiefenprüfung vom 14.10.2026](audit-2026-10-14.md) dokumentiert Fehlerbilder, Korrekturen und Grenzen der Abnahme.

## Dokumentation erzeugen

```text
python transcribe.py config template
python transcribe.py config docs
python transcribe.py config options
```

Die Ausgaben aktualisieren `.env.example`, `references/parameters.md` und `references/options.md`. Das Betriebssystem bzw. der Editor muss UTF-8 verwenden. Die Tests prüfen, dass die versionierten Dateien der Definition entsprechen.

## Spiegelung und Paket

Die Toolbox bleibt die Entwicklungsquelle. Der Tree von `transcribe-split` muss dem Tree von `.agents/skills/transcribe` entsprechen. Im Split liegen `SKILL.md`, `INSTALL.md`, `transcribe.py`, `scripts/` und `references/` an der Wurzel. Der CLI-Einstieg darf deshalb keine Toolbox-Pfade voraussetzen.

`python scripts/build_skill.py` (Legacy-Wrapper: `scripts/build-skill.sh`) erzeugt aus dem committeten Stand ein `.skill`-Archiv. Tests und Entwicklungsunterlagen sind über `.gitattributes` ausgeschlossen; Installationsanleitung, Parameterreferenz und Laufzeit bleiben enthalten. Für Releases im Toolbox- und Split-Layout die portable CLI-Hilfe und die Regressionstests prüfen.
