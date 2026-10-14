# Evaluationen für transcribe

`evals.json` enthält Szenarien für Video mit Zusatzfrage, vertrauliches Audio, Korrektur und Harness-Installation. Neben Inhaltsqualität werden Datenfluss, korrekte CLI-Optionen, Wiederaufnahme und Geheimnisbehandlung geprüft. Automatisierte Offline-Regressionstests laufen mit `python -m unittest discover -s tests -v`.

Manuell ausführen: Für jedes Szenario eine frische Claude-Code-Session öffnen, die `query` wörtlich eingeben und die referenzierten `files` bereitlegen (eigene Testaufnahmen umbenennen oder Pfade anpassen). Einmal mit installiertem Skill laufen lassen, einmal als Baseline ohne Skill (Plugin deaktivieren oder Skill-Verzeichnis temporär aus `~/.claude/skills/` entfernen).

Beobachten statt nur das Endergebnis prüfen: Wird der Skill ausgelöst, welche Referenzdateien werden gelesen, welche Kommandos und Flags laufen, und wo weicht Claude von `expected_behavior` ab. Jeden Punkt als erfüllt oder nicht erfüllt notieren und den Vergleich zur Baseline festhalten.

Abweichungen führen zu gezielten Anpassungen an `SKILL.md` oder der betroffenen Referenzdatei, danach das Szenario erneut laufen lassen. Neue Fehlerfälle aus echten Läufen als zusätzliches Szenario ergänzen.
