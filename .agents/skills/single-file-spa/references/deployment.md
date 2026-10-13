# Betrieb – Working-Machine, Container, Deploy, Daten-Pipeline

Die App bleibt eine Datei, die auch per `file://` läuft. Soll sie zusätzlich im Netz erreichbar sein, liefert sie ein nginx-Container auf der Working-Machine aus, Pangolin macht sie mit SSO öffentlich. rain und avers haben dafür dieselbe Form; das Original stammt aus nem-wochenplan.

## Inhalt

- [Bausteine](#bausteine)
- [server/ – Image, nginx, Quadlet](#server--image-nginx-quadlet)
- [tools/ – Host, Deploy, Route](#tools--host-deploy-route)
- [Daten-Pipeline (rain)](#daten-pipeline-rain)

## Bausteine

| Datei | Aufgabe |
|---|---|
| `server/Containerfile` | nginx:alpine, Conf und (ohne Pipeline) `index.html` ins Image |
| `server/nginx-<app>.conf` | nur `/` und `/index.html` ausliefern, nie aus dem Cache |
| `server/<app>-web.container` | Quadlet: Image, `PublishPort=127.0.0.1:<port>:80`, Restart |
| `tools/lib.sh` | gemeinsame Einstellungen (Host, SSH-Port, Podman-User, Web-Port), `remote()` |
| `tools/setup-host.sh` | einmalig: Build-Clone von Forgejo, Quadlet installieren |
| `tools/deploy.sh [--check\|--force\|--allow-dirty]` | Tests → Image → Neustart → servierte Version prüfen |
| `tools/setup-route.sh [--check]` | Pangolin-Resource mit SSO, läuft lokal über einen eigenen Tunnel |

Alle Skripte sind Desired-State: jeder Schritt prüft vor dem Handeln, ein zweiter Lauf meldet «vorhanden» bzw. «nichts zu tun» und ändert nichts. Ports werden zentral vergeben; die Belegung steht im Quadlet-Kommentar und im Projekt-`CLAUDE.md` (rain 8105, avers 8106).

## server/ – Image, nginx, Quadlet

- **Ohne Pipeline (avers):** `index.html` liegt im Image, nichts wird zur Laufzeit geschrieben. Deploy = Image-Tausch, Rollback = älteres Image. Kein Volume, kein Timer.
- **Mit Pipeline (rain):** `index.html` ist nicht im Image; nginx liefert ein Volume (`<app>-site`) aus, das der Pipeline-Lauf füllt.
- nginx-Conf: `Cache-Control: no-cache, must-revalidate` auf `/` und `/index.html` – ein Deploy, den der Browser nicht sieht, zeigt veraltete Werte. `location = /` mit `try_files /index.html =404`, alles andere 404 (Hash-Routen brauchen keine Pfade). Dazu `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, gzip für `text/html`. Statische Nachlade-Daten (Kacheln) als eigene `location` mit langem Cache.
- Image mit `--label "<app>.commit=<sha>"` bauen – daran erkennt der Deploy, ob neu gebaut werden muss.

## tools/ – Host, Deploy, Route

- **lib.sh:** Host, Port und User per Umgebungsvariable überschreibbar (`<APP>_DEPLOY_HOST`, …). SSH mit `-F /dev/null` (unter Windows OpenSSH `NUL`) und `BatchMode=yes`, damit es aus jeder Shell gleich läuft. Remote-Teil als Heredoc über `sudo -u <podman-user> bash -s`.
- **Code-Weg:** Der Build-Clone auf dem Host zieht von Forgejo (`forgejo`-Remote). Jeder Push muss auch dorthin, sonst bricht der Deploy ab («Build-Clone steht auf X, nicht auf Y»).
- **deploy.sh:**
  1. Abbruch bei schmutzigem Working Tree (ausser `--allow-dirty`) – gebaut wird nur, was committet ist.
  2. `APP_VERSION` aus der committeten `index.html` lesen.
  3. Tests lokal; rot → kein Deploy. Mit Coverage-Tooling läuft der Deploy über `tools/coverage.js` (rain), damit die Coverage nach jedem Release aktuell ist.
  4. Remote: Build-Clone auf den Commit setzen; nur wenn Label, Service-Status oder servierte Version abweichen (oder `--force`), Image bauen und Service neu starten.
  5. **Beweis:** per `curl` auf `127.0.0.1:<port>` die `APP_VERSION` aus der ausgelieferten Seite lesen und mit dem Checkout vergleichen. Erst danach verwaiste Images aufräumen.
  `--check` zeigt nur den Zustand (Label, Service, servierte Version, Build-Clone).
- **setup-route.sh:** Die Pangolin-Resource steht als Skript im Repo, nicht nur in der Pangolin-Datenbank – nach einem Wipe ist sonst unklar, worauf sie zeigte. Läuft lokal, öffnet einen eigenen Tunnel zur Pangolin-VM (Pageant + plink unter Windows, ssh-agent sonst), pinnt den Host-Key aus `known_hosts`, liest den API-Key aus dem lokalen `server-landscape`-Checkout und schliesst den Tunnel wieder.

## Daten-Pipeline (rain)

Wenn die App von regelmässig neuen Daten lebt:

- `pipeline/` mit einem Adapter pro Quelle (`pipeline/adapters/`) und gemeinsamen Helfern (`pipeline/lib/`); `node pipeline/run.js` holt, normalisiert, archiviert und exportiert. Status pro Quelle in einer JSON-Datei.
- Datenablage trennen: `data/archive/` (versioniertes Archiv, Quelle der Wahrheit), `data/app/` (Export, den `assemble.js` inlined), `data/cache/` (Roh-Downloads, nicht versioniert).
- Die Pipeline darf Runtime-Dependencies haben (`npm ci --omit=dev`), das Deliverable nicht.
- **Auf dem Server:** ein systemd-Timer startet einen `node:22-alpine`-Container mit dem Build-Clone read-only (`/src`), einem State-Volume (`/state`, Archiv und Export) und dem Site-Volume (`/site`). Der Lauf ruft `build.js` mit `RAIN_STATE=/state` und `RAIN_OUT=/site/index.html`. Beim ersten Lauf wird das Archiv aus dem Repo übernommen, danach führt der Server sein eigenes. Runtime-Dependencies landen einmal pro Lockfile-Hash im State-Volume.
- **Backup-Weg:** eine tägliche GitHub Action fährt Pipeline und Build und committet Daten und `index.html`.
