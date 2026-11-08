# Gezieltes Nachlesen markierter Textbereiche

Die lokale OCR liest auffällige Bereiche aus dem visuellen Abdeckungsvergleich
gezielt erneut. Ein gemeinsames Budget gilt für die gesamte physische Seite,
einschließlich ihrer PDF-Regionen und Bildkacheln. Es erlaubt vier Bereiche mit
je zwei OCR-Durchläufen. Ein Ausschnitt ist auf eine Million Pixel begrenzt,
die zusätzlichen OCR-Anfragen zusammen auf acht Millionen Pixel pro Seite.

Beide Durchläufe verwenden Apple Vision und denselben begrenzten Bildausschnitt.
Sprachkorrektur ist im ersten Durchlauf eingeschaltet und im zweiten ausgeschaltet.
Eine Zeile benötigt mindestens 0,85 Konfidenz in beiden Beobachtungen, übereinstimmenden
Text und übereinstimmende Positionen. Ihr Mittelpunkt und mindestens 70 Prozent
ihrer Fläche müssen im markierten Bereich liegen.

Die Ergänzung verwendet folgende Regeln.

Ausgangspunkt ist das Basistextergebnis desselben OCR-Durchlaufs. Bei ausdrücklich
frischer Texterkennung wird dieser Basistext erneut aus dem Original ermittelt.

- Bestehender Seitentext bleibt als Präfix erhalten. Neue Zeilen werden angehängt.
- Bereits belegte Zeilenrechtecke schützen ihren Bereich vor überlappenden Ergänzungen.
- Unterschiedliche Zahlen unter derselben expliziten Feldbezeichnung vor einem
  Doppelpunkt bleiben zur Prüfung offen.
- Die vorhandene Regel für mehrdeutige Kennungen gilt auch beim Nachlesen.
- Eine erneute visuelle Prüfung muss eine bessere Abdeckung bei mindestens gleicher
  Zahl detektierter Zeichen bestätigen. Andernfalls wird die Ergänzung verworfen.

Die neuen Zeilen erhalten UTF-16-Textbereiche, Rechtecke und die tatsächlich
gemessene Konfidenz. Beim Speichern werden sie über die bestehende Bindung an
Original-Prüfsumme, physische Seite, OCR-Konfiguration und Seitentext-Prüfsumme
gesichert. Ein PDF mit eingebettetem Text und ergänzten Zeilen verwendet die
vorhandene Methode `embeddedTextAndVision`.

Ein weiterhin auffälliger Bereich erhält seinen Prüfhinweis. Gleiches gilt nach
Budgetende oder bei unbestätigten Beobachtungen. Vollständig erkannte Kontrollen
lösen keinen regionalen OCR-Durchlauf aus. Die vorhandene Warteschlange hält den
Originalzugriff bis zum Ende der nativen Arbeit und prüft den Quellstand vor dem
Speichern.

Die Cachekonfiguration v10 trennt diese Ergebnisse von früheren Checkpoints.
Erfolgreich vervollständigte Seiten können mit ihren gebundenen Metadaten aus dem
Cache geladen werden. „Text erneut lesen“ verarbeitet das Original ausdrücklich
frisch. Zähler und Laufzeiten für Nachleseversuche, ergänzte Zeilen, Pixel und
Konflikte stehen getrennt von den vorhandenen Zeilen-Retry- und Abdeckungsmetriken.

## Prüfung vom 7. November 2026

Der Branch ist `codex/local-first-product-readiness`, Basis `87ab76c`. 149 Build-
und Testdateien wurden zwischen Arbeitsbaum und isolierter Buildkopie byteweise
verglichen. 73 gezielte Swift-Tests in elf Suites bestanden in 18,378 Sekunden.
Die acht strikten Rasterdomänen und die bisherigen Type-3-, Layout-, Block-, Import-,
Original-, lokalen Prüfmodell- und SQLite-Prüfungen sind enthalten.

| Synthetische Vorlage | Vorher erfasste Körperfelder | Nachher | Bereits belegter Wert | Nachlesezeit |
| --- | --- | --- | --- | --- |
| Versicherungsfelder aus freien Vektorpfaden | 0/3 | 3/3 | Selbstbehalt 110,00 EUR erhalten | 487 ms |
| Rechnungsfelder aus freien Vektorpfaden | 0/3 | 3/3 | Selbstbehalt 110,00 EUR erhalten | 527 ms |

Die Zeitwerte sind einzelne native Aufrufe nach vorausgegangenen OCR-Tests im
selben Prozess. Sie enthalten die regionalen OCR-Durchläufe und die erneute
Abdeckungsprüfung. Es sind drei Versuche pro Vorlage. Der Vergleich verwendet
denselben Render- und Abdeckungspfad mit ausgeschalteter regionaler Ergänzung.
Der ursprüngliche Text bleibt jeweils Präfix und die vorhandenen Zeilenrechtecke
bleiben gleich. Originalbytes, Quellenbindung und die lokale Layoutvalidierung
sind geprüft.

Im Konfliktfall bleibt „Beitrag 49,99 EUR“ erhalten. Das erneut gelesene „Beitrag
82,47 EUR“ wird abgewiesen. Der unabhängige Beginn wird ergänzt, und die Seite
bleibt prüfbedürftig. Tests prüfen zusätzlich nicht übereinstimmende Beobachtungen,
räumliche Überschneidungen, falsche Zielbereiche und mehrdeutige Kennungen. Die
vollständig erkannte Kontrolle erzeugt keinen zusätzlichen regionalen OCR-Versuch.

Eine Vorlage mit fünf markierten Feldern bestätigt das Vier-Bereiche-Budget.
Der erste Test erwartete vier Ergänzungen aus vier Versuchen, der tatsächliche
Lauf übernahm drei. Die Assertion prüft jetzt Versuchslimit, Übereinstimmung der
tatsächlich ergänzten Felder mit dem Zähler und den verbleibenden Prüfhinweis.
Die Annahmeschwellen wurden dafür nicht geändert.

Der echte Worker-/MCP-Test importierte die beiden positiven Vorlagen und den
Konfliktfall. Sechs Felder wurden ergänzt, drei bereits belegte Werte erhalten.
Die vollständigen Seiten melden `all-declared-pages-processed`, der Konfliktfall
`incomplete-or-unknown`. Neue Texte sind suchbar und mit Belegen auf Seite 1
lesbar. Unfreigegebene Dokumente, interne Prüfsummen und Geometrie sind durch
die bestehende Ausgabegrenze geschützt. Cacheabruf, ausdrückliche Frischerkennung,
unverändertes Test-Freigabeprofil und Widerruf sind geprüft.

Der zweite Wiretest bestätigt die bisherigen beiden Type-3-Vorlagen mit sechs
exakten Sollfeldern, Quellenbelegen, Cache, Frischerkennung und Widerruf.
[Maschinenlesbarer Prüfnachweis](quality/ocr-marked-region-recovery-2026-11-07.json).

Die folgenden Befehle liefen nacheinander in
`/private/tmp/vauldy-ocr-vector-wtr5pb1z`.

```sh
VAULDY_OCR_REGION_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/region-fixtures VAULDY_OCR_COVERAGE_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/coverage-fixtures VAULDY_OCR_VECTOR_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/vector-fixtures VAULDY_OCR_AB_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/raster-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'OCRMarkedRegionRecoveryTests|OCRBlockCoverageTests|OCRLayoutTests|PDFVectorTextOCRTests|OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalImportTests|LocalOriginalReferenceTests|BaseAnalysisMCPTests|LocalDocumentReviewTests|SQLiteIntegrationTests'
python3 scripts/mcp/visual_coverage_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp region-fixtures
python3 scripts/mcp/vector_ocr_quality_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp vector-fixtures
```

Die Fixture-Erzeugung und die neue Erwartung des bestehenden Wiretests sind im
Regressionsskript eingetragen. Der Nachweis umfasst den genannten gezielten Lauf
und beide Wiretests. Der globale Regressionslauf bleibt ein eigenes Releasegate.

Geändert wurden `OCRRegionRecovery.swift`, `OCRLineRecovery.swift`,
`NativeLocalDocumentOCR.swift`, `LocalOCRMetrics.swift` und `LocalOCRPageCache.swift`
unter `Sources/VauldyCore`, die Tests `OCRMarkedRegionRecoveryTests.swift`,
`OCRBlockCoverageTests.swift` und `PDFVectorTextOCRTests.swift`, die Skripte
`visual_coverage_smoke_test.py`, `vector_ocr_quality_smoke_test.py` und
`regression_test.py` sowie die zugehörigen Dokumentations- und Prüfdateien.

## Grenzen

Die Konfliktprüfung verwendet räumliche Überschneidung und explizite Feldbezeichnungen.
Zusammengehörige Begriffe mit unterschiedlichen Beschriftungen benötigen weitere
Inhaltsprüfungen. Übereinstimmende Fehlablesungen beider Durchläufe bleiben ein
Qualitätsrisiko. Sehr helle, bereits leer klassifizierte Seiten und Unterschiede
innerhalb geometrisch vollständig abgedeckter Zeilen bleiben eigene Arbeitsschritte.
