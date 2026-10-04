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

- **Shells:** PowerShell 7 für interaktive Arbeit. `.sh`-Skripte und Claude-Code-Hooks laufen in Git Bash (scoop). Linux-Tooling läuft in WSL (Ubuntu), das in der PowerShell über `bash` aufgerufen wird – ohne installierte Distribution schlägt `bash` dort fehl, dann Git Bash explizit aufrufen.
- **Git-Remotes** über HTTPS mit Git Credential Manager. SSH je nach Shell: PowerShell mit Pageant + Plink, WSL mit lokalem `ssh-agent` (Pageant funktioniert dort NICHT, Keys nach `~/.ssh/` kopieren).
- **Repos unter `D:\Meine Ablage` liegen in Google Drive.** Drive synchronisiert Arbeitsdateien vom anderen Rechner, ohne dass `git` davon weiss. Bei «behind + dirty» zuerst prüfen, ob das Arbeitsverzeichnis schon dem Upstream entspricht (`git diff --stat @{u}`), bevor irgendetwas gestasht wird.

## Arbeitsprinzipien

- **Automatisierungs-Priorität: Skript → LLM → Human.** Was deterministisch berechenbar ist, gehört in ein Skript (Code, CLI, Build-Step). LLM-Calls nur für genuin kreative/analytische Aufgaben, die sich nicht in Regeln fassen lassen. Human in the Loop bleibt als Qualitäts-Gate für Freigaben und Reviews. Reihenfolge ist verbindlich – kein LLM-Call, wenn ein Skript reicht; keine Rückfrage an den User, wenn ein LLM zuverlässig entscheiden kann.
- **Bei Unsicherheit fragen.** Lieber eine kurze Rückfrage als eine falsche Annahme – besonders bei Scope, Pfaden, destruktiven Aktionen und Architektur-Entscheidungen.
- **Keine Duplikation.** Vor neuem Code prüfen, ob Konstante/Helfer/Klasse/Pattern bereits existiert. Wenn die bestehende Lösung nicht exakt passt: leicht abstrahieren und wiederverwenden statt kopieren und anpassen.
- **Desired-State / Idempotenz.** ALLE Skripte (Setup, Build, Deploy, Migration, Cleanup, …) müssen beliebig oft ausführbar sein, ohne Seiteneffekte oder Fehler zu produzieren. Mutationen erfolgen nur, wenn der Zielzustand vom Ist-Zustand abweicht – vor jedem Schritt prüfen statt blind ausführen. Re-Runs nach Abbruch oder Teilerfolg dürfen nie schaden.
- **Code-Änderungen mit Write/Edit, nie per Bash-Heredoc.** Quellcode und Konfigdateien werden mit den Datei-Tools (Write, Edit) geschrieben oder gepatcht. Bash-Heredocs (`python - <<'EOF'`, `cat <<EOF`) sind nur für Wegwerf-Skripte ohne Escape-Sequenzen geeignet: Der Tool-Transport wandelt Sequenzen wie `\x00`, `\x11` oder `\n` in echte Bytes um, was in Python-Quelltext zu Null-Bytes, Steuerzeichen und zerrissenen String-Literalen führt.
- **Verbesserungs-Loop nach jedem Run.** Nach jeder Ausführung eines Skills, MCP-Servers oder Skripts werden aus den gemachten Erfahrungen automatisch konkrete Verbesserungsvorschläge generiert – Reibung, Fehlerfälle, Edge-Cases, Effizienz-Gewinne, Bugs, missverständliche Defaults, fehlende Idempotenz, schlechte Help-Texte. Jeder Vorschlag mit Zielort (welches Skript/welche Skill-Definition/welcher Tool-Code), kurzer Begründung, und falls möglich konkretem Diff/Patch-Vorschlag. Ausgabe direkt im Anschluss an den Run, nicht erst auf Nachfrage.

## Git-Workflows

### Querliegende Prinzipien

- **Trunk-Based Development.** Alle Änderungen laufen direkt auf `main` (bzw. dem Default-Branch) – keine Long-Running-Feature-Branches. Verbindlicher Ablauf für jede Änderung: **Pull → Read → Changes → Commit → Push.** `pull` zuerst, damit lokal mit dem Remote synchron ist. `read` heisst aktuellen Stand der betroffenen Dateien sichten (kein Blind-Edit auf Annahmen). Erst dann `changes` machen, sofort danach `commit` mit aussagekräftiger Message, abschliessend `push`. Niemals länger als nötig uncommittet liegen lassen. **Schnitt-Kriterium innerhalb einer Session:** committet wird, sobald eine Datei in einem Zustand ist, den du nicht verlieren möchtest – nicht erst, wenn das Thema fertig ist. Eine noch laufende Analyse, ein offener Klärungspunkt oder ein erwarteter Folge-Edit sind kein Grund, Zwischenstände liegen zu lassen.
- **Investigation vor Aktion.** Bei jedem nicht-trivialen Zustand zuerst `git status`, `git diff --stat` und `git log HEAD..@{u} --stat` lesen, bevor etwas gestasht oder zurückgesetzt wird. Kein `git pull --rebase` über lokale, ungepushte Commits ohne diese Sichtung.
- **Commit-Stil:** `git log -5 --format="%s"` gibt den Message-Stil des Repos vor.
- **Backups so lange wie möglich behalten.** Ein Stash bleibt liegen, bis der User das Resultat bestätigt hat – auch nach einem erfolgreichen Pop. Vor einem History-Rewrite (z.B. `git filter-repo`) betroffene Dateien nach `/tmp/git-backup/` bzw. `$env:TEMP\git-backup\` kopieren und erst nach Bestätigung löschen.
- **Upstream hat restrukturiert:** Jede lokale Änderung zuordnen («upstream schon enthalten», «upstream-redundant, verwerfen», «noch nicht upstream, integrieren») und die Entscheidung pro Gruppe gebündelt beim User einholen (`AskUserQuestion`, max. 4 Fragen pro Runde). Danach auf Reste alter Pfade prüfen (`ls` gegen `git ls-tree HEAD --name-only`, untracked, ignored, `git submodule status`).
- **Kein `--force` / `--force-with-lease`** ohne explizite User-Freigabe.

## Deaktivierte Claude-Code-Tools

Die globale Settings-Baseline steht versioniert in `claude-settings.json` (dieses Repo) und wird mit `toolbox install --what claude-settings` nach `~/.claude/settings.json` gemerged. Braucht eine Aufgabe ein dort abgeschaltetes Tool, NICHT stillschweigend einen Workaround bauen: den User darauf hinweisen und die Reaktivierung nennen (Eintrag in `claude-settings.json` entfernen, `toolbox remove` + `install`, Session neu starten).

<!-- APP_VERSION: 0.20.30 -->
