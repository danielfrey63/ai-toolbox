# Stay Alive

`stay-alive.ps1` hält eine Windows-Sitzung (lokal, RDP oder VDI) wach: kein Standby, kein Abschalten des Bildschirms, kein Leerlauf-Timeout, optional auch kein VPN-Leerlauf. Nur Windows, darum keine bash-Variante.

## Funktionsweise

Das Skript hält per `SetThreadExecutionState` (System + Display required) eine Wach-Anforderung, solange es läuft, und setzt alle `IntervalSeconds` (Default 50) den Leerlauf-Zähler mit einer Mausbewegung um 0 Pixel zurück. Der Cursor bewegt sich nicht, keine Taste wird gedrückt. Bei Ctrl+C gibt es die Wach-Anforderung wieder frei.

Pro Durchlauf zeigt es die Leerlaufzeit vor und nach dem Anstoss. Die zweite Zahl muss nahe 0 liegen; bleibt sie hoch, kommt die Eingabe nicht an (Sitzung gesperrt oder getrennt).

## Verwendung

```powershell
pwsh -File tools\stay-alive\stay-alive.ps1
pwsh -File tools\stay-alive\stay-alive.ps1 -IntervalSeconds 30
# With VPN keep-alive (runs in Windows PowerShell 5.1 too)
powershell -File tools\stay-alive\stay-alive.ps1 -KeepAliveHost intranet.example.com
```

## VPN-Leerlauf (GlobalProtect, Cisco Secure Client)

VPN-Gateways sehen weder Maus noch Tastatur. Sie trennen, wenn eine Zeit lang kein Verkehr durch den Tunnel geht (GlobalProtect «Inactivity Logout», Cisco «Idle Timeout»). Mit `-KeepAliveHost` baut das Skript alle `-KeepAliveMinutes` (Default 5) eine TCP-Verbindung zu einem internen Host auf (`-KeepAlivePort`, Default 443). Der Host muss nur über den Tunnel erreichbar sein; ein TCP-Handshake genügt, ohne HTTP, Proxy oder Zertifikate. In der Ausgabe steht dann `vpn ok`, bei Problemen gelb `vpn timeout` oder `vpn failed: …`.

Gegen eine maximale Sitzungsdauer des Gateways (GlobalProtect «Login Lifetime», Cisco «Session Timeout») hilft das nicht. Welche Grenze greift, steht in der Warnmeldung bzw. im Client-Log.

## Warum nicht `SendKeys`

Der Vorgänger schickte per `WScript.Shell.SendKeys('{SCROLLLOCK}')` jede Minute die Rollen-Taste. Das scheitert still, sobald die RDP-Sitzung minimiert, getrennt oder gesperrt ist (kein aktiver Desktop), oder wenn ein Fenster mit Admin-Rechten im Vordergrund liegt (UIPI blockt simulierte Eingaben). Es verhindert Standby und Display-Abschaltung nicht zuverlässig und schaltet nebenbei die Rollen-Taste um.

## Grenzen

- Ein serverseitiges RDS-Leerlauflimit misst soweit bekannt die Eingaben vom Client. Dann muss das Skript lokal laufen und das RDP-Fenster im Vordergrund sein.
- Eine per GPO/Intune erzwungene Sperre nach Inaktivität lässt sich je nach Konfiguration nicht verhindern.
