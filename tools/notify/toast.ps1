# toast.ps1 - Windows toast notifications for background scripts.
#
# Dot-source it, then call Show-Toast:
#   . "<ai-toolbox>\tools\notify\toast.ps1"
#   Show-Toast -Title "Backup fertig" -Body "12 GB in 40 min" [-Url https://...] [-Reminder]
#            [-AppId 'AIToolbox.Backup' -AppName 'AI-Toolbox Backup']
#
# -Url makes the toast body and an "Öffnen" button open the page (protocol
# activation); -Reminder keeps the toast in the Action Center with a "Später"
# button until dismissed. -AppId/-AppName register a display name for the
# sender under HKCU (no admin needed); without them the toast is sent under
# Explorer's AppUserModelID, which every Windows already trusts.
#
# Works from Windows PowerShell 5.1 and from pwsh 7: the WinRT projection
# ([...] ContentType = WindowsRuntime) exists only in 5.1, so under pwsh the
# call re-enters this script in powershell.exe through run-hidden.vbs (no
# console window). The parameters travel base64-encoded so quotes and line
# breaks survive the two command lines in between.
#
# Command-line use (what the pwsh path does internally):
#   powershell.exe -NoProfile -File toast.ps1 -Title "..." -Body "..."
[CmdletBinding()]
param(
    [string]$Title,
    [string]$Body = '',
    [string]$Url = '',
    [switch]$Reminder,
    [string]$AppId = '',
    [string]$AppName = '',
    # Base64(UTF-8 JSON) of all parameters; used by the pwsh -> 5.1 hand-over.
    [string]$Payload = ''
)

function Show-Toast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Body = '',
        [string]$Url = '',
        [switch]$Reminder,
        [string]$AppId = '',
        [string]$AppName = ''
    )
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $json = @{ Title = $Title; Body = $Body; Url = $Url; Reminder = [bool]$Reminder; AppId = $AppId; AppName = $AppName } | ConvertTo-Json -Compress
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $wrapper = Join-Path $PSScriptRoot '..\run-hidden\run-hidden.vbs'
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # --detach: the toast is handed to the notification platform, nothing to wait for
        & $wscript //B //Nologo $wrapper --detach $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -Payload $payload
        return
    }

    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    if (-not $AppId) { $AppId = 'Microsoft.Windows.Explorer' }  # pre-registered AppUserModelID for script toasts
    if ($AppName) {
        # Unpackaged senders need an AppUserModelID with a display name, else the toast is dropped.
        $reg = "HKCU:\Software\Classes\AppUserModelId\$AppId"
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        if ((Get-ItemProperty -Path $reg -Name DisplayName -ErrorAction SilentlyContinue).DisplayName -ne $AppName) {
            New-ItemProperty -Path $reg -Name DisplayName -Value $AppName -PropertyType String -Force | Out-Null
        }
    }

    $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $scenario = if ($Reminder) { ' scenario="reminder"' } else { '' }
    $launch = if ($Url) { " activationType=`"protocol`" launch=`"$(& $esc $Url)`"" } else { '' }
    $actions = @()
    if ($Url) { $actions += "<action content=`"Öffnen`" activationType=`"protocol`" arguments=`"$(& $esc $Url)`"/>" }
    if ($Reminder) { $actions += '<action content="Später" activationType="system" arguments="snooze"/>' }
    $actionsXml = if ($actions) { "<actions>$($actions -join '')</actions>" } else { '' }
    $xml = @"
<toast$scenario$launch>
  <visual><binding template="ToastGeneric">
    <text>$(& $esc $Title)</text>
    <text>$(& $esc $Body)</text>
  </binding></visual>
  $actionsXml
</toast>
"@
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show(
        [Windows.UI.Notifications.ToastNotification]::new($doc))
}

# Script invoked directly (not dot-sourced): show the toast from the parameters.
if ($Payload) {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
    Show-Toast -Title $p.Title -Body $p.Body -Url $p.Url -Reminder:$p.Reminder -AppId $p.AppId -AppName $p.AppName
} elseif ($Title) {
    Show-Toast -Title $Title -Body $Body -Url $Url -Reminder:$Reminder -AppId $AppId -AppName $AppName
}
