---
name: doc-consistency
description: "Re-Read-Guard und Konsistenz-Propagation über gekoppelte Dokument-Artefakte (lokales Markdown ↔ Confluence-Seite ↔ Jira-Felder). Verwenden wenn: der User sagt «ich habe das Dokument angepasst, zieh den Rest nach», «mach es wieder konsistent», «lies zuerst nochmals ein», «auf Confluence gleich mitaktualisieren», oder wenn in einer Session dasselbe geteilte Dokument mehrfach editiert wird (User editiert erfahrungsgemäss parallel out-of-band)."
user-invocable: true
allowed-tools: Bash, Read, Edit, Grep, Glob
metadata:
  version: "0.0.1"
---

# /doc-consistency — Blind-Edits verhindern, Kopplungen nachziehen

Zwei wiederkehrende Probleme, ein Skill: (1) Claude editiert ein Dokument auf Basis eines veralteten Read-Stands, während der User es parallel geändert hat. (2) Ein Dokument existiert in mehreren gekoppelten Formen (MD, Confluence, Jira-Feld) und Änderungen versanden in einer davon.

## Teil 1 — Re-Read-Guard (vor JEDEM Edit an einem geteilten Dokument)

1. Beim ersten Kontakt mit dem Dokument Hash merken:
   ```bash
   md5sum "pfad/dokument.md"
   ```
2. Vor jedem weiteren Edit in derselben Session: Hash erneut berechnen und vergleichen. Nach jedem `/compact` gilt der Read-Stand grundsätzlich als ungültig → immer neu lesen.
3. Bei Divergenz: NICHT editieren. Erst Diff zeigen (`git diff` falls versioniert, sonst gegen letzte bekannte Fassung), neu einlesen, den geplanten Edit auf den neuen Stand rebasen, dann editieren.
4. Nach User-Aussagen wie «ich habe noch etwas angepasst» oder «schau, was ich geändert habe»: immer zuerst Diff/Neu-Lesen, dann erst weiterarbeiten — nie aus dem Gedächtnis beantworten, was im Dokument steht.

## Teil 2 — Kopplungsgruppen deklarieren und propagieren

Zu Beginn der Arbeit die Kopplungsgruppe explizit machen (und im Verlauf aktuell halten):

```
Gruppe «Betriebskonzept»:
  - lokal:      docs/betriebskonzept.md          (führend für Inhalt)
  - confluence: Seite 123456789                   (Publikation)
  - jira:       ABC-42, Feld «Description»        (Verweis/Auszug)
```

Regeln:
- **Eine führende Quelle pro Gruppe** (normalerweise das lokale MD). Änderungen an der führenden Quelle werden in die anderen propagiert; Änderungen in einer nachgelagerten Form (z.B. Confluence-Kommentar-Einarbeitung) werden zuerst in die führende Quelle zurückgeholt, dann regulär propagiert.
- **Nach jeder inhaltlichen Änderung** fragen: Welche Mitglieder der Gruppe sind jetzt stale? Alle stale Mitglieder in derselben Arbeitseinheit nachziehen — nicht auf «später» verschieben. Wenn der User «immer auch gleich auf Confluence aktualisieren» etabliert hat, gilt das als stehende Anweisung für die Gruppe.
- **Widersprüche melden statt überschreiben:** Wenn zwei Formen unabhängig divergiert sind, beide Diffs zeigen und den User entscheiden lassen; niemals still eine Seite als Verlierer wählen.

## Werkzeuge

- Upload/Merge MD→Confluence: `sbb-atlassian`-Plugin (`atlassian-connect`) — macht Chapter-Level-Merge und schützt HIL-validierte Kapitel; diesen Weg nutzen statt `confluence_update_page` roh, sobald die Seite kapitelweise gepflegt wird.
- Rückrichtung Confluence→MD: `confluence_get_page` + gezielter Abgleich; Confluence-only-Änderungen als Diff ins MD zurückschreiben.
- Jira-Felder: `jira_update_issue` nur mit dem propagierten Auszug, nie mit dem Volltext, wenn das Feld nur eine Zusammenfassung trägt.

## Abgrenzung

`sbb-atlassian` ist das Upload-Backend (Einbahn MD→Confluence mit Merge); dieser Skill liefert die Session-Disziplin darum herum: Re-Read-Guard, Gruppen-Deklaration, bidirektionale Propagation, Konfliktmeldung.
