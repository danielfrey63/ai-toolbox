# Workspace Audit

Inventarisiert alle Git-Repositories unterhalb eines Workspace-Ordners und meldet Struktur- und Zustandsprobleme, die sich beim manuellen Aufräumen sonst nur mühsam zusammensuchen lassen. Das Skript ist rein lesend; einzig `--fetch` aktualisiert Remote-Tracking-Refs, damit ahead/behind stimmen.

## Verwendung

```
workspace-audit [--depth N] [--fetch] [--quiet] [ROOT ...]
```

`ROOT` ist ein oder mehrere Ordner (Default: aktuelles Verzeichnis). `--depth` bestimmt, wie tief nach Repositories und Struktur-Auffälligkeiten gesucht wird (Default 3). `--quiet` unterdrückt die Informationszeilen (Remote, Branch, Stashes) und zeigt nur Findings. Exit-Code 0 bei null Findings, sonst 1, damit sich der Lauf in Skripte einbauen lässt. `node_modules`, `.venv`, `__pycache__`, `.gradle`, `dist`, `build`, `target` werden nie betreten.

## Findings

Pro Repository (Zeile mit Pfad, darunter eingerückt Infos und Findings in eckigen Klammern):

| Code | Bedeutung |
|---|---|
| `SPLIT_GIT` | `.git` hat `config`/`HEAD`, aber kein `objects`/`refs` (oder umgekehrt). Entsteht, wenn ein `mv` eines Repos halb scheitert, z.B. auf Sync-Ordnern. |
| `NO_REMOTE` | Repository ohne Remote, Historie existiert nur lokal. |
| `DETACHED` | HEAD auf keinem Branch (bei Submodulen normal und darum dort nur Info). |
| `NO_UPSTREAM` | Branch ohne Upstream. |
| `AHEAD` / `BEHIND` | Lokaler Branch weicht vom Upstream ab (mit `--fetch` aktuell). |
| `DIRTY` | Anzahl geänderter oder ungetrackter Pfade. |
| `SUBMODULE_UNINIT` / `SUBMODULE_DRIFT` | Submodul nicht ausgecheckt bzw. auf anderem Commit als im Parent hinterlegt. |
| `NESTED_GIT` | Ein Clone innerhalb eines Repos, der kein Submodul ist. |
| `NAME_MISMATCH` | Ordnername entspricht nicht dem Repo-Namen aus der origin-URL (case-insensitiv verglichen, Submodule ausgenommen). |

Auf Workspace-Ebene (nur ausserhalb von Repository-Arbeitsbäumen, versteckte Ordner ausgenommen):

| Code | Bedeutung |
|---|---|
| `STRAY_GITMODULES` | `.gitmodules` in einem Ordner ohne `.git`. |
| `CONTAINER` | Ordner, dessen einziger Inhalt ein Unterordner ist (unnötige Zwischenebene wie `Marvin-Admin/maven-maintenance`). |
| `SAME_NAME_NESTED` | Ordner enthält einen gleichnamigen Unterordner (`2026/2026`, `CCAI/CCAI`). |

## Beispiel

```
== /d/Develop/Akros
/d/Develop/Akros/marvin
  remote: https://git.example.com/ccai/marvin.git
  branch: master -> origin/master
  stashes: 1
/d/Develop/Akros/old/2026
  [SPLIT_GIT] .git is meta-only - repository metadata is incomplete
/d/Develop/Akros/old/2026
  [SAME_NAME_NESTED] contains a sub-directory named '2026' again

2 finding(s)
```

## Installation

```
toolbox install --what workspace-audit
```

Legt `workspace-audit` als Kommando in `~/.local/bin` an (Symlink auf dieses Skript). Direkt ausführbar ist es auch ohne Installation: `tools/workspace-audit/workspace-audit.sh <root>`.
