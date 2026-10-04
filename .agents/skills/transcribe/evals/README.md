# Evaluationen für transcribe

`evals.json` enthält drei realistische Szenarien im Format von Anthropic (`skills`, `query`, `files`, `expected_behavior`): ein YouTube-Video mit Zusatzfrage (Auslösung, Captions statt Whisper, Fokus-Lauf, Chat-Antwort), eine vertrauliche Audio-Aufnahme (on-device, Basisname, Sprecherzuordnung) und eine Korrektur an einem bestehenden Lauf (Overrides, Repair-Pass, Cache-Resume).

Manuell ausführen: Für jedes Szenario eine frische Claude-Code-Session öffnen, die `query` wörtlich eingeben und die referenzierten `files` bereitlegen (eigene Testaufnahmen umbenennen oder Pfade anpassen). Einmal mit installiertem Skill laufen lassen, einmal als Baseline ohne Skill (Plugin deaktivieren oder Skill-Verzeichnis temporär aus `~/.claude/skills/` entfernen).

Beobachten statt nur das Endergebnis prüfen: Wird der Skill ausgelöst, welche Referenzdateien werden gelesen, welche Kommandos und Flags laufen, und wo weicht Claude von `expected_behavior` ab. Jeden Punkt als erfüllt oder nicht erfüllt notieren und den Vergleich zur Baseline festhalten.

Abweichungen führen zu gezielten Anpassungen an `SKILL.md` oder der betroffenen Referenzdatei, danach das Szenario erneut laufen lassen. Neue Fehlerfälle aus echten Läufen als zusätzliches Szenario ergänzen.
