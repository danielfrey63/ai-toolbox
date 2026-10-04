# Claude Code – Globale Konfiguration

## Sprache und Stil

Zwei strikt getrennte Sprach-Domänen:

- **Englisch – Code & Commits.** Jegliche Skripte, Quellcode, Programmierung, Kommentare *im Code* und Commit-Messages sind **immer** auf Englisch. Ausnahmslos, in allen Repos.
- **Deutsch (Schweiz) – Kommunikation.** Konversation, Zusammenfassungen und Markdown-Dateien, die dem Austausch zwischen Mensch und Maschine dienen (Hand-offs, Notizen, Pläne, CLAUDE.md, …), sind auf Deutsch.
- **Umlaute & ss.** Wo Deutsch geschrieben wird: IMMER echte Umlaute (ä, ö, ü, é) und `ss` statt `ß` – NIEMALS `ae`, `oe`, `ue` als Ersatz.
- **Gedankenstrich: immer der deutsche Halbgeviertstrich `–` (U+2013), mit Leerzeichen davor und danach.** NIE der amerikanische Geviertstrich `—` (U+2014), der doppelt so lang ist. Gilt für alles, was ich schreibe: Konversation, Markdown, Code-Kommentare, Commit-Messages, auch in englischem Text. Beim Editieren bestehender Dateien betroffene Absätze gleich mit umstellen. Für Nachrichtenentwürfe in Daniels Namen gilt zusätzlich der Schreibstil unten: dort möglichst gar kein Gedankenstrich.
- **Markdown: ein Absatz = eine Zeile.** Keine Pseudosatz-/Spiegel-Umbrüche (hard wraps) innerhalb von Absätzen oder Listenpunkten. Zeilenumbrüche nur an echten Struktur-Grenzen (Absatz, Listenpunkt, Überschrift, Tabellenzeile, Code-Zeile). Gilt für alle neu geschriebenen oder umgeschriebenen Markdown-Dateien; beim Editieren bestehender Dateien betroffene Absätze auf Einzeiler zusammenziehen.

### Schreibstil für Nachrichtenentwürfe in Daniels Namen

Sobald ein Text **in Daniels Namen** entworfen wird (Chat, Mail, Teams) – in jedem Projekt und jeder Session – gilt verbindlich der nachfolgend importierte Schreibstil (`schreibstil.md`, neben dieser CLAUDE.md im ai-toolbox-Repo): maximal kurz, dialogisch, per Du, Konjunktiv für Vorschläge, kein Briefing-Ton.

@schreibstil.md

## Umgebungen

### Linux (primär)

- **Shell:** Bash.
- **Kommando-Trennung:** `&&` für bedingte Verkettung, `;` nur für unkonditionierte Trennung.
- **SSH:** Desktop-Keyring-Agent (gcr) – die bashrc setzt `SSH_AUTH_SOCK` auf `$XDG_RUNTIME_DIR/gcr/ssh`, ein Agent für die ganze Login-Session (Keys einmalig per `ssh-add ~/.ssh/id_rsa` laden bzw. beim Login entsperren). Eigener `ssh-agent` nur als Fallback ohne Desktop (TTY/SSH-Login).

### Windows-Devbox (PowerShell + WSL)

- **PowerShell:** Kommando-Trennung mit `;`. Bedingte Verkettung mit `&&` / `||`. Beispiel: `$env:VAR="wert"; bash script.sh`.
- **Bash unter WSL:** wie Linux oben.
- **SSH-Setup je nach Shell:**
  - **PowerShell:** Pageant (PuTTY Agent) + Plink – funktioniert direkt.
  - **WSL/Bash:** Lokaler `ssh-agent` (Pageant funktioniert dort NICHT); SSH-Keys nach `~/.ssh/` kopieren.

## Arbeitsprinzipien

- **Automatisierungs-Priorität: Skript → LLM → Human.** Was deterministisch berechenbar ist, gehört in ein Skript (Code, CLI, Build-Step). LLM-Calls nur für genuin kreative/analytische Aufgaben, die sich nicht in Regeln fassen lassen. Human in the Loop bleibt als Qualitäts-Gate für Freigaben und Reviews. Reihenfolge ist verbindlich – kein LLM-Call, wenn ein Skript reicht; keine Rückfrage an den User, wenn ein LLM zuverlässig entscheiden kann.
- **Bei Unsicherheit fragen.** Lieber eine kurze Rückfrage als eine falsche Annahme – besonders bei Scope, Pfaden, destruktiven Aktionen und Architektur-Entscheidungen.
- **Keine Duplikation.** Vor neuem Code prüfen, ob Konstante/Helfer/Klasse/Pattern bereits existiert. Wenn die bestehende Lösung nicht exakt passt: leicht abstrahieren und wiederverwenden statt kopieren und anpassen.
- **Desired-State / Idempotenz.** ALLE Skripte (Setup, Build, Deploy, Migration, Cleanup, …) müssen beliebig oft ausführbar sein, ohne Seiteneffekte oder Fehler zu produzieren. Mutationen erfolgen nur, wenn der Zielzustand vom Ist-Zustand abweicht – vor jedem Schritt prüfen statt blind ausführen. Re-Runs nach Abbruch oder Teilerfolg dürfen nie schaden.
- **Code-Änderungen mit Write/Edit, nie per Bash-Heredoc.** Quellcode und Konfigdateien werden mit den Datei-Tools (Write, Edit) geschrieben oder gepatcht. Bash-Heredocs (`python - <<'EOF'`, `cat <<EOF`) sind nur für Wegwerf-Skripte ohne Escape-Sequenzen geeignet: Der Tool-Transport wandelt Sequenzen wie `\x00`, `\x11` oder `\n` in echte Bytes um, was in Python-Quelltext zu Null-Bytes, Steuerzeichen und zerrissenen String-Literalen führt (Diss-Erigeron-Export, 12.09.2026: drei Reparaturrunden, und dieser Absatz selbst wurde beim ersten Versuch per Heredoc genauso zerlegt).
- **Verbesserungs-Loop nach jedem Run.** Nach jeder Ausführung eines Skills, MCP-Servers oder Skripts werden aus den gemachten Erfahrungen automatisch konkrete Verbesserungsvorschläge generiert – Reibung, Fehlerfälle, Edge-Cases, Effizienz-Gewinne, Bugs, missverständliche Defaults, fehlende Idempotenz, schlechte Help-Texte. Jeder Vorschlag mit Zielort (welches Skript/welche Skill-Definition/welcher Tool-Code), kurzer Begründung, und falls möglich konkretem Diff/Patch-Vorschlag. Ausgabe direkt im Anschluss an den Run, nicht erst auf Nachfrage.

## Git-Workflows

### Querliegende Prinzipien

- **Trunk-Based Development.** Alle Änderungen laufen direkt auf `main` (bzw. dem Default-Branch) – keine Long-Running-Feature-Branches. Verbindlicher Ablauf für jede Änderung: **Pull → Read → Changes → Commit → Push.** `pull` zuerst, damit lokal mit dem Remote synchron ist. `read` heisst aktuellen Stand der betroffenen Dateien sichten (kein Blind-Edit auf Annahmen). Erst dann `changes` machen, sofort danach `commit` mit aussagekräftiger Message, abschliessend `push`. Niemals länger als nötig uncommittet liegen lassen. **Schnitt-Kriterium innerhalb einer Session:** committet wird, sobald eine Datei in einem Zustand ist, den du nicht verlieren möchtest – nicht erst, wenn das Thema fertig ist. Eine noch laufende Analyse, ein offener Klärungspunkt oder ein erwarteter Folge-Edit sind kein Grund, Zwischenstände liegen zu lassen.
- **Investigation vor Aktion.** Bei jedem nicht-trivialen Zustand zuerst `git status`, `git diff --stat` und `git log HEAD..@{u} --stat` lesen, bevor etwas gestasht oder zurückgesetzt wird.
- **Vor dem Commit:** `git diff` zeigt nur Gewolltes, `git log -5 --format="%s"` gibt den Message-Stil des Repos vor. **Vor dem Push:** Working Tree clean, `git log @{u}..HEAD` zeigt nur gewollte Commits.
- **Backups so lange wie möglich behalten.** Ein Stash bleibt liegen, bis der User das Resultat bestätigt hat. Vor einem History-Rewrite (z.B. `git filter-repo`) betroffene Dateien nach `/tmp/git-backup/` bzw. `$env:TEMP\git-backup\` kopieren und erst nach Bestätigung löschen.
- **Mehrere Entscheidungen bündeln:** `AskUserQuestion` mit max. 4 Fragen pro Runde.

### Pull blockiert durch lokale Änderungen

`investigate → stash push -m "<name>" → pull → stash pop → Konflikte einzeln lösen → commit → push`. Bei einem Pop-Konflikt nie sofort `git reset --hard`, erst analysieren.

### Upstream hat restrukturiert

1. Upstream-Commits durchgehen: Renames erscheinen in `git log HEAD..@{u} --stat` als `old/path => new/path`, dazu gelöschte Dateien und verschobene Submodule.
2. Jede lokale Änderung zuordnen: «upstream schon enthalten», «upstream-redundant, verwerfen» oder «noch nicht upstream, integrieren».
3. Entscheidung pro Gruppe beim User einholen.
4. Stash → Pull → bei Pop-Konflikt `git reset --hard HEAD` und `git checkout stash@{0} -- <pfade>` für die zu behaltenden Dateien → commit → push.
5. Danach prüfen: `ls` gegen `git ls-tree HEAD --name-only` (leere Reste alter Pfade), `git ls-files --others --exclude-standard`, `git status --ignored -s`, `git submodule status`.

### Anti-Patterns

- `git stash drop` direkt nach erfolgreichem Pop – kein Backup mehr, falls später etwas fehlt.
- `git checkout --ours/--theirs` bei Stash-Pop, ohne die Seiten zu kennen: Dort ist «ours» = HEAD/Upstream und «theirs» = Stash, invers zum Merge.
- `git pull --rebase` ohne Investigation, wenn lokale Commits nicht im Remote sind – versteckt Konflikte hinter der Rebase-Mechanik.
- `--force` oder `--force-with-lease` ohne explizite User-Freigabe.

## Deaktivierte Claude-Code-Tools (Kontext-Trimming)

In `~/.claude/settings.json` sind ungenutzte Built-in-Tools abgeschaltet (Analyse über alle Sessions, Stand 2026-07-19: 0 Aufrufe). Wenn eine Aufgabe eines dieser Tools braucht, NICHT stillschweigend einen Workaround bauen – den User darauf hinweisen, dass das Tool deaktiviert ist und wie er es reaktiviert (Eintrag entfernen, Session neu starten).

- **`permissions.deny`** (bare Name = Schema komplett aus dem Kontext): EnterPlanMode/ExitPlanMode (Plan Mode), DesignSync, NotebookEdit (Jupyter), PushNotification, RemoteTrigger, CronCreate/CronDelete/CronList (geplante Jobs), Monitor, EnterWorktree/ExitWorktree, ListMcpResourcesTool/ReadMcpResourceTool/ReadMcpResourceDirTool (MCP-Ressourcen), EndConversation.
- **`disableWorkflows: true`** – Multi-Agent-Workflows/ultracode und `/deep-research` sind aus. Reaktivieren, wenn orchestrierte Fan-outs gewünscht sind.
- **`disableArtifact: true`** – kein Publizieren von Artifacts auf claude.ai. Reaktivieren für teilbare HTML-Reports/Seiten.
- **Bewusst AKTIV gelassen**: AskUserQuestion (häufig genutzt, von dieser CLAUDE.md verlangt), Task-Tools, Agent/Skill/ToolSearch, ScheduleWakeup (für `/loop`; der frühere session-keepwarm Stop-Hook ist seit 2026-08-18 ausgebaut, der `wakeup-guard`-PreToolUse-Hook blockt Rest-Ticks), SendUserFile, ReportFindings (für `/code-review`), Bundled Skills (`/loop`, `/update-config` in Nutzung), Remote Control (remoteControlAtStartup), claude.ai-Connectoren (gdrive-Skill braucht Google Drive; abschaltbar nur alle zusammen via `disableClaudeAiConnectors`).

<!-- APP_VERSION: 0.18.28 -->
