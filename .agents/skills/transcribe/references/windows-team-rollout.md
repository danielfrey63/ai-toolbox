# Transcribe im Windows-Team bereitstellen

Die allgemeine Installation, Profile, Konfiguration und Abnahme stehen verbindlich in [INSTALL.md](../INSTALL.md). Dieses Dokument ergänzt die Bereitstellung eines getesteten Stands und die Einbindung in ein Arbeitsprojekt.

## Verantwortlichkeiten

Der Verantwortliche liefert Repository-URL, vollständige getestete Commit-ID, freigegebenen Ablageort und Modell-Endpunkt. Der Checkout kann die Toolbox oder das eigenständige Skill-Repository enthalten. Jeder Arbeitsplatz erhält seine eigene Installation. Zugangsdaten werden separat pro Benutzer provisioniert und nie im Release mitgeliefert.

Der Datenfluss muss zur Klassifikation passen: `--local` hält Audioverarbeitung lokal, `--analysis model` sendet Text/Bilder zum konfigurierten Endpunkt, `--analysis harness` verwendet die Datenverarbeitung des Clients. `--analysis none` führt keine Analyse im Modell aus. Schwärzung finaler Bilder verhindert nicht die vorherige Übertragung der Quellbilder für die Auswertung.

## Checkout und Projektverknüpfung

Der folgende interaktive Block prüft vorhandene Checkouts und Junctions, bevor er etwas ändert. In einer administrierten Installation die vier Eingaben durch explizite Deployment-Parameter ersetzen. Er läuft mit Toolbox- und Split-Layout. Das Beispiel registriert den Skill in Claude Code; andere Harnesses verwenden ihren eigenen Skill-Pfad oder direkt die portable CLI.

```powershell
$ErrorActionPreference = 'Stop'
$Repository = Read-Host 'Approved AI-Toolbox Git URL'
$Version = Read-Host 'Approved full commit ID'
$Checkout = Read-Host 'Absolute path for the dedicated AI-Toolbox checkout'
$Project = Read-Host 'Absolute path of the working project'

if ($Version -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'A full commit ID is required.'
}
if (-not [System.IO.Path]::IsPathRooted($Checkout)) {
    throw 'The checkout path must be absolute.'
}
if (-not [System.IO.Path]::IsPathRooted($Project) -or
    -not (Test-Path -LiteralPath $Project -PathType Container)) {
    throw 'The working project must be an existing absolute directory.'
}

if (-not (Test-Path -LiteralPath $Checkout)) {
    New-Item -ItemType Directory -Path (Split-Path $Checkout -Parent) -Force | Out-Null
    git clone -- $Repository $Checkout
    if ($LASTEXITCODE -ne 0) { throw 'Git clone failed.' }
}
if (-not (Test-Path -LiteralPath (Join-Path $Checkout '.git') -PathType Container)) {
    throw 'The checkout path is not a dedicated Git clone.'
}
$Origin = git -C $Checkout remote get-url origin
if ($LASTEXITCODE -ne 0 -or $Origin -ne $Repository) {
    throw 'The existing checkout does not use the requested repository URL.'
}
$CurrentVersion = git -C $Checkout rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the installed version.' }
if ($CurrentVersion -ne $Version) {
    $Changes = git -C $Checkout status --porcelain
    if ($LASTEXITCODE -ne 0) { throw 'Cannot check local changes.' }
    if ($Changes) { throw 'Local changes exist. Resolve them before switching versions.' }
    git -C $Checkout fetch origin
    if ($LASTEXITCODE -ne 0) { throw 'Git fetch failed.' }
    git -C $Checkout checkout --detach $Version
    if ($LASTEXITCODE -ne 0) { throw 'The approved version is not available.' }
}

$Skill = if (Test-Path -LiteralPath (Join-Path $Checkout 'SKILL.md')) { $Checkout } else { Join-Path $Checkout '.agents\skills\transcribe' }
if (-not (Test-Path -LiteralPath (Join-Path $Skill 'SKILL.md') -PathType Leaf)) {
    throw 'SKILL.md is missing at the expected location.'
}
$SkillParent = Join-Path $Project '.claude\skills'
New-Item -ItemType Directory -Path $SkillParent -Force | Out-Null
$Link = Join-Path $SkillParent 'transcribe'
if (Test-Path -LiteralPath $Link) {
    $ExistingLink = Get-Item -LiteralPath $Link -Force
    if ($ExistingLink.LinkType -ne 'Junction' -or
        [System.IO.Path]::GetFullPath([string]$ExistingLink.Target) -ne
        [System.IO.Path]::GetFullPath($Skill)) {
        throw 'The skill destination exists and does not match the requested junction.'
    }
} else {
    New-Item -ItemType Junction -Path $Link -Target $Skill | Out-Null
}
Get-Item -LiteralPath $Link | Select-Object FullName, LinkType, Target
```

Die Projekt-Ignore-Datei um `/.claude/skills/transcribe` ergänzen; die Junction nicht committen. Falls Junctions nicht erlaubt sind, das vollständige kuratierte Skill-Bundle verteilen. Es enthält unter anderem `SKILL.md`, `INSTALL.md`, `transcribe.py`, `scripts/` und `references/`; keine lokalen Schlüssel, Modelle oder Medien.

## Laufzeit und Abnahme

Nach [INSTALL.md](../INSTALL.md) das benötigte Profil installieren und mit `doctor` verifizieren. Für unbeaufsichtigte Installationen `--non-interactive` verwenden. Ein sichtbarer Slash-Befehl bestätigt nur die Client-Erkennung. Der dort beschriebene Test mit einer bekannten Aufnahme prüft Transkription, Bilder, Sprecher und Wiederaufnahme.

Den getesteten Commit, Rechner/CPU/GPU, verwendeten Modell-Endpunkt, Laufzeit und das Ergebnis der Inhaltskontrolle im Freigabenachweis festhalten. Modellrechte beim ersten lokalen Sprecherlauf separat prüfen.

## Regulärer Ablauf und Publikation

Aufnahme, Glossar und Teilnehmerliste am freigegebenen Ablageort bereithalten. Der Name `YYYYMMDD-hhmm - Thema` ist eine Empfehlung für neue Aufnahmen. Bestehende Aufnahmen müssen nicht umbenannt werden.

Mit `transcribe.py run` verarbeiten. Optional am Sprecher-Gate anhalten, Zuordnungen in `speakers.md` korrigieren und fortsetzen. Bericht, Transkript, Hörproben, Bilder und Ziel anhand `review.md` prüfen. `transcribe.py publish --dry-run` erzeugt eine lokale Vorschau; der echte Publish-Aufruf folgt erst nach menschlicher Freigabe. Die PMO-Übernahme bleibt ein externer Prozess.

Das [Ablaufdiagramm](transcribe-ablauf.png) ([Draw.io-Quelle](transcribe-ablauf.drawio)) zeigt den fachlichen Ablauf. Befehle und Defaults sind ausschliesslich in der CLI-Hilfe, [INSTALL.md](../INSTALL.md) und der [generierten Parameterreferenz](parameters.md) massgeblich.
