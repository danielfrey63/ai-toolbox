# PRD: Lokales Hybrid-RAG mit GraphRAG (`full-rag`)

**Status:** Konsolidiert, bereit für M1 · **Stand:** 2026-07-12 11:18 CEST · **Owner:** Daniel Frey · **Referenz-Analyse:** [graphify-analyse.md](graphify-analyse.md)

## 1. Problem

Klassisches Vektor-RAG findet semantisch ähnliche Textstellen, scheitert aber an zwei Fragetypen: exakte Begriffe/Identifikatoren (Namen, IDs, Fachtermini — hier ist Keyword-Suche überlegen) und Fragen über Zusammenhänge, die über mehrere Dokumente verteilt sind («Wie hängt X mit Y zusammen?», «Gib mir einen Überblick über Thema Z»). Es fehlt eine wiederverwendbare, lokale Pipeline, die alle drei Fragetypen abdeckt.

## 2. Lösung in einem Satz

`full-rag` (eigenes Repo) ist eine generische, quellenunabhängige Ingestion-und-Retrieval-Pipeline, die pro Dokument gleichzeitig einen Vektor-Index, einen Keyword-Index (BM25) und einen Entitäten-/Relations-Graph aufbaut und beim Retrieval die drei Signale fusioniert; alle Daten und Indizes bleiben lokal, LLM-Calls laufen provider-agnostisch über [`llm-provider`](https://github.com/danielfrey63/llm-provider).

## 3. Ziele

1. **Generisch:** Datenquelle ist austauschbar (Markdown-Ordner, PDFs, Code, Exporte); neue Quellen brauchen nur einen Loader, keine Pipeline-Änderung.
2. **Hybrid-Retrieval:** Vektor-Ähnlichkeit + BM25, fusioniert per Reciprocal Rank Fusion (RRF), optional Reranking.
3. **GraphRAG:** Entitäten und Relationen als Graph — deterministisch extrahiert wo möglich, LLM-extrahiert wo nötig; Graph-Retrieval für Beziehungs- und Überblicksfragen (Nachbarschaft + verdichtete Zusammenfassungen).
4. **Lokale Daten:** Dokumente, Chunks, Embeddings, Graph und Indizes liegen ausschliesslich auf eigener Hardware; die Maschine verlassen Inhalte nur als Calls an die konfigurierten Provider (Generierung, Extraktion, Embeddings) — mit lokalen Providern gar nicht.
5. **Inkrementell & idempotent:** Re-Runs indexieren nur Geändertes (Hash-basiert); Abbruch und Wiederholung schaden nie.
6. **Trigger-Schicht nach graphify-Vorbild:** Der Index-Lauf selbst ist trigger-agnostisch; darüber liegen drei dünne Auslöser: (A) manueller CLI-Aufruf, (B) git post-commit-Hook (indexiert nur die im Commit geänderten Dateien), (C) optionaler File-Watcher mit Debounce, der nur die billigen Stufen (Chunking, BM25, Embeddings) sofort ausführt und teure LLM-Stufen (Graph-Extraktion) lediglich als `needs_update`-Flag für den nächsten expliziten Lauf vormerkt.
7. **Provider-agnostisch:** Alle LLM-Calls über `llm-provider`; Modellwechsel ist Konfiguration, kein Code.

**Nicht-Ziele:** Kein Multi-User-Betrieb, keine Web-UI (CLI/API zuerst), kein permanenter Sync-Daemon als Kernbestandteil (der Watcher aus Ziel 6 ist opt-in und macht nie LLM-Calls von selbst), kein eigenes Frontend für Graph-Visualisierung (Export für bestehende Tools genügt).

## 4. Architektur

```
Quellen (md, pdf, code, …)
   │  Loader (pluggable, JS-nativ)
   ▼
Chunking (strukturbewusst: Überschriften/Funktionen, Overlap)
   ├──► Embeddings ──► Vektor-Index ─┐
   ├──► Tokenisierung ──► BM25-Index ─┼──► RRF-Fusion ──► (Rerank) ─┐
   └──► Extraktion ──► Graph (Entitäten/Relationen/Summaries) ──────┤
        (deterministisch vor LLM)                                   ▼
                                              Kontext-Assembly ──► LLM-Antwort (llm-provider)
```

**Query-Trigger & Bypass:** Die Pipeline ist ein Werkzeug, kein Always-on-Layer — getriggert vom Aufrufer: explizit per CLI (`ask`) oder durch einen Agenten (Skill-/MCP-Tool mit klarer «when to use»-Beschreibung: Fragen über den indexierten Korpus). Vor jedem Retrieval sortiert ein deterministischer Pre-Router (Skript, kein LLM) Trivialfälle aus: (1) Mitgeliefertes Dokument passt in den Kontext (Token-Schwelle) → **Bypass**, Dokument direkt in den Prompt, kein Retrieval. (2) Dokument zu gross → Retrieval nur über dieses Dokument (Source-Filter). (3) Kein Dokument, Frage betrifft den Korpus → volles Retrieval mit Strategie-Router.

**Strategie-Router:** Kein hartes Verzweigen, sondern Gewichte pro Quelle — alle Strategien liefern Ranked Lists ins selbe RRF (Faktenfrage → Vektor+BM25; Beziehungsfrage → Graph-Nachbarschaft der erkannten Entitäten; Überblicksfrage → Community-/Themen-Summaries). Diskriminiert wird deterministisch, LLM nur als Fallback: (1) **Entity-Lexikon-Match** — Frage-Terme gegen Entitäten/Aliase des Graphen; ≥2 Treffer → Graph-Gewicht hoch (Pfad/Nachbarschaft zwischen den Treffern), 1 Treffer → Hybrid plus 1-Hop-Nachbarschaft, 0 Treffer → Fakten oder Überblick. (2) **IDF-Statistik** — seltene Terme/Identifier (hohe IDF im BM25-Index, Quoted Strings, CamelCase, IDs) → BM25-Gewicht hoch; nur breite Terme → Vektor-Gewicht hoch. (3) **Frage-Muster** — Signalphrasen («Überblick», «alle …», «wie hängt … zusammen») → Summaries bzw. Graph. Bei widersprüchlichen Signalen klassiert ein billiger LLM-Call (kleines Modell, JSON: Strategie + Entitäten); im Zweifel laufen alle drei Strategien — Retrieval ist lokal und billig, teuer ist nur der finale Generierungs-Call, und der läuft genau einmal.

## 5. Tech-Stack

- **Sprache/Runtime:** Vanilla JS auf Node — kein TypeScript, kein Build-Step, UMD-Stil wie `llm-provider`.
- **Store:** Ein SQLite-File: `sqlite-vec` (Vektoren) + FTS5 (BM25) + Graph-Tabellen (`entities`, `relations`, `mentions`, `summaries`).
- **Graph-Modell:** Nach graphify-Vorbild ([graphify-analyse.md](graphify-analyse.md) §8): Kanten-Provenance (`EXTRACTED`/`INFERRED`/`AMBIGUOUS` mit diskreten Scores), kanonische IDs aus Pfad+Symbol, deterministische Extraktion vor jedem LLM-Einsatz (Code via `web-tree-sitter`), Communities via Leiden/Louvain (`graphology`).
- **Embeddings:** `llm-provider.embed()`; Provider und Modell sind Konfiguration (lokal via `openai-compatible`, z.B. Ollama, oder Cloud-API).
- **Loader:** JS-nativ hinter schmalem Loader-Interface — M1: Markdown; M3: PDF via `pdfjs-dist` (seitengenaue Quellenangabe), Code via tree-sitter. Optional `graphify.ingest` als externer URL-Fetcher (YouTube/arXiv/Webseite → Datei).
- **LLM-Anbindung:** `llm-provider` für Generierung, Graph-Extraktion, Router-Fallback und Embeddings.

## 6. Meilensteine

1. **M1 — Hybrid-RAG:** Repo `full-rag`, Markdown-Loader, Chunking, SQLite mit `sqlite-vec`+FTS5, Embeddings via `llm-provider.embed()`, RRF, Antwort via `llm-provider`, CLI (`index`, `ask`); Referenz-Korpus: `ai-toolbox`.
2. **M2 — GraphRAG:** Graph-Extraktion beim Indexieren (deterministisch vor LLM), Graph-Tabellen, Entity-basiertes Retrieval, Strategie-Router.
3. **M3 — Härtung:** Inkrementelle Re-Indexierung (Manifest, Stat-Fast-Path, Replace-on-Re-Extract), Trigger-Schicht (post-commit-Hook, opt-in Watcher), Summaries für Überblicksfragen, Eval-Suite (Fragenkatalog mit erwarteten Quellen), weitere Loader (PDF, Code).

## 7. Erfolgskriterien

- Faktenfragen mit exakten Begriffen werden gefunden, die reines Vektor-RAG verfehlt (Eval-Suite, M3).
- Beziehungs-/Überblicksfragen liefern Antworten mit Quellen aus ≥2 Dokumenten; PDF-Quellen seitengenau.
- Voll-Indexierung eines 1000-Dokumente-Korpus < 30 Min; inkrementeller Lauf ohne Änderungen < 10 Sek.
- Kein Dokumentinhalt verlässt die Maschine ausser als Calls an die konfigurierten Provider-APIs; mit lokalen Providern läuft die Pipeline vollständig offline.
