' Windowless launcher for scheduled tasks and background helpers.
'
' Why: "pwsh -WindowStyle Hidden" (and powershell.exe alike) still flashes a
' console window on every start, because Windows creates the console before
' PowerShell gets to process the flag. wscript.exe is a GUI-subsystem process,
' so starting the executable from here with window style 0 shows nothing.
'
' Usage: wscript.exe //B //Nologo run-hidden.vbs [--detach] <exe> [args...]
'   default   wait for the process and exit with its exit code, so the task's
'             "last run result" stays meaningful and the scheduler's execution
'             time limit still ends a stuck run (the child lives in the task's
'             job object)
'   --detach  start the process and return 0 at once (long-running watchers
'             that must outlive the launcher)
' Every argument is re-quoted, so paths with spaces are safe; arguments must
' not contain double quotes themselves.
Option Explicit
Dim i, cmd, first, detach
detach = False
first = 0
If WScript.Arguments.Count > 0 Then
    If WScript.Arguments.Item(0) = "--detach" Then
        detach = True
        first = 1
    End If
End If
cmd = ""
For i = first To WScript.Arguments.Count - 1
    cmd = cmd & """" & WScript.Arguments.Item(i) & """ "
Next
If cmd = "" Then WScript.Quit 2
Dim rc
rc = CreateObject("WScript.Shell").Run(Trim(cmd), 0, Not detach)
If detach Then
    WScript.Quit 0
Else
    WScript.Quit rc
End If
