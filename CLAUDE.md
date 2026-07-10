# Claude Code — Globale Konfiguration

## Sprache und Stil

Zwei strikt getrennte Sprach-Domänen:

- **Englisch — Code & Commits.** Jegliche Skripte, Quellcode, Programmierung, Kommentare *im Code* und Commit-Messages sind **immer** auf Englisch. Ausnahmslos, in allen Repos.
- **Deutsch (Schweiz) — Kommunikation.** Konversation, Zusammenfassungen und Markdown-Dateien, die dem Austausch zwischen Mensch und Maschine dienen (Hand-offs, Notizen, Pläne, CLAUDE.md, …), sind auf Deutsch.
- **Umlaute & ss.** Wo Deutsch geschrieben wird: IMMER echte Umlaute (ä, ö, ü, é) und `ss` statt `ß` — NIEMALS `ae`, `oe`, `ue` als Ersatz.
- **Markdown: ein Absatz = eine Zeile.** Keine Pseudosatz-/Spiegel-Umbrüche (hard wraps) innerhalb von Absätzen oder Listenpunkten. Zeilenumbrüche nur an echten Struktur-Grenzen (Absatz, Listenpunkt, Überschrift, Tabellenzeile, Code-Zeile). Gilt für alle neu geschriebenen oder umgeschriebenen Markdown-Dateien; beim Editieren bestehender Dateien betroffene Absätze auf Einzeiler zusammenziehen.

### Schreibstil für Nachrichtenentwürfe in Daniels Namen

Sobald ein Text **in Daniels Namen** entworfen wird (Chat, Mail, Teams) — in jedem Projekt und jeder Session — gilt verbindlich der nachfolgend importierte Schreibstil (`schreibstil.md`, neben dieser CLAUDE.md im ai-toolbox-Repo): maximal kurz, dialogisch, per Du, Konjunktiv für Vorschläge, kein Briefing-Ton.

@schreibstil.md

## Umgebungen

### Linux (primär)

- **Shell:** Bash.
- **Kommando-Trennung:** `&&` für bedingte Verkettung, `;` nur für unkonditionierte Trennung.
- **SSH:** Lokaler `ssh-agent` (Bash lädt `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_rsa` beim Start).

### Windows-Devbox (PowerShell + WSL)

- **PowerShell:** Kommando-Trennung mit `;`. Bedingte Verkettung mit `&&` / `||`. Beispiel: `$env:VAR="wert"; bash script.sh`.
- **Bash unter WSL:** wie Linux oben.
- **SSH-Setup je nach Shell:**
  - **PowerShell:** Pageant (PuTTY Agent) + Plink — funktioniert direkt.
  - **WSL/Bash:** Lokaler `ssh-agent` (Pageant funktioniert dort NICHT); SSH-Keys nach `~/.ssh/` kopieren.

## Arbeitsprinzipien

- **Automatisierungs-Priorität: Skript → LLM → Human.** Was deterministisch berechenbar ist, gehört in ein Skript (Code, CLI, Build-Step). LLM-Calls nur für genuin kreative/analytische Aufgaben, die sich nicht in Regeln fassen lassen. Human in the Loop bleibt als Qualitäts-Gate für Freigaben und Reviews. Reihenfolge ist verbindlich — kein LLM-Call, wenn ein Skript reicht; keine Rückfrage an den User, wenn ein LLM zuverlässig entscheiden kann.
- **Bei Unsicherheit fragen.** Lieber eine kurze Rückfrage als eine falsche Annahme — besonders bei Scope, Pfaden, destruktiven Aktionen und Architektur-Entscheidungen.
- **Keine Duplikation.** Vor neuem Code prüfen, ob Konstante/Helfer/Klasse/Pattern bereits existiert. Wenn die bestehende Lösung nicht exakt passt: leicht abstrahieren und wiederverwenden statt kopieren und anpassen.
- **Desired-State / Idempotenz.** ALLE Skripte (Setup, Build, Deploy, Migration, Cleanup, …) müssen beliebig oft ausführbar sein, ohne Seiteneffekte oder Fehler zu produzieren. Mutationen erfolgen nur, wenn der Zielzustand vom Ist-Zustand abweicht — vor jedem Schritt prüfen statt blind ausführen. Re-Runs nach Abbruch oder Teilerfolg dürfen nie schaden.
- **Verbesserungs-Loop nach jedem Run.** Nach jeder Ausführung eines Skills, MCP-Servers oder Skripts werden aus den gemachten Erfahrungen automatisch konkrete Verbesserungsvorschläge generiert — Reibung, Fehlerfälle, Edge-Cases, Effizienz-Gewinne, Bugs, missverständliche Defaults, fehlende Idempotenz, schlechte Help-Texte. Jeder Vorschlag mit Zielort (welches Skript/welche Skill-Definition/welcher Tool-Code), kurzer Begründung, und falls möglich konkretem Diff/Patch-Vorschlag. Ausgabe direkt im Anschluss an den Run, nicht erst auf Nachfrage.

## Git-Workflows

### Querliegende Prinzipien

- **Trunk-Based Development.** Alle Änderungen laufen direkt auf `main` (bzw. dem Default-Branch) — keine Long-Running-Feature-Branches. Verbindlicher Ablauf für jede Änderung: **Pull → Read → Changes → Commit → Push.** `pull` zuerst, damit lokal mit dem Remote synchron ist. `read` heisst aktuellen Stand der betroffenen Dateien sichten (kein Blind-Edit auf Annahmen). Erst dann `changes` machen, sofort danach `commit` mit aussagekräftiger Message, abschliessend `push`. Niemals länger als nötig uncommittet liegen lassen.
- **Nie destruktiv ohne User-Bestätigung.** Das gilt für `git reset --hard`, `git stash drop`, `git push --force`, `rm -rf` auf potentiell wertvolle Pfade, `git clean -fdx`, Submodule entfernen.
- **Backups so lange behalten wie möglich.** Ein angelegter Stash bleibt liegen, bis der User bestätigt hat, dass das Resultat passt — dann erst `git stash drop`.
- **Bei mehreren Entscheidungen: `AskUserQuestion` gruppieren.** Pro Fragerunde max. 4 Fragen, lieber 2-3 gut formulierte Mehrfach-Choice-Fragen als zehn Einzelnachfragen.
- **Investigation kommt vor Aktion.** Bei jedem nicht-trivialen Git-Zustand zuerst `git status`, `git diff --stat`, `git log HEAD..@{u} --stat` lesen, bevor irgendwas gestasht oder zurückgesetzt wird.
- **History-Rewrite (z.B. `git filter-repo`):** lokale Dateien IMMER behalten. Vor dem Rewrite betroffene Dateien nach `/tmp/git-backup/` (bzw. `$env:TEMP\git-backup\` auf Windows) kopieren. Lokale Kopien erst nach User-Bestätigung löschen.

### 1. Standardfluss (konfliktfrei)

```
git pull → read → changes → git commit → git push
```

Vor dem Commit:
- `git status` und `git diff` zeigen, dass nur Gewolltes drin ist
- `git log -5 --format="%s"` für den Commit-Message-Stil des Repos

### 2. Einfacher Konflikt (Pull blockiert wegen lokaler Änderungen)

```
investigate → stash → pull → pop → resolve → commit → push
```

Schritte:
1. `git status` + `git diff --stat`: was ist lokal?
2. `git log HEAD..@{u} --stat`: was kommt upstream?
3. Wenn Überlapp gering → `git stash push -m "<sprechender-name>"` (alle Änderungen)
4. `git pull` (jetzt clean)
5. `git stash pop` → wenn Konflikt: nie sofort `--hard` resetten, erst analysieren
6. Konflikt-Files einzeln auflösen, dann `git add` + commit/push
7. **Stash bleibt liegen, bis User bestätigt** — dann `git stash drop`

### 3. Tiefer Konflikt (Upstream hat restrukturiert)

```
investigate gründlich → mapping aufstellen → user fragen
→ stash → pull → reset+selektiv aus stash → commit → push
```

Schritte:
1. **Investigate gründlich**: Upstream-Commits durchgehen (Pfad-Renames, gelöschte Dateien, Submodule-Verschiebungen). `git log HEAD..@{u} --stat` und einzelne Commit-Messages lesen — Renames sind in `--stat` als `old/path => new/path` sichtbar.
2. **Mapping aufstellen**: Jede lokale Änderung einem Upstream-Resultat zuordnen:
   - lokal-Datei X → upstream-Pfad Y → "schon enthalten, ignorieren"
   - lokal-Datei X → "upstream-redundant, lokal verwerfen"
   - lokal-Datei X → "noch nicht upstream, integrieren"
3. **User-Entscheidung pro Gruppe einholen** (`AskUserQuestion`, nicht einzeln).
4. Stash → Pull (fast-forward) → bei Pop-Konflikt: `git reset --hard HEAD` (zurück auf Upstream-Stand) + `git checkout stash@{0} -- <selektive Pfade>` für die zu behaltenden Datei(en).
5. Commit, push.
6. **Stash erst droppen, wenn User OK gibt.**

### 4. Post-Restructure-Checks

Wenn Upstream Pfade umgezogen hat, IMMER nachträglich prüfen:

- **Top-Level-Inventur**: `ls` vs. `git ls-tree HEAD --name-only` — leere Reste alter Pfade finden (z. B. ehemalige Submodul-Verzeichnisse, alte Export-Pfade).
- **Untracked-Check**: `git ls-files --others --exclude-standard` muss leer/erwartet sein.
- **Ignored-Check**: `git status --ignored -s` — passt der Ignore-Stand zur neuen Struktur?
- **Submodule-Status**: `git submodule status` — Submodul-Pfade nach Restructure stimmen mit `.gitmodules` überein?
- **Working Tree clean** vor Push: `git status` muss sauber sein.

### 5. Typische Anti-Patterns

- ❌ `git reset --hard HEAD` als Shortcut bei Stash-Pop-Konflikt, ohne den Stash-Inhalt vorher zu prüfen → Datenverlust möglich
- ❌ `git stash drop` direkt nach Pop, "weil hat ja geklappt" → kein Backup mehr falls später was fehlt
- ❌ `git checkout --ours/--theirs` bei Stash-Pop, ohne zu wissen welche Seite "ours" ist (bei Stash-Pop ist "ours" = HEAD/Upstream, "theirs" = Stash — invers zu Merge!)
- ❌ `git pull --rebase` ohne Investigation, wenn lokale Commits nicht im Remote sind → versteckt potentielle Konflikte hinter Rebase-Mechanik
- ❌ Force-Push auf shared Branches ohne explizite User-Freigabe

### 6. Push-Regeln

- **Niemals** `git push --force` auf `master`/`main` ohne explizite User-Anweisung.
- Vor Push: Working Tree clean, `git log @{u}..HEAD` zeigt nur gewollte Commits.
- Bei `--force-with-lease` (sicherer als `--force`) trotzdem User fragen.

## Datei-Caching

- Claude Code cached Dateien lokal — gecachte Versionen können veraltet sein. Falls Änderungen nicht berücksichtigt werden: explizit auf aktuelle Version hinweisen oder Neuladen anfordern.

<!-- APP_VERSION: 0.5.8 -->
# graphify
- **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
When the user types `/graphify`, invoke the Skill tool with `skill: "graphify"` before doing anything else.
