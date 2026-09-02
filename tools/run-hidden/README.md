# run-hidden

Fensterloser Starter für Scheduled Tasks und Hintergrund-Helfer unter Windows.

## Problem

`pwsh -WindowStyle Hidden` und `powershell.exe -WindowStyle Hidden` blitzen bei jedem Start trotzdem kurz ein Konsolenfenster auf, weil Windows die Konsole anlegt, bevor PowerShell das Flag verarbeitet. Bei einem Task, der alle 10 Minuten läuft, sind das rund 100 Fenster pro Tag auf dem Desktop.

## Lösung

`run-hidden.vbs` läuft in `wscript.exe`, einem GUI-Prozess ohne Konsole, und startet das eigentliche Programm mit Fensterstil 0. Der Task-Scheduler startet also `wscript.exe //B //Nologo run-hidden.vbs <exe> [args…]` statt `<exe> [args…]`.

Standardmässig wartet der Starter auf das Programm und gibt dessen Exit-Code zurück. Damit bleibt das «Ergebnis der letzten Ausführung» im Scheduler aussagekräftig, und das Ausführungszeitlimit des Tasks beendet weiterhin einen hängenden Lauf, weil das Kindprozess im Job-Objekt des Tasks lebt. Mit `--detach` als erstem Argument kehrt der Starter sofort zurück; das ist für dauerhaft laufende Watcher gedacht, die den Starter überleben müssen.

## Verwendung in Installern

`HiddenTask.ps1` wird im Installer dot-sourced und ersetzt `New-ScheduledTaskAction`:

```powershell
. "<ai-toolbox>\tools\run-hidden\HiddenTask.ps1"
$action = New-HiddenTaskAction -FilePath (Get-TaskShell) -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script)
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force
```

`New-HiddenTaskAction` nimmt die Argumente als einzelne Tokens entgegen und quotet Tokens mit Leerzeichen selbst; Argumente dürfen keine doppelten Anführungszeichen enthalten. `-Detach` schaltet den Nicht-Warten-Modus ein. `Get-TaskShell` liefert den vollen Pfad zu `pwsh`, ersatzweise zu Windows PowerShell 5.1 (`-WindowsPowerShell` erzwingt 5.1); ein blosses `powershell.exe` als Task-Programm scheitert mit 0x80070002, sobald der Scheduler-PATH kein System32 mehr enthält.

## Nutzer

Die Task-Installer von `session-cleanup` (Toolbox), `pmo/windows/install-*.ps1`, `sbb/tools/ingest/install-ingest-task.ps1` und `drive-sync/backup/install-backup-task.ps1` verwenden den Helfer; `tools/notify/toast.ps1` startet über ihn Windows PowerShell für Toasts aus `pwsh` heraus. Die DriveSync-Watcher-Tasks tragen noch eine eigene, nicht wartende Kopie des Skripts (`drive-sync/run-hidden.vbs`); sie liesse sich mit `--detach` auf diese Version umstellen.
