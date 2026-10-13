# UI-Muster – Routen, Deep-Links, Druck, http-only-Funktionen

## Mehrere Seiten über Hash-Routen (avers)

- Eine Datei, mehrere Seiten: Routen als `#/<pfad>?<query>` (`#/`, `#/preise`, `#/haus`). Hash-Routen funktionieren unter `file://` und brauchen auf dem Server keine Rewrite-Regel.
- Seitenliste und Parser pure in einer Engine-Section (`04-route.js`): `PAGES = [{ id, path, title }]`, `parseRoute(hash)` → `{ page, query }`, `routeHash(pageId, query)`. Unbekannte Pfade landen auf der Startseite.
- Seiteninhalte stehen als `<section data-page="…">` im Template; der Router (dünner DOM-Adapter) blendet per `hidden` um, hört auf `hashchange` und scrollt nach oben.
- Die Query einer Seite trägt deren Zustand (Formular des Rechners, siehe [persistence.md](persistence.md)). Beim Wechsel zurück auf die Seite den letzten Query-Stand wiederherstellen.
- Links einer früheren Einseiten-Version (`#from=…`) weiter erkennen und auf die passende Route umleiten.

## Deep-Links auf eine Stelle (rain)

- `?at=lat,lon` (auch `#at=…`) öffnet die App an einer Stelle; weitere Parameter setzen Periode und Abfrage (`&p=w2&forest=…&mm=10-`). Parser pure (`parseCoords`, `viewParams`, `paramsPatch`), tolerant gegenüber mehreren Schreibweisen (LV95, LV03, Dezimalgrad in beiden Reihenfolgen, Grad-Minuten-Sekunden).
- Über Deep-Links gesetzte Werte erst mit der nächsten eigenen Änderung speichern – ein geöffneter Link überschreibt nicht still die gespeicherten Einstellungen.
- Der Tooltip bzw. Detail-Dialog bietet den Link auf die aktuelle Stelle an; externe Links (z.B. swisstopo) als Universal Links, die auf dem Handy die App öffnen.

## Druck (avers)

- Eigenes Drucksystem am Ende von `src/styles.css` mit `@page` und `@media print`, im Kopfkommentar die Absatzformate auflisten. Neue Formate dort einordnen statt einzeln zu übersteuern.
- Satzspiegel und Grundschrift in absoluten Einheiten (A4, cm, pt); Abstände als ganze oder halbe Zeilen.
- Alle Seiten einer Hash-Route-App erscheinen im Druck nacheinander, jede ab neuem Blatt; Navigation und interaktive Elemente ausblenden.
- `orphans`/`widows: 3`, `break-after: avoid` für Überschriften, `break-inside: avoid` für Bilder, Tabellenzeilen und Listenpunkte.
- Seiten im Druck als Block fliessen lassen, nicht als Grid – WebKit bricht Grids schlecht um.

## Funktionen nur über http(s) (rain)

Das Deliverable bleibt unter `file://` vollständig benutzbar; auf dem Server darf es mehr können:

- Nachladen grosser Daten (Kacheln) nur bei `location.protocol.startsWith('http')`; unter `file://` bleibt die eingebettete, gröbere Stufe. Kein Fehlerhinweis – der Fallback ist der Normalfall.
- APIs mit sicherem Kontext (`navigator.geolocation`) nur anbieten, wo der Browser sie hat; das Bedienelement sonst ausblenden.
- Trifft nachgeladener Inhalt ein, nur die betroffenen Teile neu rechnen (rain: `raster.invalidate`), nicht die ganze Ansicht.
- Diese Pfade brauchen eigene E2E-Tests über HTTP, weil der `file://`-Alltag sie nie ausführt (siehe [testing.md](testing.md)).

## Mobile Layouts (rain)

- Breakpoints nach Platz, Eingabeart und Ausrichtung kombinieren (`max-width`, `orientation`, `pointer: coarse`), nicht nur nach Breite.
- Panels auf schmalen Bildschirmen als Tabs; im Querformat wandern sie in einen Einstellungsdialog.
- Während der Tastatureingabe kein Layoutwechsel – sonst verschwindet das Feld mit dem Fokus.
