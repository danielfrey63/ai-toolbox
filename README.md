# AI-Toolbox

Persönliches Werkzeug-Repository: ein Katalog aus Skills, Git-Hooks, Plugins und
Konfiguration, der sich mit *einem* Befehl in eine Claude-Code- / Codex- /
agentskills-Umgebung installieren lässt — plus ein generisches
Versionierungs-System für alle Artefakte.

## Schnellstart

```bash
git clone https://github.com/danielfrey63/ai-toolbox.git
cd ai-toolbox
./toolbox.sh install --what cli      # macht `toolbox` systemweit verfügbar
```

Danach steht der Befehl `toolbox` überall zur Verfügung:

```bash
toolbox list                                       # was ist installierbar?
toolbox validate                                    # stimmt der Katalog noch mit der Platte überein?
toolbox install --what discover --target claude
toolbox install --what versioning-hooks --scope project
toolbox status --all                                # was ist wo installiert?
toolbox reconcile                                   # bestehende Links finden + nachtragen
```

- **Linux/macOS:** `./toolbox.sh` legt einen Symlink `~/.local/bin/toolbox` an —
  dieses Verzeichnis muss im `PATH` sein.
- **Windows (PowerShell):** `./toolbox.ps1 install --what cli` trägt eine
  `toolbox`-Funktion ins `$PROFILE` ein.

## Die `toolbox`-CLI

`toolbox <install|status|remove|list|reconcile|validate>` installiert, prüft und
entfernt Einträge aus dem Katalog `tools/catalog.json`. Jeder Eintrag hat einen
Typ, der den Install-Handler bestimmt:

| Typ | Was es macht |
|---|---|
| `skill`  | Skill-Verzeichnis nach `~/.{claude,codex,agents}/skills/` verlinken |
| `hook`   | eine markierte Shim-Zeile in `pre-commit`/`post-commit` eines Repos einfügen (ruft den `toolbox-bump`-Launcher) |
| `plugin` | echtes `claude plugin`-Install (Target `claude`), sonst Skill-Link |
| `config` | globale Konfig-Datei (`CLAUDE.md`) nach `~/.claude/` verlinken |
| `bin`    | einen CLI-Befehl systemweit verfügbar machen — exec (Symlink in `~/.local/bin` / `&` in `$PROFILE`) oder sourced (Funktion in `~/.bashrc` / `.` in `$PROFILE`, Katalog `source: true` — z.B. für env-setzende Tools wie `cc-profil`) |

`reconcile` durchsucht die globalen Link-Ziele (Skills-Verzeichnisse je Target,
`~/.claude`, `~/.local/bin`) nach Symlinks, die in dieses Repo zeigen, und trägt
fehlende in die Registry nach — so werden auch von Hand (ausserhalb von
`toolbox install`) angelegte Links von `status`/`remove` erfasst. Projekt-weite
Installs (Hooks, Repo-Skills) findet der globale Scan nicht — die stellt man per
`install … --scope project --project <repo>` wieder her.

`validate` ist ein reiner Lese-Check des Katalogs gegen die Platte (kein `--target`/`--scope` nötig): jeder Eintrag muss auf einen existierenden Pfad zeigen, `skill`/`plugin`-Verzeichnisse brauchen ein `SKILL.md` mit gültigem `name`/`description`-Frontmatter, `bin`-Einträge brauchen ein `command`-Feld und (bei `.sh`-Pfaden) ein `.ps1`-Gegenstück. Exit-Code 1 bei mindestens einem Fehler. Der `pre-commit`-Hook führt den Check automatisch aus, sobald ein Commit in der Toolbox `tools/catalog.json` oder eine `SKILL.md` berührt — kaputte Katalog-Stände kommen so gar nicht erst in die History.

`tests/parity.sh` hält die beiden handgepflegten CLI-Ports synchron: der Harness fährt `validate` (sauberes + absichtlich kaputtes Fixture) und `list` durch `toolbox.sh` **und** `toolbox.ps1` in Wegwerf-Sandboxes und vergleicht Exit-Codes, Status-Zeilen und Fehler-Zähler. Mit `--lint` laufen zusätzlich shellcheck/PSScriptAnalyzer (informativ), sofern installiert.

Vollständige Referenz: `toolbox --help`. Alle Befehle sind idempotent — beliebig oft ausführbar, ohne Schaden.

## Versionierung

Jedes Artefakt trägt eine `APP_VERSION` (`MAJOR.MINOR.BUILD`):

- **pro Edit** erhöht ein PostToolUse-Hook den BUILD,
- **pro Commit** erhöhen die Git-Hooks MINOR + BUILD und setzen einen
  Versions-Tag.

In einem beliebigen Repo aktivieren:

```bash
toolbox install --what versioning-hooks --scope project
```

`tools/bump-version.{sh,ps1}` ist der generische Bumper dahinter — er erkennt
Skills, Agents, Scripts, Plugins und `CLAUDE.md`.

### Wie der Hook im Repo aussieht

`toolbox install` schreibt **keine** `core.hooksPath`-Umleitung mehr, sondern eine
einzelne, markierte Shim-Zeile in die `pre-commit`/`post-commit` des aktiven
Hook-Verzeichnisses (`.git/hooks` bzw. ein vorhandenes `core.hooksPath`-Ziel):

```sh
toolbox-bump pre-commit   # ai-toolbox:versioning-hooks (managed - do not edit)
```

Das ist **pfadfrei** und damit portabel: `toolbox-bump` ist ein winziger Launcher
in `~/.local/bin` (von `toolbox install` pro Maschine erzeugt), der auf die
*lokale* Toolbox zeigt. `~/.local/bin` liegt auf dem PATH von Gits `sh` (Linux
wie Windows-git-bash). Bestehende Hooks im selben File bleiben unangetastet —
entfernt/aktualisiert wird nur die markierte Zeile. Die eigentliche Bump-Logik
liegt zentral in der Toolbox; ein `git pull` dort propagiert Verbesserungen an
alle Repos automatisch.

### Migration bestehender Installs (z.B. auf anderen Maschinen)

Frühere Versionen schrieben entweder `core.hooksPath` aufs Toolbox-Verzeichnis
oder eine Shim-Zeile mit hartem Pfad. Nach einem `git pull` der Toolbox:

1. `toolbox status` markiert betroffene Repos mit `[! ] … (old shim path …)` bzw.
   `(legacy core.hooksPath …)` — „re-install to migrate".
2. Pro markiertem Repo neu installieren (idempotent; legt die Launcher an und
   ersetzt nur die markierte Zeile):

   ```bash
   toolbox install --what versioning-hooks --scope project --project <repo>
   ```

Hängt das Repo an `--target claude`, dieselbe Flag mitgeben. `~/.local/bin` muss
auf dem `sh`-PATH liegen (sonst weist der Install darauf hin).

## Registry

Jeder Install wird in `~/.config/ai-toolbox/installs.json` (pro Maschine)
vermerkt — ein reiner Discovery-Index, damit auch projektspezifische Installs
wiederauffindbar sind:

```bash
toolbox status --all     # jeden erfassten Install prüfen, tote Einträge ausräumen
toolbox remove --all     # alles Installierte wieder entfernen
```

Vor jeder Aktion wird gegen die Realität verifiziert — der Index kann nicht
gefährlich driften, und `status --all` heilt ihn.

## `aiprofil` — Backend-Profile für Claude Code & Kilo

Schaltet zwischen benannten Backend-Profilen um — API-Key, Foundry-Endpoint, Modell-Defaults, Git-Identität, …. Jedes Profil ist eine `.env`-Datei unter `aiprofil/profiles/`; `aiprofil use <profil> [--target cc|kilo|both] [--scope session|user|project]` projiziert es über die Adapter `cc-profil` (env-Vars für Claude Code) und `kilo-profil` (`kilo.jsonc`) auf die Ziele, `aiprofil list` zeigt Profile plus aktiven Zustand, `aiprofil status` was jedes Ziel gerade verwendet.

Einmalig installieren (legt die sourcing-Funktion in `~/.bashrc` bzw. PowerShell-`$PROFILE` an):

```bash
toolbox install --what aiprofil
# danach in einer neuen Shell oder nach `source ~/.bashrc`:
aiprofil list
aiprofil use <name>
```

Die echten `.env`-Dateien enthalten Live-Schlüssel und sind **gitignored**; nur `*.env.example`-Vorlagen und `.managed-vars` sind versioniert. Das Top-Level-Verzeichnis `cc-profil/` enthält nur noch Deprecation-Shims, die alte `~/.bashrc`-Verdrahtungen auf `aiprofil/adapters/` weiterleiten.

## Repo-Aufbau

```
ai-toolbox/
├── toolbox.sh / toolbox.ps1     ← die CLI (bash + PowerShell)
├── CLAUDE.md                    ← globale Claude-Konfiguration
├── .agents/skills/              ← integrierte Skills (component-audit, discover, fable-mode, transcribe, …)
├── aiprofil/                    ← Backend-Profil-Switcher (Claude Code + Kilo)
│   ├── aiprofil.sh / .ps1
│   ├── adapters/                ← cc-profil, kilo-profil
│   └── profiles/                ← *.env.example getrackt, echte *.env lokal
├── cc-profil/                   ← Deprecation-Shims (alter cc-profil-Pfad)
├── tests/
│   └── parity.sh                ← Parity-Harness toolbox.sh ↔ toolbox.ps1
└── tools/
    ├── catalog.json             ← der Tool-Katalog
    ├── bump-version.{sh,ps1}    ← Versions-Bumper
    └── githooks/                ← pre-commit / post-commit
```

Jedes Skript gibt es in bash **und** PowerShell — Linux/macOS wie Windows.
