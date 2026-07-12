# PRD: Lokales Hybrid-RAG mit GraphRAG (`full-rag`)

**Status:** Umgesetzt (M1–M4) in [danielfrey63/full-rag](https://github.com/danielfrey63/full-rag) · **Stand:** 2026-07-12 13:46 CEST · **Owner:** Daniel Frey · **Referenz-Analyse:** [graphify-analyse.md](graphify-analyse.md)

## 1. Problem

Klassisches Vektor-RAG findet semantisch ähnliche Textstellen, scheitert aber an zwei Fragetypen: exakte Begriffe/Identifikatoren (Namen, IDs, Fachtermini — hier ist Keyword-Suche überlegen) und Fragen über Zusammenhänge, die über mehrere Dokumente verteilt sind («Wie hängt X mit Y zusammen?», «Gib mir einen Überblick über Thema Z»). Es fehlt eine wiederverwendbare, lokale Pipeline, die alle drei Fragetypen abdeckt.

## 2. Lösung in einem Satz

`full-rag` (eigenes Repo) ist eine generische, quellenunabhängige Ingestion-und-Retrieval-Pipeline, die pro Dokument im Endausbau einen Vektor-Index, einen Keyword-Index (BM25) und einen Entitäten-/Relations-Graph aufbaut (M1: Vektor+BM25, ab M2 mit Graph) und beim Retrieval die Signale fusioniert; alle Daten und Indizes bleiben lokal, LLM-Calls laufen provider-agnostisch über [`llm-provider`](https://github.com/danielfrey63/llm-provider).

## 3. Ziele

1. **Generisch:** Datenquelle ist austauschbar (Markdown-Ordner, PDFs, Code, Exporte); neue Quellen brauchen nur einen Loader, keine Pipeline-Änderung.
2. **Hybrid-Retrieval:** Vektor-Ähnlichkeit + BM25, fusioniert per Reciprocal Rank Fusion (RRF). Reranking ist kein M1-Scope, sondern ein späteres Opt-in-Modul (nach M3) mit deterministischem Fallback auf die RRF-Rangfolge.
3. **GraphRAG:** Entitäten und Relationen als Graph — deterministisch extrahiert wo möglich, LLM-extrahiert wo nötig; Graph-Retrieval für Beziehungsfragen (Nachbarschaft, Pfade).
4. **Lokale Daten:** Dokumente, Chunks, Embeddings, Graph und Indizes liegen ausschliesslich auf eigener Hardware; die Maschine verlassen Inhalte nur als Calls an die konfigurierten Provider (Generierung, Extraktion, Embeddings) — mit lokalen Providern gar nicht.
5. **Inkrementell & idempotent (ab M1):** Re-Runs indexieren nur Geändertes (Content-Hash). Commit-Grenze ist das Dokument: alle Stufen eines Dokuments laufen in einer SQLite-Transaktion, Re-Indexierung ersetzt alle Artefakte des Dokuments (Replace-per-Document) — Abbruch und Wiederholung schaden nie, Leser sehen nur vollständige Stände. Gelöschte Dateien (Manifest minus aktueller Scan) werden mitsamt abhängigen Artefakten entfernt; Renames sind Delete+Add — der Content-Hash macht die Re-Verarbeitung billig bis gratis.
6. **Trigger-Schicht nach graphify-Vorbild:** Der Index-Lauf selbst ist trigger-agnostisch; darüber liegen drei dünne Auslöser: (A) manueller CLI-Aufruf, (B) git post-commit-Hook (indexiert nur die im Commit geänderten Dateien), (C) optionaler File-Watcher mit Debounce, der automatisch nur Stufen ohne externe Calls ausführt (Chunking, BM25; Embeddings nur bei lokalem Provider oder explizitem Opt-in) und alles Übrige (Graph-Extraktion, Cloud-Embeddings) als `needs_update`-Flag für den nächsten expliziten Lauf vormerkt. Alle Trigger serialisieren auf genau einen Writer (SQLite WAL, Lock plus durable Queue nach graphify-Muster); konkurrierende Trigger werden zusammengeführt, nie parallel ausgeführt.
7. **Provider-agnostisch:** Alle LLM-Calls über `llm-provider`; Modellwechsel ist Konfiguration, kein Code.
8. **Wiki-Schicht:** Generierte Markdown-Verdichtung über dem Graph (pro Community ein Artikel), menschlich kuratierbar — reine Ausgabe-Schicht, wird nie re-indexiert (weder Vektor/BM25 noch Graph).

**Nicht-Ziele:** Kein Multi-User-Betrieb, keine Web-UI (CLI und programmatische JS-API zuerst; MCP/Skill als dünne Read-Schicht in M3), kein permanenter Sync-Daemon als Kernbestandteil (der Watcher aus Ziel 6 ist opt-in und macht nie externe Provider-Calls ohne Opt-in), kein eigenes Frontend für Graph-Visualisierung (Graph-Export in M2 genügt).

## 4. Architektur

```
Quellen (md, pdf, code, …)
   │  Loader (pluggable, JS-nativ)
   ▼
Chunking (strukturbewusst: Überschriften/Funktionen, Overlap)
   ├──► Embeddings ──► Vektor-Index ─┐
   ├──► Tokenisierung ──► BM25-Index ─┼──► RRF-Fusion ──► (Rerank) ─┐
   └──► Extraktion ──► Graph (Entitäten/Relationen) ────────────────┤
        (deterministisch vor LLM)      │                            ▼
                                       ▼              Kontext-Assembly ──► LLM-Antwort (llm-provider)
                          Wiki-Schicht (generierte md-Artikel,
                          reine Ausgabe — wird nie re-indexiert)
```

**Query-Trigger & Bypass:** Die Pipeline ist ein Werkzeug, kein Always-on-Layer — getriggert vom Aufrufer: explizit per CLI (`ask`) oder durch einen Agenten (Skill-/MCP-Tool mit klarer «when to use»-Beschreibung: Fragen über den indexierten Korpus). Vor jedem Retrieval sortiert ein deterministischer Pre-Router (Skript, kein LLM) Trivialfälle aus: (1) Mitgeliefertes Dokument passt in den Kontext (Token-Schwelle) → **Bypass**, Dokument direkt in den Prompt, kein Retrieval. (2) Dokument zu gross → Retrieval nur über dieses Dokument (Source-Filter). (3) Kein Dokument, Frage betrifft den Korpus → volles Retrieval mit Strategie-Router.

**Strategie-Router:** Kein hartes Verzweigen, sondern Gewichte pro Quelle — Vektor, BM25 und Graph liefern Ranked Lists ins selbe RRF (Faktenfrage → Vektor+BM25; Beziehungsfrage → Graph-Nachbarschaft der erkannten Entitäten); Überblicksfragen laufen nicht über Retrieval, sondern per direktem Lookup auf die Wiki-Schicht (erkannte Entität/Community → Artikel). Diskriminiert wird deterministisch, LLM nur als Fallback: (1) **Entity-Lexikon-Match** — Frage-Terme gegen Entitäten/Aliase des Graphen; ≥2 Treffer → Graph-Gewicht hoch (Pfad/Nachbarschaft zwischen den Treffern), 1 Treffer → Hybrid plus 1-Hop-Nachbarschaft, 0 Treffer → Fakten oder Überblick. (2) **IDF-Statistik** — seltene Terme/Identifier (hohe IDF im BM25-Index, Quoted Strings, CamelCase, IDs) → BM25-Gewicht hoch; nur breite Terme → Vektor-Gewicht hoch. (3) **Frage-Muster** — Signalphrasen («Überblick», «alle …», «wie hängt … zusammen») → Wiki bzw. Graph. Bei widersprüchlichen Signalen klassiert ein billiger LLM-Call (kleines Modell, JSON: Strategie + Entitäten); im Zweifel laufen alle Retrieval-Strategien — lokal und billig, teuer ist nur der finale Generierungs-Call, und der läuft genau einmal. Die Fusion folgt der RRF-Standardformel `score(d) = Σᵢ wᵢ/(k + rankᵢ(d))` mit fixen Defaults (k, top_n pro Retriever, final_k); fehlende Listen zählen null, Ties werden stabil über Dokument-ID/Chunk-Position aufgelöst, Gewichte und Parameter werden pro Anfrage geloggt. `ask` prüft vor dem Routing den Indexzustand: Bei stale Graph (`needs_update`) wird Graph-Retrieval für betroffene Dokumente deaktiviert und die Antwort trägt eine Warnung; `ask --refresh-graph` aktualisiert zuerst — stilles Antworten aus veralteten Graphdaten ist ausgeschlossen.

**Wiki-Schicht (Verdichtung):** Pro Graph-Community (und pro God-Node-Thema) generiert die Pipeline einen Markdown-Artikel in `wiki/` — Fliesstext mit Wikilinks und Quellenliste, im Frontmatter die Content-Hashes der Quell-Dateien. Invalidierung ist damit deterministisch: geänderte Quelle → betroffene Community → nur dieser Artikel wird regeneriert; Generierung liest ausschliesslich Roh-Chunks und Graph, nie andere Artikel. Von Hand editierte Artikel (`curated: true` im Frontmatter) werden nie überschrieben — bei Staleness wird ein Konflikt-Hinweis abgelegt. Die Schicht ist **reine Ausgabe**: Artikel werden nicht re-indexiert, weder in Vektor/BM25 noch in den Graph; der Zugriff läuft ausschliesslich über den Router-Lookup. Community-Berechnung und Artikel-Generierung laufen nur in expliziten Graph-/Wiki-Läufen (nie im Watcher); jeder Artikel stempelt Provider, Modell und Prompt-Version ins Frontmatter. Ergänzend ein «Arbeitsgedächtnis»-Artikel nach graphify-LESSONS-Muster: Antwort-Outcomes (`useful`/`dead_end`/`corrected`) werden geloggt und zeitverfallend zu bevorzugten Quellen, Sackgassen und Korrekturen aggregiert — gelesen zu Session-Start.

**Antwort-Vertrag (Grounding & Injection):** Jede Tatsachenbehauptung in einer Antwort trägt mindestens eine maschinenlesbare Citation (Dokument-ID, Pfad, Chunk-ID, bei PDFs Seite); doppelte Quellen werden zusammengeführt. Der Generierungs-Prompt darf nur bereitgestellte Evidenz verwenden und meldet bei fehlender oder widersprüchlicher Evidenz Unsicherheit, statt Beziehungen zu ergänzen. Dokumentinhalt gilt durchgängig als untrusted: klar abgegrenzt von den Instruktionen (graphify-Muster `<untrusted_source>`), eingebettete Anweisungen werden nicht befolgt; Injection-Testfälle sind Teil der Eval-Suite.

## 5. Tech-Stack

- **Sprache/Runtime:** Vanilla JS auf Node — kein TypeScript, kein Build-Step, UMD-Stil wie `llm-provider`.
- **Store:** Ein SQLite-File: `sqlite-vec` (Vektoren) + FTS5 (BM25) + Graph-Tabellen (`entities`, `relations`, `mentions`, `summaries`).
- **Graph-Modell:** Nach graphify-Vorbild ([graphify-analyse.md](graphify-analyse.md) §8): Kanten-Provenance (`EXTRACTED`/`INFERRED`/`AMBIGUOUS` mit diskreten Scores), deterministische Extraktion vor jedem LLM-Einsatz (Code via `web-tree-sitter`), Communities via Leiden/Louvain (`graphology`). Zwei ID-Regimes: Code-Symbole erhalten kanonische IDs aus Pfad+Symbol (Rename = Delete+Add); semantische Entitäten (Personen, Organisationen, Begriffe) erhalten IDs aus dem normalisierten Label mit Alias-Auflösung und Fuzzy-Dedup (nur für Nicht-Code).
- **Embeddings:** `llm-provider.embed()`; Provider und Modell sind Konfiguration (lokal via `openai-compatible`, z.B. Ollama, oder Cloud-API). Der Store hält einen Index-Fingerprint (Provider, Modell, Dimension, Chunker-Version, Normalisierung); eine inkompatible Konfiguration wird erkannt und erzwingt Re-Indexierung statt stiller Vektorraum-Mischung.
- **Loader:** JS-nativ hinter schmalem Loader-Interface — M1: Markdown; M3: PDF via `pdfjs-dist` (seitengenaue Quellenangabe), Code via tree-sitter. Optional `graphify.ingest` als externer URL-Fetcher (YouTube/arXiv/Webseite → Datei).
- **LLM-Anbindung:** `llm-provider` für Generierung, Graph-Extraktion, Router-Fallback und Embeddings.

## 6. Meilensteine

1. **M1 — Hybrid-RAG:** Repo `full-rag`, Markdown-Loader, Chunking, SQLite mit `sqlite-vec`+FTS5, Embeddings via `llm-provider.embed()` (inkl. Index-Fingerprint), RRF, Antwort via `llm-provider`, CLI (`index`, `ask`) plus programmatische JS-API. Idempotentes Datenmodell ab Tag 1: Content-Hash, eine Transaktion pro Dokument, Replace-per-Document, Delete-Handling. Eval-Fragenkatalog v1 (Fragetyp, erwartete Evidenz-Chunks, Negativquellen) als Akzeptanzgrundlage; Referenz-Korpus: `ai-toolbox`.
2. **M2 — GraphRAG:** Graph-Extraktion beim Indexieren (deterministisch vor LLM), Graph-Tabellen, Entity-basiertes Retrieval, Strategie-Router, Graph-Export (`graph export --format graphml|json` mit IDs, Typen, Scores, Provenance).
3. **M3 — Härtung:** Inkrementelle Re-Indexierung ausgebaut (Manifest, Stat-Fast-Path), Trigger-Schicht (post-commit-Hook, opt-in Watcher), MCP-Server und Claude-Skill als dünne Read-Schicht über dem Store, Eval-Suite mit Metriken (Recall@k/MRR pro Fragetyp gegen Vektor- und BM25-Baselines, Citation Precision/Recall, Injection-Testfälle), weitere Loader (PDF, Code).
4. **M4 — Wiki-Schicht:** Artikel-Generierung pro Community (Frontmatter mit Quell-Hashes, `curated`-Flag, Konflikt-Hinweis bei Staleness), Router-Lookup für Überblicksfragen, Outcome-Logging und «Arbeitsgedächtnis»-Artikel.

## 7. Erfolgskriterien

- Retrieval-Qualität: Recall@k und MRR pro Fragetyp schlagen die reinen Vektor- und BM25-Baselines auf dem versionierten Fragenkatalog; konkrete Mindestwerte werden nach einem dokumentierten Baseline-Lauf fixiert, nicht geschätzt.
- Beziehungs-/Überblicksfragen: Alle erwarteten Evidenz-Dokumente werden gefunden, keine unbelegten Beziehungen behauptet; Citations maschinenlesbar, bei PDFs seitengenau.
- Performance auf dem fixierten Benchmark-Korpus (dokumentiert: Hardware, Dokument-/Chunk-Verteilung, Provider, Cache-Zustand): Voll-Indexierung von 1000 Dokumenten < 30 Min lokale Pipeline-Zeit (externe Provider-Latenz separat ausgewiesen); inkrementeller Lauf ohne Änderungen < 10 Sek.
- Kein Dokumentinhalt verlässt die Maschine ausser als Calls an die konfigurierten Provider-APIs; mit lokalen Providern läuft die Pipeline vollständig offline. Automatische Trigger lösen nie unkonfigurierte externe Calls aus.
