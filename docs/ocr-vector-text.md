# OCR · Übersehener Text aus Type-3-Schriften

Eine PDF kann eine lesbare eingebettete Kopfzeile und weitere sichtbare Inhalte
in Type-3-Schriftzeichen enthalten. Type-3-Zeichen sind PDF-Inhaltsströme und
können vollständige Textzeilen als Vektorumrisse zeichnen. Die von PDFKit
extrahierte Zeichenfolge bildet diese Inhalte nicht immer ab. Der bisherige
Schnellpfad konnte dann die Kopfzeile übernehmen und die Seite als erfasst melden.

Die lokale PDF-Inhaltsprüfung berücksichtigt jetzt die tatsächlich ausgewählten
Schriften des Seitenstroms. Eine ausgewählte Type-3-Schrift löst die bestehende
Erkennung der sichtbaren ganzen Seite mit Apple Vision aus. Die Schriftressourcen
eingebetteter PDF-Formulare werden dabei ebenfalls geprüft. Ein unbenutzter
Type-3-Eintrag im Ressourcenverzeichnis löst keine zusätzliche OCR aus.
Der Wechsel gilt auch für korrekt zugeordnete Type-3-Zeichen und verursacht dort
zusätzliche lokale OCR-Arbeit. Die Entscheidung basiert auf dem verwendeten
Schrifttyp. Eine allgemeine visuelle Abdeckungsprüfung bleibt der nächste Ausbau.

Die Cachekonfiguration v7 schließt frühere Kopfzeilen-Checkpoints aus. Bereits
abgeschlossene Importe können ausdrücklich mit „Text erneut lesen“ aktualisiert
werden. Das gespeicherte Datenformat benötigt dafür keine Migration.

## Prüfung vom 7. November 2026

Geprüft wurde der Arbeitsstand von
`codex/local-first-product-readiness` auf Basis von `87ab76c`.
141 Build- und Testdateien wurden zwischen Arbeitsbaum und isolierter Buildkopie
byteweise verglichen. Die 42 gezielten Swift-Tests in sechs Suites bestanden in
9,624 Sekunden. Darin enthalten sind die acht strikten nativen Rasterfälle aus
verschiedenen Dokumentdomänen, die vorherige Rasterkorrektur, Import und Originalzugriff.

| Synthetische Vorlage | Bisheriger Pfad | Neuer Pfad | Direkte neue Seitenerkennung |
| --- | --- | --- | --- |
| Versicherungsfelder in Type-3-Vektorumrissen | 0/3 exakte Körperfelder | 3/3 | 118 ms |
| Rechnungsfelder in Type-3-Vektorumrissen | 0/3 exakte Körperfelder | 3/3 | 130 ms |

Die Kopfzeile blieb in beiden Fällen erhalten. Der Vergleichspfad übernahm jeweils
die eingebettete Kopfzeile und meldete die Seite ohne Prüfhinweis als erfasst.
Weitere Tests bestätigen Type-3-Schriften in Formularressourcen, den schnellen
eingebetteten Textpfad trotz unbenutzter Type-3-Ressource, das Verwerfen eines
v6-Checkpoints und die Wiederverwendung eines neuen erfolgreichen OCR-Ergebnisses.
Die Millisekundenwerte beziehen sich auf den direkten nativen OCR-Aufruf, einschließlich
Rendern und Inspektion. Sie enthalten keinen CLI-, Workerstart- oder ChatGPT-Ablauf.

Der separate Wiretest importierte beide synthetischen PDFs über den echten Worker.
Alle sechs Felder wurden gespeichert. Nur das ausdrücklich freigegebene Dokument
erschien in der MCP-Suche und -Lesung, mit Quellenbelegen auf Seite 1 und ohne
interne IDs oder lokale Pfade. Lesen änderte den Bestand nicht. Cacheabruf,
ausdrückliche frische OCR, unverändertes Freigabeprofil und Widerruf wurden geprüft.
Die neue Prüfung ist im Regressionsskript eingetragen.

Der erste Swift-Lauf brach beim Erzeugen der neuen Fixture mit Signal 5 ab.
Nach Ergänzung quadratischer Glyphenpfade bestand der wiederholte Lauf. Der erste
Wire-Aufruf wurde wegen eines relativen Fixture-Pfads von der CLI abgewiesen.
Das Testskript löst diesen Pfad jetzt absolut auf. Der erneute Wiretest bestand.
[Maschinenlesbarer Prüfnachweis](quality/ocr-vector-text-2026-11-07.json).

Diese Befehle liefen in `/private/tmp/vauldy-ocr-vector-wtr5pb1z`.

```sh
VAULDY_OCR_VECTOR_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/vector-fixtures VAULDY_OCR_AB_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/raster-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'PDFVectorTextOCRTests|OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalImportTests|LocalOriginalReferenceTests|BaseAnalysisMCPTests'
python3 scripts/mcp/vector_ocr_quality_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp vector-fixtures
```

Geändert wurden `Sources/VauldyCore/PDFContentInspection.swift`,
`Sources/VauldyCore/LocalOCRPageCache.swift`,
`Tests/VauldyMCPRuntimeTests/PDFVectorTextOCRTests.swift`,
`scripts/mcp/vector_ocr_quality_smoke_test.py`, `scripts/mcp/regression_test.py`
und die zugehörigen Dokumentations- und Prüfdateien.

## Grenzen und nächster Schritt

Dieser Schritt behandelt sichtbaren Text in ausgewählten Type-3-Schriften.
Frei gezeichnete Vektorpfade ohne Schriftressource, übersehene Bereiche in
Rasterbildern und plausibel falsche Unicode-Zuordnungen anderer Schrifttypen
bleiben offen. Quellengebundene Zeilenkoordinaten sind in der
[Folgeiteration umgesetzt](ocr-line-layout.md). Auch Textblöcke und der
[visuelle Abdeckungsvergleich](ocr-block-coverage.md) und das
[gezielte Nachlesen auffälliger Regionen](ocr-marked-region-recovery.md) sind umgesetzt.
