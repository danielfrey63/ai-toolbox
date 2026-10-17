# Setup und Preflight

Die verbindliche Anleitung ist [INSTALL.md](../INSTALL.md). Parameter, Defaults und Vorrang stehen in der generierten [Parameterreferenz](parameters.md).

## Legacy-Einstiege

| Aufruf | Bedeutung |
|---|---|
| `python scripts/setup.py --check` | Allgemeiner Preflight: 0 bereit, 2 Werkzeuge fehlen, 3 Transkriptionsweg fehlt, 4 beides fehlt |
| `python scripts/setup.py --json` | Strukturierter allgemeiner Preflight |
| `python scripts/setup.py --non-interactive` | Installation ohne Eingabedialog |
| `python scripts/setup.py --venv` | Verwaltete Whisper-Laufzeit herstellen oder reparieren |
| `python scripts/setup.py --speakers-venv` | Verwaltete Sprecher-Laufzeit (pyannote, torch) herstellen oder reparieren |
| `python scripts/setup.py --install-binaries --force` | Standalone-Werkzeuge erneuern, etwa bei veraltetem yt-dlp |

Für neue Automatisierungen die profilbezogenen Befehle `transcribe.py doctor` und `install` verwenden. Ein allgemeiner Legacy-Check kann bei konfiguriertem Cloud-Backend erfolgreich sein, obwohl der lokale Venv fehlt.

## Download-Probleme

Veraltetes yt-dlp oder fehlendes deno kann YouTube-Downloads verhindern. Bei einem entsprechenden Fehler die Standalone-Werkzeuge einmal aktualisieren und erneut versuchen. Bei DRM-, Login- oder Regionsbeschränkungen den konkreten Fehler melden, nicht endlos wiederholen.

## Laufzeit

`uv` provisioniert eine verwaltete Python-Version und zwei Venvs: `venv` für faster-whisper ohne torch und `venv-speakers` für pyannote und torch. Installiert wird jeweils exakt die Lockdatei aus `requirements/`; Pakete aus älteren Ständen oder manuellen Reparaturen werden dabei entfernt. Danach läuft `scripts/runtime_check.py` auf einer synthetischen Aufnahme. Erst wenn dieser Test besteht, gilt die Laufzeit als bereit; ein Fehlschlag steht mit Ursache in `doctor`. Ein fehlender Basisinterpreter, ein ABI-Konflikt oder eine geänderte Lockdatei macht den Venv ebenfalls nicht bereit; `--venv` bzw. `--speakers-venv` repariert den Zustand, und der nächste Lauf tut das bei Bedarf selbst. Der Host-Interpreter bleibt unverändert.
