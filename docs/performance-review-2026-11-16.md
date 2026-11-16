# Performance-Analyse · 16.11.2026

Stand: `main` (5ea2b27) mit nicht committetem Arbeitsstand, Release-Build um 20:00.
Die gemessene Binary meldet `vauldy-mcp 0.14.13`. Ihre SHA-256 ist
`1100e7fba20dcf66d2decb86ebad67f38bfdffc7497d73642e2674d2ada345d8`,
die von `vauldy-local` ist `3d1065547f5926511c473a4d5e9dc24a74be5ed6b63bd2bd38ddd6a3d71ae11a`.
`MCPBuild.swift` wurde nach dem Build parallel auf 0.14.14 geändert. Die Werte gelten für
die gemessene Binary.

Getestet wurde nur mit synthetischen Beständen in temporären Verzeichnissen. Profile,
Archive, Installationen und Clientverbindungen wurden nicht verwendet. Kein OCR-Benchmark
lief parallel zu einem anderen. Es wurde kein Paket erstellt. Die Werte sind lokale
stdio-Zeiten auf einem Mac (arm64, macOS 27.2). Sie sind keine Chatlatenz und keine
Prognose für reale Archive.

## Ergebnis

| Prio | Befund | Messwert |
|---|---|---|
| P0 | Ein erster Inhaltsabruf skaliert stark mit Textlänge und Anzahl der Kennungen. Ursache ist die Regex-Kompilierung in der Privacy-Session. | Ein 128-KiB-Text mit 800 Kennungen braucht 68 s, einer mit 200 Kennungen 17 s. |
| P0 | Der Privacy-Cache hält 8 Dokumente. Ab dem neunten Dokument wird jeder Abruf wieder zu einem Kaltabruf. | Beim Wechsel über 12 Dokumente: Median 5,1 s pro Lesen. Bei 8 Dokumenten: 15 ms. |
| P1 | Die feste 1-GiB-Grenze der SQLite (`max_page_count=262144`) wird durch die neue Layoutspeicherung früher erreicht. | 20.000er-Matrix: `database or disk is full`. 5.000 Dokumente: +37 % Bytes gegenüber R3d.4. |
| P1 | Bei JSON-Beständen über 64 MiB fällt der Snapshot-Cache weg. Danach dekodiert jeder Aufruf den gesamten Bestand. | 5.000 Freigaben (84 MB): 185 ms pro Lesen eines einzelnen Dokuments, bei 1.000 Freigaben 25 ms. |
| P2 | Rangsuche, Kaltstatus und Indexaufbau sind gegenüber R3d.4 bei 5.000 Dokumenten langsamer. Sie halten die Gates aber ein. | Siehe Vergleichstabelle. |

Die SQLite-Listen-, Filter- und Statuspfade bleiben bei 1.000 und 5.000 Dokumenten deutlich
unter den Gates. Das gilt auch während einer nativen OCR mit 24 Seiten. Die Hauptlatenz
entsteht durch die Privacy-Vorbereitung bei Inhaltsabrufen, nicht durch die Suche.

## P0: Privacy-Vorbereitung ist superlinear

`preparedDocument` (`ReadOnlyMCPRuntime.swift`) baut für jedes Dokument eine
`IdentifierPrivacySession` über den vollständigen Text. Das geschieht auch dann, wenn nur
ein Auszug ausgegeben wird.

Die Kosten entstehen an drei Stellen:

- **`IdentifierPrivacySession.ranges(of:in:)`:** erzeugt für jede Ersetzung und jeden
  `protect`-Aufruf ein neues `NSRegularExpression`. Das Muster für ganze Wörter enthält
  `\p{L}`/`\p{N}` und `.caseInsensitive`. ICU baut dafür bei jeder Kompilierung
  UnicodeSets neu auf.
- **`protect`:** prüft nacheinander jede Ersetzung gegen den gesamten Text. Der Aufwand
  wächst mit Ersetzungen × Textlänge, dazu kommen R Kompilierungen pro Aufruf.
- **Residual-Schleife im Initializer:** läuft bis zu 8-mal. Jeder Durchlauf ruft `protect`
  und den Detektor erneut über alle Inhalte auf.

Ein Stack-Sampling (8 s, 128 KiB, 800 Kennungen) zeigt rund 4.770 aktive Samples in
`IdentifierPrivacySession.init → protect`. Davon liegen 4.222 (≈ 89 %) in der
Initialisierung von `NSRegularExpression`. Die führenden Frames sind
`icu::UnicodeSet::findCodePoint` und `applyFilter`. Auszug:
[privacy-cold-read-sample-top.txt](quality/performance-2026-11-16/privacy-cold-read-sample-top.txt).

Gemessen wurde der erste `read_document`-Aufruf in einem frischen Prozess. Die synthetischen
Kennungen sind Name, IBAN, E-Mail und Vertragsnummer je Zeile.

| Text | 0 Kennungen | 50 | 200 | 800 |
|---:|---:|---:|---:|---:|
| 32 KiB | 0,37 s | 1,6 s | 4,9 s | 6,9 s |
| 128 KiB | 1,4 s | 6,0 s | 17,1 s | 68,4 s |
| 512 KiB | 6,2 s | 21,0 s | – | – |

Bei einem Cachetreffer dauert derselbe Abruf 13–35 ms. Ein `passages`-Abruf nach
Cachetreffer dauert 0,04–0,9 s. Der Standard-Clienttimeout der Testskripte (15 s) wurde
ab 128 KiB mit 200 Kennungen überschritten.

**Folge:** Ein Chat, der 10–20 Verträge nacheinander liest, sucht oder vergleicht, kann
allein lokal Minuten warten. Ursache ist das Zusammenspiel mit dem Cache aus 8 Dokumenten
(nächster Abschnitt). Das passt zu den früher beobachteten mehrminütigen Chatantworten, ist
aber noch nicht im Zielchat nachgewiesen.

**Vorschlag, ohne die Privacy-Grenze zu verändern:**

1. Kompilierte Regex in der Session je `Replacement` einmal erzeugen und wiederverwenden.
   Wahrscheinlich bringt das allein den Hauptgewinn, denn ≈ 89 % der Samples entfallen
   auf die Kompilierung.
2. Alle Originalwerte in einer einzigen Alternation kompilieren (längste zuerst) und den
   Text einmal durchlaufen. Die Überlappungsregel „längste gewinnt“ bleibt dabei über die
   bisherige Sortierung erhalten.
3. Residual-Durchläufe nur auf die Bereiche um neu ersetzte Spannen beschränken. Die
   abschließende Validierung der vollständigen Ausgabe bleibt unverändert.
4. Danach die bestehenden Privacy-Regressionen ausführen: Suche, Text und Metadatensicht,
   `IdentifierPrivacyCompletionTests` und `MCPPrivacyBoundaryTests`. Die ausgegebenen
   Bytes müssen gegenüber vorher identisch sein.

## P0: Privacy-Cache mit 8 Dokumenten

`protectedDocuments` verdrängt ab 8 Dokumenten oder 8 MB. Gemessen wurden
`read_document`-Abrufe in der zweiten Runde (64 KiB Text, je 100 Kennungen):

| Abwechselnd gelesene Dokumente | Median pro Abruf |
|---:|---:|
| 8 | 14,6 ms |
| 12 | 5.111,9 ms |

Bei FIFO-Verdrängung und zyklischem Zugriff verfehlt jeder Abruf den Cache. Suche und
Liste mit Auszügen über mehr als 8 Treffer verhalten sich genauso.

**Vorschlag:** Zuerst P0 beheben. Danach den Cache nach Bytes statt nach Anzahl begrenzen,
zum Beispiel 32–64 MB, und LRU statt FIFO verwenden. Die Bindung an Fingerprint und Profil
bleibt erhalten. Keine TTL.

## P1: 1-GiB-Grenze und gewachsene Datensätze

`SQLiteDocumentStorePilot` setzt für Schreibverbindungen `PRAGMA max_page_count=262144`
(1 GiB, Kommentar „until R3d load acceptance“). Seit 9467d0c (14.11.) speichert jede Seite
`layout` mit Block-, Zeilen- und Coverage-Geometrie als ungekürzte Doubles. Im Beispiel
sind das rund 370 Byte pro Textzeile.

| | R3d.4 (06.11.) | Jetzt |
|---|---:|---:|
| Datenbank bei 5.000 Dokumenten | 228,6 MB | 313,4 MB (+37 %) |
| Datenbank bei 20.000 Dokumenten | 914,0 MB | Abbruch beim Befüllen: `database or disk is full` |

Auf dem Datenträger waren 24 GiB frei. Die Grenze greift auch im Produktschreiber. Ein
Import würde dann fehlschlagen, und die Meldung nennt fälschlich eine volle Platte. Mit
der synthetischen Form (8 Seiten, 32 KiB Text) liegt die Grenze rechnerisch bei etwa
17.000 Dokumenten. Dichte reale Seiten mit vielen Zeilen erreichen sie früher. Das ist
eine Abschätzung, keine Messung.

**Vorschlag:** Die Geometrie vor dem Speichern auf etwa 4–5 Nachkommastellen runden. Das
spart voraussichtlich etwa die Hälfte der Layoutbytes. Zusätzlich die Grenze für
verständliche Meldungen sichtbar machen, bevor sie erreicht wird. Eine Anhebung der
1-GiB-Grenze braucht eine eigene Lastabnahme bei 20.000 Dokumenten, nicht nur eine
geänderte Zahl.

## P1: JSON-Snapshot oberhalb des Cachebudgets

Mit JSON-Bestand wurde ein einzelnes Dokument (32 KiB, 20 Kennungen) gelesen. Der übrige
Bestand bestand aus Fülldokumenten mit 16 KiB.

| Freigaben | Snapshot | `read_document` (warm) | `extract_document_fields` |
|---:|---:|---:|---:|
| 10 | 0,2 MB | 14,5 ms | 11,7 ms |
| 1.000 | 16,7 MB | 25,4 ms | 24,1 ms |
| 5.000 | 83,6 MB | 184,9 ms | 186,7 ms |

Oberhalb von 64 MiB wird nichts gehalten. Dann dekodiert jeder Aufruf den Bestand
vollständig. Das ist derselbe Befund wie am 06.11. und weiterhin offen. `extract_document_fields`
und `compare_contract_versions` laden auch mit SQLite-Bestand alle freigegebenen Dokumente
über `authorizedDocuments`, obwohl `read_document` und `get_deadline_overview` bereits
gezielt einzeln auflösen. Diese beiden Pfade für 1–10 Handles auf `resolveSingle` umstellen.

## Vergleich SQLite-Lastmatrix mit R3d.4 (5.000 Dokumente)

Gemessen mit `sqlite_combined_acceptance.py` und denselben Parametern (32 KiB, 24 OCR-Seiten,
25 Samples). Ergebnis: **GO** für 5.000. 1.000 schlug im Gesamtlauf direkt nach dem
abgebrochenen 20.000er-Fall mit „Native import or fresh OCR failed“ fehl. Der einzeln
wiederholte Lauf bestand (GO). Die Ursache des ersten Fehlschlags wurde nicht geklärt.

| Kennzahl | R3d.4 | Jetzt | Gate |
|---|---:|---:|---:|
| Initialer Projektionsaufbau | 54,4 s | 64,7 s | – |
| Kaltstatus | 102 ms | 169 ms | 5.000 ms |
| Warmstatus P95 | 86 ms | 56 ms | 1.000 ms |
| Kompakte Liste P95 | 116 ms | 100 ms | 1.000 ms |
| Vollständige Paginierung (50 Aufrufe) | 5,04 s | 4,71 s | – |
| Seltener Marker, gerankt | 416 ms | 526 ms | – |
| Breite Rangsuche, steady P95 | 501 ms | 584 ms | 5.000 ms |
| Breite Rangsuche während OCR, P95 | 199 ms | 744 ms¹ | 5.000 ms |
| Native OCR, 24 Seiten | 4,04 s | 4,17 s | – |
| Peak-RSS Server | 41,6 MB | 45,6 MB | 512 MiB |

¹ Nur 18 überlappende Samples. Ein einzelner Ausreißer bestimmt den P95, daher ist das
kein belastbarer Trend.

Die Verschlechterungen beim Aufbau und bei der Rangsuche passen zu den größeren Datensätzen.
Werte für 20.000 Dokumente liegen nicht vor, siehe P1.

## Weitere Codebefunde (nicht einzeln gemessen)

- **Revalidierung:** Jede Revalidierung (`MCPFileVersion` → `LocalVaultSnapshotSource.generation`)
  öffnet eine neue SQLite-Verbindung. Ein Suchaufruf öffnet so mehrere Verbindungen und
  liest das Profil mehrfach. Im Warmpfad liegen die Werte unter 100 ms, daher ist das
  derzeit nachrangig.
- **Kleine Regex-Kompilierungen:** `MCPSourceExcerpt`, `MCPContractComparison` und
  `MCPDeadlineOverview` kompilieren Regex pro Aufruf oder pro Zeile. Gleiches Vorgehen
  wie unter P0.
- **OCR:** Seiten laufen seriell auf einer Queue. Seiten mit `needsReview` werden nie im
  Seitencache gespeichert und daher bei jedem erneuten Lesen vollständig neu erkannt.
  `LocalOCRPageCache` sortiert und bereinigt bei jedem Öffnen das Cacheverzeichnis. Eine
  OCR-Parallelisierung braucht wegen Speicher und Vision-Lastverhalten einen eigenen A/B-Test.

## Reproduktion

```sh
swift build -c release
python3 scripts/mcp/sqlite_combined_acceptance.py .build/release/vauldy-local .build/release/vauldy-mcp \
  --counts 20000,1000,5000 --broad-ocr-min 2 --output /tmp/combined.json
python3 scripts/mcp/privacy_request_benchmark.py .build/release/vauldy-mcp /tmp/privacy.json
```

Rohdaten: [sqlite-combined.json](quality/performance-2026-11-16/sqlite-combined.json) und
[privacy-request-path.json](quality/performance-2026-11-16/privacy-request-path.json).
`privacy_request_benchmark.py` ist neu und nutzt nur temporäre JSON-Bestände. Die
Privacy-Tabelle stammt aus zwei Läufen derselben Binary. Der erste Lauf brach mit dem
15-s-Timeout ab, deshalb verwendet das Skript jetzt 180 s.

Nicht gemessen: Zielchat und Relay, reale Archive, Peak-RSS bei 20.000 Dokumenten,
Setup-UI, Paket und Installation.
