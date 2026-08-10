Verbesserungsvorschläge aus dem Run (zwei echte Stolperer, beide behoben, aber skript-seitig vermeidbar):

1. ✅ **Erledigt** (Commit `8a5cbd4`, transcribe v1.29.131) — NFD-Dateinamen (run.py, Local-File-Auflösung): `resolve_source_path()` in download.py probiert jetzt NFC und NFD und scannt als Fallback das Elternverzeichnis NFC-gefaltet; run.py nutzt dieselbe Auflösung für den `.md`-Zielpfad.
2. ✅ **Erledigt** (Commit `bb19894`, transcribe v1.30.132) — Venv-ABI-Check (setup.py --check/--venv): `venv_status()` fragt das Venv-Python nach seiner echten Version (ein schneller `-I -c`-Spawn, gecacht) und vergleicht sie mit dem Marker-Pin und dem numpy-Wheel-ABI-Tag; `cmd_provision_venv()` erzwingt bei Runtime/ABI-Drift einen kompletten Rebuild statt eines No-op-pip-installs.

Diese Datei kann gelöscht werden, sobald du das Resultat geprüft hast.
