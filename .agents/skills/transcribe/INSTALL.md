# Installation für Menschen und Harnesses

Diese Anleitung gilt für das eigenständige Repository, den Toolbox-Unterordner und ein entpacktes Skill-Bundle. `<skill>` ist immer der Ordner mit dieser Datei, `SKILL.md` und `transcribe.py`. Eine Harness liest zuerst diese Datei; sie benötigt keinen Claude-spezifischen Installer.

## Voraussetzungen

- Python ab 3.10 zum Starten des Installers: Windows `python`, macOS/Linux meist `python3`. Unter macOS ist `python3` oft das System-Python 3.9; dann ein neueres wie `/opt/homebrew/bin/python3.14` verwenden. Der SessionStart-Hook sucht ein passendes und nennt es.
- Ein Checkout oder Release des Skills. Bei Git-Installation einen festgelegten Commit verwenden; die vollständige Toolbox ist nicht erforderlich, wenn das gespiegelte Repository verfügbar ist.
- Netzwerkzugriff für die erste Installation von Werkzeugen, Python-Paketen und Modellen. Für lokale Modelle werden keine Cloud-API-Keys benötigt. Sprechertrennung benötigt einen Hugging-Face-Token und die Annahme der Modelllizenz.
- macOS benötigt für die automatische ffmpeg-Installation Homebrew. Linux und Windows verwenden Werkzeuge im Benutzerverzeichnis ohne Administratorrechte.

## Automatischer Ablauf

Die Beispiele laufen im Skill-Ordner. Aus einem anderen Arbeitsverzeichnis den absoluten Pfad zu `transcribe.py` verwenden. Pfade immer quotieren.

```text
python transcribe.py doctor --profile local --json
python transcribe.py install --profile local --non-interactive
python transcribe.py doctor --profile local --json
```

Eine Harness führt `install` nur aus, wenn `doctor` den gewünschten Zustand nicht bestätigt. Danach muss `doctor` erneut Exit `0` und `ready: true` liefern. Ein Installer-Exit ohne anschliessende Prüfung ist kein Abnahmenachweis. `--non-interactive` fragt weder nach Schlüsseln noch nach Bestätigungen; fehlende Voraussetzungen erscheinen als Fehler. Bei Download- oder Berechtigungsfehlern die konkrete Ursache beheben, statt dieselbe Installation unbegrenzt zu wiederholen.

| Profil | Gewünschter Zustand |
|---|---|
| `local` | ffmpeg, ffprobe, yt-dlp und verwaltete Whisper-Laufzeit mit bestandenem Funktionstest |
| `local-speakers` | Zusätzlich Sprecher-Laufzeit (pyannote, torch) und konfigurierter Hugging-Face-Zugang |
| `headless` | Lokale Laufzeit und konfigurierter Analyse-Endpunkt |
| `publish` | Konfigurierter Confluence-Zugang und isolierte Markdown-Laufzeit |

`doctor` prüft Konfiguration und installierte Laufzeit. Die Installation lässt jede Laufzeit einmal auf einer synthetischen Aufnahme laufen und meldet sie erst danach als bereit; `doctor --probe` wiederholt diesen Test. Installiert werden die geprüften Versionen aus `requirements/*.lock`. Modelle werden beim ersten Gebrauch geladen; ein vorhandener Token beweist noch keine Modellberechtigung. Ein echter kurzer Testlauf prüft diese zusätzlich. `doctor --profile headless --probe` prüft den Text-Endpunkt mit einem echten Modellaufruf; Bildunterstützung lässt sich mit `python scripts/llm.py --probe --image test.png` prüfen.

Der Installer legt einen `transcribe`-Launcher unter `~/.transcribe/bin/` an. Dieses Verzeichnis kann in `PATH` aufgenommen werden. Die portable Form `python <skill>/transcribe.py` funktioniert auch ohne PATH-Änderung. Ein erneuter Installationslauf behält passende Dateien bei.

## Konfiguration und Datenfluss

```text
python transcribe.py config show --explain
python transcribe.py config template
```

Benutzerkonfiguration: `~/.config/transcribe/.env`. Eine andere Datei wird ausdrücklich gewählt:

```text
python transcribe.py --config "/absolute/path/transcribe.env" doctor --profile headless --json
```

Vorrang: CLI-Optionen, Prozessumgebung, explizite Datei, Benutzerdatei, Default. Leere Werte gelten als nicht gesetzt. Eine `.env` im Arbeitsverzeichnis wird nicht automatisch gelesen. Migration alter Installationen: diese Datei mit `--config` auswählen oder die benötigten Werte in die Benutzerkonfiguration übernehmen. [Parameterreferenz](references/parameters.md) und `.env.example` werden aus derselben Definition erzeugt.

API-Keys gehören in eine geschützte Datei oder die Prozessumgebung, nicht in CLI-Argumente. `config show` zeigt nur gesetzt/nicht gesetzt. Der Installer setzt POSIX-Dateien auf `0600` und entfernt unter Windows breite ACL-Freigaben für Everyone, Authenticated Users und Users. `doctor` prüft sowohl die Benutzerdatei als auch eine explizit gewählte Konfiguration. Organisationsspezifische ACLs und Geheimnisverwaltung bleiben Sache des Arbeitsplatzbetriebs. Der interaktive Legacy-Installer verwendet verdeckte Schlüsseleingaben.

`--local` bindet Transkription und Sprechertrennung an lokale Backends. Es verbietet keine Modell-Auswertung: `--analysis model` sendet Text und gegebenenfalls Bilder an den konfigurierten Endpunkt. `--analysis harness` übergibt die Auswertung an die aufrufende Harness; deren Datenfluss gilt zusätzlich. `--analysis none` erzeugt ausschliesslich die lokalen Begleitdateien. Widersprüchliche Cloud-Backend-Overrides zusammen mit `--local` werden abgewiesen.

## Erster Lauf

```text
python transcribe.py run "aufnahme.m4a" --local --no-diarize --analysis none --plan --json
python transcribe.py run "aufnahme.m4a" --local --no-diarize --analysis none --json
```

Danach einen bekannten Satz samt Zeitstempel im ausgegebenen Transkript prüfen. Für eine Harness mit eigener Auswertung `--analysis harness` verwenden und anschliessend [die Report-Anweisung](references/report-writing.md) lesen. Für Headless-Auswertung `--analysis model` und ein eingerichtetes Analyse-Deployment verwenden. Ein Beispiel für Azure steht in `.env.example`; Schlüssel oder Deployment-Namen anderer Arbeitsplätze dürfen nicht übernommen werden.

Bei Video zusätzlich einen bekannten Bildschirminhalt prüfen. Sprechertrennung separat mit `--local` ohne `--no-diarize` testen. Wiederholen muss vorhandene gültige Ergebnisse wiederverwenden. `run --plan --json` zeigt die Entscheidung, `status <base> --json` die gespeicherten Stufenergebnisse.

## Einbindung in eine Harness

Den Skill-Ordner in den vom jeweiligen Client unterstützten Skill-Pfad installieren oder verknüpfen. Die Verknüpfung zeigt auf den Ordner mit `SKILL.md`, nicht auf `scripts/`. Für Claude Code kann das mitgelieferte Marketplace-Manifest genutzt werden. Andere Harnesses können direkt die portable CLI aufrufen; `${CLAUDE_SKILL_DIR}` ist dafür nicht erforderlich.

Quelle, Commit, Zielordner und Client-Verknüpfung sind Installationsparameter des Aufrufers. Vorhandene abweichende Checkouts oder Verknüpfungen nicht stillschweigend ersetzen. Das organisationsspezifische [Windows-Rollout-Dokument](references/windows-team-rollout.md) ergänzt diese Anleitung.

## Updates, Cleanup und isolierte Tests

Vor einem Update die installierte Commit-ID notieren. Den gewünschten Stand auschecken, dann Installation und Abnahmetest wiederholen. Ein Code-Rollback ersetzt keine bereits aktualisierten Modelle; die Laufzeit wird erneut geprüft.

`python transcribe.py cleanup` entfernt ausschliesslich den zu diesem Checkout gehörenden Launcher. Konfiguration, Modelle, Aufnahmen und Ergebnisse bleiben erhalten. Eine fremde Launcher-Datei wird nicht entfernt. Für vollständig isolierte Tests vor dem Prozessstart `TRANSCRIBE_CONFIG_DIR` und `TRANSCRIBE_BIN_DIR` auf eigene temporäre Verzeichnisse setzen. Keine Cleanup-Prüfung gegen produktive Aufnahmen durchführen.

## Rückgabewerte

| Exit | Bedeutung |
|---|---|
| `0` | Gewünschte Aktion erfolgreich; bei Harness-Auswertung ist der JSON-Status `handoff` |
| `1` | Laufzeit-, Modell- oder Validierungsfehler |
| `2` | Aufruf ungültig oder gewünschte Installation/Konfiguration unvollständig |
| `3` | Analyse-Endpunkt nicht konfiguriert; Legacy-Setup: lokale Laufzeit fehlt |
| `4` | Am ausdrücklich angeforderten Sprecher-Review angehalten |
| `5` | Publikationsfreigabe noch offen |

Spezialskripte behalten ihre dokumentierten Legacy-Codes. Fehlercodes von Kindprozessen werden weitergereicht; unbekannte Nichtnull-Codes sind Fehler. Fortschritt läuft auf stderr, `--json` liefert bei abgeschlossenen Aktionen ein JSON-Ergebnis auf stdout. Ungültige Aufrufe oder frühe Laufzeitfehler können ohne JSON mit einem Nichtnull-Code enden. Ein Hintergrundlauf gegen eine bereits bearbeitete Aufnahme endet mit `0` und dem Status `busy`; eine Harness versucht ihn später erneut. Freigabe-Checkboxen werden ausschliesslich von Menschen gesetzt.
