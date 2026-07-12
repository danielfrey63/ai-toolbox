# Graphify-Analyse: Wie es funktioniert und was `full-rag` übernimmt

**Stand:** 2026-07-12 10:17 CEST · **Analysierte Version:** graphify 0.9.12 (installiertes PyPI-Paket `graphifyy`, ~33k Zeilen Python, plus Skill `~/.claude/skills/graphify/`) · **Kontext:** Referenz-Analyse für [rag-hybrid-graphrag-prd.md](rag-hybrid-graphrag-prd.md), Entscheid B (Eigenbau mit graphify als Vorbild).

## 1. Grundprinzip: Skript macht alles Deterministische, LLM nur Semantik

Die Architektur-Wette von graphify steht fast wörtlich im Skill: Jede deterministische Operation (Datei-Erkennung, AST-Parsing, Graph-Bau, Clustering, Diff, Export, Kosten-Tracking) läuft als Python-Code; das LLM wird für genau fünf irreduzibel semantische Aufgaben eingesetzt: (1) semantische Extraktion über Nicht-Code (Docs, Papers, Bilder), (2) Community-Benennung, (3) Query-Expansion auf das Korpus-Vokabular, (4) Antwort-Synthese, (5) Report-Narration. Code-Extraktion ist explizit **kein** LLM-Task — tree-sitter-AST, gratis, offline; ein reines Code-Korpus braucht gar keinen API-Key. Das deckt sich exakt mit unserer Automatisierungs-Priorität Skript → LLM → Human.

## 2. Pipeline: Datei-Übergabe-Stufen mit inspizierbaren JSON-Verträgen

Der Full Build läuft als Kette benannter Stufen, die je eine JSON-Zwischendatei lesen und die nächste schreiben (`.graphify_detect.json` → `.graphify_ast.json` + `.graphify_semantic.json` → `.graphify_extract.json` → `graph.json`): AST-Extraktion und LLM-Subagenten laufen parallel und werden per ID-Dedup gemergt; danach Build → Leiden-Clustering → Analyse (God Nodes, Surprising Connections, Suggested Questions) → Export → Report. Vorteile des Musters: Parallelität, Wiederaufsetzbarkeit (Cache-Check überspringt Extrahiertes), und jede Merge-Stufe ist eine testbare Mengen-Operation. Zwei Betriebsdetails: Für übersprungene Zweige wird immer eine **leere Datei** geschrieben (der unbedingte Read danach kann nie `FileNotFoundError` werfen), und JSON wird nie per Shell-Redirect geschrieben, wenn das Tool zugleich Fortschritt auf stdout druckt.

## 3. Datenmodell

- **Knoten:** `id`, `label`, `norm_label` (diakritik-bereinigt, lowercase — vorberechnetes Suchfeld), `file_type` (genau sechs Werte: code/document/paper/image/rationale/concept), `source_file` (wörtlich, relativ zum Root), `source_location` (`L{zeile}`), `community`, `community_name`, plus Provenance (`source_url`, `captured_at`, `author`, `contributor`).
- **Kanten:** `source`, `target`, `relation` (calls/imports/inherits/contains/references/conceptually_related_to/…), `confidence` (**EXTRACTED/INFERRED/AMBIGUOUS**), `confidence_score`, `context` (call/import/field/return_type/…), `source_file` — Kanten tragen ihre eigene Herkunft und sind damit unabhängig von den Endpunkten prunebar.
- **Hyperedges:** 3+ Knoten, die gemeinsam ein Konzept bilden (`participate_in/implement/form`), max. 3 pro Extraktions-Chunk.
- **Rationale als Attribut, nicht als Knoten:** Design-Begründungen (WHY-Kommentare, Trade-offs) werden als `rationale`-Feld am betroffenen Konzept-Knoten gespeichert — Prosa-Fragmente werden nie eigenständige Knoten, das hält den Graph frei von Low-Degree-Textmüll.
- **Diskretisierte Confidence:** EXTRACTED = 1.0; INFERRED = exakt einer aus {0.95, 0.85, 0.75, 0.65, 0.55}; AMBIGUOUS = 0.1–0.3. Begründung aus der Produktion: Kontinuierliche Skalen kollabieren bimodal (>50% bei 0.5); Modelle folgen diskreten Rubriken besser. Escape-Hatch: lieber AMBIGUOUS markieren als tief raten.

## 4. ID-Disziplin: das Merge-Rückgrat

Der wichtigste Einzelmechanismus. Knoten-IDs sind eine **reine Funktion aus Pfad + Symbol** (`{stem}_{entity}`, stem = voller repo-relativer Pfad ohne Extension, jedes Segment lowercase, `/`→`_`), NFKC-normalisiert, idempotent. Drei unabhängige Produzenten müssen byte-identische IDs liefern (AST-Extraktor, LLM-Subagenten, Graph-Builder) — deshalb: (1) Die Normalisierung lebt in **genau einem Modul** (`ids.py` existiert, weil das Rezept einmal in drei Stellen kopiert war und driftete). (2) Der Builder **leitet IDs aus `source_file` neu ab** statt dem LLM-String zu vertrauen — drift-sicher by construction. (3) **Nie** Chunk-/Lauf-Suffixe (`_c1`) — dieselbe Entität muss immer dieselbe ID ergeben, egal welcher parallele Subagent sie verarbeitet; nur so mergen N Fragmente ohne Geister-Duplikate. (4) `source_file` wörtlich und zeichengenau — es ist der Replace-Schlüssel des inkrementellen Merges.

## 5. Inkrementalität

- **Manifest** (`manifest.json`): pro Datei `{mtime, ast_hash, semantic_hash}`, relative POSIX-Pfade (portabel). **Stat-Fast-Path:** mtime gleich → unverändert, Datei wird nicht mal gelesen; mtime anders → MD5-Vergleich; nur bei Hash-Differenz Re-Extraktion (`touch` ist gratis). **Zwei Hash-Spalten** trennen die billige Stufe (AST) von der teuren (LLM): fehlender `semantic_hash` heisst zuverlässig «teure Stufe ausstehend».
- **Replace-on-Re-Extract:** Vor dem Merge werden alle Knoten/Kanten gelöscht, deren `source_file` zu den neu extrahierten Dateien gehört — sonst «überleben verschwundene Symbole für immer». Gelöschte Dateien (`manifest − aktueller Scan`) werden explizit gepruned.
- **Zwei Caches, unterschiedlich invalidiert:** AST-Cache ist **versioniert** nach Tool-Version (Extractor-Fix muss invalidieren, kostet nichts); LLM-Cache ist **nur content-keyed** (Re-Billing pro Release inakzeptabel) mit Liveness-Sweep gegen Orphans. Cache-Key = SHA256(Inhalt + relativer Pfad); Markdown hasht nur den Body unterhalb des Frontmatters (Metadaten-Edit invalidiert nicht).
- **Fail-safe-Guards:** Leerer Graph → Abbruch **vor** jedem Write; Shrink-Guard verweigert unerklärtes Schrumpfen (ausser Löschungen sind deklariert); korruptes bestehendes `graph.json` wird nie überschrieben (fail-safe, nicht fail-open); alle Writes tmp-then-rename; Manifest wird **zuletzt** geschrieben (Crash mittendrin → nächster Lauf extrahiert neu, nie falsches «unverändert»); No-op-Erkennung via kanonischem Graph-Vergleich lässt Outputs bei identischem Resultat unangetastet.
- **Trigger-Robustheit:** Debounce (3s) + Single-Writer-Lock (`flock`) + **durable Queue**: Wer den Lock nicht kriegt, hängt sein Change-Set an `.pending_changes` an; der Lock-Halter draint die Queue vor und nach dem Lauf — kein Change-Set geht verloren, Commit-Stürme quiescen ohne Livelock. Hooks starten den Rebuild **detached** (Commit blockiert nie) und pinnen den Interpreter-Pfad zur Install-Zeit.

## 6. Query-Seite: Entity-Linking ganz ohne Embeddings

- **Matching in drei Stufen mit riesigen Abständen:** Exact-Label ×1000, Prefix ×100, Substring ×1 — jeweils multipliziert mit **IDF** (`log(1 + N/(1+df))` über Knoten-Labels, gecacht). Ein exakter Identifier-Treffer dominiert Fuzzy-Rauschen deterministisch; generische Tokens («error», «handler») werden per IDF entwertet.
- **Coverage²-Skalierung:** Exact/Prefix-Beiträge werden mit `(getroffene Terme / alle Terme)²` skaliert — ein einzelnes generisches Wort mit Exact-Match kann einen Knoten, der mehrere Frage-Terme trifft, nicht mehr verdrängen.
- **Seed-Auswahl mit Pro-Term-Garantie:** Top-Treffer plus pro Frage-Term mindestens ein Seed (Tie-Break: Grad absteigend) — eine zufällige Kollision kann echte Terme nicht aushungern.
- **Hub-Blocking-Traversierung:** BFS (Tiefe 2) expandiert **nicht durch** Knoten mit Grad ≥ p99 (Floor 50), ausser der Hub ist selbst Seed — verhindert, dass God Nodes den ganzen Graph in den Kontext ziehen. Die wichtigste Context-Size-Lektion für GraphRAG.
- **Token-budgetiertes Rendering:** Seeds zuerst, Rest nach Grad absteigend, harter Char-Budget-Cut (~3 Zeichen/Token) mit explizitem Truncation-Marker, damit das LLM weiss, dass die Sicht partiell ist.
- **Vokabular-beschränkte Query-Expansion:** Das Skript extrahiert das tatsächliche Label-Vokabular; das LLM darf bis 12 Tokens **nur aus dieser Liste** wählen, druckt die Auswahl (auditierbar) und stoppt ehrlich bei Null-Match statt zu fabulieren. Tötet eine ganze Klasse von Retrieval-Miss- und Halluzinations-Fehlern.
- **Trigram-Index als Kandidaten-Generator:** Invertierter 3-Gramm-Index liefert eine Kandidaten-Obermenge, die exakt nachbewertet wird; Fallback auf Full-Scan bei schlechter Selektivität — «never worse»-Beschleunigung. SQLite-FTS5 mit Trigram-Tokenizer ist das direkte Pendant.
- **Feedback-Loop (reflect/LESSONS.md):** Query-Ergebnisse werden mit Outcome (`useful`/`dead_end`/`corrected`) als Memory-Docs gespeichert; ein deterministischer `reflect`-Lauf aggregiert sie mit **vorzeichenbehafteten, zeitverfallenden Scores** (`0.5^(Alter/30d)`) und Korroborations-Schwelle zu LESSONS.md (bevorzugte Quellen / bekannte Sackgassen / Korrekturen), das zu Session-Start gelesen wird. Der Graph selbst wird nie mutiert — das Learning ist ein **Display-only-Overlay** mit Content-Fingerprint zur Staleness-Erkennung.

## 7. Qualitäts-Guards

- **False-Positive-Guards bei der Kanten-Auflösung** (jeder an eine konkrete Regression geknüpft): Nur-ein-Kandidat-Regel (Name in ≥2 Dateien wird nie per Name allein gebunden), Builtin-Filter (`len`, `console` werden keine God Nodes), Case-Sensitivity pro Sprache, Cross-Language-Family-Guard (TSX-Callback bindet nie an gleichnamige Kotlin-Methode), «kein Import ⇒ keine Kante» für ES-Module. Durchgängig: Recall bewusst gegen Precision getauscht — Name-only-Matching bläht God Nodes auf.
- **«Defer, don't drop»:** Ungelöste Referenzen werden als `raw_calls`-Fakten und Stub-Knoten mitgeführt und erst korpus-weit aufgelöst, wenn alle Dateien bekannt sind; Auflösungs-Pässe sind additiv und idempotent (Seen-Set auf `(src,tgt,relation)`).
- **LLM-Output als untrusted an einer Code-Grenze:** Validierung erzwingt Grössen-Caps, ID-Zeichensatz, Pfad-Escape-Schutz; Sanitisierung entfernt Prosa-als-Knoten. Quell-Dateien werden in `<untrusted_source path sha256>`-Blöcke gewickelt, Injection-Sentinels defanged. Erfolgssignal eines Subagenten ist die **Datei auf der Platte**, nicht seine Erfolgsbehauptung; >50% fehlgeschlagene Chunks → Abbruch mit Ansage.
- **Honesty Rules:** Nie Kanten erfinden (AMBIGUOUS nutzen), Token-Kosten immer zeigen (`cost.json` kumulativ), Grössen-Gate vor teuren Läufen, Health-Warnungen (dangling/self-loop/collapsed edges) müssen im Summary auftauchen.

## 8. Was `full-rag` konkret übernimmt

1. **Arbeitsteilung strukturell erzwingen:** Chunking, Indexierung, Retrieval-Mathematik, Dedup, Provenance = CLI-Code; LLM nur für Bedeutungs-Extraktion, Community-Labels, Query-Expansion, Antwort-Synthese.
2. **Ein ID-Modul** (`normalizeId`/`makeId`, NFKC + casefold, idempotent), von allen Produzenten importiert; IDs im Code aus `source_file` + Symbol neu ableiten, nie dem LLM-String vertrauen; keine Lauf-/Chunk-Suffixe.
3. **SQLite-Schema nach diesem Vorbild:** `files(path PK, size, mtime_ns, content_hash, cheap_hash, llm_hash)`, `chunks`, `nodes(id PK, label, norm_label, source_file, file_type, community, degree, rationale)`, `edges(src, tgt, relation, confidence, confidence_score, context, source_file)`, `hyperedges` + Members, `learning`-Overlay-Tabelle. `norm_label` und `degree` als persistierte Spalten, nicht query-time-berechnet.
4. **Inkrementalität:** Stat-Fast-Path → Hash → Re-Extract; Replace-on-Re-Extract als `DELETE WHERE source_file IN (…)` + Insert in einer Transaktion; Deleted-Pruning als First-Class-Output der Detection; zwei Hash-Spalten für billige vs. LLM-Stufe; LLM-Cache content-keyed ohne Versions-Sweep, deterministische Caches versioniert.
5. **Fail-safe-Guards:** Empty-Guard vor Write, Shrink-Guard, tmp-then-rename für Export-Artefakte (SQLite: Transaktion + WAL), Manifest-Stempel zuletzt, No-op-Vergleich vor Write.
6. **Query-Router:** Tiers × IDF × Coverage² als SQL (CASE-Score über `norm_label` + FTS5-Trigram-Kandidaten), Pro-Term-Seed-Garantie, Hub-Blocking-BFS über die `edges`-Tabelle, token-budgetiertes Subgraph-Rendering mit Truncation-Marker, vokabular-beschränkte Query-Expansion. Das ergänzt unser Vektor+BM25-RRF um die Graph-Seite — graphify beweist, dass die Entity-Ebene komplett ohne Embeddings funktioniert.
7. **Learning-Loop (M3+):** Outcome-Logging pro Antwort, zeitverfallende Aggregation zu «bevorzugte Quellen / Sackgassen», Display-only-Overlay mit Content-Fingerprint — billiges, erklärbares Feedback ohne Retraining.
8. **Confidence-Taxonomie** EXTRACTED/INFERRED/AMBIGUOUS mit diskreter Score-Rubrik auf allen LLM-extrahierten Kanten; Traversierung und Antworten gewichten danach.

## 9. Wo `full-rag` bewusst abweicht

- **Vektor + BM25 zusätzlich:** graphify verzichtet komplett auf Embeddings — für Code-Strukturfragen richtig, aber unsere Fakten-/Ähnlichkeitsfragen über Prosa-Korpora brauchen die semantische Ebene. Der Graph wird bei uns dritte Retrieval-Quelle im RRF, nicht Ersatz.
- **SQLite statt graph.json:** graphify hält den Graph als JSON-Artefakt und lädt ihn pro Query; wir halten alles in einem SQLite-File mit Indizes — bei unserem Zielvolumen (1000+ Dokumente, Chunks + Vektoren) ist das JSON-Muster nicht mehr tragfähig.
- **Kein NetworkX-Pendant nötig:** Traversierung ist bounded BFS Tiefe 1–2 mit Hub-Blocking — das ist rekursives SQL bzw. eine kleine JS-Schleife, keine Graph-Library.
- **Subagenten-Chunking entfällt vorerst:** graphify dispatcht LLM-Extraktion als parallele Assistant-Subagenten (Skill-Kontext); `full-rag` ruft die API direkt via `llm-provider` und kann Concurrency selbst steuern.
