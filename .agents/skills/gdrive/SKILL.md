---
name: gdrive
description: Liest Google-native Dateien (.gsheet/.gdoc/.gslides-Pointer) aus einem Google-Drive-Sync-Ordner («Meine Ablage»/«My Drive») über die Google-MCP-Tools, statt an den lokalen JSON-Pointern zu scheitern, und sucht/liest Drive-Inhalte generell. Verwenden wenn - eine .gsheet/.gdoc/.gslides/.gdraw-Datei gelesen werden soll, ein Pfad unter einem Drive-Sync-Ordner liegt und nur ein Pointer zurückkommt, «auf Google Drive suchen», ein Google Sheet strukturiert ausgewertet werden soll, oder ein autonomer Lauf Unterlagen-Ordner mit Google-nativen Dateien sichtet.
argument-hint: "<pfad-zur-pointer-datei | suchbegriff>"
allowed-tools: Read, Glob, Grep, ToolSearch
homepage: https://github.com/danielfrey63/ai-toolbox
repository: https://github.com/danielfrey63/ai-toolbox
license: MIT
metadata:
  version: "0.1.2"
---

# /gdrive — Google-native Dateien aus einem Drive-Sync-Ordner lesen

Google Drive for Desktop synchronisiert normale Dateien (xlsx, pdf, docx, jpg, …) als echte Dateien — die liest du direkt lokal, ganz ohne diesen Skill. Google-**native** Dokumente (Sheets, Docs, Slides, Drawings, Forms) liegen dagegen nur als **Pointer-Dateien** im Sync-Ordner: `.gsheet`, `.gdoc`, `.gslides`, `.gdraw`, `.gform` — kleine JSON-Dateien mit URL und Dokument-ID, ohne Inhalt. Dieser Skill definiert den Weg vom Pointer zum Inhalt über die Google-MCP-Tools.

Typische Sync-Ordner: `D:\Meine Ablage\…` («My Drive» auf Deutsch), `G:\Meine Ablage\…`, `~/Google Drive/…`.

## Schritt 1 — Pointer auflösen

Die Pointer-Datei mit `Read` lesen. Inhalt ist JSON; das Format variiert nach Drive-Client-Version:

```json
{"":"ACHTUNG! BITTE BEARBEITEN SIE DIESE DATEI NICHT. …","doc_id":"<ID>","resource_key":"","email":"…"}
{"url":"https://docs.google.com/spreadsheets/d/<ID>/edit?usp=drive_fs","doc_id":"<ID>","email":"…"}
```

`doc_id` verwenden; fehlt das Feld, die ID aus dem URL-Muster `/d/<ID>/` extrahieren. Ein nicht-leeres `resource_key`-Feld (ältere Freigaben) mitführen, falls vorhanden.

## Schritt 2 — MCP-Tools laden (EINE ToolSearch)

Die Google-MCP-Tools sind meist deferred. Alle benötigten Tools in **einem** ToolSearch-Call laden, nicht einzeln:

- Für Sheets: `select:mcp__google-sheets__list_sheets,mcp__google-sheets__get_sheet_data,mcp__google-sheets__get_multiple_sheet_data`
- Für Docs/Slides/Suche: `select:mcp__claude_ai_Google_Drive__read_file_content,mcp__claude_ai_Google_Drive__download_file_content,mcp__claude_ai_Google_Drive__get_file_metadata,mcp__claude_ai_Google_Drive__search_files`

## Schritt 3 — Inhalt lesen (Typ-Mapping)

| Pointer | Primärweg | Fallback |
|---------|-----------|----------|
| `.gsheet` | `google-sheets`-MCP: `list_sheets(doc_id)` → `get_sheet_data` pro Tab (strukturiert, mit Formeln via `get_sheet_formulas`) | `claude_ai_Google_Drive.read_file_content(doc_id)` — **ACHTUNG: liefert nur das erste Tab** (verifiziert an einem 7-Tab-Sheet). Für alle Tabs das XLSX-Export-Rezept unten verwenden. |
| `.gdoc` | `claude_ai_Google_Drive.read_file_content(doc_id)` | `download_file_content` (Export) |
| `.gslides` / `.gdraw` | `claude_ai_Google_Drive.read_file_content(doc_id)` | `download_file_content`, dann lokal weiterverarbeiten |
| kein Pointer, nur Name bekannt | `claude_ai_Google_Drive.search_files(name)` → ID → wie oben | `list_recent_files` |

Mehrere Tabs oder mehrere Sheets batchen (`get_multiple_sheet_data` / `get_multiple_spreadsheet_summary`) statt einzeln abzurufen — schneller und schonender für Rate-Limits.

## Sheets vollständig lesen ohne Sheets-API (XLSX-Export-Rezept)

Wenn der `google-sheets`-MCP 403 liefert und mehr als das erste Tab gebraucht wird:

1. `claude_ai_Google_Drive.download_file_content(fileId, exportMimeType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")` — liefert JSON `{content: <base64>, title, mimeType}`. Grosse Antworten persistiert der Harness als Datei (Pfad steht in der Fehlermeldung) statt sie inline zurückzugeben.
2. Base64 dekodieren und mit `openpyxl` alle Tabs dumpen (ins Scratchpad-Verzeichnis, nicht ins Projekt):

```python
import json, base64, pathlib, openpyxl
data = json.loads(pathlib.Path(PERSISTED_RESULT).read_text(encoding="utf-8"))
xlsx = pathlib.Path(SCRATCHPAD) / "export.xlsx"
xlsx.write_bytes(base64.b64decode(data["content"]))
wb = openpyxl.load_workbook(xlsx, data_only=True)
for name in wb.sheetnames:
    for row in wb[name].iter_rows(values_only=True):
        ...
```

`data_only=True` liefert berechnete Werte statt Formeln. Verifiziert: ein 7-Tab-Sheet (17 KB nativ, 60 KB XLSX) kommt so vollständig und strukturiert in den Kontext.

## Fehlerfälle und autonome Läufe

- **403 vom `google-sheets`-MCP («The caller does not have permission»):** Dieser Server authentisiert sich als Service-Account und sieht nur Sheets, die mit dessen E-Mail-Adresse geteilt wurden. Sofort auf `claude_ai_Google_Drive.read_file_content` ausweichen (liest, was das claude.ai-Google-Login sieht — beobachtet: funktioniert für private Sheets des Users). Wird die strukturierte Sheets-API wiederholt gebraucht, dem User einmalig vorschlagen, das Sheet/den Ordner mit der Service-Account-Adresse zu teilen.
- **MCP nicht verbunden / Auth abgelaufen:** Der `claude_ai_Google_Drive`-Connector existiert nur in interaktiv angemeldeten Sessions; in Headless-/Cron-Läufen kann er fehlen. Dann: nicht blockieren und nicht nachfragen — die Lücke explizit dokumentieren (welche Datei, warum unlesbar) und mit den lokal lesbaren Quellen weiterarbeiten. Das gilt besonders für autonome Läufe mit Never-ask-Regel (master-prompt-Muster).
- **Pointer ohne `doc_id` und ohne parsebare URL:** Datei als unlesbar protokollieren, per `search_files` über den Dateinamen einen zweiten Versuch machen.
- **Zugriff verweigert (fremde Freigabe):** dokumentieren, nicht wiederholt probieren.

## Scope

Nur Lesezugriffe. `create_file`, `copy_file` und Freigabe-Änderungen sind nicht Teil dieses Skills — nur auf explizite User-Anweisung nutzen.
