# Setup und Preflight

Die verbindliche Anleitung ist [INSTALL.md](../INSTALL.md). Parameter, Defaults und Vorrang stehen in der generierten [Parameterreferenz](parameters.md).

## Legacy-Einstiege

| Aufruf | Bedeutung |
|---|---|
| `python scripts/setup.py --check` | Allgemeiner Preflight: 0 bereit, 2 Werkzeuge fehlen, 3 Transkriptionsweg fehlt, 4 beides fehlt |
| `python scripts/setup.py --json` | Strukturierter allgemeiner Preflight |
| `python scripts/setup.py --non-interactive` | Installation ohne Eingabedialog |
| `python scripts/setup.py --venv` | Verwaltete ML-Laufzeit herstellen oder reparieren |
| `python scripts/setup.py --install-binaries --force` | Standalone-Werkzeuge erneuern, etwa bei veraltetem yt-dlp |

Für neue Automatisierungen die profilbezogenen Befehle `transcribe.py doctor` und `install` verwenden. Ein allgemeiner Legacy-Check kann bei konfiguriertem Cloud-Backend erfolgreich sein, obwohl der lokale Venv fehlt.

## Download-Probleme

Veraltetes yt-dlp oder fehlendes deno kann YouTube-Downloads verhindern. Bei einem entsprechenden Fehler die Standalone-Werkzeuge einmal aktualisieren und erneut versuchen. Bei DRM-, Login- oder Regionsbeschränkungen den konkreten Fehler melden, nicht endlos wiederholen.

## Laufzeit

`uv` provisioniert eine verwaltete Python-Version und den ML-Venv. Ein fehlender Basisinterpreter oder ABI-Konflikt macht den Venv nicht bereit; `--venv` repariert den Zustand. Der Host-Interpreter bleibt unverändert.
