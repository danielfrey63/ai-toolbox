# session-move

Werkzeuge, um Claude-Code-Sessions zwischen Projektordnern umzuziehen. Claude Code ordnet eine Session über ihren Transkript-Ordner `~/.claude/projects/<kodierter-pfad>/` einem Projekt zu. Claude Desktop führt zusätzlich eigene Metadaten pro Session (`%APPDATA%\Claude\claude-code-sessions\<account>\<org>\local_<id>.json`), gruppiert die Sidebar nach deren `cwd` und setzt die Session dort fort. Ein vollständiger Umzug braucht deshalb beide Seiten: erst die Transkripte, dann die Desktop-Metadaten.

| Skript | Zweck |
|---|---|
| `move-session.ps1` | Eine einzelne Session (Transkript + Sidecar) in ein anderes Projekt verschieben, optional mit `/rename`-Titel. |
| `transfer-cc-sessions.ps1` | Nach dem Umzug eines ganzen Verzeichnisbaums alle betroffenen Projektordner (Sessions, Memory) additiv unter den neuen Pfad kopieren. |
| `relocate-desktop-sessions.ps1` | Die Desktop-Metadaten nachziehen: `cwd`/`originCwd` jeder Session auf den Ordner setzen, in dem ihr Transkript liegt. |
| `CCProjects.ps1` | Gemeinsame Helfer (Pfad-Kodierung, Dekodierung gegen das Dateisystem, letzte Aktivität, additives Kopieren), auch von `session-cleanup` genutzt. |

## relocate-desktop-sessions.ps1

Für jede Desktop-Session wird `<cliSessionId>.jsonl` in allen Projektordnern gesucht. Kopien, deren Projektordner auf einen existierenden Ordner zurückdekodiert, haben Vorrang, danach gewinnt die jüngste Aktivität (innerer Zeitstempel, nicht die mtime). Bei Gleichstand gewinnt die Kopie, auf die die Session schon zeigt – so bleiben Wiederholungen stabil.

Existiert der Ordner einer Session gar nicht mehr («verwaist»), nennt `-Map` das neue Zuhause. Schlüssel sind alte Ordnerpfade (Präfix-Match, der längste gewinnt) oder Session-IDs (`local_…`, gelten immer, auch für nicht verwaiste Sessions). Das Transkript samt Sidecar wird additiv in den Projektordner des Ziels kopiert; die Altkopie räumt `session-cleanup` später als redundantes Duplikat ab.

Sessions ohne Transkript werden nur gemeldet (`[NO-TRANSCRIPT]`) und gehören in der App archiviert. `originCwd` wird nur angepasst, wenn es dem alten `cwd` entspricht oder der Ordner fehlt – Worktree-Sessions behalten so ihr Repo.

```powershell
# 1. Dry-Run (die App darf dabei laufen)
.\relocate-desktop-sessions.ps1
# 2. Claude Desktop beenden (Tray-Icon > Quit), zuerst eine einzelne Session umstellen
.\relocate-desktop-sessions.ps1 -Only local_<id> -Apply
# 3. App starten, Sidebar prüfen, App wieder beenden, dann den Rest inkl. verwaister Sessions
.\relocate-desktop-sessions.ps1 -Map @{ 'D:\alt\projekt' = 'D:\neu\projekt'; 'local_<id>' = 'D:\anderes\projekt' } -Apply
```

`-Map` ist eine Hashtable, das Skript also aus einer pwsh-Sitzung aufrufen (`pwsh -File` übergibt nur Strings).

**Sicherheit.** `-Apply` bricht ab, solange Claude Desktop läuft (Electron hält `%APPDATA%\Claude\lockfile` gesperrt), weil die App die Metadaten im Speicher hält und zurückschreibt; `-Force` übergeht das. Jede geänderte Datei wird vorher nach `%TEMP%\desktop-sessions-backup\<zeitstempel>\` kopiert. Das JSON wird mit `System.Text.Json` bearbeitet: Nur `cwd`/`originCwd` ändern sich, Zahlen, Schlüsselreihenfolge und Umlaute bleiben unverändert. Ein zweiter Lauf ändert nichts mehr.
