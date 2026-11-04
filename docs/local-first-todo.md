# Vauldy Local-First · Entwicklungsstand

Arbeitsbranch `codex/local-first-product-readiness`. Jede Verbindung nutzt den MCP auf dem Mac des jeweiligen Kunden. JSON und das vorhandene Backup bleiben führend. Die Kundenabnahme folgt auf die intern geprüfte lokale Architektur.

Die Weiterentwicklung konzentriert sich auf den eigenständigen Vauldy MCP. Der Chatbot ist die einzige Oberfläche für die Dokumentarbeit. Die Vauldy-Hauptapp ist aus dem Entwicklungsumfang ausgeschieden. Der vorhandene MCP-Einrichtungsassistent ist ein technischer Installations- und Verbindungsweg. Die künftige Einrichtung und Freigabeverwaltung werden separat vom Chatbetrieb festgelegt.

Nach jeder Iteration werden die betreffenden Aufgaben abgehakt und der tatsächliche Prüfnachweis, offene Punkte und der nächste Schritt unten ergänzt. Die Reihenfolge in den offenen Abschnitten gilt als Arbeitsreihenfolge.

## Abgeschlossen

- [x] Beide Repository-Stände und die Quellabweichungen erfassen. Deutscher Masterprompt und Bestandsaufnahme liegen im App-Repo.
- [x] MCP-Paketierung auf gemeinsame Version, Plattformprüfung und Paketnachweis umstellen.
- [x] Vollständigen Softwarewechsel, Startprüfung und Rollback mit synthetischem Bestand prüfen.
- [x] Reale lokale stdio-Verträge für Privacy, Pagination und Widerruf absichern.
- [x] Installationsassistent in einer isolierten Instanz bis zum lokalen Starttest durchspielen.
- [x] Rekursiven Ordnerimport und gemeinsamen Dokumentzähler implementieren. Der Import von zwölf synthetischen PDFs wurde verifiziert.
- [x] Seitenmarkierungsvertrag in `VauldyDocumentCore` extrahieren und optionalen FTS5-Speicherpilot anbinden.
- [x] Agensi-Anweisungspaket bauen. Die Zielclient-Abnahme steht separat aus.

## Architektur zuerst

- [x] Privat abgelegten, aus JSON wiederaufbaubaren SQLite-Index für ausdrücklich freigegebene Datensätze implementieren. Inkrementelle Änderungen, Profilbindung und Korruptionsrückweg absichern.
- [x] Kompakte Listenmetadaten mit gültigem JSON-Stand und Profil verbinden. Gleichheit der Antworten, Cursor und Quellen prüfen.
- [x] Cachegröße, kompakte Projektion und FTS5 getrennt an 20.000 synthetischen Dokumenten messen. Die Größen 1.000, 2.000, 5.000, 10.000 und 20.000 prüfen. Latenz einschließlich P95, Peak-RSS, Vollständigkeit und Wiederverwendung über Prozessneustarts erfassen.
- [x] Index bei gleichzeitigem Freigabewiderruf, Entfernen einer Verbindung und Prozessabbruch absichern. Stagingreste, SQLite-Journal und liegen gebliebenen getrennten Cache beim Wiederanlauf prüfen.
- [x] Kompakte Pagination im lokalen stdio-Server als Standard für `includeExcerpts=false` aktivieren. Der Dateiindex bleibt optional. JSON bleibt führend. Eine spätere Formatänderung braucht eine eigene Backup- und Restore-Abnahme.
- [x] Verträge des eigenständigen MCP für Dokument-IDs, Seitenbelege, Suchvollständigkeit, Datenschutz und Widerruf festlegen. Interne Swift-Modelle und versionierte Werkzeugantworten abgrenzen. Kompatibilität mit bestehenden Clients und lokalen Daten anhand synthetischer Testfälle prüfen.
- [ ] Einen Referenzablauf im Chat mit den vorhandenen MCP-Werkzeugen messen. Beispielauftrag ist eine Tabelle zu synthetischen Versicherungsverträgen mit Versicherer, Vertragsnummer und Kündigungsfrist. Erwartete Treffer, Feldwerte und Fundstellen vorab festhalten.
- [ ] Einen lokalen Recherche-Agenten für diesen Auftrag erproben. Er nutzt die vorhandenen Such- und Lesewerkzeuge, verfolgt bei vollständigen Abfragen alle Folgeseiten und liefert eine Tabelle mit Seitenbelegen. Fehlende oder widersprüchliche Felder und vorzeitig beendete Suchen kennzeichnet er ausdrücklich.
- [ ] Recherche-Agenten und direkten Chatablauf am selben Bestand vergleichen. Trefferabdeckung, korrekte Feldbelege, Laufzeit und Werkzeugaufrufe erfassen. Abbruch, begrenzte Laufzeit und Freigabewiderruf während des Auftrags prüfen. Der Offline-Lauf nutzt ein lokal verfügbares Modell.
- [ ] Optional ein gezieltes lokales Extraktionswerkzeug erproben, wenn der Pilot eine wiederkehrende Lücke bei vorhandenen Metadaten oder Fundstellen zeigt. Pro Feld Wert, Seite und Textbeleg liefern. Ein separater Extraktions-Agent setzt einen belegten Bedarf an mehrstufiger Extraktion voraus.
- [ ] Lokalen Import und OCR-Worker unter kontrollierter Last messen. Vor einer Kundenfreigabe Referenz-Mac, Dokumentmix, P95, Durchsatz, Speichergrenzen und Suchqualität festlegen.
- [ ] Lokale Worker-Parallelität begrenzen, Abbruch und Wiederaufnahme nach Absturz belegen und einen Diagnosebericht mit technischen Zählern prüfen.
- [ ] Festlegen, wie ein bewusst gestarteter lokaler Import und sein Gesamtfortschritt im Chat sichtbar werden. Technische Einrichtung und Freigaben separat betrachten.

## Nach der Architektur

- [ ] Zwei kompatible Developer-ID-Pakete bauen, notarisieren und die Tickets im finalen ZIP prüfen.
- [ ] Auf einem frischen Offline-Test-Mac Erststart, Update und Rollback mit synthetischen Daten und stabilen Clientpfaden belegen.
- [ ] Agensi-Skill im Zielclient mit dem bestehenden lokalen MCP prüfen. Inventar, Quellenlesen und Widerruf abnehmen.
- [ ] Freigabeentscheidung für Kundenauslieferung und 20.000 reale Dokumente dokumentieren.
- [ ] Optionale Remote- und Lizenzfunktionen bei Bedarf in einem separaten Architekturvorschlag entscheiden. Lokalen stdio-Betrieb offline weiterhin prüfen.

## Iterationen

| Iteration | Stand | Nachweis und nächster Schritt |
| --- | --- | --- |
| 0 · Lokale Produktschnittstelle | Abgeschlossen | Release-Gates, Update/Rollback, Assistent und rekursiver Import. Interne und Kundenabnahme werden getrennt geführt. |
| 1 · Architekturpilot | Abgeschlossen | Seitenvertrag und zuschaltbarer FTS5-Speicherindex. Synthetisches Inventar mit 20.000 Dokumenten vollständig. |
| 2 · Persistenz und Projektion | Abgeschlossen | 21 gezielte Swift-Tests bestanden. Geprüft sind unter anderem Neustart, inkrementelle Änderungen, Korruptionsreparatur, Cursor und Widerruf. |
| 3 · Variantenmessung | Abgeschlossen | Fünf Varianten bei fünf Bestandsgrößen. Bei 20.000 Dokumenten lieferte der Dateimodus alle 200 Seiten in 30,62 s und verwendete den Index nach Neustart bytegleich wieder. [Messwerte](local-first-release.md#variantenmessung) |
| 4 · Widerruf, Wiederanlauf und Standardbetrieb | Abgeschlossen | Der gestoppte Indexschreiber liefert nach Widerruf keine Treffer. Nach zwei realen `SIGKILL`-Abbrüchen sind Bestand und Berechtigungen intakt. Kompakte Pagination ist lokaler Standard. Im 20.000er-Vergleich sank der Median der ersten zehn Folgeseiten von 703 auf 126 ms. [Prüfbefehle](local-first-release.md#prüfbefehle) |
| 5 · MCP-Verträge für den Chatbetrieb | Abgeschlossen | Werkzeugvertrag v1, Seitenbelege, veraltete Handles und Freigabeprüfung vor der Ausgabe abgesichert. 54 gezielte Swift-Tests, separater nativer OCR-Test und MCP-Protokollprüfungen bestanden. [Werkzeugvertrag und Referenzauftrag](mcp-mvp.md#vauldy-werkzeugvertrag-v1) |
| 6 · Recherche-Agent | Als Nächstes | Referenzablauf messen und einen lokalen Agenten dagegen prüfen. Belege, Trefferabdeckung, Abbruch, Widerruf und Offline-Ausführung sind Teil der Abnahme. |
| 7 · Gezielte Extraktion | Bedingt | Nur bei einer im Recherchepilot belegten Lücke. Zuerst ein Werkzeug mit Feldwert und Quellenbeleg prüfen. |
