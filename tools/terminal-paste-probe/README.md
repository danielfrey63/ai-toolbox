# Terminal Paste Probe

Zwei Diagnose-Skripte für den Fall «Text, der in ein Terminal gepastet wird, kommt in der TUI-App nicht an» (Wispr Flow, Windows-Diktat, Clipboard-Tools). Sie trennen die drei Verdächtigen sauber: das Werkzeug, das pastet, den Terminal-Emulator, der die Taste verarbeitet, und die App, die den Byte-Strom liest.

## Die Skripte

`pty_paste_test.py` startet eine TUI-App headless in einem ConPTY, beantwortet ihre Capability-Probes so wie xterm.js (DA1, DA2, CPR, OSC 10/11, kitty `CSI ? u`), wartet auf den Prompt, schiebt einen Marker auf verschiedene Arten hinein (Bracketed Paste, ungeklammert, zeichenweise, gesplittet, mit Fokus-Events oder Terminal-Antworten im selben Chunk) und meldet, ob der Marker auf dem Bildschirm erscheint. Zusätzlich listet er, welche Eingabe-Protokolle die App beim Start einschaltet (Bracketed Paste, Kitty-Flags, modifyOtherKeys, win32-input-mode, Fokus-Events). Exit-Code 0 bei sichtbarem Paste, 1 bei verschlucktem, 2 wenn der Prompt nie erschien.

`raw_input_logger.py` läuft im echten Terminal (VS Code, Windows Terminal, conhost) und zeigt, welche Bytes die App bei einem Paste tatsächlich bekommt. Mit dem Argument `kitty` schaltet er vorher dieselben Protokolle ein wie Claude Code ab 2.1.269, mit `plain` nur Bracketed Paste und Fokus-Events.

## Voraussetzungen

Windows 10 1809 oder neuer, Python 3.10+, für den PTY-Test `pywinpty`. Am besten in einem Wegwerf-venv, damit nichts im System-Python landet:

```powershell
python -m venv "$env:TEMP\paste-probe-venv"
& "$env:TEMP\paste-probe-venv\Scripts\pip.exe" install pywinpty
```

## Verwendung

```powershell
$py = "$env:TEMP\paste-probe-venv\Scripts\python.exe"
# Aktuelles Claude Code, VS-Code-Umgebung, Bracketed Paste (Standard)
& $py tools\terminal-paste-probe\pty_paste_test.py --exe "$env:USERPROFILE\.local\bin\claude.exe" --cwd <vertrauter-Ordner>
# Eine ältere Version zum Vergleich, Windows-Terminal-Umgebung, zeichenweise
& $py tools\terminal-paste-probe\pty_paste_test.py --exe C:\tmp\claude-2.1.268.exe --env wt --mode typed
# Im zu testenden Terminal selbst, dann einmal pasten oder diktieren
python tools\terminal-paste-probe\raw_input_logger.py kitty
```

Ältere Claude-Code-Binaries gibt es unter `https://downloads.claude.ai/claude-code-releases/<version>/win32-x64/claude.exe`. Der PTY-Test setzt `DISABLE_AUTOUPDATER=1`, und Claude Code speichert in dieser Kindsession kein Transkript. Der Prompt wird per Regex erkannt (`--ready`, Default passt auf Claude Code); für andere TUIs den Regex anpassen.

## Anwendungsfall vom 17.09.2026: Wispr Flow und Claude Code im VS-Code-Terminal

Symptom: Seit 12.09.2026 kam kein Wispr-Diktat mehr in Claude Code an, sobald Claude Code im integrierten VS-Code-Terminal lief. Windows Terminal war nicht betroffen, manuelles Ctrl+V in VS Code ging weiter.

Befund mit diesen Skripten: Bracketed Pastes kommen in allen Claude-Code-Versionen an, also liegt es nicht am Paste-Inhalt. Aber 2.1.268 stellt keine `CSI ? u`-Probe, 2.1.274 stellt sie und pusht nach der Antwort die Kitty-Flags (`CSI > 5 u`) plus modifyOtherKeys. VS Code 1.138 implementiert das Kitty-Keyboard-Protokoll in xterm.js (Setting `terminal.integrated.enableKittyKeyboardProtocol`, Default an). Im Kitty-Modus kodiert xterm.js die Insert-Taste immer selbst und schickt Shift+Insert als `ESC [ 2 ; 2 ~` an die App, statt den Browser-Paste auszulösen. Wispr pastet auf Windows per Clipboard plus Shift+Insert (Feature-Flag `shift-insert`), und Shift+Insert ist in VS Code unter Windows kein Terminal-Keybinding, also landet die Taste bei xterm.js. Windows Terminal fängt Shift+Insert als eigenes Paste-Keybinding ab, bevor die App etwas sieht.

Workaround: `"terminal.integrated.enableKittyKeyboardProtocol": false` in den VS-Code-User-Settings, danach die Claude-Session im Terminal neu starten. Verwandte Issues: anthropics/claude-code#93782, anthropics/claude-code#38620, anomalyco/opencode#34499.
