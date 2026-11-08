# Lokale OCR-Zeilenkoordinaten

Neu erkannter Text kann pro physischer Seite eine optionale Geometrie erhalten.
Jede Zeile trägt ihren UTF-16-Bereich im unveränderten Seitentext, ein normalisiertes
Rechteck und die Erkennungsmethode. Die Konfidenz stammt bei Vision-Zeilen aus
der tatsächlich akzeptierten Beobachtung. Eingebetteter PDF-Text erhält keine
synthetische Konfidenz.

Beim Speichern bindet `LocalDocumentStore.finish` die Geometrie an die geprüfte
Original-Prüfsumme, die physische Seitennummer, die OCR-Konfiguration und die
Prüfsumme des exakten Seitentextes. Das lokale Prüfmodell stellt sie nur bei
passender Bindung und verfügbarem Original weiter. Ungültige Rechtecke,
UTF-16-Bereiche und zu große Zeilenmengen werden verworfen.

| Koordinatenraum | Ursprung und Bezug |
| --- | --- |
| `pdfCropBottomLeft` | Unten links im ungedrehten PDF-CropBox-Rechteck, normalisiert auf 0 bis 1. Die Seitendrehung wird separat gespeichert. |
| `uprightImageBottomLeft` | Unten links im durch ImageIO ausgerichteten Bild, normalisiert auf 0 bis 1. |

Die Vision-Rechtecke werden aus den weißen Randbeschnitten zurückgerechnet.
Bei langen Bildern werden die Kacheln auf das gesamte Bild bezogen. PDF-Regionen
verwenden die tatsächlich benutzte Rendertransformation, einschließlich eines
gegebenenfalls korrigierten Rasterdurchlaufs. Dadurch bleiben Renderauflösung,
PDF-CropBox und Seitendrehung nachvollziehbar. Hybridseiten führen eingebettete
und visuell erkannte Zeilen mit angepassten Textpositionen zusammen.

Die Angaben bleiben lokale Verwaltungsmetadaten. Die bestehenden MCP-Ausgabeobjekte
verwenden weiterhin ihre geschützten Text- und Seitenbelege. Alte Datensätze ohne
Geometrie bleiben lesbar. Die Cachekonfiguration v8 schließt ältere Checkpoints
aus. Vorhandene abgeschlossene Importe werden bei ausdrücklicher Frischerkennung
aktualisiert. Wird ein Seitenmarker aus dem Quelltext beim Speichern entschärft,
entfällt für diese Seite die Geometrie, da sich die Textpositionen geändert haben.

Die Zeilenrechtecke bilden die eindeutig zugeordneten Textbereiche ab.
Textblöcke und der geometrische visuelle Abdeckungsvergleich sind in der
[Folgeiteration umgesetzt](ocr-block-coverage.md). Auch das
[gezielte Nachlesen auffälliger Regionen](ocr-marked-region-recovery.md) ist umgesetzt.
Zusätzliche Inhaltsprüfungen bleiben eigene Qualitätsschritte.

## Prüfung vom 7. November 2026

143 Build- und Testdateien der isolierten Kopie wurden mit dem Arbeitsbaum auf
`codex/local-first-product-readiness`, Basis `87ab76c`, byteweise verglichen.
60 gezielte Swift-Tests in neun Suites bestanden in 12,171 Sekunden. Der erste
Buildversuch scheiterte an einer verschachtelten `#require`-Assertion im neuen
Test. Nach Aufteilung der Assertion wurden die Tests erfolgreich ausgeführt.

Die neuen geometrischen Sollwerttests verwenden eingebettete und gerasterte
PDFs mit CropBox-Versatz und den Drehungen 0, 90, 180 und 270 Grad. Hinzu kommen
zwei PNG-Größen mit weißen Rändern und Bildkacheln, eine Hybridseite und eine
lange PDF mit mehreren Erkennungsregionen. Die erkannten Zeilen werden über
ihren Textbereich gefunden und gegen die unabhängig vorgegebenen physischen
Positionen geprüft.

Weitere Tests prüfen alte Daten ohne Layout, ungültige Rechtecke und
UTF-16-Bereiche innerhalb eines Surrogatpaars, geänderte Quellen, Seiten,
Texte und Konfigurationen, das Laden gespeicherter Metadaten, Cachetreffer
und die Behandlung entschärfter Quell-Seitenmarker. Die bestehenden acht
strikten Rasterdomänen, Type-3-Felder, Import-, Original-, Prüfmodell- und
SQLite-Integrationsprüfungen sind im Lauf enthalten.

Der echte Worker-/MCP-Test importierte die beiden synthetischen Type-3-PDFs,
speicherte alle sechs Sollfelder mit gebundener Geometrie und prüfte Suche,
Seitenbelege, Freigabe, Cache, Frischerkennung und Widerruf. Interne Hashes und
Geometrie wurden in der MCP-Antwort nicht ausgegeben.
[Maschinenlesbarer Prüfnachweis](quality/ocr-line-layout-2026-11-07.json).

Die folgenden Befehle wurden in `/private/tmp/vauldy-ocr-vector-wtr5pb1z`
mit den aktuellen Quellen ausgeführt. Der Wiretest lief nach dem ersten
erfolgreichen 58-Test-Lauf. Anschließend kamen die zwei zusätzlichen Tests
für Hybridtext und lange PDF-Regionen hinzu. Der abschließende 60-Test-Lauf
verwendete denselben Produktcode.

```sh
VAULDY_OCR_VECTOR_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/vector-fixtures VAULDY_OCR_AB_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/raster-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'OCRLayoutTests|PDFVectorTextOCRTests|OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalImportTests|LocalOriginalReferenceTests|BaseAnalysisMCPTests|LocalDocumentReviewTests|SQLiteIntegrationTests'
python3 scripts/mcp/vector_ocr_quality_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp vector-fixtures
```

Geändert wurden `LocalOCRLayout.swift`, `LocalImportModels.swift`,
`NativeLocalDocumentOCR.swift`, `LocalOCRPageCache.swift`, `LocalDocumentStore.swift`
und `LocalDocumentReview.swift` unter `Sources/VauldyCore`, dazu
`Tests/VauldyMCPRuntimeTests/OCRLayoutTests.swift`, der vorhandene
`scripts/mcp/vector_ocr_quality_smoke_test.py` und die zugehörigen Dokumentations-
und Prüfdateien.
