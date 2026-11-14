# OCR-Qualitätsprüfung · 10.11.2026

Geprüft wird der aktive lokale MCP auf `main`, Ausgangscommit `0630053`.
Der Auftrag ist eine Qualitätsprüfung, keine Änderung des Erkenners. Die vorhandene
fremde Whitespace-Änderung in `faint-line-corpus.json` bleibt erhalten.
248 Source-, Test-, Skript- und Paketdateien wurden vor dem Build bytegleich in eine
isolierte Kopie übernommen; alle sieben Abhängigkeiten entsprechen ihren Pins.
Während des Laufs kamen fremde Änderungen an Setup, Relay-Verwaltung und
`MCPInventoryQuality` hinzu. Diese sind nicht Bestandteil der getesteten Kopie;
der OCR-Kern blieb identisch. Keine Abnahme dieser parallelen Verwaltungsänderungen.

**Ergebnis: technische Regression bestanden; umfassende OCR-Qualitätsabnahme
nicht erreicht.** Der native Weg bleibt als Such- und Lesehilfe nutzbar. Die
vorliegenden Messungen rechtfertigen keine automatische Bestätigung vollständig
richtiger Dokumentinhalte.

## Bewertungsmaßstab

Technisch erfolgreiche Verarbeitung, vollständige Texterfassung und richtige
Feldwerte sind verschiedene Anforderungen. Für eine belastbare automatische
Dokumentauswertung müssen kritische Angaben wörtlich stimmen, fehlende oder
widersprüchliche Inhalte erkennbar bleiben und Tabellenwerte der richtigen Zeile
und Spalte zugeordnet werden. Ein erfolgreicher Regressionstest oder hohe native
Konfidenz allein erfüllt diese Anforderungen nicht.

## Befunde nach Priorität

1. **Hohe Priorität: schwierige Rastertexte bleiben unzureichend erkannt.**
   Der eingefrorene Korpus umfasst 35 Bilder und 79 vollständige Sollfelder.
   Der neue native Lauf bestätigt 52/79; insbesondere zwölf sehr blasse,
   kleine und verrauschte Bilder liefern 0/24 Sollfelder. Die produktive
   Zeilennachlese benötigt zunächst erkannte Zeilen. Nicht erkannte bzw. nur
   fragmentarisch erkannte Schrift liefert ihr häufig keinen ausreichenden Ansatz.
   Die zusätzliche Faint-Raster-Erweiterung liegt ausschließlich im Testziel.
   Quellen: `NativeLocalDocumentOCR.recognizeImage`, `OCRFaintRasterTests`,
   [bisherige Korpusabnahme](ocr-faint-raster.md).

2. **Hohe Priorität: fehlender Prüfhinweis bestätigt keine Richtigkeit.**
   Die Zeilenentscheidung verwendet Konfidenz, bestimmte Kennungsmuster und
   Zweitlesungen. Die visuelle Abdeckung vergleicht Rechtecke, nicht Zeicheninhalte.
   Ein geometrisch abgedeckter, selbstbewusst falsch gelesener Wert kann daher
   unmarkiert bleiben. Der erneut gemessene feste Fall `tilted-9-right` enthält nur
   1/3 richtige Sollfelder bei `needsReview=false` und nativer Konfidenz **1,0**.
   Eine zuverlässige automatische
   Freigabe darf nicht allein auf diesem Flag beruhen.
   Quellen: `NativeLocalDocumentOCR.recognizeImage`,
   `LocalOCRVisualCoverage.compare`, [Zeilenprüfung](ocr-consistent-lines.md).

3. **Hohe Priorität bei Tabellen: Zuordnung nicht abgenommen.**
   Der native Pfad speichert Text, Zeilen und Textblöcke, aber kein belegtes
   Tabellenraster. Der historische deutsche Mehrseitenvergleich vom 08.11.2026
   erreicht 132/133 Label-Wert-Stellen und 311/345 Tabelleninhalte als Text;
   eine korrekte Zellposition wurde für Apple nicht ausgegeben. Seine
   Zeichenfehlerrate von 10,20 % enthält auch Lesereihenfolgefehler und ist keine
   isolierte Zeichenverwechslungsquote. Dieser Vergleich wurde in dieser Prüfung
   nicht erneut ausgeführt. Quelle: [V2-Vergleich](german-document-comparison-v2.md).

4. **Mittlere Priorität: frische Nachlese ist kein Korrekturworkflow.**
   `LocalImportWorker` umgeht bei `fresh` den Cache, schaltet aber bei vorhandenem
   Text `EvidencePreservingLocalOCR` davor. Sobald eine frühere Zeile nicht mehr
   wortgleich und in derselben Reihenfolge vorkommt, bleibt die gesamte alte Seite
   erhalten und wird prüfbedürftig. Das schützt Belege, hält jedoch auch alte
   OCR-Fehler fest und kann neue richtige Ergänzungen derselben Seite verwerfen.
   Es fehlt ein gesonderter, nachvollziehbarer Entscheidungsweg für abweichende
   Kandidaten. Den bestehenden Belegschutz dafür nicht pauschal entfernen.

## Neu ausgeführte Prüfungen

| Prüfung | Ergebnis | Aussage |
|---|---|---|
| Swift Release, native OCR, Import und Originalverweise | 93 Tests / 21 Suites, 125,511 s, bestanden laut Testzusammenfassung | Funktions- und Regressionsnachweis |
| Optionaler externer OCR-Anbietervergleich | Ein Test ausdrücklich übersprungen | Kein neuer Anbieter-/Modellvergleich |
| Rastervergleich mit neun Vorlagen | 35/36 Sollfelder exakt | Die mehrdeutige Kennung bleibt falsch und markiert; kein pauschaler 100-%-Nachweis |
| Eingefrorener schwieriger Korpus | 52/79, einschließlich 0/24 in zwölf extremen Vorlagen | Bekannte Erkennungsgrenze aktuell reproduziert |
| Unmarkierte fehlerhafte Fälle im schwierigen Korpus | 1 von 35 Bildern; dort 2 von 3 Sollfeldern falsch | Review-Flag ist kein Richtigkeitszertifikat |
| Separates Faint-Qualitätsgate | NO-GO, Exitcode 1; 52 → 52, kein Gewinn | Testkandidat bleibt deaktiviert; Belege erhalten |
| Python-Tests des Qualitätsgates | 5 bestanden | Gate-Logik geprüft, keine OCR-Qualitätsverbesserung |
| Echte Raster-PDF-Worker-/stdio-Prüfung | 3 PDFs, 12/12 gespeicherte Sollfelder, bestanden | Seitenbeleg, Privacy, Freigabe, Cache, frische Nachlese und Widerruf |
| Echte Zeilenbild-Worker-/stdio-Prüfung | 3 Bilder, 6/6 native Felder, 5 geschützte Auszüge, bestanden | Mehrdeutige Kennung bleibt markiert; Gründe persistiert; Original/Freigabe unverändert; drei Widerrufe |

[Maschinenlesbarer Nachweis](quality/ocr-path-audit-2026-11-10.json),
[nativer Testlauf](quality/ocr-path-audit-2026-11-10/swift-native-clean.log),
[aktuelle 35 Einzelfälle](quality/ocr-path-audit-2026-11-10/current-corpus.json).

Der Build dauerte 120,69 s. Der erste Buildversuch scheiterte am gesperrten
Standard-Modulcache, der zweite am absoluten Pfad kopierter Compilerartefakte.
Erst nach Entfernen ausschließlich der eigenen kopierten Buildprodukte erfolgte
der saubere native Build und Testlauf. Diese Fehlversuche zählen nicht als
OCR-Erkennungsfehler oder bestandene Prüfungen. Es ist kein vollständiger
Release-/Installerregressionslauf und kein neuer Performancebenchmark.

Ausführung in `/private/tmp/vauldy-ocr-audit-20261110/source`:

```sh
VAULDY_OCR_AB_FIXTURES=/private/tmp/vauldy-ocr-audit-20261110/raster \
VAULDY_OCR_FAINT_FIXTURES=/private/tmp/vauldy-ocr-audit-20261110/faint \
VAULDY_OCR_LINE_FIXTURES=/private/tmp/vauldy-ocr-audit-20261110/lines \
CLANG_MODULE_CACHE_PATH=/private/tmp/vauldy-ocr-audit-20261110/module-cache \
swift test --build-system native -c release --disable-sandbox \
  --disable-automatic-resolution \
  --cache-path /private/tmp/vauldy-ocr-audit-20261110/cache --jobs 4 \
  -debug-info-format none -Xswiftc -parse-as-library --no-parallel \
  --filter 'OCR|LocalImportTests|LocalOriginalReferenceTests|LocalImportWorkerTests'

python3 scripts/mcp/faint_ocr_quality_gate.py \
  /private/tmp/vauldy-ocr-audit-20261110/faint \
  --report /private/tmp/vauldy-ocr-audit-20261110/faint-gate.json
python3 scripts/mcp/faint_ocr_quality_gate_test.py
python3 scripts/mcp/raster_ocr_quality_smoke_test.py \
  .build/release/vauldy-local .build/release/vauldy-mcp \
  /private/tmp/vauldy-ocr-audit-20261110/raster
python3 scripts/mcp/line_ocr_smoke_test.py \
  .build/release/vauldy-local .build/release/vauldy-mcp \
  /private/tmp/vauldy-ocr-audit-20261110/lines
```

## Nächste Qualitätsabnahme

- Feste schwierige Bilder und Sollwerte beibehalten; vollständige Felder,
  verlorene zuvor richtige Felder und unmarkierte Fehler getrennt messen.
- Das bestehende Verbesserungs-Gate verlangt mindestens 53/79 ohne Verlust
  alter Belege oder unerwartete Zusätze. Das ist nur ein Fortschrittsnachweis,
  noch keine ausreichende Gesamtprodukt-Abnahme.
- Kritische Kennungen, Beträge und Daten sowie mehrspaltige Tabellen und
  Lesereihenfolge mit unabhängig annotierten, zurückgehaltenen Fällen prüfen.
- Einen beleggebundenen Vergleich neuer und gespeicherter Lesungen vorsehen,
  damit richtige Korrekturen nach ausdrücklicher Entscheidung übernommen werden
  können. Originale und bisherige Evidenz erhalten.

Es wurden keine produktiven Archive neu gelesen, keine Freigaben verändert und
keine Modelle installiert oder Anbieter gewechselt. Ein allgemeines Qualitätsziel
für reale Kundenarchive ist durch synthetische Korpora nicht nachgewiesen.
