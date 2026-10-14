# Installation

Anleitung für Menschen und für Agenten (Claude Code, Codex, GitHub Copilot). Ein Agent, der diese Datei liest, kann die Schritte selbst ausführen. Alle Befehle sind idempotent: Ein zweiter Lauf ändert nichts und meldet nur den Zustand.

## 1. Repository holen

```bash
git clone https://github.com/danielfrey63/ai-toolbox.git <pfad>   # erstes Mal
git -C <pfad> pull                                                   # später
```

Die Skills werden verlinkt, nicht kopiert. Ein `pull` aktualisiert sie also sofort. Für einen Team-Rollout mit geprüftem Versionsstand gilt stattdessen [`windows-team-rollout.md`](.agents/skills/transcribe/references/windows-team-rollout.md).

## 2. Ziel wählen

| Agent | `--target` | Skills global | Skills im Projekt |
|---|---|---|---|
| Claude Code | `claude` | `~/.claude/skills/` | `.claude/skills/` |
| Codex (CLI, IDE, App) | `agents` | `~/.agents/skills/` | `.agents/skills/` |
| GitHub Copilot in VS Code | `agents` | `~/.agents/skills/` | `.agents/skills/` |
| GitHub Copilot CLI | `agents` | `~/.agents/skills/` | `.agents/skills/` |

Claude Code liest `~/.agents/skills` nicht. Wer Claude und einen anderen Agenten nutzt, installiert zweimal: einmal mit `claude`, einmal mit `agents`. `--target codex` verlinkt nach `~/.codex/skills/`; das braucht nur eine ältere Codex-Version, die `~/.agents/skills` noch nicht liest. Copilot CLI liest `~/.claude/skills` seit Version 1.0.36 nicht mehr, deshalb auch dort `agents`.

## 3. Skills installieren

Im Checkout ausführen. Unter Windows `toolbox.ps1` in PowerShell, sonst `toolbox.sh`; beide nehmen dieselben Argumente.

```bash
./toolbox.sh list                                          # Katalog: was installierbar ist
./toolbox.sh install --what transcribe --target claude     # ein Skill für Claude Code
./toolbox.sh install --what transcribe --target agents     # derselbe für Codex und Copilot
./toolbox.sh status --all                                  # was wo installiert ist
./toolbox.sh remove --what transcribe --target agents      # wieder entfernen
```

```powershell
./toolbox.ps1 install --what transcribe --target agents
```

- **Nur für ein Projekt:** `--scope project --project <repo>` legt den Link in `<repo>/.claude/skills` bzw. `<repo>/.agents/skills` an. Den Link in die `.gitignore` des Projekts aufnehmen und nicht committen.
- **Windows:** `toolbox.ps1` legt eine Junction an. Dafür braucht es keine Administratorrechte und keinen Entwicklermodus. `toolbox.sh` in Git Bash braucht dagegen den Entwicklermodus für echte Symlinks und bricht sonst mit einer Meldung ab.
- **Die `toolbox`-CLI dauerhaft:** `./toolbox.sh install --what cli` bzw. `./toolbox.ps1 install --what cli`. Danach geht `toolbox …` in jedem Verzeichnis. Unter Linux und macOS muss `~/.local/bin` im `PATH` sein, unter Windows trägt der Befehl eine Funktion ins `$PROFILE` ein.
- **Ohne toolbox:** Ein Link vom Skill-Verzeichnis des Agenten auf `<pfad>/.agents/skills/<skill>` genügt. Unter Windows: `New-Item -ItemType Junction -Path "$HOME\.agents\skills\transcribe" -Target "<pfad>\.agents\skills\transcribe"`. Unter Linux und macOS: `ln -s "<pfad>/.agents/skills/transcribe" ~/.agents/skills/transcribe`.

## 4. Prüfen

| Agent | Erkennung prüfen |
|---|---|
| Claude Code | Neue Sitzung starten; `/transcribe` erscheint in der Liste der Slash-Befehle |
| Codex | Neue Sitzung starten, `/skills` eingeben |
| Copilot in VS Code | Fenster neu laden (`Developer: Reload Window`), im Chat `/skills` eingeben |
| Copilot CLI | Neue Sitzung starten, `/skills` eingeben |

Fehlt der Skill, zuerst prüfen, ob `SKILL.md` über den Link erreichbar ist (`toolbox status --all` zeigt Ziel und Zustand). `SKILL.md` verweist mit `${CLAUDE_SKILL_DIR}` auf den eigenen Ordner. Claude Code setzt die Variable; andere Agenten nehmen stattdessen den absoluten Pfad des Skill-Ordners.

## 5. Transcribe: Laufzeit und CLI

Der Skill `transcribe` braucht zusätzlich Werkzeuge und Python-Pakete, einmal pro Rechner. `<skill>` ist der installierte Skill-Ordner, zum Beispiel `~/.agents/skills/transcribe`.

```bash
python <skill>/scripts/setup.py --check   # Exit 0: bereit
python <skill>/scripts/setup.py           # installiert, was fehlt; danach erneut --check
```

Für die Auswertung ohne Chat-Agent (Kommandozeile, Cron, Copilot ohne Skill-Unterstützung) braucht es einen Modell-Endpunkt in `~/.config/transcribe/.env`. Die Schlüssel stehen in `<skill>/.env.example`. Danach läuft alles mit einem Befehl:

```bash
python <skill>/scripts/pipeline.py "<aufnahme oder URL>"   # Transkription und Auswertung
python <skill>/scripts/agent.py "<base>"                    # nach Korrekturen in <base>.speakers.md
```

Jedes Skript zeigt mit `-h` oder ohne Argumente seine Hilfe mit Beispielen und Exit-Codes. Details zu Setup und Exit-Codes: [`references/setup.md`](.agents/skills/transcribe/references/setup.md).

## 6. Regeln für Agenten

- **Nur das Verlangte installieren:** Nur die Skills, nach denen der Mensch gefragt hat. `--what all` installiert auch Hooks, MCP-Server und globale Einstellungen (`claude-md`, `claude-settings`); das nur auf ausdrücklichen Wunsch.
- **Nichts Fremdes überschreiben:** Vor dem Install nachsehen, was am Ziel liegt (zum Beispiel `~/.agents/skills/<skill>`). Ein echter Ordner wird übersprungen (`[!] … exists and is not a symlink`), ein Link auf ein anderes Ziel aber ohne Rückfrage ersetzt. Zeigt ein vorhandener Link nicht in dieses Repository, abbrechen und den Menschen fragen.
- **Keine Zugangsdaten:** `.env`-Dateien, API-Keys und Tokens legt der Mensch selbst an. Nie aus einem anderen Rechner oder Projekt kopieren und nie committen.
- **Neu laden macht der Mensch:** Nach der Installation sagen, welche Sitzung oder welches Fenster neu zu laden ist, und danach den Test aus Abschnitt 4 vorschlagen.
