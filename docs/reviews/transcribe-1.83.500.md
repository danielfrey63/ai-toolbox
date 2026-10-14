# Transcribe: Evaluation des aktuellen Ansatzes

Geprüft am 14.10.2026: Toolbox-Commit `74d1848`, Skill **1.83.500**, SBB-Spiegelcommit `96b5190564cf9c6768dd738b947b75120551eef8`. Diese Bewertung bezieht sich auf diesen Stand; ältere, inzwischen behobene Befunde werden nicht als offene Fehler gezählt.

## Urteil

Der Ansatz trägt: ein portabler CLI-Einstieg, lokale Medienverarbeitung, isolierte ML-Laufzeit, optionale Modellauswertung und eine gesonderte Publikationsfreigabe. Installation, echter Video-/OCR-/Sprachlauf und automatische Berichtserstellung funktionieren in der geprüften Windows-Umgebung. Die Wiederverwendung spart nachweislich Arbeit. Die Dokumentation führt Menschen und Harnesses zum selben Einstieg.

Für einen verlässlich unbeaufsichtigten Teambetrieb bleiben jedoch wesentliche Lücken: Die Installationsprüfung vertraut einem Marker stärker als den tatsächlich installierten Paketen, die Invalidierung von Ergebnissen und Sprecherzuordnungen ist unvollständig, und das Spiegelungsskript erzwingt seinen Publikationsumfang nicht vollständig. Die hohe Zahl grüner Tests belegt diese Eigenschaften noch nicht. Priorität haben überprüfbare Stufenverträge und ein verpflichtendes Release-Prüfverfahren.

**Evidenz:** VERIFIED bezeichnet eine Beobachtung dieser Prüfung. Empfehlungen und die Gesamtbewertung sind daraus abgeleitete Einschätzungen. Nicht geprüfte Plattformen oder Inhaltsqualitäten werden ausdrücklich genannt.

## Ausgeführte Abnahme

| Prüfung | VERIFIED: Beobachtung |
|---|---|
| Bestehende Regressionstests | 54/54 erfolgreich; ebenfalls 54/54 im eigenständigen Checkout des Spiegelbranches |
| Bestehende Selbsttests | 6/6 Transkriptformatierung, 7/7 Reparaturerkennung |
| Leere separate Konfiguration und ML-Laufzeit | `doctor`: Exit 2, Venv fehlt |
| Echte Installation, kein simulierter Paketinstaller | Erster Lauf 29,50 s, zweiter Lauf 3,63 s; beide Exit 0 |
| Abnahme der neuen Installation | `doctor` Exit 0; tatsächliche Imports von `faster_whisper`, `torch`, `pyannote.audio` erfolgreich, Torch `2.6.0+cu124`, CUDA verfügbar |
| Cleanup zweimal | Exit 0 in 0,17 bzw. 0,16 s; Launcher entfernt, Laufzeit und Konfiguration erhalten |
| Echter 8,4-s-Videoclip mit Sprache und sichtbarer URL | Drei erwartete Sätze korrekt transkribiert; `https://example.org/audit` durch RapidOCR mit Score 0,99 erkannt |
| Wiederaufnahme des Clips | 1,33 s; keine erneute Medienaufbereitung |
| `--rerun` | 2,92 s; Medienaufbereitung läuft, OCR und Transkription werden wiederverwendet |
| `--fresh` | 27,52 s; OCR und Transkription werden neu berechnet |
| Azure-Bericht mit `--analysis model --no-frames` | Ein Aufruf, 20,0 s Modellzeit, 8'620 Eingabe- und 828 Ausgabetokens; vollständiger Bericht und offene menschliche Review-Checkboxen |
| Inhaltsprüfung des Berichts | Testaufnahme, Sitzungsbeginn 10 Uhr, Thema Dokumentation und sichtbare URL korrekt. Keine erfundenen Teilnehmenden oder Sachentscheide; unsicheres Aufnahmedatum als Metadatenableitung gekennzeichnet |
| Zweiter Berichtslauf | Vorhandener Bericht wird ohne weiteren Modellaufruf verwendet |
| Skill-Validator und Bundle | Erfolgreich; 58 Dateien. Fünf CLI-Aufrufe aus dem ausgepackten Bundle erfolgreich |
| SBB-Live-Abgleich | `master` und `v1.83.500` zeigen beide auf `96b5190`; Tree stimmt exakt mit dem Toolbox-Skill überein |

Die Installationsmessung verwendet eine neue Laufzeitumgebung, aber vorhandene Systemwerkzeuge und Download-Caches. Der kurze, synthetische Clip mit statischem Bild prüft die Integration; er ist kein repräsentativer Qualitäts- oder Durchsatzbenchmark für lange Meetings. Die Modellprüfung sendete ausschliesslich diese synthetischen Inhalte an den konfigurierten Azure-Endpunkt.

## Offene Befunde nach Priorität

P1 sollte vor einer nächsten Freigabe für unbeaufsichtigte Teamläufe behoben werden. P2 betrifft Wartbarkeit, Reproduzierbarkeit und Bedienung.

| Priorität | VERIFIED: Befund | Wirkung und konkrete Empfehlung |
|---|---|---|
| P1 | Ein leerer Venv mit passendem Installationsmarker ergibt `venv_status.ready = true`; der Import von `faster_whisper` scheitert, `install --profile local` endet trotzdem mit 0. Reproduktion `empty_runtime`. | Beschädigte oder nachträglich entfernte Pakete bleiben unerkannt. In [setup.py](../../.agents/skills/transcribe/scripts/setup.py) zur Marker-/ABI-Prüfung einen begrenzten Import- und Versionscheck ergänzen; nach einer Installation wirklich importieren, erst danach den Zustand als bereit markieren. |
| P1 | `report.build_input` verwendet OCR-Text auch bei `--no-frames`. Der Report-Fingerprint berücksichtigt dann jedoch nicht `p.ocr`. Nach einer OCR-Korrektur bleibt der Schlüssel gleich und der Report wird übersprungen. Reproduktion `ocr_report_dependency`. | Ein korrigierter Name oder Bildschirmtext gelangt nicht in den Bericht. Alle tatsächlich gelesenen Inputs in [state.py](../../.agents/skills/transcribe/scripts/state.py) erfassen; Abhängigkeiten unmittelbar bei der betreffenden Stufe definieren und Änderungen einzeln testen. |
| P1 | Beim Ersetzen der Quelldatei wird zwar neu transkribiert und diarisiert, die bestehende Zuordnung `SPEAKER_00 = Alice` wird aber wieder angewendet. Die neue Aufnahme erhält dadurch den alten Namen. Reproduktion `replaced_source_names`. | Sprecherlabels gelten nur innerhalb einer konkreten Diarisierung. In [run.py](../../.agents/skills/transcribe/scripts/run.py) Sprecherzuordnungen an Quell- und Diarisierungsidentität binden. Bei neuer Identität bisherige Zuordnungen erhalten, aber als neu zu prüfen behandeln. |
| P1 | Das Spiegelungsskript akzeptiert einen existierenden Versions-Tag, ohne dessen Ziel zu vergleichen: falscher Tag, korrekter Branch, trotzdem „up to date“. Reproduktion `mirror_wrong_tag`. | Branch und Release-Tag können unterschiedliche Stände bezeichnen. In [mirror-skill.sh](../../tools/mirror-skill/mirror-skill.sh) das tatsächliche Commit-Ziel des Tags prüfen, bei annotierten Tags auch den aufgelösten Commit. Widersprüche mit Fehler beenden. |
| P1 | Bei zusätzlich vorhandenem `remote.<name>.push`-Eintrag veröffentlicht `git push <remote>` auch diesen Branch. Im lokalen Bare-Test wurde neben dem Skill die komplette synthetische Toolbox-History als weiterer Branch gepusht. Reproduktion `mirror_additional_push_mapping`. | Der zugesicherte Exportumfang ist von versteckter Git-Konfiguration abhängig. Immer explizit den Split-Commit auf genau den Zielbranch pushen; keine impliziten Push-Zuordnungen verwenden. Beim tatsächlichen SBB-Remote wurde nur die gewünschte Zuordnung gefunden; diese Prüfung belegt keinen bisherigen Fehl-Upload. |
| P1 | Das Spiegelungsskript führt keine Tests aus. Der GitHub-Workflow liegt innerhalb des Skill-Unterordners; im Toolbox-Root gibt es keinen GitHub-Workflow. Die mitgelieferte GitHub-Datei ist kein Bitbucket-Prüfverfahren. | Im Repository ist kein verbindlicher Testschritt vor dem Spiegel-Push hinterlegt. Ein gemeinsamer Release-Befehl sollte Tests, echten Medien-Smoke-Test, Bundle-Prüfung und Tree-/Tag-Abgleich ausführen und erst dann publizieren. Extern konfigurierte SBB-CI wurde nicht eingesehen. |
| P2 | Identische Trees erzeugen unterschiedliche Archive: Toolbox 1'172'429 Byte, eigenständiger Checkout 1'174'117 Byte. 54 Textdateien unterscheiden sich ausschliesslich durch LF/CRLF. Die LF-Regeln stammen aus der Toolbox-Wurzel und fehlen im Split. | Reproduzierbare Releases benötigen Regeln im exportierten Modul. Die benötigten `text`-/`eol=lf`-Attribute in dessen `.gitattributes` aufnehmen und Bundle-Gleichheit zwischen beiden Layouts testen. |
| P2 | `run.py::execute` umfasst 1'171 Zeilen; die 35 Python-Skripte zusammen 14'553 Zeilen. Ablauf, Optionen, Abhängigkeiten und Status werden in mehreren Modulen beschrieben. | Stufenweise Funktionen für Beschaffung, Bilder, OCR, Sprache, Sprecher und Persistenz mit klaren Datentypen herauslösen. Plan und Ausführung sollten dieselbe Stufenbeschreibung nutzen. Das reduziert gerade die nachgewiesenen Abhängigkeits- und Pfadfehler. |
| P2 | `status` für einen nie angelegten Lauf liefert Exit 0 und `stages: {}`. Beim wiederholten Modelllauf meldet die CLI ausserdem erneut „transcript changed … rebuilding“ für die mangels Sprecherlabels nicht anwendbare Kompaktfassung. | „Nicht gefunden“, „nicht anwendbar“, „aktuell“ und „fehlgeschlagen“ unterscheiden. Menschliche Statusausgabe als kurze Stufenliste, JSON mit ausdrücklich bezeichnetem Zustand. |
| P2 | Die Parameterreferenz ist korrekt generiert, enthält aber zahlreiche leere Beschreibungen und bildet nicht alle Wertebereiche ab. `TRANSCRIBE_WHISPER_MODEL` wird beim CPU-Fallback durch das fest codierte Modell `medium` ersetzt. | Bereiche, Einheiten und Wirkungsbereich aus der Definition mit ausgeben. Eine explizite CPU-Modellwahl bzw. klare Trennung zwischen automatischem Fallback und Benutzerwahl vorsehen. |
| P2 | OCR/Pillow werden über `uv run --with` ohne feste Versionen aufgelöst; auch ein Teil der ML-Abhängigkeiten ist ungebunden. Ein gleicher Installationsmarker garantiert daher keine identische Abhängigkeitsmenge. | Getestete Abhängigkeitsstände und Modellrevisionen festhalten, besonders für freigegebene Teamversionen. OCR/Bildwerkzeuge in ein prüfbares Video-Profil aufnehmen. |

## Bewertung der gewünschten Eigenschaften

| Bereich | Bewertung und nächster sinnvoller Schritt |
|---|---|
| Dokumentation | README mit kopierbaren CLI-Aufrufen und die direkte Verknüpfung `SKILL.md → INSTALL.md` sind gut. Installationsprofile, Datenfluss und Wiederaufnahme sind auffindbar. Den SBB-Bezug und die dort nötige Git-/SSH-Konfiguration beim Team-Einstieg konkreter machen. |
| Skripte | Die getrennten Worker schützen die Host-Laufzeit wirksam. Der grosse Ablauf in `run.py` ist der zentrale Wartungsschwerpunkt; dort lohnt sich die Zerlegung zuerst. |
| Konsistenz | Zentrale Konfiguration, Zeitstempelhelfer und UTF-8-Subprozesshelfer sind Fortschritte. Inhaltliche Konsistenz scheitert noch an unvollständigen Abhängigkeiten und nicht an einheitlicher Schreibweise. |
| Einheitlichkeit | Die öffentliche CLI vereinheitlicht den Hauptweg. Legacy-Einstiege und interne Module bleiben zahlreich; neue Anleitungen sollten konsequent die öffentliche CLI verwenden und Spezialskripte als solche kennzeichnen. |
| Hilfestellungen | `--help`, `--help-all`, `--plan`, `doctor` und die generierten Referenzen funktionieren. Fehlermeldungen und Status brauchen eindeutigere Zustände; „bereit“ muss durch die tatsächliche Nutzbarkeit gedeckt sein. |
| Installierbarkeit | In einer frischen Windows-Laufzeit nachgewiesen, auch beim Wiederholen. Vollständige Neuinstallation aller Systemwerkzeuge auf einem leeren Windows-, Linux- oder macOS-Rechner wurde nicht durchgeführt. |
| Einfachheit | Der erste Aufruf ist einfach. Viele Begleitdateien und Stufenzustände erhöhen die spätere Orientierungslast. Eine brauchbare `status`-Übersicht hilft mehr als weitere Schalter. |
| Performance | Wiederaufnahme ist wirkungsvoll. Beim kurzen Clip dominieren Initialisierung und Modellaufruf. Der ausführliche Bericht benötigt selbst für drei Sätze 8'620 Eingabetokens. Ein zum Inhalt passender Kurzbericht-Modus und wiederaufnehmbare einzelne Cloud-Audio-Chunks sind sinnvolle nächste Optimierungen. |
| Parameter und Geheimnisse | Die zentralen Definitionen, Vorrangregeln, maskierte Ausgabe und geschützte Konfigurationsdateien sind gut; die bestehenden Tests prüfen diese Verträge. Die frisch geschriebene Windows-Datei bestand den ACL-Check. Das ist keine Prüfung organisationsspezifischer Geheimnisverwaltung oder sämtlicher Berechtigungsgruppen. |

## SBB-Spiegel: aktueller Stand und Grenzen

Ziel: `ssh://git@codessh.sbb.ch:7999/am_dfa/transcribe.git`, Branch `master`. Live abgefragt wurden `master` und `v1.83.500`; beide entsprechen dem lokalen Split `96b5190`. Dessen Tree ist `1decc1d3be0d0d2bc079067a3c7b52eeec6dc584`, identisch mit `74d1848:.agents/skills/transcribe`.

Der erste Versuch mit OpenSSH wurde abgewiesen. Die Abfrage mit dem am Arbeitsplatz konfigurierten PuTTY/Plink-Client funktionierte. Daraus folgt kein allgemeiner VPN-Ausfall. Die Fehlerszenarien für Tags und zusätzliche Push-Zuordnungen wurden ausschliesslich gegen neu angelegte lokale Bare-Repositories ausgeführt.

## Reproduktion und empfohlene Reihenfolge

Die [gezielten Laufzeitproben](transcribe-1.83.500/probes.py) und [Spiegelproben](transcribe-1.83.500/mirror_probe.py) sind mit diesem Bericht abgelegt. Sie benötigen den geprüften Toolbox-Checkout; die Spiegelprobe verwendet den Git-Bash-Pfad dieses Windows-Arbeitsplatzes. Sie erzeugen isolierte temporäre Verzeichnisse und geben Beobachtungen als JSON aus. Ihr Exit 0 bedeutet, dass die Diagnose ausgeführt wurde, nicht dass die untersuchte Eigenschaft korrekt ist.

Aus dem Toolbox-Root:

```text
python -X utf8 -B -m unittest discover -s .agents/skills/transcribe/tests -v
python -X utf8 -B docs/reviews/transcribe-1.83.500/probes.py .agents/skills/transcribe
python -X utf8 -B docs/reviews/transcribe-1.83.500/mirror_probe.py .
```

1. Die reproduzierten P1-Fälle beheben und als verpflichtende Regressionstests übernehmen. Markerprüfung, OCR-Abhängigkeit und Sprecheridentität sind inhaltliche Korrektheit, nicht Komfort.
2. Den Release-Befehl absichern: explizite Ref-Specs, korrekte Tags, erfolgreiche Tests und identische Artefakte vor dem Push.
3. Den bestehenden Ablauf schrittweise in klar abgegrenzte Stufen aufteilen. Dabei die bestehende CLI und die Wiederaufnahmeverträge als stabile Grenze behandeln.
4. Danach Bedienung und Performance verbessern: aussagekräftiger Status, vollständige Parameterhilfe, Video-Abnahmeprofil, knappe Berichte für kurze Inhalte und Cache pro Cloud-Audio-Chunk.

Offen bleiben ein breiter Benchmark mit langen Meetings, Sprecherwechseln und schwieriger Tonqualität, echte Bildanalyse/Illustrationen im Modelllauf sowie eine Neuinstallation auf Linux/macOS. Ein echter Confluence-Publish wurde nicht ausgeführt.
