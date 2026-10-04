# Evaluationen für idempotent-devops

`evals.json` enthält drei realistische Szenarien (Scaffold, Audit, Verify-Loop) im Format der Anthropic-Best-Practices: pro Eintrag die `query`, optionale Eingabedateien unter `files` und die erwarteten Verhaltensweisen unter `expected_behavior`.

## Manuell ausführen

1. Für Szenarien mit `files` ein Wegwerf-Verzeichnis anlegen und dort passende Beispieldateien hinlegen (z.B. ein `deploy.sh` mit `>> /etc/hosts`, `mkdir` ohne `-p` und ohne `cleanup`). Nie gegen produktive Hosts testen.
2. **Baseline:** eine frische Session ohne diesen Skill starten (Skill nicht verlinkt oder deaktiviert), die `query` wörtlich eingeben und die Antwort sichern.
3. **Mit Skill:** eine frische Session mit verlinktem Skill starten, dieselbe `query` eingeben und die Antwort sichern.
4. Beide Antworten Punkt für Punkt gegen `expected_behavior` abhaken. Ein Punkt gilt nur als erfüllt, wenn er klar sichtbar ist.
5. Der Skill lohnt sich, wenn er die Baseline deutlich übertrifft. Fällt ein Punkt mit Skill durch, `SKILL.md` oder die Referenzen gezielt nachschärfen und das Szenario erneut laufen lassen.

Zusätzlich prüfen, ob der Skill bei der `query` überhaupt geladen wird. Wird er nicht ausgelöst, liegt das Problem in der `description`, nicht im Body.
