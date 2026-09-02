# notify

Windows-Toast-Benachrichtigungen für Hintergrund-Skripte. Ein Scheduled Task hat keine sichtbare Konsole; was er getan hat, gehört als Toast ins Info-Center, nicht in ein aufblitzendes Fenster.

## Verwendung

```powershell
. "<ai-toolbox>\tools\notify\toast.ps1"
Show-Toast -Title "Backup fertig" -Body "12 GB in 40 min"
Show-Toast -Title "PMO: 3 fällig" -Body $lines -Url https://pmo.example -Reminder
Show-Toast -Title "Session-Cleanup" -Body "4 Sessions in den Papierkorb" -AppId 'AIToolbox.SessionCleanup' -AppName 'AI-Toolbox Session Cleanup'
```

| Parameter | Wirkung |
|---|---|
| `-Title`, `-Body` | Text; Sonderzeichen werden XML-escaped, Zeilenumbrüche im Body bleiben erhalten |
| `-Url` | Klick auf den Toast und ein «Öffnen»-Button öffnen die Adresse |
| `-Reminder` | bleibt bis zum Wegklicken im Info-Center, mit «Später»-Button |
| `-AppId`, `-AppName` | Absendername; registriert die AppUserModelID unter HKCU (kein Admin nötig). Ohne Angabe sendet der Toast unter Explorers ID |

Direkt aufrufbar ist das Skript ebenfalls: `powershell.exe -NoProfile -File toast.ps1 -Title "…" -Body "…"`.

## pwsh 7 und Windows PowerShell

Die WinRT-Projektion (`[…, ContentType = WindowsRuntime]`) gibt es nur in Windows PowerShell 5.1. Unter `pwsh` ruft `Show-Toast` deshalb das Skript selbst in `powershell.exe` erneut auf, und zwar über `tools/run-hidden/run-hidden.vbs`, damit dabei kein Konsolenfenster aufblitzt. Die Parameter reisen als Base64-kodiertes JSON, damit Anführungszeichen und Zeilenumbrüche die zwei Kommandozeilen überstehen. Der Aufruf kehrt sofort zurück; der Toast erscheint etwa eine Sekunde später.

## Regel für Hintergrund-Tasks

Ein Toast pro Ergebnis, nicht pro Start: Läufe, die nichts zu tun hatten, bleiben still (ein 10-Minuten-Task würde sonst das Info-Center fluten). Gemeldet werden erledigte Arbeit mit Kennzahlen, Befunde, die eine Entscheidung brauchen (dann `-Reminder`), und Fehler.
