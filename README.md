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
toolbox install --what discover --target claude
toolbox install --what versioning-hooks --scope project
toolbox status --all                                # was ist wo installiert?
```

- **Linux/macOS:** `./toolbox.sh` legt einen Symlink `~/.local/bin/toolbox` an —
  dieses Verzeichnis muss im `PATH` sein.
- **Windows (PowerShell):** `./toolbox.ps1 install --what cli` trägt eine
  `toolbox`-Funktion ins `$PROFILE` ein.

## Die `toolbox`-CLI

`toolbox <install|status|clean|list>` installiert, prüft und entfernt Einträge
aus dem Katalog `tools/catalog.json`. Jeder Eintrag hat einen Typ, der den
Install-Handler bestimmt:

| Typ | Was es macht |
|---|---|
| `skill`  | Skill-Verzeichnis nach `~/.{claude,codex,agents}/skills/` verlinken |
| `hook`   | `core.hooksPath` eines Repos auf die Toolbox-Git-Hooks zeigen |
| `plugin` | echtes `claude plugin`-Install (Target `claude`), sonst Skill-Link |
| `config` | globale Konfig-Datei (`CLAUDE.md`) nach `~/.claude/` verlinken |
| `bin`    | die CLI selbst als `toolbox`-Befehl auf den `PATH` |

Vollständige Referenz: `toolbox --help`. Alle Befehle sind idempotent — beliebig
oft ausführbar, ohne Schaden.

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

## Registry

Jeder Install wird in `~/.config/ai-toolbox/installs.json` (pro Maschine)
vermerkt — ein reiner Discovery-Index, damit auch projektspezifische Installs
wiederauffindbar sind:

```bash
toolbox status --all     # jeden erfassten Install prüfen, tote Einträge ausräumen
toolbox clean --all      # alles Installierte wieder entfernen
```

Vor jeder Aktion wird gegen die Realität verifiziert — der Index kann nicht
gefährlich driften, und `status --all` heilt ihn.

## Repo-Aufbau

```
ai-toolbox/
├── toolbox.sh / toolbox.ps1   ← die CLI (bash + PowerShell)
├── CLAUDE.md                  ← globale Claude-Konfiguration
├── .agents/skills/            ← integrierte Skills (component-audit, discover, watch)
└── tools/
    ├── catalog.json           ← der Tool-Katalog
    ├── bump-version.{sh,ps1}  ← Versions-Bumper
    └── githooks/              ← pre-commit / post-commit
```

Jedes Skript gibt es in bash **und** PowerShell — Linux/macOS wie Windows.
