# OCR Korrekturen für Zahlentrennzeichen Kubikmeter und Formatierung

Die fünf verbliebenen Fehler bei Zahlentrennzeichen und `m³` sowie die 24
Formatabweichungen sind im unveränderten deutschen PDF-Korpus behoben.
**133/133 Dokumentfelder bleiben korrekt; die exakten Tabelleninhalte steigen
von 316/345 auf 345/345.** Keine zuvor richtige Angabe und kein korrektes
Wortvorkommen geht verloren. Alle 31 Seiten wurden auch gegen den v16-Bestand
mit dem Belegschutz einer frischen Nachlese geprüft; sämtliche Verbesserungen
werden übernommen.

| Stelle | Vorher | Jetzt |
|---|---|---|
| Versicherung, Seite 2, Bargeldgrenze | `1,500,00€` | `1.500,00 €` |
| Nebenkosten, Seite 2, Schlafzimmerdifferenz | `1.635.3` | `1.635,3` |
| Warmwasser, alter Stand | `86,240 m` | `86,240 m³` |
| Warmwasser, neuer Stand | `117,960 m3` | `117,960 m³` |
| Warmwasser, Differenz | `31,720 m` | `31,720 m³` |
| Geldbetrag ohne Zwischenraum | `45,00€` | `45,00 €` |
| Getrenntes Minuszeichen | `- 1.284,37 €` | `-1.284,37 €` |
| Falsch angeordnete Währung im Gebührenbescheid | `€ 2,50` | `2,50 €` |

Die Tabellenkennzahl zählt exakte Textvorkommen mit Wortgrenzen und Häufigkeiten,
keine vollständige Rekonstruktion beliebiger Tabellenstrukturen. Zusätzlich zur
Messmenge erhält der Bruttobetrag in der Werkstattrechnung seinen Zwischenraum.
Damit wurden 24 reine Leerzeichenkorrekturen und sechs neue Zeichenkorrekturen
vorgenommen; 29 davon betreffen die zuvor offenen Tabellenvorkommen. Die sieben
bereits behobenen Beispiele aus der vorherigen Iteration bleiben korrekt.

## Umsetzung

`OCRNumericRefinement` trennt verlustfreie Darstellung von tatsächlicher
Zeichenerkennung. Bei alleinstehenden Geldbeträgen werden lediglich die
Zwischenräume vereinheitlicht. Jede Ziffer, jedes Trennzeichen, das Vorzeichen
und die gelesene Seite des Eurozeichens bleiben identisch. Die ursprüngliche
native Konfidenz bleibt unverändert; eine unsichere Lesung wird dadurch nicht
als sicher ausgegeben. Frühere Schreibweisen bleiben lokal erhalten.

Ein Wechsel zwischen Punkt und Komma ist nur bei einer bereits ungültigen
Zahlenschreibweise zulässig, nach zwei übereinstimmenden nativen Nachlesungen
mit mindestens 0,95 Konfidenz. Ziffernfolge, Vorzeichen, Länge und Positionen der
Trennzeichen müssen erhalten bleiben. Gültige deutsche und englische
Zahlenschreibweisen werden nicht anhand einer angenommenen Sprache umgedeutet.
Auch eine andere Position des Eurozeichens braucht zwei entsprechende Lesungen
am Original; die Formatierung allein verschiebt es nicht.

`OCRMetreGlyphs` misst die getrennte hochgestellte Endziffer neben dem `m`.
Ihre Originalpixel werden vorübergehend auf Grundliniengröße gebracht, damit
Vision die Ziffer liest. Anschließend wird ausschließlich die gemessene
Hochstellung wiederhergestellt. Es wird keine `3` als Sollwert eingesetzt.
Die Zellnachlese behält den gedruckten Zeilenkontext und vergleicht zwei leicht
unterschiedliche Anordnungen. Die Quellmarkierung umfasst die ursprüngliche
Zelle einschließlich des ergänzten Exponenten.

Der Belegschutz akzeptiert reine Leerzeichenänderungen nur mit gleicher
Zeichenfolge, gleicher Konfidenz, lokaler Historie und passender Quellgeometrie.
Für tatsächliche Zeichenkorrekturen gilt weiterhin die Grenze von 0,95.
Arbeitsbudgets bleiben bei acht Nachlesepaaren und acht Millionen zusätzlichen
Rasterpixeln je physischer Seite. Die Cachekennung lautet
`ocr-v17-numeric-cell-evidence-`.

## Unveränderte Referenzen

Grundlage sind dieselben 15 PDFs mit 31 Seiten, 133 Dokumentfeldern, 345
nichtleeren Tabellenzellen und drei Leerbildkontrollen. PDF- und Bilddateien
wurden anhand des bisherigen Manifests verifiziert:
`e8d6d5a7bb874081381eacdd541b686acb0643d1249bd36cc4785fb5ace947c0`.
Kein Sollwert, keine Originaldatei und keine Toleranz des Vergleichs wurde geändert.
Vier weitere bestehende PDFs wurden bytegleich ins Swift-Testbundle aufgenommen;
zusammen mit drei bisherigen Dateien prüfen sie die neuen und früheren Fehlerarten.

Zehn PDF-Seitentexte enthalten die neuen Korrekturen, 21 bleiben wortgleich.
Die Zahl der Prüfseiten steigt von 13 auf 14. Frühere fehlerhafte Lesungen bleiben
lokal nachvollziehbar und zählen nicht als aktuelle korrekte Felder. Die drei
Leerbildkontrollen enthalten weiterhin keinen erfundenen Text.

Das neue Qualitätsgate verlangt 345/345 Tabelleninhalte, den Erhalt aller
vorherigen Felder, Tabelleninhalte, korrekten Wortvorkommen und wörtlichen Belege.
Absichtlich eingebrachte Fehler an einem zuvor richtigen Feld, am Trennzeichen,
am Exponenten und an der Euroformatierung werden vom Gate abgewiesen.

## Abschlussprüfung

Der native Abschlusslauf besteht mit 117 Tests in 26 Suites. Der bereits zuvor
optionale Test für einen separat vorbereiteten Anbieter-Korpus wird übersprungen.
Die neuen Tests prüfen sieben unveränderte PDFs mit 18 Seiten, wiederholte frische
Nachlese, unveränderte Dateibytes und den Erhalt früherer Belege. Gegenproben
verhindern Änderungen an gültigen deutschen/englischen Zahlen, Ziffern, Vorzeichen
und bereits korrekt gelesenen Einheiten. Gedruckte `m²` und `m³` werden im gleichen
Zeilenkontext wie im Produkt gelesen; normale Grundlinienziffern werden nicht
hochgestellt. Ein erster Testlauf zeigte für einen isolierten Zahlenbeschnitt zu
wenig native Konfidenz. Der Test verwendet nun den tatsächlichen Zeilenkontext;
Produktcode, Konfidenzgrenze und eingefrorene PDF-Referenzen bleiben dabei gleich.

Im separaten 35-Bilder-Korpus bleiben **53/79 Felder** korrekt, wie unter v16.
Alle 35 Texte sind unverändert, sämtliche Originalhashes stimmen. Die übrigen
26 schwierigen Bildfelder sind durch diese gezielte PDF-Korrektur nicht behoben.
Das ältere Vergleichsgate weist zusätzlich den erhaltenen Gewinn gegenüber v14
aus; dieser ist kein neuer Gewinn dieser Iteration.

Der echte Import-Worker importiert die sieben PDFs zunächst mit v16 und liest
sie anschließend zweimal frisch mit v17. Alle früheren und neuen Korrekturen,
Originalidentitäten, Freigaben und lokale Historien bleiben erhalten. Die
persistierten Ergebnisse überstehen den Neustart; MCP gibt ausschließlich den
geschützten aktuellen Text aus. Der Widerruf wird weiterhin durchgesetzt.
Die bestehenden Raster-, Zeilen-, Import-, Originalverweis- und früheren
Wortkorrektur-Wiretests bestehen ebenfalls mit den neuen Binaries. 195 Quell-
und Testdateien der isolierten Buildkopie wurden gegen den Arbeitsstand geprüft.

## Reproduktion

```sh
VAULDY_OCR_IMPROVED_FIXTURES=/tmp/ocr-numeric-faint \
VAULDY_OCR_LINE_FIXTURES=/tmp/ocr-numeric-lines \
VAULDY_OCR_AB_FIXTURES=/tmp/ocr-numeric-raster \
swift test --build-system native -c release --disable-sandbox \
  --disable-automatic-resolution --jobs 4 -debug-info-format none \
  -Xswiftc -parse-as-library -Xswiftc -enable-testing --no-parallel \
  --filter 'OCR|LocalImportTests|LocalOriginalReferenceTests|LocalDocumentReviewTests|LocalDocumentQualityTests'
python3 scripts/mcp/ocr_numeric_quality_gate.py FROZEN_V2 APPLE_RESULTS --report report.json
python3 scripts/mcp/ocr_numeric_recovery_smoke_test.py V16_LOCAL NEW_LOCAL NEW_MCP
```

Der vollständige PDF-Probe mit v16-Vergleich und frischer Nachlese ist zusammen
mit den [Messwerten und Protokollen](quality/ocr-numeric-2026-11-13/) abgelegt.
Die Änderungen sind ein geprüfter Entwicklungsstand; eine Produktivinstallation
oder vollständige Release-Abnahme gehört nicht zu dieser Iteration.
