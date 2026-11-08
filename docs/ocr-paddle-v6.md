# PaddleOCR PP-OCRv6 medium: deutscher Korpusvergleich

Stand 08.11.2026, Branch `codex/local-first-product-readiness`, Ausgangscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6` mit vorher vorhandenen lokalen Änderungen.
**Rohgewinn nachgewiesen: beste Variante 54/79 gegenüber Apple Vision 52/79.**
Unter dem unveränderten bestehenden Belegschutz bleiben **52/79**. Das kombinierte
Qualitätsgate für einen belegschützenden Austausch liefert **Exitcode 1 / NO-GO**.
PaddleOCR wurde ausschließlich in der isolierten Testumgebung ausgeführt.

## Modell und deutsche Sprache

Installierte, tatsächlich verwendete Versionen: `paddleocr==3.7.0`,
`paddlepaddle==3.3.1`, `paddlex==3.7.2`, Python 3.12.6. Die vollständigen
[aufgelösten Abhängigkeiten](quality/ppocr6-requirements-2026-11-08.txt) sind gespeichert.
Virtuelle Umgebung: `/private/tmp/vauldy-ppocr6-qq4oj5su/venv`; keine globale Python-/Vauldy-Installation.

Die offizielle Sprachzuordnung von `de` und `PP-OCRv6` wurde im installierten Paket
abgefragt und auf genau `PP-OCRv6_medium_det` / `PP-OCRv6_medium_rec` geprüft. PP-OCRv6
verwendet hier ein gemeinsames mehrsprachiges Erkennungsmodell; es gibt kein separates
`deu`-Gewicht wie bei Tesseract. Danach wurden ausschließlich diese expliziten lokalen
Modelldateien geladen. Ein automatischer Rückfall auf andere Modellfamilien war ausgeschlossen.

- [Offizielles Detektionsmodell](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_det/tree/8e0f56fb2ef86b461d99cfc7ac5c137738985f61):
  Gewichte SHA-256 `85218d2e3d98f5a21c58b4220627be923a97aee5db3cc71f39536ab31ac53960`.
- [Offizielles Erkennungsmodell](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec/tree/e5a92bcbc5cc1b494628e458d267778f0704fd7c):
  Gewichte SHA-256 `1b01c79a914587933f615569e75de54f2e638ebb5d3f3b3c1b38c24ede8c7319`.
- Sämtliche acht Konfigurations-, Graph-, Gewichts- und README-Dateien wurden gegen die
  veröffentlichten Git-Blob-/LFS-Prüfsummen der gepinnten Revisionen geprüft. Provenienz
  und Dateigrößen stehen im JSON-Nachweis. Modelle liegen unter `/private/tmp/vauldy-ppocr6-qq4oj5su/models`.

Die Inferenz lief seriell auf CPU mit zwei Threads, ohne MKL-DNN, Seitenentzerrung,
Orientierungs- oder zusätzliche heruntergeladene Hilfsmodelle. Detektorgrenzen blieben
bei den dokumentierten Standardwerten 0,3 / 0,6, Erkennungsfilter 0,0; Konfidenzwerte
wurden unverändert aufgezeichnet. Das macOS-Prozessprofil verbietet Netzwerk sowie
Lesen und Schreiben im Benutzerordner. Caches liegen im eigenen Testordner; `HOME`
wurde nicht umgebogen. Paket-/Modelldownloads erfolgten vor der Inferenz. Der Mac als
Ganzes war nicht netzgetrennt.

## Identischer Korpus und tatsächliche Ergebnisse

35 Original-PNGs und 79 vollständige Literal-Sollfelder aus dem bereits eingefrorenen
Manifest. Eingabebilder und bisherige Apple-Belegdateien blieben per SHA-256 unverändert.
Apple Vision wurde neu cachefrei ausgeführt: **52/79**, drei Tests in einer Suite
bestanden (12.657 s). Es wurden keine erwarteten Wörter,
Kennungen oder Sollwerte an PaddleOCR übergeben.

Jede der drei festen Varianten wurde auf alle 35 Bilder angewandt, insgesamt **105
PaddleOCR-Seitenaufrufe**. Keine Auswahl der besten Variante je Dokument anhand der Wahrheit.
`original` liest die unveränderten PNGs. `scale3` erzeugt getrennte pixelgetreue
Vergrößerungen. `contrast3` ergänzt eine feste pixelbasierte Kontrastspreizung am
leeren Bildrand. Originaldateien werden nie überschrieben; Testbilder sind auf vier
Millionen Pixel begrenzt. Ein hängender Seitenaufruf wird nach 90 Sekunden abgebrochen.

| Variante | Rohfelder | Zusätzlich korrekt | Alte korrekte Literal-Felder verfehlt | Mit Belegschutz | Seitenrückfälle | Unerwartete Zusätze danach |
|---|---:|---:|---:|---:|---:|---:|
| `original` | 49/79 | 1 | 4 | 52/79 | 5 | 0 |
| `scale3` | 54/79 | 3 | 1 | 52/79 | 3 | 0 |
| `contrast3` | 53/79 | 2 | 1 | 52/79 | 3 | 10 |

**Die zwölf besonders blassen/verrauschten Bilder bleiben bei allen drei Varianten
bei 0/24 vollständigen Sollfeldern.** Der Rohgewinn löst diese schwierigste Teilgruppe
also noch nicht. Er liegt bei kleinen geneigten Zeilen und der mehrdeutigen Kennung.

### Was konkret besser bzw. schlechter wird

Ausschließlich synthetische Beispiele aus dem unveränderten Korpus:

| Fall | Apple Vision | PaddleOCR `scale3` | Bedeutung |
|---|---|---|---|
| `ambiguous` | `Policennummer: 1000-171` | `Policennummer: IO0O-171` | Vollständiges Sollfeld getroffen; I/O/0-Verwechslungen bleiben im Produkt prüfbedürftig. |
| `tilted-9-right` | `Leistung: Zahnriemerwechsel am Aggregat` | `Leistung: Zahnriemenwechsel am Aggregat` | Ein Wortfehler wird korrekt gelesen; kann Suche und wörtliche Chatbelege verbessern. |
| `tilted-9-right` | `Beitrag: 82.47 EUR` | `Beitrag: 82,47 EUR` | Das Literal-Sollfeld stimmt; keine neue Preisangabe, sondern korrekte Zeichensetzung. |
| `dense` | `Beginn: 19.08.2027` | `Beginn:19.08.2027` | Ein Leerzeichen fehlt; der Datumswert ist vorhanden, das strikte Literalmaß zählt den Treffer nicht. |

Die beste Rohvariante hat damit drei neue vollständige Literal-Treffer und einen
Literal-Verlust, netto **+2**. Das sind keine drei neu entdeckten Vertragsfakten. Die
Metrik wurde trotz der Formatunterschiede nicht nachträglich gelockert. `contrast3`
liest das Datum mit Leerzeichen, erzeugt dafür unter anderem `Laistung:` statt `Leistung:`
in `italic-Helvetica-Oblique-11`; diese Variante erreicht insgesamt 53/79.

## Weshalb das Austauschgate trotzdem nicht besteht

`EvidencePreservingLocalOCR.preserving` schützt derzeit ganze bisherige Belegzeilen.
Ändert ein Kandidat eine solche Zeile, erhält der Seitenrückfall die vorherige Seite.
Das schützt auch gegen unbemerkte Zahlen-/Kennungsänderungen und wurde nicht gelockert.
Es verwirft damit ebenfalls die hier richtig erkannten Korrekturen früherer OCR-Fehler.

Der native Test führt **tatsächliche** Ausgaben jeder Variante durch diese vorhandene
Funktion und prüft alle 52 vorher korrekten Sollfelder, jede alte Zeile in Reihenfolge,
Originalbytes und Belegdateien. Rückfälle erhalten auch die bisherige Geometrie. Der
externe Textadapter bleibt unbestätigt, ohne erfundene native Konfidenz oder Geometrie,
und wird niemals in einen Bestand geschrieben. Alle Varianten bleiben so bei **52/79**.

Die Kontrastvariante enthält außerdem zehn unerwartete zusätzliche Zeilen, die der reine
Altbelegschutz nicht aussortiert. Das separate Qualitätsgate zählt sie als Fehler.
Mehr Text und hohe Modellkonfidenz sind keine Garantie für korrekte neue Aussagen.

**Entscheidung:** Rohqualität am Korpus verbessert; automatische belegschützende
Übernahme noch NO-GO. Kein produktiver Anbieterwechsel, Cacheversionswechsel oder
Nachlesen der neun realen Dokumente. Alle 108 produktiven Swift-Quellen, bestehende
Belege, Freigaben, ChatGPT-Kopplung und installierte Version blieben unverändert.

## Ausgeführte Prüfungen

- Abschließende native Prüfung: **13 Tests / 4 Suites bestanden,
  15.658 s**. Enthalten sind tatsächliche PaddleOCR-Ausgaben, Belegschutz,
  fester Korpus, native Wiederholung und Cachegrenzen.
- Rückwärtskompatibilität mit den gespeicherten tatsächlichen Tesseract-Ausgaben:
  **1 Test / 1 Suite neu bestanden**, 1.495 s.
  Dies ist keine neue Tesseract-Inferenzmessung.
- Vier Python-Tests bestanden: Source-Koordinaten bei Skalierung, ungültige Beobachtungen,
  virtuelle Umgebung/Cacheisolation und bytegleiche Originale bei Vergrößerung.
- Echter lokaler Worker-/MCP-Zeilentest bestanden: sechs native Sollfelder, fünf
  geschützte Auszüge, frisches Nachlesen, unveränderte Freigaben/Originale, lokale
  Diagnose und drei Widerrufe.
- Syntaxprüfung und bytegleiche Buildkopie bestanden. Das Qualitätsgate wurde separat
  tatsächlich ausgeführt: **Exitcode 1 / NO-GO**. Keine vollständige Paket-/UI-/Relay-
  oder Kunden-Mac-Abnahme in dieser Iteration.

Ein früher API-Probestarter hatte einen fehlenden `self`-Parameter; ein erster
Controller-Test erwartete einen nichtkanonischen `/var`-Pfad. Beide Fehler wurden
korrigiert und die Prüfungen neu ausgeführt; sie zählen nicht als bestandene OCR-Läufe.

## Performance und Ressourcen

Hardware: **Apple M1 Pro, 16 GiB RAM**, CPU-Inferenz mit zwei Threads. Peak-RSS des
Paddle-Prozesses: **4.272 GiB**. Die drei vollständigen
Varianten einschließlich Start/Vorbereitung benötigten als Prozess insgesamt
936.891 s.

| Variante | Summe 35 Inferenzaufrufe | Median pro Bild | P95 pro Bild |
|---|---:|---:|---:|
| `original` | 64.454 s | 1.984 s | 2.519 s |
| `scale3` | 431.135 s | 12.324 s | 13.230 s |
| `contrast3` | 433.792 s | 12.467 s | 13.038 s |

Die Modelleinrichtung wurde separat mit 2.720 s
aufgezeichnet; Python-Importe gehören nicht zu diesem Wert. Apple meldete für seine
35 cachefreien Seiten 7.407 s, Median
0.200 s, P95 0.414 s.
Die Engines nutzen unterschiedliche Beschleunigung und Messgrenzen. Das ist keine
Chatlatenz oder universelle Importdurchsatzzusage. Eine pauschale dreifache Vergrößerung
wird aus diesem Aufwand nicht als Produktstandard abgeleitet.

## Reproduzieren und Dateien

Ausgeführt in der gegen den Workspace bytegeprüften Buildkopie
`/private/tmp/vauldy-ocr-vector-wtr5pb1z`:

```sh
VAULDY_OCR_FAINT_FIXTURES=/private/tmp/vauldy-ppocr6-qq4oj5su/apple-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter OCRFaintRasterTests
python3 scripts/mcp/paddle_ocr_comparison.py run --root /private/tmp/vauldy-ppocr6-qq4oj5su --fixtures /private/tmp/vauldy-ppocr6-qq4oj5su/apple-fixtures --output /private/tmp/vauldy-ppocr6-qq4oj5su/final --python /private/tmp/vauldy-ppocr6-qq4oj5su/venv/bin/python
VAULDY_OCR_ALTERNATIVE_RUN=/private/tmp/vauldy-ppocr6-qq4oj5su/final swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'LocalOCRAlternativeComparisonTests|EvidencePreservingOCRTests|OCRFaintRasterTests|OCRTargetedRetryTests'
VAULDY_OCR_ALTERNATIVE_RUN=/private/tmp/vauldy-alt-ocr-zklrh9uc/final swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter LocalOCRAlternativeComparisonTests
python3 scripts/mcp/line_ocr_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp line-fixtures
/private/tmp/vauldy-ppocr6-qq4oj5su/venv/bin/python scripts/mcp/paddle_ocr_comparison_test.py
python3 -m py_compile scripts/mcp/paddle_ocr_comparison.py scripts/mcp/paddle_ocr_comparison_test.py
python3 scripts/mcp/paddle_ocr_comparison.py check /private/tmp/vauldy-ppocr6-qq4oj5su/final
```

Für eine Wiederholung neue aufgabeneigene Ausgabe-/Laufverzeichnisse benutzen und die
gepinnten Modelle bereitstellen. Das Vergleichsskript lädt keine Modelle herunter.
Vollständige Kommandos, Modelle, Exitcodes, Zeiten, Prüfsummen und Fälle stehen im
[JSON-Nachweis](quality/ocr-paddle-v6-2026-11-08.json). Historische Testergebnisse sind
keine neue Abnahme. Kein Commit, Push, PR oder Installationspaket wurde erstellt.

Dateien dieser Iteration:

- Neu: `scripts/mcp/paddle_ocr_comparison.py`, isolierter Vergleich und separates Gate.
- Neu: `scripts/mcp/paddle_ocr_comparison_test.py`, vier Tests der Benchmarkgrenzen.
- Erweitert: `Tests/VauldyMCPRuntimeTests/LocalOCRAlternativeComparisonTests.swift`,
  explizite Engine-/Sprachzuordnung für PaddleOCR bei erhaltener Tesseract-Kompatibilität.
- Neu: diese Datei, JSON-Nachweis und `docs/quality/ppocr6-requirements-2026-11-08.txt`.
- Aktualisiert: `docs/local-first-todo.md` und Querverweis im früheren Tesseract-Bericht.

## Nächster sinnvoller Schritt

PaddleOCR als gezielte zweite Lesung weiter untersuchen. Korrekturen müssen als
quellengebundene, versionierte Vorschläge neben den alten Belegen prüfbar sein. Alte
Zitatbelege dürfen nicht verschwinden; Zahlen-/Kennungskonflikte bleiben ausdrücklich
prüfbedürftig. Eine automatische Übernahme setzt diese Tests und unabhängige deutsche
Vorlagen voraus. Die zwölf extrem blassen Vorlagen sind ein eigener weiterhin offener
Qualitätspunkt. Keine Auswahl oder Korrektur anhand der Korpus-Sollwahrheit im Produkt.
