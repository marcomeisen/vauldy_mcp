# Textblöcke und visueller Abdeckungsvergleich

Die lokale OCR gruppiert geometrisch benachbarte Zeilen in Textblöcke. Jeder Block
enthält Verweise auf die gespeicherten Zeilen und ein umschließendes Rechteck.
Die Zuordnung berücksichtigt Zeilenhöhe, Abstand, Einrückung und horizontale
Überlappung. Spalten und entfernte Absätze bleiben getrennt. Mehrdeutige Nachbarn
bilden eigene Blöcke. Der gespeicherte Seitentext bestimmt weiterhin die Textreihenfolge.

Zusätzlich prüft `VNDetectTextRectanglesRequest` mit Zeichenrechtecken das sichtbare
lokale Seitenbild. Der Vergleich zählt pro erkanntem Bereich, wie viele Zeichen
von den vorhandenen OCR-Zeilenrechtecken abgedeckt werden. Er verwendet die einzelnen
Zeilen. Die Blockrechtecke dienen der Gruppierung, da sie auch leere Abstände
zwischen Zeilen umfassen.

Ein Bereich wird auffällig, wenn mindestens drei Zeichen unzugeordnet bleiben und
weniger als 85 Prozent seiner Zeichen abgedeckt sind. Ein Zeichen gilt bei mindestens
50 Prozent Flächenüberlappung als zugeordnet. Kleine geometrische Abweichungen werden
mit einem begrenzten Rand berücksichtigt. Diese Schwellen sind konservative lokale
Heuristiken und im synthetischen Korpus geprüft.

## Speicherung und Verarbeitung

`LocalOCRGeometry` speichert optional `blocks` und `coverage` innerhalb der vorhandenen
Bindung an Original-Prüfsumme, physische Seite, OCR-Konfiguration und Seitentext-Prüfsumme.
Die Vergleichsrechtecke werden zusammen mit den Zeilen aus Randbeschnitt, Kacheln
und PDF-Renderkoordinaten zurückgerechnet. Bei eingebettetem Text und Hybridseiten
wird das vollständige sichtbare PDF-Seitenbild geprüft.

Der Vergleich ist auf 128 Bereiche, 256 Zeichen pro Bereich und 128 passende
Zeilen pro Bereich begrenzt. Die Blockbildung verwendet maximal 4.096 Zeilen und
64 aktive Nachbargruppen. Vergleichsergebnisse unterscheiden `checked`, `limited`
und `unavailable`. Grenzen und Fehler führen zu einem Prüfhinweis. `checked`
dokumentiert den ausgeführten geometrischen Vergleich. Die Anzahl der gefundenen
Bereiche gehört zum Ergebnis und kann null sein.

Bei auffälligen Bereichen setzt die OCR `needsReview`. Der Import wird dadurch
teilweise erfasst, und die vorhandene MCP-Ausgabe meldet unvollständige Quellenabdeckung.
Die lokale Seitenprüfung nennt den Grund „Die visuelle Prüfung hat möglicherweise
nicht erfasste Textbereiche gefunden.“ Block- und Vergleichsrechtecke sowie interne
Prüfsummen bleiben lokale Verwaltungsmetadaten.

Die Cachekonfiguration v9 schließt alte Zeilen-Checkpoints ohne Vergleich aus.
Prüfbedürftige Ergebnisse werden erneut geprüft. Erfolgreiche Ergebnisse können
ihre gebundenen Metadaten aus dem Cache laden. Neue Importe und ausdrücklich mit
„Text erneut lesen“ verarbeitete Dokumente erhalten den Vergleich.

## Prüfung vom 7. November 2026

147 Build- und Testdateien wurden zwischen Arbeitsbaum und isolierter Buildkopie
byteweise verglichen. Der Branch ist `codex/local-first-product-readiness`, Basis
`87ab76c`. Im abschließenden Release-Testlauf bestanden 68 gezielte Swift-Tests in
zehn Suites in 12,144 Sekunden. Enthalten sind die acht strikten Rasterdomänen,
Type-3-Schriften, Zeilenkoordinaten, Import, Quellenzugriff, lokale Seitenprüfung
und SQLite-Integration.

| Synthetische Vorlage | Bisheriger Prüfhinweis | Visuell auffällige Bereiche | Vergleichszeit |
| --- | --- | --- | --- |
| Kopfzeile mit freien Versicherungs-Vektortexten | Aus | 3 | 16 ms |
| Kopfzeile mit freien Rechnungs-Vektortexten | Aus | 3 | 17 ms |

Die Zeitwerte sind Einzelläufe nach vorausgegangenen OCR-Tests im selben Prozess.
Sie enthalten Rendern und visuelle Prüfung, getrennt von der eigentlichen OCR-Zeit.
Die Vorlage mit Balken und Rechtecken blieb ohne zusätzlichen Prüfhinweis.
Weitere Prüfungen bestätigen getrennte Spalten, Absatzabstände, eine nicht erfasste
Zeile innerhalb eines Blockrechtecks, kleine Zuordnungsabweichungen und die expliziten
Grenz- und Fehlerzustände. Ein alter v8-Checkpoint konnte den neuen Vergleich nicht
umgehen. Beschädigte Blockreferenzen und Vergleichszähler werden beim Binden verworfen.

Der erste echte Worker-/MCP-Test importierte beide Lücken-Vorlagen als teilweise
erfasst. Die MCP-Lesung meldete `incomplete-or-unknown` und den bestehenden
Seiten-Prüfhinweis. Die Ausgabe enthielt die tatsächlich erfasste Kopfzeile.
Vergleichsrechtecke, interne Hashes und unerkannte Sollfelder wurden nicht ausgegeben.
Wiederholung und Frischerkennung bestätigten die Prüfhinweise, das Freigabeprofil
blieb bytegleich, und Widerruf sperrte den Zugriff.

Der zweite Worker-/MCP-Test importierte die beiden vollständig erkannten
Type-3-Vorlagen. Alle sechs Sollfelder wurden gespeichert und über die vorhandene
Privacy-Grenze ausgegeben. Quellenbelege, unfreigegebene Dokumente, erfolgreiche
Cachetreffer, Frischerkennung und Widerruf sind geprüft.

Bei der abschließenden Trennung der Messzeiten brach ein Zwischenbuild wegen
überlappender Swift-Zugriffe auf die optionalen Messwerte ab. Nach Lesen in eine
lokale Konstante wurden der Build, die 68 Tests und beide Wiretests erfolgreich
wiederholt. Die Nachweise stehen in
[der Ergebnisdatei](quality/ocr-block-coverage-2026-11-07.json).

Die folgenden Befehle liefen mit den aktuellen Quellen in
`/private/tmp/vauldy-ocr-vector-wtr5pb1z`. Die OCR-Prüfungen liefen nacheinander.

```sh
VAULDY_OCR_COVERAGE_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/coverage-fixtures VAULDY_OCR_VECTOR_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/vector-fixtures VAULDY_OCR_AB_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/raster-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'OCRBlockCoverageTests|OCRLayoutTests|PDFVectorTextOCRTests|OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalImportTests|LocalOriginalReferenceTests|BaseAnalysisMCPTests|LocalDocumentReviewTests|SQLiteIntegrationTests'
python3 scripts/mcp/visual_coverage_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp coverage-fixtures
python3 scripts/mcp/vector_ocr_quality_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp vector-fixtures
```

Die neue Prüfung und Fixture-Erzeugung sind im Regressionsskript eingetragen.
Der Nachweis umfasst den angegebenen gezielten Lauf und die beiden Wireprüfungen.
Der globale Regressionslauf bleibt ein eigenes Releasegate.

Geändert wurden `LocalOCRBlocks.swift`, `LocalOCRVisualCoverage.swift`,
`LocalOCRLayout.swift`, `NativeLocalDocumentOCR.swift`, `LocalOCRMetrics.swift`,
`LocalOCRPageCache.swift` und `LocalDocumentReview.swift` unter `Sources/VauldyCore`,
die Tests `OCRBlockCoverageTests.swift` und `PDFVectorTextOCRTests.swift`, die Skripte
`visual_coverage_smoke_test.py`, `vector_ocr_quality_smoke_test.py` und
`regression_test.py` sowie die zugehörigen Dokumentations- und Prüfdateien.

## Grenzen und nächster Schritt

Der Vergleich prüft geometrische Zuordnung. Gleich positionierter, plausibel falsch
zugeordneter Text und Unterschiede innerhalb eines bereits umschließenden Zeilenrechtecks
benötigen zusätzliche Inhaltsprüfungen. Die Textbereichserkennung liefert mögliche
Textregionen. Ihre Ergebnisse können bei realen Grafiken und schwierigen Vorlagen
vom kleinen synthetischen Korpus abweichen.
Der vorhandene Leerpfad wird gesondert behandelt. Sehr helle, dort bereits als leer
klassifizierte Seiten benötigen einen eigenen Qualitätsschritt.

Das [gezielte Nachlesen markierter Regionen](ocr-marked-region-recovery.md) ist in
der Folgeiteration mit begrenztem Budget und geschützter Ergänzung umgesetzt.
