# Review: Inkonsistenzen und Lücken im Hybrid-GraphRAG-PRD

**Geprüftes Dokument:** [rag-hybrid-graphrag-prd.md](rag-hybrid-graphrag-prd.md)  
**Review-Stand:** 2026-07-12-12-00-00

Es wurden 18 relevante Inkonsistenzen und Lücken gefunden. Die wichtigsten betreffen Idempotenz, Trigger-Verhalten, Graph-Identitäten und nicht messbare Erfolgskriterien.

## Kritische Inkonsistenzen

### 1. Idempotenz ist ein Kernziel, wird aber erst in M3 implementiert

Das PRD verspricht hashbasierte, abbruchsichere Re-Runs als grundlegende Eigenschaft (Zeile 19). Manifest und Replace-on-Re-Extract kommen jedoch erst in M3 (Zeile 56). Damit kann M1 weder sicher wiederholt noch verlässlich betrieben werden.

**Empfehlung:** Minimale Idempotenz bereits in M1 vorsehen: Dokument-ID, Content-Hash, Transaktion pro Dokument, Löschbehandlung und atomarer Austausch aller Chunks und Embeddings.

### 2. „Pro Dokument gleichzeitig drei Indizes“ stimmt nicht mit den Meilensteinen überein

Die Produktdefinition sagt, jedes Dokument baue Vektor-, Keyword- und Graphindex gleichzeitig auf (Zeile 11). M1 erzeugt aber keinen Graphen; beim Watcher darf der Graph sogar bewusst veraltet bleiben.

**Empfehlung:** M1 als bewusstes **Hybrid-RAG ohne Graph** bezeichnen und die Produktdefinition entsprechend relativieren. M1 liefert Vektor+BM25, M2 vervollständigt das Produktversprechen um GraphRAG; bis M2 gilt das System ausdrücklich als Teilprodukt. Alternativ müsste bereits M1 einen minimalen Graph erzeugen, was den Meilenstein unnötig vergrössern würde.

### 3. Der Watcher kann unbeabsichtigt externe Provider aufrufen

Der Watcher führt Embeddings automatisch aus (Zeile 20); Embeddings dürfen aber über eine Cloud-API laufen (Zeile 48). Die Aussage, der Watcher mache „nie LLM-Calls“ (Zeile 23), schützt somit nicht davor, dass Dokumentinhalte automatisch die Maschine verlassen.

**Empfehlung:** Der Watcher darf externe Calls nur nach explizitem Opt-in auslösen.

### 4. Gelöschte und umbenannte Dateien sind nicht definiert

Der post-commit-Hook „indexiert geänderte Dateien“ (Zeile 20). Es fehlt, wie Chunks, Vektoren, Mentions, Kanten und Summaries gelöschter Dateien entfernt beziehungsweise bei Renames migriert werden.

**Empfehlung:** Der Trigger übergibt Ereignistyp und alten/neuen Pfad. Deletes entfernen in einer Transaktion alle dokumentabhängigen Artefakte; Renames behalten eine pfadunabhängige Dokument-ID, aktualisieren den Pfad und re-extrahieren nur pfadabhängige Symbole. Nicht mehr belegte Entitäten, Relationen, Communities und Wiki-Summaries werden per Garbage Collection entfernt beziehungsweise invalidiert.

### 5. Kanonische Graph-IDs funktionieren nicht für alle versprochenen Quellen

IDs aus `Pfad+Symbol` (Zeile 47) passen zu Code, nicht zu Personen, Organisationen oder Begriffen aus Markdown und PDFs. Zudem ändert ein Rename die vermeintlich kanonische ID.

**Empfehlung:** Dokument-, Mention-, Symbol- und semantische Entity-Identitäten trennen; Regeln für Alias-Auflösung, Entity-Merging und Rename-Stabilität festlegen.

## Wesentliche funktionale Lücken

### 6. Keine Lösch-, Fehler- und Transaktionssemantik

„Abbruch und Wiederholung schaden nie“ ist ohne Festlegung von Commit-Grenzen nicht prüfbar. Offen ist, was bei Fehlern zwischen BM25, Embedding und Graph-Extraktion sichtbar bleibt.

**Empfehlung:** Pro Dokument eine Staging-Version erzeugen und erst nach erfolgreichem Abschluss aller für den Lauf verlangten Stufen atomar aktiv schalten. Leser sehen nur die letzte vollständige Version. Fehlerstatus und letzte erfolgreiche Stufe werden im Manifest gespeichert; ein Re-Run verwirft oder ersetzt Staging-Daten deterministisch.

### 7. Veralteter Graph wird nicht kenntlich gemacht

Der Watcher aktualisiert Textindizes sofort, setzt beim Graphen aber nur `needs_update`. Beim anschließenden `ask` ist nicht definiert, ob:

- der veraltete Graph verwendet wird,
- Graph-Retrieval deaktiviert wird,
- die Anfrage warnt oder scheitert,
- zunächst eine Aktualisierung verlangt wird.

**Empfehlung:** `ask` prüft den Indexzustand vor dem Routing. Bei `graph_stale=true` wird Graph-Retrieval für betroffene Dokumente standardmässig deaktiviert und die Antwort enthält eine Warnung; optional kann `ask --refresh-graph` zuerst aktualisieren. Ein stilles Verwenden veralteter Graphdaten sollte ausgeschlossen werden.

### 8. API, Skill und MCP sind erwähnt, aber nicht eingeplant

Das PRD sagt „CLI/API zuerst“ (Zeile 23) und nennt Skill/MCP als Aufrufer (Zeile 39). Kein Meilenstein enthält API, MCP-Server oder Skill.

**Empfehlung:** Für M1 nur CLI plus stabile interne JS-API zusagen. Einen MCP-Server und einen Codex-Skill als eigenes Deliverable in M3 aufnehmen. Falls keine öffentliche HTTP-API geplant ist, „CLI/API zuerst“ durch „CLI und programmatische JS-API zuerst“ ersetzen.

### 9. Graph-Export ist Nicht-Ziel-Ersatz, aber kein Deliverable

Statt Visualisierung soll Export genügen (Zeile 23); Format, CLI-Befehl und Meilenstein fehlen.

**Empfehlung:** In M2 `full-rag graph export --format graphml|json` liefern. Der Export enthält stabile IDs, Labels, Typen, Scores und Provenance; GraphML dient bestehenden Visualisierungstools, JSON der maschinellen Weiterverarbeitung.

### 10. Reranking ist nur ein Platzhalter

„Optional Reranking“ (Zeile 16) spezifiziert weder Provider, lokales beziehungsweise externes Verhalten, Eingabegrenzen noch Fallback und Kostenbudget.

**Empfehlung:** Reranking für M1 aus dem zugesagten Scope nehmen oder exakt definieren. Empfohlen ist ein opt-in M3-Modul mit konfigurierbarem lokalem/externem Provider, maximaler Kandidatenzahl und Tokenmenge, Timeout, Kostenlimit sowie deterministischem Fallback auf die unveränderte RRF-Rangfolge.

### 11. Die gewichtete RRF-Fusion ist unterspezifiziert

Der Router vergibt Gewichte, aber es fehlen Formel, `k`, Kandidatenzahl je Retriever, Umgang mit fehlenden Listen und Score-/Rank-Ties. Ohne diese Regeln ist das Retrieval nicht reproduzierbar.

**Empfehlung:** Die Formel als `score(d)=sum_i w_i/(k+rank_i(d))` festschreiben, für M1 feste Defaults für `k`, `top_n` je Retriever und `final_k` definieren und fehlende Listen mit Beitrag null behandeln. Ties werden stabil über Dokument-ID und Chunk-Position aufgelöst; Gewichte und Parameter werden mit jeder Anfrage geloggt.

### 12. Community-Summaries fehlen im Datenlebenszyklus

Nicht definiert sind:

- wann Communities neu berechnet werden,
- wann Summaries invalidiert werden,
- welche Quellen eine Summary belegen,
- wie inkrementelle Änderungen propagiert werden,
- ob deren Erstellung externe LLM-Calls auslösen darf.

**Empfehlung:** Community-Berechnung und Summary-Generierung nur in expliziten Graph-/Wiki-Läufen erlauben. Jede Summary speichert Community-Version, Quell-Chunk-IDs, Content-Hashes, Provider/Modell und Prompt-Version. Änderungen invalidieren transitiv nur betroffene Communities; externe Calls folgen derselben expliziten Provider-Policy wie die Graph-Extraktion.

### 13. Embedding-Modellwechsel ist nicht behandelt

„Modellwechsel ist Konfiguration“ (Zeile 21) ist bei Embeddings nicht ohne Reindexierung möglich: Dimension und Vektorraum können wechseln.

**Empfehlung:** Einen Index-Fingerprint aus Provider, Modell, Dimension, Chunker-Version und Normalisierung speichern und inkompatible Konfigurationen erkennen.

### 14. Kein Zitier- und Grounding-Vertrag

Quellen werden in Erfolgskriterien verlangt, aber es fehlen Ausgabeformat, Chunk-/Seitenreferenzen, Zitierpflicht, Deduplizierung und Verhalten bei unzureichender Evidenz.

**Empfehlung:** Jede Tatsachenbehauptung erhält mindestens eine maschinenlesbare Citation mit Dokument-ID, Pfad, Chunk-ID und bei PDFs Seite. Doppelte Quellen werden zusammengeführt. Der Antwort-Prompt darf nur bereitgestellte Evidenz verwenden und muss bei fehlender oder widersprüchlicher Evidenz Unsicherheit melden statt Beziehungen zu ergänzen.

### 15. Keine Regeln für konkurrierende Zugriffe

CLI, Watcher und post-commit-Hook können dasselbe SQLite-File parallel öffnen. Locking, WAL-Modus, Job-Serialisierung und Verhalten während einer laufenden Indexierung fehlen.

**Empfehlung:** SQLite im WAL-Modus betreiben, genau einen Writer über ein datenbankgestütztes Lease/Lock zulassen und Indexjobs in einer Queue serialisieren. Reads verwenden einen konsistenten Snapshot der zuletzt aktivierten Indexversion; konkurrierende Trigger werden dedupliziert und zusammengeführt statt parallel ausgeführt.

### 16. Prompt-Injection aus indexierten Dokumenten fehlt

Dokumenttext gelangt direkt oder per Retrieval in Prompts. Es fehlen die Trennung von Instruktionen und Evidenz sowie die Regel, Anweisungen aus Quellen nicht auszuführen.

**Empfehlung:** Quelltext als nicht vertrauenswürdige, klar abgegrenzte Evidenz behandeln. System-/Tool-Instruktionen verbieten das Befolgen eingebetteter Anweisungen, das Offenlegen von Secrets und Tool-Aufrufe aufgrund von Dokumentinhalt. Für Ingestion, Routing und Antwortgenerierung werden Injection-Testfälle in die Eval-Suite aufgenommen.

## Nicht ausreichend prüfbare Erfolgskriterien

### 17. Retrieval-Qualität hat keine Metriken

„Werden gefunden“ (Zeile 60) braucht beispielsweise Recall@k oder MRR, eine Baseline, die Testset-Größe und eine Mindestverbesserung. Auch Antwortqualität und Quellenkorrektheit benötigen eine Bewertungsmethode.

**Empfehlung:** Vor M1 einen versionierten Fragenkatalog mit Fragetyp, erwarteten Evidenz-Chunks und Negativquellen anlegen. Pro Fragetyp Recall@k und MRR gegen reine Vektor- und reine BM25-Baselines messen; zusätzlich Citation Precision/Recall und Faithfulness der Antwort bewerten. Konkrete Mindestwerte werden nach einem dokumentierten Baseline-Lauf festgelegt, nicht frei geschätzt.

### 18. Performancekriterien sind nicht reproduzierbar

„1000 Dokumente < 30 Min“ (Zeile 62) spezifiziert weder Hardware, Dokumentumfang, Chunkzahl, Provider/Modell, Cachezustand noch, ob Graph-Extraktion enthalten ist. Mit Cloud-LLM-Extraktion ist das Ziel zudem von Rate Limits abhängig.

Das Kriterium „Quellen aus mindestens zwei Dokumenten“ (Zeile 61) belohnt außerdem unnötige Quellen und scheitert bei korrekt beantwortbaren Ein-Dokument-Fragen. Besser wäre: Alle erwarteten Evidenzdokumente werden gefunden und keine unbelegten Beziehungen behauptet.

**Empfehlung:** Einen festen Benchmark-Korpus mit dokumentierter Hardware, Dokument-/Chunk-Verteilung, Provider und Modellen, warmem/kaltem Cache sowie aktivierten Pipeline-Stufen definieren. Lokale Pipeline-Zeit und externe Provider-Latenz getrennt berichten. Das Zwei-Dokument-Kriterium durch evidenzabhängige Vollständigkeit und das Verbot unbelegter Beziehungen ersetzen.

## Empfohlene Priorität vor M1

1. Minimales idempotentes Daten- und Transaktionsmodell in M1 vorziehen.
2. Löschungen, Renames und partielle Fehler definieren.
3. Automatische Cloud-Calls des Watchers explizit regeln.
4. Index-Fingerprint und Verhalten bei Modell-/Chunker-Wechsel festlegen.
5. M1-Akzeptanzkriterien mit messbaren Retrieval- und Performancewerten ergänzen.
6. API/MCP/Skill und Graph-Export entweder terminieren oder aus dem zugesagten Scope entfernen.
