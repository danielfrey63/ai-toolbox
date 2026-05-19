# Claude Code — Globale Konfiguration

## Sprache und Stil

- **Sprache:** Deutsch (Schweiz) — `ss` statt `ß`, vollständige Umlaute (ä, ö, ü, é).
- **Umlaute IMMER echt schreiben** — in ALLEN Dateien (Code, Markdown, Kommentare, CLAUDE.md, README.md, …). NIEMALS `ae`, `oe`, `ue` als Ersatz.
- **Commit-Messages:** IMMER auf Englisch — abweichend von der Deutsch-Regel. Gilt für alle Repos.

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
- **Desired-State / Idempotenz.** Setup-Skripte müssen beliebig oft ausführbar sein, ohne Seiteneffekte zu produzieren.
- **Verbesserungs-Loop nach jedem Run.** Nach jeder Ausführung eines Skills, MCP-Servers oder Skripts werden aus den gemachten Erfahrungen automatisch konkrete Verbesserungsvorschläge generiert — Reibung, Fehlerfälle, Edge-Cases, Effizienz-Gewinne, Bugs, missverständliche Defaults, fehlende Idempotenz, schlechte Help-Texte. Jeder Vorschlag mit Zielort (welches Skript/welche Skill-Definition/welcher Tool-Code), kurzer Begründung, und falls möglich konkretem Diff/Patch-Vorschlag. Ausgabe direkt im Anschluss an den Run, nicht erst auf Nachfrage.

## Git

- **Trunk-Based Development.** Alle Änderungen laufen direkt auf `main` (bzw. dem Default-Branch) — keine Long-Running-Feature-Branches. Verbindlicher Ablauf für jede Änderung: **Pull → Read → Changes → Commit → Push.** `pull` zuerst, damit lokal mit dem Remote synchron ist. `read` heisst aktuellen Stand der betroffenen Dateien sichten (kein Blind-Edit auf Annahmen). Erst dann `changes` machen, sofort danach `commit` mit aussagekräftiger Message, abschliessend `push`. Niemals länger als nötig uncommittet liegen lassen.
- **History-Rewrite (z.B. `git filter-repo`):** lokale Dateien IMMER behalten. Vor dem Rewrite betroffene Dateien nach `/tmp/git-backup/` kopieren. Lokale Kopien erst nach User-Bestätigung löschen.

## Datei-Caching

- Claude Code cached Dateien lokal — gecachte Versionen können veraltet sein. Falls Änderungen nicht berücksichtigt werden: explizit auf aktuelle Version hinweisen oder Neuladen anfordern.
