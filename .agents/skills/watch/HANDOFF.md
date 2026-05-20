# Handoff — Multi-STT-Strategie für den `/watch`-Skill

> Kontext-Transfer-Dokument. Stand: 2026-05-20. Erstellt, damit eine neue
> Session die laufende Arbeit nahtlos übernehmen kann. Nach erfolgreichem
> Transfer darf diese Datei gelöscht werden — sie ist kein permanenter
> Repo-Bestandteil.

---

## 1. Worum es geht

Dieses Repo (`/home/daniel/Develop/claude-video`) **ist der Quellcode des
`/watch`-Skills** — ein Claude-Code-Plugin, mit dem Claude Videos
analysieren kann (Frames extrahieren + Transkript + Diarisierung). Reines
Python-stdlib, keine pip-Abhängigkeiten; `ffmpeg`/`ffprobe`/`yt-dlp` als
externe Binaries.

Die laufende Arbeit: **eine Strategie für mehrere Speech-to-Text-Backends**.
Ausgangslage war eine fest auf Whisper verdrahtete Transkriptions-Pipeline.
Ziel: eine pluggbare Abstraktion, damit ein neues STT-Backend nur noch ein
Registry-Eintrag + zwei Funktionen ist — statt die Pipeline neu zu bauen.

Treiber: SBB-interne Inhalte dürfen **nicht** in öffentliche Clouds (Groq,
OpenAI, AssemblyAI). Dafür gibt es ein privates Azure-Backend
(`gpt-4o-transcribe-diarize`), das auf dem eigenen Azure-Tenant läuft und
Transkription + Diarisierung in einem Call macht.

---

## 2. Stand der Arbeit — was fertig ist

Die Strategie wurde in Etappen gebaut. Alle vier sind committet und gepusht
auf `main`:

| Commit    | Etappe | Inhalt |
|-----------|--------|--------|
| `f601990` | —      | `scripts/whisper.py` → `scripts/stt.py` umbenannt (Modul ist nicht mehr Whisper-spezifisch) |
| `8a561d2` | 1      | `STTBackend`-Abstraktion + Registry + generischer Orchestrator; `WhisperBackend` (Groq/OpenAI) als erste Backends |
| `adef8e4` | 2 + 3  | `AzureDiarizeBackend`, Dauer-Chunking, `claude-opus-4-7`-Speaker-Reconcile, **Preflight-Checks** |
| `614be04` | 4      | `watch.py` wählt Backends über die Registry (Azure-Auto-Wahl); `azure_transcribe_test.py` zu dünner Hülle über Produktivcode umgebaut |

**Verifiziert:** Whisper-Pfad ohne Regression; Azure-Backend end-to-end mit
echtem 40-s-Single-Chunk-Call (6 Segmente, Speaker-Label `[A]`, SBB-Inhalt
blieb auf Azure); `watch.py` transkribiert end-to-end via `azure-diarize`;
der Test-Harness läuft durch den Produktivcode.

**Noch NICHT verifiziert (das ist der wichtige offene Test):** der
**Multi-Chunk-Pfad** — Audio >600 s, das gechunkt + pro Chunk diarisiert +
via `claude-opus-4-7` reconciled wird. Das braucht den `AZURE_CLAUDE_KEY`,
den der User noch platzieren muss.

---

## 3. Die STT-Architektur (in `scripts/stt.py`)

### Das Abstraktions-Prinzip

Jedes STT-Backend ist eine `STTBackend`-Subklasse mit **deklarativer
Policy** + zwei Methoden. Der generische Orchestrator macht den Rest.

```
STTBackend (Basisklasse)
  name           str
  chunk_by       "size" | "duration" | None   -> wie wird gechunkt
  chunk_limit    float                        -> MB (size) bzw. Sek. (duration)
  chunk_overlap  float                        -> Sek. Überlappung
  diarization    "none" | "per-chunk" | "global"
  available()    -> (bool, reason)            -> ist es konfiguriert?
  transcribe_one(audio_path) -> [segments]    -> EINEN Chunk transkribieren
```

Der Schlüssel ist `diarization`:
- `none` (Whisper) — keine Sprecher, kein Nachbearbeitungs-Schritt.
- `per-chunk` (Azure) — Labels sind chunk-lokal → `reconcile_speakers()` nötig.
- `global` (zukünftig AssemblyAI/MAI) — Labels schon korrekt, kein Reconcile.

### Konkrete Backends

| Backend (Registry-Name) | Klasse | chunk_by | diarization | Keys |
|---|---|---|---|---|
| `azure-diarize` | `AzureDiarizeBackend` | duration (600 s) | per-chunk | `AZURE_TRANSCRIBE_DIARIZE_URL/_KEY` |
| `groq` | `WhisperBackend("groq")` | size (20 MB) | none | `GROQ_API_KEY` |
| `openai` | `WhisperBackend("openai")` | size (20 MB) | none | `OPENAI_API_KEY` |

Registry: `BACKEND_FACTORIES` (dict). Reihenfolge = Priorität —
`azure-diarize` zuerst, damit `/watch` den privaten Backend bevorzugt.

### Der generische Orchestrator

`transcribe_audio(audio_path, backend, chunks_dir, parallel_uploads)`:
1. `_probe_duration` (nur bei duration-Backends).
2. **`preflight(backend, audio_seconds)`** — Fail-Fast-Gate, siehe unten.
3. `_plan_chunks` — dispatcht nach `chunk_by` (`_chunk_audio` size /
   `_chunk_audio_by_duration` duration).
4. Single-Chunk → `backend.transcribe_one()`. Multi-Chunk →
   `_transcribe_chunks()` (parallel-aware) → `_stitch_chunked_segments()`.
5. Wenn `diarization=="per-chunk"` und Multi-Chunk → `reconcile_speakers()`.

`transcribe_video(video, audio_out, backend=name, ...)` — dünner
Compat-Wrapper, der `extract_audio` + `transcribe_audio` bündelt.
`watch.py` ruft das.

### Preflight (das vom User geforderte Fail-Fast)

`preflight(backend, audio_seconds)` prüft **vor jeder Extraktion / jedem
API-Call**, ob alles konfiguriert ist, und gibt eine Liste von Problemen
zurück. Konkret: STT-Backend nutzbar? Und falls der Lauf Multi-Chunk auf
einem `per-chunk`-Backend wird → ist der `claude-opus-4-7`-Reconcile-Backend
(`AZURE_CLAUDE_URL/_KEY`) konfiguriert? So bricht ein 2000-s-Azure-Lauf ohne
Claude-Key in <1 s ab statt nach 25 min Upload.

### Speaker-Reconcile

`reconcile_speakers(segments)` — faltet chunk-lokale Labels (`C1-A`, `C2-B`,
…) via `claude-opus-4-7` zu echten Sprechern. Bei JEDEM Fehler (kein
Config, HTTP-Fehler, unparsebare Antwort) bleiben die chunk-getaggten Labels
erhalten + Warnung — ein brauchbares Transkript mit hässlichen Labels ist
besser als ein verlorener Lauf. Endpoint: Anthropic Messages API über den
Azure-AI-Foundry-Passthrough (`/anthropic/v1/messages`), Header `x-api-key`
+ `api-key` + `anthropic-version: 2023-06-01`.

---

## 4. Konfiguration (`~/.config/watch/.env`)

`.env.example` im Repo ist die committete, secret-freie Vorlage.
`setup.py` kopiert sie nach `~/.config/watch/.env`. Keys platziert der User
selbst; `.env` ist gitignored, wird nie nach stdout/Dateien geschrieben.

Relevante Variablen:
```
GROQ_API_KEY / OPENAI_API_KEY              Whisper
AZURE_TRANSCRIBE_DIARIZE_URL / _KEY        Azure STT (gesetzt)
AZURE_TRANSCRIBE_CHUNK_SECONDS=600         optional, Tuning
AZURE_TRANSCRIBE_OVERLAP_SECONDS=20        optional, Tuning
AZURE_TRANSCRIBE_TIMEOUT=900               optional, Tuning
AZURE_CLAUDE_URL / _KEY                    Reconcile  <-- KEY FEHLT NOCH
MAI_TRANSCRIBE_URL / _KEY                  MAI (Backend noch nicht gebaut)
```

Aktueller Zustand auf dieser Maschine: `GROQ_API_KEY` und
`AZURE_TRANSCRIBE_DIARIZE_URL/_KEY` sind gesetzt. **`AZURE_CLAUDE_KEY` ist
noch nicht gesetzt** — deshalb der offene Multi-Chunk-Test.

---

## 5. Tests, die jetzt zu machen sind

### 5a. Der wichtige Test: Multi-Chunk Azure + Reconcile

Voraussetzung: `AZURE_CLAUDE_URL` + `AZURE_CLAUDE_KEY` in
`~/.config/watch/.env` eintragen.

```bash
# Schneller 2-3-Chunk-Test (trimmt auf 1400 s):
python3 scripts/azure_transcribe_test.py <langes-audio.mp3> --max-seconds 1400

# Voller Lauf:
python3 scripts/azure_transcribe_test.py <langes-audio.mp3>

# Ganzer /watch-Pfad:
python3 scripts/watch.py <langes-video> --no-save-md
```

Zu prüfen: Chunking korrekt? Stitching ohne Textverlust an den Nähten?
`claude-opus-4-7`-Endpoint antwortet (HTTP 200)? Reconcile faltet die
`C1-A`/`C2-B`-Labels auf eine sinnvolle Sprecherzahl (NICHT 33 — siehe
Challenge 6c)? Report landet als `<name>.stt-test.md`.

### 5b. Regression Whisper

`python3 scripts/watch.py <video>` mit Whisper-Pfad (z. B. wenn Azure nicht
konfiguriert) — sollte unverändert funktionieren.

### 5c. Preflight

Multi-Chunk-Azure-Lauf OHNE `AZURE_CLAUDE_KEY` → muss in <1 s mit klarer
Meldung abbrechen, nicht transkribieren.

---

## 6. Offene Herausforderungen / Risiken

**6a. `claude-opus-4-7`-Endpoint unverifiziert.** Der Reconcile-Code ist
gebaut, aber noch nie gegen einen echten Endpoint mit Key gelaufen. Der
User war sich beim Endpoint-URL-Format unsicher
(`…services.ai.azure.com/anthropic/v1/messages`). Erster Multi-Chunk-Test
verifiziert das. Bei HTTP-Fehler: Auth-Header / `anthropic-version` /
URL prüfen.

**6b. Quadratische Verarbeitungszeit beim Azure-STT.** `gpt-4o-transcribe-
diarize` skaliert ~quadratisch mit Chunk-Länge: 600-s-Chunk ≈ 150 s API,
1400-s-Chunk sprengte 900 s Timeout. Deshalb Default 600 s. Bei Timeouts:
`AZURE_TRANSCRIBE_CHUNK_SECONDS` runter oder `AZURE_TRANSCRIBE_TIMEOUT` hoch.

**6c. Diarisierungs-Fragmentierung.** Jeder Chunk wird unabhängig
diarisiert → derselbe Sprecher kriegt pro Chunk neue Labels. Ein früher
Overlap-basierter Auto-Reconcile fragmentierte 3 echte Sprecher zu 33.
Lösung: kein Auto-Reconcile im Stitcher, stattdessen `claude-opus-4-7`, das
ALLE Chunk-Labels mit Textproben sieht und global auflöst. Das ist die
zentrale Annahme, die Test 5a validieren muss.

**6d. Kein Partial-Success bei Multi-Chunk.** Schlägt ein Chunk fehl
(Timeout), bricht `transcribe_audio` den ganzen Lauf ab — anders als der
alte Test-Harness, der erfolgreiche Chunks behielt. Bei langen Läufen wäre
ein Retry oder „behalte erfolgreiche Chunks" sinnvoll. Bewusst nicht gebaut
(Scope) — Kandidat für eine Folge-Etappe.

**6e. `--whisper`-Flag heisst noch so**, wählt aber auch `azure-diarize`.
Ein `--stt`-Alias wäre ehrlicher (kosmetisch). Ebenso die Konstante
`WHISPER_PARALLEL_UPLOADS` / das Flag `--whisper-workers`.

---

## 7. Etappe 5 — noch offen: MAI-Transcribe-1

Microsoft `MAI-Transcribe-1` ist ein alternatives STT-Deployment auf
demselben sicheren Backend. **Blockiert: der User kann es noch nicht
allozieren.** Wenn verfügbar: ein `MaiBackend(STTBackend)` in `stt.py`
schreiben (Registry-Eintrag + `available()` + `transcribe_one()` + die
Policy-Attribute), Limits unbekannt — evtl. akzeptiert es längeres Audio
als die 1500-s-Grenze von Azure und braucht weniger/keine Chunks. `.env`
hat `MAI_TRANSCRIBE_URL/_KEY` schon vorbereitet. Dank der Abstraktion ist
das genau das: ein Deskriptor + zwei Funktionen, Pipeline unangetastet.

---

## 8. Schlüsseldateien

| Datei | Rolle |
|---|---|
| `scripts/stt.py` | **STT-Modul** — Abstraktion, Backends, Orchestrator, Reconcile, Preflight |
| `scripts/watch.py` | Entry-Point; wählt STT-Backend via `select_backend()` |
| `scripts/transcribe.py` | VTT-Parsing + `merge_speaker_turns` + `format_transcript` (shared) |
| `scripts/azure_transcribe_test.py` | Dünner Test-Harness über `transcribe_audio` (keine Duplikate) |
| `scripts/diarize.py` | AssemblyAI / pyannote-Backends (separater `--diarize`-Pfad, unverändert) |
| `scripts/setup.py` | Preflight + Installer + `.env`-Scaffolding |
| `.env.example` | Committete Vorlage aller Keys |
| `SKILL.md` | Skill-Contract |

`stt.py`-Funktionen, die ein neuer Entwickler kennen sollte:
`STTBackend`, `WhisperBackend`, `AzureDiarizeBackend`, `BACKEND_FACTORIES`,
`get_backend`, `select_backend`, `transcribe_audio`, `transcribe_video`,
`preflight`, `reconcile_speakers`, `_get_config`, `_chunk_audio_by_duration`,
`_stitch_chunked_segments`.

---

## 9. Arbeitskonventionen (aus dem globalen CLAUDE.md)

- **Sprache:** Deutsch (Schweiz) — `ss` statt `ß`, echte Umlaute überall.
  **Commit-Messages auf Englisch.**
- **Git:** Trunk-based auf `main`. Ablauf je Änderung: Pull → Read →
  Changes → Commit → Push. Nicht uncommittet liegen lassen.
- **Idempotenz:** alle Skripte beliebig oft ausführbar.
- **Keine Duplikation:** vor neuem Code prüfen, ob etwas existiert.
- **Bei Unsicherheit fragen** — besonders bei Architektur-Entscheidungen.
- **Plugin-Cache:** nach Skript-Änderungen die Kopie in
  `~/.claude/plugins/cache/claude-video/watch/0.1.2/` mitziehen (sonst
  läuft der Skill auf veraltetem Code).
- **Keys/Secrets:** nie hardcoden, nie nach stdout/Dateien schreiben.
  `.env` ist gitignored, `.env.example` ist secret-frei.

---

## 10. Nächster Schritt für die neue Session

1. User fragen, ob `AZURE_CLAUDE_KEY` platziert ist.
2. Falls ja: Test 5a fahren (`azure_transcribe_test.py --max-seconds 1400`
   auf einem langen MP3), Report gemeinsam auswerten — besonders ob der
   Reconcile eine plausible Sprecherzahl liefert (Challenge 6c).
3. Bei Endpoint-Fehlern: Challenge 6a abarbeiten.
4. Optional: Challenge 6d (Partial-Success) oder 6e (`--stt`-Alias) als
   kleine Folge-Etappe.
5. Etappe 5 (MAI), sobald der User es allozieren kann.
