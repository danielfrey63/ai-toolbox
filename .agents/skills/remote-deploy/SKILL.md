---
name: remote-deploy
description: "Deploy auf Legacy-Server über SSH mit Offline-Vendoring, Patch-Dateien, funktionaler Verifikation und Rollback. Verwenden wenn: auf einen alten Server ohne PyPI/Internet deployt wird («PyPI ist tot», Python 2, alte OS), Änderungen an Remote-Dateien anstehen («patch statt sed»), ein Dienst nach Restart nicht hochkommt, oder ein Deploy verifiziert/zurückgerollt werden muss — typisch server-landscape/04-openerp (OpenERP/Pentaho), generell jede SSH-Zielmaschine ohne moderne Toolchain."
user-invocable: true
allowed-tools: Bash, PowerShell, Read, Write, Edit, Grep
metadata:
  version: "0.0.1"
---

# /remote-deploy — Legacy-Server-Deploy mit Verify & Rollback

Kodifiziert den in den OpenERP/Pentaho-Sessions dutzendfach durchlaufenen Zyklus: Vendoring → Transport → Patch → Restart → Verify → (Rollback). Jeder Schritt idempotent, jeder Schritt verifiziert — nie «deploy and pray».

## 1. Dependencies offline vendoren

Der Zielserver hat kein (funktionierendes) PyPI/Repo. Deshalb lokal bauen, als Tarball transportieren:

- Ziel-Interpreter exakt treffen (z.B. Python 2.7): Versionen pinnen, die es für den Ziel-Interpreter noch gibt (`PyPDF2==1.26.0` statt aktuell). Bei C-Extensions auf der Zielplattform bauen oder reine Wheels/sdists wählen.
- Tarball-Struktur: `vendor/` mit entpackbaren Paketen + `install.sh`, das per `--no-index --find-links` bzw. direktem `setup.py install` installiert. API-Brüche alter Libs per Shim lösen (z.B. `tostring`→`tobytes` für reportlab/Pillow), Shim gehört ins Deploy-Paket, nicht als Handedit auf dem Server.

## 2. Änderungen NUR als Patch-Datei

Nie In-place-`sed` auf Remote-Dateien. Stattdessen:

```bash
diff -u original.py geaendert.py > fix-beschreibung.patch     # lokal erzeugen
scp fix-beschreibung.patch host:/tmp/
ssh host 'cp /pfad/core.py /pfad/core.py.bak-$(date +%Y%m%d) && patch -p0 --dry-run < /tmp/fix.patch && patch -p0 < /tmp/fix.patch'
```

- `--dry-run` zuerst; schlägt er fehl, ist der Remote-Stand nicht der erwartete → erst Ist-Stand holen und Patch neu basieren.
- Backup mit Datum VOR jedem Apply. Backups bleiben liegen, bis der User den Erfolg bestätigt.
- Patch-Dateien im Repo versionieren (`<modul>/migration/*.patch`) — sie SIND die Deploy-Doku.

## 3. Dienst restarten — Init-System zuerst ermitteln

«unrecognized service» kostet Runden. Vor dem ersten Restart einmalig feststellen und merken:

```bash
ssh host 'command -v systemctl && systemctl list-units --type=service | grep -i <name>; ls /etc/init.d/ | grep -i <name>'
```

Dann konsequent den gefundenen Weg nutzen (`service X restart` / `/etc/init.d/X restart` / `systemctl restart X`). Bei Applikationsservern (Tomcat) beachten: Caches können alte Artefakte halten — Cache-Verzeichnis (`work/`) leeren gehört zum Restart, wenn sich Ressourcen (Reports, Fonts, JARs) geändert haben.

## 4. Funktional verifizieren, nicht Exit-Code

Der Deploy ist erst fertig, wenn sich das VERHALTEN nachweislich geändert hat:

- Artefakt-Diff: Ergebnis-Datei (PDF, Report) vor/nach Deploy per `md5sum`/Byte-Vergleich — byte-gleiches Resultat nach angeblichem Fix = Deploy hat nicht gegriffen (falscher Pfad, Cache, alter Prozess).
- Log-Probe: `tail -f` bzw. `grep` auf das Dienst-Log während eines Test-Requests; Fehler-Pattern explizit prüfen (`Traceback`, `ERROR`, HTTP 500).
- End-to-End-Probe des eigentlichen Use-Case (Rechnung generieren, Login, …), nicht nur «Dienst läuft».

## 5. Rollback

Bei 500er/Parse-Fehler/Regressionsbefund: Backup zurückkopieren, Dienst restarten, Funktions-Probe wiederholen («es tut nach dem Rollback wieder» ist das Erfolgskriterium). Erst danach Ursache analysieren — Verfügbarkeit vor Diagnose.

## Abgrenzung

`idempotent-devops` baut idempotente Setup-Skripte für eigene Maschinen; dieser Skill deckt den Remote-Zyklus auf fremden/alten Zielsystemen ab. Für die SSH-Verbindungsdiagnose selbst: `/tunnel-connect`.
