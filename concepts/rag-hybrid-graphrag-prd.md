# PRD: Lokales Hybrid-RAG mit GraphRAG

**Status:** Entwurf · **Stand:** 2026-07-12 09:51 CEST · **Owner:** Daniel Frey

## 1. Problem

Klassisches Vektor-RAG findet semantisch ähnliche Textstellen, scheitert aber an zwei Fragetypen: exakte Begriffe/Identifikatoren (Namen, IDs, Fachtermini — hier ist Keyword-Suche überlegen) und Fragen über Zusammenhänge, die über mehrere Dokumente verteilt sind («Wie hängt X mit Y zusammen?», «Gib mir einen Überblick über Thema Z»). Es fehlt eine wiederverwendbare, lokale Pipeline, die alle drei Fragetypen abdeckt.

## 2. Lösung in einem Satz

Eine generische, quellenunabhängige Ingestion-und-Retrieval-Pipeline, die pro Dokument gleichzeitig einen Vektor-Index, einen Keyword-Index (BM25) und einen Entitäten-/Relations-Graph aufbaut und beim Retrieval die drei Signale fusioniert; alle Daten und Indizes bleiben lokal, LLM-Calls (Graph-Extraktion, Antwort-Generierung) laufen über [`llm-provider`](https://github.com/danielfrey63/llm-provider) und sind damit provider-agnostisch (primär Claude).

## 3. Ziele

1. **Generisch:** Datenquelle ist austauschbar (Markdown-Ordner, PDFs, Code, Exporte); neue Quellen brauchen nur einen Loader, keine Pipeline-Änderung.
2. **Hybrid-Retrieval:** Vektor-Ähnlichkeit + BM25, fusioniert per Reciprocal Rank Fusion (RRF), optional Reranking.
3. **GraphRAG:** LLM-extrahierte Entitäten und Relationen als Graph; Graph-Retrieval für Beziehungs- und Überblicksfragen (lokale Nachbarschaft + verdichtete Zusammenfassungen).
4. **Lokale Daten:** Dokumente, Chunks, Embeddings, Graph und Indizes liegen ausschliesslich auf eigener Hardware; nur Prompt-Inhalte gehen an die LLM-API.
5. **Inkrementell & idempotent:** Re-Runs indexieren nur Geändertes (Hash-basiert); Abbruch und Wiederholung schaden nie.
6. **Trigger-Schicht nach graphify-Vorbild:** Der Index-Lauf selbst ist trigger-agnostisch; darüber liegen drei dünne Auslöser: (A) manueller CLI-Aufruf, (B) git post-commit-Hook (indexiert nur die im Commit geänderten Dateien), (C) optionaler File-Watcher mit Debounce, der nur die billigen deterministischen Stufen (Chunking, BM25, lokale Embeddings) sofort ausführt und teure LLM-Stufen (Graph-Extraktion) lediglich als `needs_update`-Flag für den nächsten expliziten Lauf vormerkt.
7. **Provider-agnostisch:** Alle LLM-Calls über `llm-provider`; Modellwechsel ist Konfiguration, kein Code.

**Nicht-Ziele:** Kein Multi-User-Betrieb, keine Web-UI (CLI/API zuerst), kein permanenter Sync-Daemon als Kernbestandteil (der Watcher aus Ziel 6 ist opt-in und macht nie LLM-Calls von selbst), kein eigenes Frontend für Graph-Visualisierung (Export für bestehende Tools genügt).

## 4. Architektur (Skizze)

```
Quellen (md, pdf, code, …)
   │  Loader (pluggable)
   ▼
Chunking (strukturbewusst: Überschriften/Funktionen, Overlap)
   ├──► Embeddings ──► Vektor-Index ─┐
   ├──► Tokenisierung ──► BM25-Index ─┼──► RRF-Fusion ──► (Rerank) ─┐
   └──► LLM-Extraktion ──► Graph (Entitäten/Relationen/Summaries) ──┤
                                                                    ▼
                                              Kontext-Assembly ──► LLM-Antwort (llm-provider)
```

Retrieval-Strategie pro Frage: Faktenfrage → Hybrid (Vektor+BM25); Beziehungsfrage → Graph-Nachbarschaft der erkannten Entitäten + zugehörige Chunks; Überblicksfrage → Community-/Themen-Summaries. Der Router setzt dabei keine harte Weiche, sondern Gewichte pro Quelle — alle Strategien liefern Ranked Lists ins selbe RRF.

**Strategie-Router: Diskriminierung** (deterministische Signale zuerst, LLM nur als Fallback): (1) **Entity-Lexikon-Match** — Frage-Terme gegen die Entitäten/Aliase des Graphen matchen; ≥2 Treffer → Beziehungsfrage (Graph-Gewicht hoch, Pfad/Nachbarschaft zwischen den Treffern), genau 1 Treffer → Hybrid plus 1-Hop-Nachbarschaft, 0 Treffer → Fakten oder Überblick. (2) **IDF-Statistik** — seltene Terme/Identifier (hohe IDF im vorhandenen BM25-Index, Quoted Strings, CamelCase, IDs) → BM25-Gewicht hoch; nur breite, häufige Terme → Vektor-Gewicht hoch. (3) **Frage-Muster** — Signalphrasen («Überblick», «Zusammenfassung», «alle …», «wie hängt … zusammen», «Unterschied zwischen») → Summaries bzw. Graph. Widersprechen sich die Signale, klassiert ein billiger LLM-Call (kleines Modell via `llm-provider`, JSON: Strategie + erkannte Entitäten). Im Zweifel laufen alle drei Strategien — Retrieval ist lokal und billig, RRF sortiert; teuer ist nur der finale Generierungs-Call, und der läuft ohnehin genau einmal.

**Query-Trigger & Bypass:** Die Pipeline ist ein Werkzeug, kein Always-on-Layer — getriggert wird sie vom Aufrufer: explizit per CLI (`ask`), oder durch einen Agenten (Skill-/MCP-Tool mit klarer «when to use»-Beschreibung: Fragen über den indexierten Korpus). Vor jedem Retrieval läuft ein deterministischer Pre-Router (Skript, kein LLM), der Trivialfälle aussortiert: (1) Mitgeliefertes Dokument passt in den Kontext (Token-Schwelle) → **Bypass**, Dokument direkt in den Prompt, kein Retrieval. (2) Mitgeliefertes Dokument zu gross → Retrieval nur über dieses Dokument (Source-Filter), kein Korpus-Zugriff. (3) Kein Dokument, Frage betrifft den Korpus → volles Hybrid-/Graph-Retrieval mit Strategie-Router. Erst wenn die Heuristik uneindeutig ist, entscheidet ein billiger LLM-Call (Automatisierungs-Priorität Skript → LLM).

## 5. Tech-Stack: Diskussion

### Sprache / Runtime

| Option | Pro | Contra |
|---|---|---|
| **Node.js/TypeScript** | `llm-provider` direkt nutzbar; ein Ökosystem für alles | RAG-Ökosystem dünner (Chunking, Embeddings, Evaluation) |
| **Python** | Reifstes RAG-Ökosystem (Loader, Splitter, Eval) | `llm-provider` (JS) nur via Subprozess/Port nutzbar — bricht Ziel 6 |

**Empfehlung:** Node.js/TypeScript. Der Verlust an Ökosystem ist verkraftbar (Chunking und RRF sind wenig Code), die nahtlose `llm-provider`-Integration wiegt schwerer.

### Vektor- & Keyword-Store

| Option | Pro | Contra |
|---|---|---|
| **SQLite (`sqlite-vec` + FTS5)** | Eine Datei, null Betrieb, Vektor+BM25 im selben Store, transaktional | Bei sehr grossen Korpora (>1M Chunks) langsamer als dedizierte Engines |
| **LanceDB** | Embedded, schnell, natives Node-SDK, Hybrid-Suche eingebaut | Zusätzliche Abhängigkeit; FTS weniger ausgereift als FTS5 |
| **Qdrant (Docker)** | Sehr schnell, produktionsreif | Laufender Dienst — widerspricht «null Betrieb» für ein lokales Tool |

**Empfehlung:** SQLite mit `sqlite-vec` + FTS5. Ein Store für Chunks, Vektoren und Keyword-Index; Backup = Datei kopieren. Qdrant erst, wenn Messungen es nötig machen.

### Graph-Store

| Option | Pro | Contra |
|---|---|---|
| **SQLite (Adjazenz-Tabellen)** | Kein weiterer Store; für 1-2-Hop-Nachbarschaft reicht SQL rekursiv | Keine Graph-Query-Sprache; tiefe Traversals mühsam |
| **Kùzu** | Embedded, Cypher, schnell | Junges Projekt; zweiter Store neben SQLite |
| **Neo4j** | Standard, Tooling, Visualisierung | Server-Betrieb, Java — überdimensioniert für lokal |

**Empfehlung:** Start mit SQLite-Tabellen (`entities`, `relations`, `mentions`, `summaries`) im selben File wie die Indizes. GraphRAG-Retrieval braucht in der Praxis fast nur 1-2 Hops — dafür reicht SQL. Kùzu als definierter Migrationspfad, falls tiefe Traversals nötig werden.

### Embeddings

| Option | Pro | Contra |
|---|---|---|
| **Lokal: Ollama (z.B. `nomic-embed-text`)** | Daten bleiben komplett lokal, gratis, offline | Ollama muss laufen; Qualität leicht unter API-Modellen |
| **Lokal: transformers.js/fastembed im Prozess** | Kein Zusatzdienst | Kaltstart, Modell-Download, RAM |
| **API (Voyage/OpenAI)** | Beste Qualität, kein lokaler Aufwand | Dokumenteninhalte verlassen die Maschine — verletzt Ziel 4 |

**Empfehlung:** Ollama als Default (konsequent zu «Daten lokal» — Embedding-Input ist der volle Dokumenttext, nicht nur die Frage). Embedding-Aufruf hinter einem eigenen Interface, damit API-Embeddings als bewusste Option bleiben. *Lücke:* `llm-provider` hat keinen Embedding-Call; sinnvolle Erweiterung wäre ein `callEmbedding(task, texts)` dort.

### Framework vs. Eigenbau

| Option | Pro | Contra |
|---|---|---|
| **Microsoft GraphRAG** | Ausgereiftes Community-Detection-Konzept | Python, schwergewichtig, teure Voll-Indexierung |
| **LightRAG / nano-graphrag** | Genau das Ziel-Konzept (dual-level Retrieval) | Python; eigene LLM-Anbindung statt `llm-provider` |
| **graphify (Graphify-Labs)** | Graph-Aufbau für Code deterministisch per tree-sitter (0 LLM-Credits), Kanten-Provenance (EXTRACTED/INFERRED), Leiden-Communities | Bewusst kein Vektor-Index — deckt nur den Graph-Teil ab; Python-CLI mit eigenem Datenmodell |
| **Eigenbau (schlank)** | Passt exakt auf Stack und `llm-provider`; Konzepte sind gut dokumentiert und klein nachbaubar | Extraktions-Prompts und Fusion selbst pflegen |

**Entscheid (2026-07-12):** Eigenbau, konzeptionell entlang LightRAG (Entitäten + Relationen + Keyword-Duallevel statt teurer Community-Hierarchien). graphify dient als primäre Referenz für Datenmodell und Extraktions-Ansatz — insbesondere Kanten-Provenance (EXTRACTED vs. INFERRED) und deterministische Extraktion vor LLM-Einsatz, wo möglich (Automatisierungs-Priorität Skript → LLM).

## 6. Scope & Meilensteine

1. **M1 — Hybrid-RAG:** Loader (Markdown), Chunking, SQLite mit `sqlite-vec`+FTS5, Ollama-Embeddings, RRF, Antwort via `llm-provider`, CLI (`index`, `ask`).
2. **M2 — GraphRAG:** LLM-Extraktion (Entitäten/Relationen) beim Indexieren, Graph-Tabellen, Entity-basiertes Retrieval, Router.
3. **M3 — Härtung:** Inkrementelle Re-Indexierung, Trigger-Schicht (post-commit-Hook, opt-in Watcher), Summaries für Überblicksfragen, kleine Eval-Suite (Fragenkatalog mit erwarteten Quellen), weitere Loader (PDF, Code).

## 7. Erfolgskriterien

- Faktenfragen mit exakten Begriffen werden gefunden, die reines Vektor-RAG verfehlt (Eval-Suite, M3).
- Beziehungs-/Überblicksfragen liefern Antworten mit Quellen aus ≥2 Dokumenten.
- Voll-Indexierung eines 1000-Dokumente-Korpus < 30 Min; inkrementeller Lauf ohne Änderungen < 10 Sek.
- Kein Dokumentinhalt verlässt die Maschine ausser als Prompt-Kontext an die konfigurierte LLM-API.

## 8. Offene Fragen

1. Erweiterung von `llm-provider` um `callEmbedding` — dort oder als separates Modul im Pipeline-Repo?
2. Eigenes Repo (z.B. `local-rag`) oder Start unter `ai-toolbox/tools/`?
3. Erste konkrete Datenquelle für M1 als Referenz-Korpus (z.B. `ai-toolbox` selbst)?
