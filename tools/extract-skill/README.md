# extract-skill — einen Skill aus der AI-Toolbox herauslösen

Zieht einen Skill samt Git-History in ein eigenes Repository und hängt ihn am selben Pfad wieder als Submodul ein. Der Skill bleibt unter `.agents/skills/<name>`, damit die Junction nach `~/.claude/skills` und der Katalog-Eintrag unverändert weiterfunktionieren — nur der Unterbau wechselt vom Verzeichnis zum Submodul.

## Warum das mit diesem Setup funktioniert

Drei Eigenschaften machen den Schnitt sauber, sie gelten für `transcribe` nachweislich und sind bei jedem weiteren Skill vorher zu prüfen:

- Der Skill ist bereits repo-förmig: eigene `LICENSE`, `README.md`, `.gitignore`, `.gitattributes` und `.claude-plugin/plugin.json`. Sein `scripts/build-skill.sh` ruft `git archive HEAD` von der Repo-Wurzel aus auf, war also von Anfang an für ein eigenständiges Repo geschrieben.
- Er ist im Repo entkoppelt: die einzige Referenz von aussen ist sein Katalog-Eintrag in `tools/catalog.json`.
- `SKILL.md` adressiert die eigenen Skripte über `${CLAUDE_SKILL_DIR}`, nicht über absolute Pfade. Ein Skill mit hartkodierten Pfaden müsste vorher umgestellt werden.

## Drei Anpassungen, die die Extraktion überhaupt erst möglich gemacht haben

Die Versionierungs-Maschinerie war auf `.agents/skills/<name>/` als Pfadmuster verdrahtet und hätte einen Skill an der Repo-Wurzel nicht mehr erkannt:

1. **`tools/bump-version.sh`** löst jetzt auch einen Skill auf, der selbst die Repo-Wurzel ist (`SKILL.md` neben `.git`). Vorher lieferte `scripts/run.py` in so einem Repo gar kein Artefakt — kein Bump, kein Tag — und `SKILL.md` löste auf die eigene Frontmatter auf, also auf eine zweite Versionsquelle neben `plugin.json`.
2. **`tools/githooks/post-commit`** leitet den Tag-Namen aus dem Manifest ab statt aus dem Dateinamen. Vorher wären Tags `plugin.json/v1.52.184` entstanden; `drive-sync` trägt mit `transcribe/v1.29.131` und `transcribe/v1.30.132` zwei Tags aus genau dieser Fehlerklasse.
3. **`toolbox.sh`** behandelt ein deklariertes, aber nicht ausgechecktes Submodul als Bootstrap-Hinweis statt als Katalogfehler. Sonst würde `toolbox validate` nach jedem `git clone` ohne `--recurse-submodules` fehlschlagen und über den pre-commit-Gate auch das Committen blockieren.

## Ablauf

Das Skript ist idempotent: ein vorhandenes Ziel wird neu konfiguriert statt erneut extrahiert, Remotes werden angelegt oder korrigiert statt gedoppelt, gelöscht wird nichts. Eine Neu-Extraktion verlangt bewusst, das Zielverzeichnis von Hand wegzuräumen.

```bash
# 1. Probelauf — zeigt Pfade, Commit-Zahlen und Ziel, ohne etwas anzufassen
tools/extract-skill/extract-skill.sh transcribe --dry-run \
  --also-path .agents/skills/watch \
  --origin https://git.frey-champagne-import.com/daniel/transcribe.git \
  --remote github=git@github.com:danielfrey63/transcribe.git

# 2. Extraktion — Klon, filter-repo, Tag-Bereinigung, Remotes, Hooks
tools/extract-skill/extract-skill.sh transcribe \
  --also-path .agents/skills/watch \
  --origin https://git.frey-champagne-import.com/daniel/transcribe.git \
  --remote github=git@github.com:danielfrey63/transcribe.git

# 3. Remotes anlegen (Forgejo/GitHub, von Hand), dann pushen
git -C ../transcribe push -u origin main --follow-tags
git -C ../transcribe push github main --follow-tags

# 4. Als Submodul zurückhängen und hier committen
tools/extract-skill/extract-skill.sh transcribe --embed \
  --origin https://git.frey-champagne-import.com/daniel/transcribe.git
git add .gitmodules .agents/skills/transcribe && git commit
```

`--also-path` nimmt frühere Pfade des Skills mit, damit Renames nicht die History abschneiden. Für `transcribe` ist das `.agents/skills/watch`: der Skill hiess bis zum Rename `watch`, was 14 der insgesamt 53 Commits ausmacht.

### Was das Skript mit den Tags macht

`git filter-repo --tag-rename` reicht hier nicht: die Option wird nur einmal berücksichtigt, kann also nicht zwei historische Namen abdecken, und filter-repo behält jeden Tag, dessen Ziel-Commit überlebt hat. Nach dem Verengen auf einen Skill blieben so 190 fremde Tags des Toolbox-Namespaces (`toolbox.sh/v*`, `CLAUDE.md/v*`, …) auf unbeteiligten Commits stehen. Das Skript hebt daher die eigenen Tags selbst aus ihrem Namespace (`transcribe/v1.52.184` → `v1.52.184`, weil ein Standalone-Repo genau ein Artefakt hat) und verwirft den Rest. Bei `transcribe` bleiben 50 Tags von `v0.0.1` bis `v1.52.184` übrig.

`bumpversion.tagstyle=plain` wird gesetzt, **bevor** im neuen Repo der erste Commit entsteht. Der post-commit-Hook taggt im jeweils geltenden Stil, und eine gemischte Tag-History lässt sich nachträglich nur durch erneutes Umschreiben bereinigen.

## Zustand nach dem Klonen

Ein Klon des ai-toolbox braucht den Submodul-Inhalt:

```bash
git clone --recurse-submodules <ai-toolbox>
# oder nachträglich:
git submodule update --init .agents/skills/transcribe
```

Ohne diesen Schritt ist das Verzeichnis leer. `toolbox validate` meldet das seit der oben genannten Anpassung als Hinweis mit Handlungsanweisung statt als Fehler.

## Verteilung nach SBB (cc-plugins)

SBB bekommt kein drittes Remote, sondern den Skill über das dort bereits laufende Marketplace-Repo `ai-tools-exploration/cc-plugins`. Ein Submodul funktioniert dort nicht, weil `/plugin install` den Marketplace klont, ohne Submodule aufzulösen — der Inhalt muss also als Datei vorliegen. Der Weg dafür ist `git subtree`:

```bash
# einmalig
git -C <cc-plugins> subtree add  --prefix=plugins/transcribe <transcribe-repo> main --squash
# bei jedem Update
git -C <cc-plugins> subtree pull --prefix=plugins/transcribe <transcribe-repo> main --squash
```

Als Quelle taugt auch der lokale Checkout (`../transcribe`), falls FCI vom SBB-Netz aus nicht erreichbar ist.

Zwei Punkte sind beim ersten Einhängen noch zu entscheiden, weil `cc-plugins` seine Skills als `plugins/<plugin>/skills/<skill>` ablegt, `transcribe` seine `SKILL.md` aber an der Plugin-Wurzel führt:

- **Direkt als Plugin** (`--prefix=plugins/transcribe`): einfachster Sync, das mitgelieferte `.claude-plugin/plugin.json` wird direkt verwendet.
- **Als Skill im Plugin** (`--prefix=plugins/transcribe/skills/transcribe`): passt zur Hausform der übrigen SBB-Plugins, verlangt aber ein separat in `cc-plugins` gepflegtes `plugins/transcribe/.claude-plugin/plugin.json`.

In beiden Fällen muss `cc-plugins/.claude-plugin/marketplace.json` einen Eintrag für `transcribe` bekommen.
