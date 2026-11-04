# Vauldy Local-First · Entwicklungsstand

Arbeitsbranch `codex/local-first-product-readiness`. Jede Verbindung nutzt den MCP auf dem Mac des jeweiligen Kunden. JSON und das vorhandene Backup bleiben führend. Die Kundenabnahme folgt auf die intern geprüfte lokale Architektur.

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
- [ ] Index beim gleichzeitigen Freigabewiderruf, Entfernen einer Verbindung und Prozessabbruch prüfen. Der Zugriffsverlust muss sofort wirksam sein. Der Pilot braucht für verwaiste Indexdateien einen nachweisbaren Bereinigungspfad.
- [ ] Standardbetrieb anhand der Ressourcen- und Datenschutzgrenzen entscheiden. Kompakte Projektion und Dateiindex getrennt bewerten. Eine Änderung des führenden Formats braucht eine eigene Backup- und Restore-Abnahme.
- [ ] Gemeinsame Swift-Verträge für IDs, OCR, Suche und Privacy einzeln klassifizieren. Modellbesitz, Versionsregeln und Altfixtures festhalten.
- [ ] App-Anbindung und belegte Duplikate getrennt übernehmen, sobald Arbeit im App-Repo wieder freigegeben ist. App-spezifische KI und Altformate gegen dieselben Fixtures absichern.
- [ ] Lokalen Import und OCR-Worker unter kontrollierter Last messen. Vor einer Kundenfreigabe Referenz-Mac, Dokumentmix, P95, Durchsatz, Speichergrenzen und Suchqualität festlegen.
- [ ] Lokale Worker-Parallelität begrenzen, Abbruch und Wiederaufnahme nach Absturz belegen und einen Diagnosebericht mit technischen Zählern prüfen.
- [ ] Sichtbare Fortschrittsanzeige des Ordnerimports in der isolierten Oberfläche bestätigen.

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
| 4 · Entscheidung über den Standardbetrieb | Als Nächstes | Konkurrierenden Widerruf und verwaiste Dateien prüfen. Projektion unabhängig vom Dateiindex bewerten. |
