# Evaluationen für component-audit

`evals.json` enthält drei Szenarien im Format der Anthropic-Best-Practices: Standard-Audit nach einer UI-Änderung, Bootstrap ohne Inventar und Loop mit Codex als Auditor. Die Dateien unter `files` sind Platzhalter – für einen Lauf ein kleines Testprojekt mit passenden Dateien und eingebauten Bypässen bereitstellen (z.B. ein von Hand gebautes `.thumb-card` neben der Factory).

Manueller Ablauf pro Szenario:

1. **Baseline ohne Skill:** Frische Claude-Code-Session im Testprojekt, Skill nicht installiert (oder Verzeichnis temporär umbenennen), `query` eingeben und das Verhalten notieren.
2. **Mit Skill:** Frische Session mit installiertem Skill, gleiche `query`, gleiches Ausgangs-Commit im Testprojekt (`git stash` bzw. `git reset` auf den Startstand zwischen den Läufen).
3. **Bewerten:** Jeden Punkt in `expected_behavior` als erfüllt oder nicht erfüllt markieren und die beiden Läufe vergleichen. Der Skill lohnt sich nur, wenn er die Baseline klar übertrifft.

Szenario 3 braucht eine funktionierende Codex-CLI mit Login. Nach Änderungen an `SKILL.md` oder `references/` alle drei Szenarien erneut laufen lassen und fehlende Punkte als Anlass für Anpassungen am Skill nehmen.
