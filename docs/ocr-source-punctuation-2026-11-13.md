# OCR Quellenprüfung für die verbleibenden Bildfehler

Der Auftrag ist **teilweise erfüllt**: Das Dezimalkomma im unveränderten Bild
`tilted-9-right.png` wird jetzt korrekt als `Beitrag: 82,47 EUR` gelesen. Im
vollständigen Bilderlauf steigt das Ergebnis von **53/79 auf 54/79 Felder**.
Die anderen 34 Bildtexte bleiben identisch. Die Policennummer und die 24 blassen
Textzeilen sind weiterhin offen; für sie wurde keine belastbare Korrektur gefunden.

## Verifizierbarer Korrekturpfad

Die Messung am Original zeigte, dass unverzerrte Ausschnitte die kleine Kommaform
besser erhalten als die vorherige Entzerrung beziehungsweise Kontrastbehandlung.
Der neue Pfad liest begrenzte Ausschnitte kleiner, beschrifteter Geldbeträge in
zwei Größen ohne Entzerrung oder Kontraständerung nach. Beide nativen Lesungen
müssen exakt übereinstimmen und mindestens 0,95 Konfidenz erreichen. Die Annahme
ist auf den Austausch genau eines Dezimalzeichens zwischen unveränderten Ziffern
begrenzt. Beschriftung, Vorzeichen, Leerzeichen und Währung müssen identisch bleiben.
Gruppierungen, Datumswerte und Kennungen sind ausgeschlossen.

Dies ist keine sprachabhängige Ersetzung von Punkten durch Kommas. Die bisherigen
Formatregeln bleiben unverändert. Ein eigener optionaler lokaler Beleg
`sourceRepair: decimalSeparator` erlaubt dem Belegschutz die Übernahme der
bestätigten Zeichenkorrektur. Ohne diesen Beleg, ohne passende frühere Lesung,
bei zu niedriger Konfidenz, veränderter Ziffer oder unpassender Quellgeometrie wird
weiterhin der vorige Text erhalten. Spätere unveränderte Nachlesungen behalten die
Historie. Beleg und Historie werden nicht an MCP-Clients ausgegeben.

Die Cachekennung lautet `ocr-v18-source-punctuation-`. Die Grenze von acht
Nachlesepaaren und acht Millionen zusätzlichen Pixeln je physischer Seite bleibt
unverändert. Weder Solltexte noch Dateinamen oder Korpuskennungen gehen in die
Produktentscheidung ein.

## Noch offene 25 Feldvorkommen

| Anzahl | Solltext | Aktuelle Ausgabe |
|---:|---|---|
| 1 | `Policennummer: IO0O-171` | `Policennummer: 1000-171` |
| 12 | `Schutz fuer Fahrrad und Hausrat` | fehlt |
| 12 | `Leistung: Wartung der Heizungsanlage` | fehlt |

Die 24 Textzeilen verteilen sich auf die zwölf bisherigen Varianten aus den
Schriftgrößen 9/11/13, Grauanteilen 0,88/0,93 und Rauschstärken 15/25.
[Originalausschnitte und vollständige Bilder](quality/ocr-numeric-2026-11-13/remaining-image-examples/index.html)
bleiben verfügbar; die dort aufgeführte Kommazeile gehört inzwischen zu den
behobenen Fällen.

Die Diagnose umfasst 288 native Leseansichten repräsentativer Originalausschnitte:
Skalierung, Kontrast, Schwellenwerte, begrenzte Glättung, Patch-Entrauschung,
veränderte Zeichenabstände, isolierte Zeichen, überlappende Zeichengruppen und
Wortbereiche, mit und ohne Sprachkorrektur sowie mit dem schnellen nativen Modus.
Einige Einzelzeichen werden besser gelesen, die vollständige Policennummer aber
nicht stabil korrekt. Bei den blassen Zeilen entstehen auch bei nativer Konfidenz
1 falsche Wörter, zum Beispiel `Schutz fuer Fahned uni Haustal`. Diese Versuche
werden deshalb nicht in den Produktpfad übernommen.

Zusätzlich wurden 20 Ansichten mit dem bereits installierten Tesseract und dessen
vorhandenem englischen Modell diagnostisch geprüft. Auch damit entstand keine
verlässliche vollständige Korrektur. Es wurden keine Modelle heruntergeladen und
kein Produktanbieter umgeschaltet. Die Ergebnisse belegen die Grenze der hier
geprüften Verfahren, nicht eine grundsätzliche Unlesbarkeit der Originale.

## Abschlussnachweis

Die unveränderten 15 PDFs mit 31 Seiten behalten **133/133 Dokumentfelder und
345/345 Tabelleninhalte**. Alle 31 PDF-Texte sind wortgleich zu v17. Bilder und
PDFs wurden gegen die bisherigen Originalhashes geprüft. Der Vergleich schützt
jedes bisher richtige Feld und wörtliche Belege einschließlich Häufigkeiten;
auch die frische Nachlese übernimmt sämtliche bisherigen und neuen Korrekturen.
Die 25 offenen Bildfelder bleiben als prüfbedürftig markiert.

Fünf absichtlich eingebrachte Fehler werden vom Qualitätsgate abgewiesen:
Verlust eines zuvor richtigen Felds, Rücknahme der Kommakorrektur, erfundener
Zusatztext, Verlust eines zuvor korrigierten PDF-Exponenten und veränderte
Originalbytes.

Zusätzliche neue Kontrollbilder in Schriftgröße 9 zeigten zunächst drei weitere
Erkennungsfehler bei `17,29`, `-39.51` und `1.234,56`. Ein direkter Lauf mit dem
unveränderten v17-Programm bestätigt exakt dieselben Fehler. Diese Kontrollen
zählen nicht zum eingefrorenen 79-Felder-Korpus und werden nicht als korrekt
ausgewiesen. Der Regressionstest schützt ihre bisherigen Lesungen und verlangt
zusätzlich exakte Ergebnisse für den bereits richtigen 9-Punkt-Dezimalpunkt
sowie alle vier 13-Punkt-Kontrollen. Die Originalbytes und v17-Lesungen dieser
acht zusätzlichen Fälle sind separat eingefroren. Kein Sollwert des bisherigen
Korpus wurde verändert.

Der endgültige native Lauf besteht mit **119 Tests in 27 Suites**, ein optionaler
Test für einen separat vorbereiteten Anbieter-Korpus wird übersprungen.
Sechs reale Integrationstests bestehen ebenfalls: Import mit dem tatsächlichen
v17- beziehungsweise v14-Programm und jeweils zweimalige frische Nachlese,
Raster-, Zeilen-, Import- und Originalverweisprüfung. Identität, Originalbytes,
Freigaben und frühere Lesungen bleiben erhalten. Die geschützte MCP-Ausgabe
enthält die korrigierte Lesung; interne Belege bleiben lokal, Widerruf greift.
201 Quell-, Paket-, Test- und Fixturedateien der isolierten Buildkopie wurden
bytegleich gegen den Arbeitsstand geprüft.

Der endgültige native Lauf und die Worker-Prüfungen sind in
[den Messwerten](quality/ocr-source-punctuation-2026-11-13/summary.json) dokumentiert.
Es erfolgt keine Produktivinstallation oder vollständige Release-Abnahme.

```sh
VAULDY_OCR_IMPROVED_FIXTURES=/tmp/ocr-source-images \
VAULDY_OCR_LINE_FIXTURES=/tmp/ocr-source-lines \
VAULDY_OCR_AB_FIXTURES=/tmp/ocr-source-raster \
swift test --build-system native -c release --disable-sandbox \
  --disable-automatic-resolution --jobs 4 -debug-info-format none \
  -Xswiftc -parse-as-library -Xswiftc -enable-testing --no-parallel \
  --filter 'OCR|LocalImportTests|LocalOriginalReferenceTests|LocalDocumentReviewTests|LocalDocumentQualityTests'
python3 scripts/mcp/ocr_source_punctuation_quality_gate.py IMAGES FROZEN_V2 PDF_RESULTS --report report.json
python3 scripts/mcp/ocr_source_punctuation_quality_gate_test.py IMAGES FROZEN_V2 PDF_RESULTS --report mutations.json
python3 scripts/mcp/ocr_repair_smoke_test.py V17_LOCAL NEW_LOCAL NEW_MCP IMAGES/tilted-9-right.png
```
