# Stay Alive

`stay-alive.ps1` hält eine Windows-Sitzung (lokal oder in RDP) wach: kein Standby, kein Abschalten des Bildschirms, kein Leerlauf-Timeout. Nur Windows, darum keine bash-Variante.

## Funktionsweise

Das Skript hält per `SetThreadExecutionState` (System + Display required) eine Wach-Anforderung, solange es läuft, und setzt alle `IntervalSeconds` (Default 50) den Leerlauf-Zähler mit einer Mausbewegung um 0 Pixel zurück. Der Cursor bewegt sich nicht, keine Taste wird gedrückt. Bei Ctrl+C gibt es die Wach-Anforderung wieder frei.

Pro Durchlauf zeigt es die Leerlaufzeit vor und nach dem Anstoss. Die zweite Zahl muss nahe 0 liegen; bleibt sie hoch, kommt die Eingabe nicht an (Sitzung gesperrt oder getrennt).

## Verwendung

```powershell
pwsh -File tools\stay-alive\stay-alive.ps1
pwsh -File tools\stay-alive\stay-alive.ps1 -IntervalSeconds 30
```

## Warum nicht `SendKeys`

Der Vorgänger schickte per `WScript.Shell.SendKeys('{SCROLLLOCK}')` jede Minute die Rollen-Taste. Das scheitert still, sobald die RDP-Sitzung minimiert, getrennt oder gesperrt ist (kein aktiver Desktop), oder wenn ein Fenster mit Admin-Rechten im Vordergrund liegt (UIPI blockt simulierte Eingaben). Es verhindert Standby und Display-Abschaltung nicht zuverlässig und schaltet nebenbei die Rollen-Taste um.

## Grenzen

- Ein serverseitiges RDS-Leerlauflimit misst soweit bekannt die Eingaben vom Client. Dann muss das Skript lokal laufen und das RDP-Fenster im Vordergrund sein.
- Eine per GPO/Intune erzwungene Sperre nach Inaktivität lässt sich je nach Konfiguration nicht verhindern.
