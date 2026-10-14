# Interaktive Auswertung durch die Harness

Medienaufbereitung und Bericht sind zwei getrennte Schritte. Installation und Datenfluss stehen in [INSTALL.md](../INSTALL.md). Die Harness verwendet dieselbe Medienpipeline wie die CLI; sie schreibt anschliessend selbst die Auswertung.

## Aufbereiten und Quellen lesen

```text
python "<skill>/transcribe.py" run "<source>" --local --language de --analysis harness --json
```

Quelle und zusätzliche Frage getrennt übergeben. Sprache und gewünschte Zeitbereiche mitgeben. Vorhandene Aufnahmen behalten ihren Namen. Bei einem strikten Verbot von Cloud-Verarbeitung muss auch die Harness lokal arbeiten; andernfalls nur `--analysis none` ausführen und die Inhalte nicht in das Chatmodell einlesen.

Der JSON-Status `handoff` bestätigt die Medienaufbereitung. Er liefert die Pfade `protocol`, `transcript`, `report`, `review` sowie eine über die Aufnahme verteilte Auswahl `frames`. Protokoll, Transkript und diese Frames lesen. Audioaufnahmen haben keine Frames. Weitere Frames gezielt bei offenen Fragen oder schlecht lesbarem Inhalt nachladen; die Auswahl muss auch das Ende einer langen Aufnahme abdecken.

Zusätzlich vorhandene Quellen berücksichtigen: `speakers.md`, `links.md`, `ocr.json`, `crosscheck.md`, Glossar und Teilnehmerliste. OCR-Zeilen mit `(?)` anhand des Bildes prüfen. Reparierte Passagen bleiben ohne Gegenprüfung unsicher. Widersprüche anhand der Aufnahme oder Plattformuntertitel auflösen.

## Sprecher zuordnen

Name, Confidence und Evidence in `<base>.speakers.md` pflegen. Frame- oder Caption-Voice-Evidenz zusammen mit Anredemustern ergibt `high`; eine Quelle ergibt `medium` mit `(?)`, ohne Evidenz bleibt der Name leer. Bei Audio genügt konsistente Rollen-/Inhaltsevidenz zusammen mit mindestens einer Anrede für `high`. Vorname als kanonische Form verwenden, bei Kollision mit kürzestem eindeutigem Nachnamenpräfix.

Ein gemeinsam verwendetes Mikrofon kann mehrere Personen unter einem Label führen. Einzelne Beiträge in der Overrides-Tabelle zuordnen; eine Zeit innerhalb des Beitrags genügt. Danach deterministisch anwenden und Hörproben aktualisieren:

```text
python "<skill>/scripts/speakers.py" --apply "<base>"
python "<skill>/scripts/grounding.py" "<base>"
```

Ursprüngliche Labels bleiben für spätere Korrekturen erhalten. Unsichere Namen nicht stillschweigend festschreiben. Offene Zuordnungen aus `speakers.md` in den Bericht übernehmen.

## Bericht schreiben

Vor dem Schreiben [report-writing.md](report-writing.md) lesen. Inventar, Konsistenzprüfung, Datumsbestimmung und Abdeckung sind Pflicht. Der Bericht enthält `## Übersicht`, `## Summary`, `## Analysis`. Vorhandenen Header und Verweise erhalten, einen vorhandenen Berichtsteil ersetzen statt einen zweiten anzuhängen. Eine Nutzerfrage zusätzlich mit Zeitstempeln beantworten.

Das kompakte Transkript `<base>.transcript-kompakt.md` fasst Aussagen unter chronologischen Themenüberschriften zusammen. Ein Block beginnt mit `**[MM:SS] Name:**`; das Original bleibt die wortnahe Referenz. Füllwörter dürfen entfallen, fachliche Inhalte und Unsicherheiten müssen erhalten bleiben. Sprecherkorrekturen und Glossar in beide Ausgaben übernehmen.

Illustrationen gemäss Report-Anweisung als Spec beschreiben, über `illustrate.py` rendern und anhand des Manifests einbetten. Die finalen Ausschnitte visuell prüfen. Keine unabhängig handgeschnittenen Kopien erzeugen. Pfade im Markdown relativ zum Bericht halten und bei Leerzeichen in Winkelklammern einschliessen.

Den tatsächlichen Datenfluss nennen: lokales oder Cloud-Audiobackend laut Protokoll sowie die auswertende Harness und deren empfangene Texte/Bilder. Eine geschwärzte Illustration bedeutet nicht, dass das ursprüngliche Bild dem Analysemodell verborgen war.

## Abschluss

```text
python "<skill>/transcribe.py" review "<base>"
```

Die Review-Datei aktualisieren, Checkboxen ausschliesslich dem Menschen überlassen. In der Antwort Kernaussagen, die Antwort auf die konkrete Frage und klickbare Dateilinks im vom Client unterstützten Format liefern. Den vollständigen Bericht nicht im Chat duplizieren. Frames für erwartete Rückfragen behalten; ein späteres Cleanup darf nur das konkrete Arbeitsverzeichnis des Laufs betreffen.
