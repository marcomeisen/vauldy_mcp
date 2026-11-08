# Deutsche lokale OCR: Tesseract gegen Apple Vision

Stand 08.11.2026, MCP-Branch `codex/local-first-product-readiness`, Ausgangscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6`. **Vergleich abgeschlossen, Qualitätsgate NO-GO.**
Apple Vision erreicht erneut **52/79** vollständige wörtliche Sollfelder, Tesseract
mit deutschem Modell in den acht getesteten Varianten höchstens **39/79**. Der vorhandene
Belegschutz erhält **52/79**, liefert aber keinen abgesicherten zusätzlichen Gewinn.
Ein produktiver Austausch oder Fallback wurde nicht aktiviert.

## Reproduzierbare Voraussetzungen

- Installiertes Tesseract **5.5.4**, LSTM-Pfad `--oem 1`, explizit Sprache **`deu`**.
  Das vorinstallierte englische Modell wurde für die Vergleichsläufe nicht verwendet.
- Offizielles [deutsches Modell aus tessdata_best](https://github.com/tesseract-ocr/tessdata_best/blob/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/deu.traineddata),
  Commit `e12c65a915945e4c28e237a9b52bc4a8f39a0cec`, 8.628.461 Bytes,
  SHA-256 `8407331d6aa0229dc927685c01a7938fc5a641d1a9524f74838cdac599f0d06e`.
  Download gegen den Git-Blob `6dd654880db617f3edfa00bc2ed9c9e3107b8fd0` geprüft.
- Modell und Apache-2.0-Lizenz nur im isolierten Testordner
  `/private/tmp/vauldy-alt-ocr-zklrh9uc/tessdata-deu-best`; keine globale Sprachinstallation oder Hostkonfiguration.
  Der erste Python-HTTPS-Abruf scheiterte an dessen lokaler Zertifikatskette. Der
  anschließende System-curl-Abruf nutzte reguläre TLS-Prüfung; die Prüfung wurde nicht abgeschaltet.
- Alle **280 Tesseract-OCR-Prozesse** laufen seriell mit zwei Threads und dem macOS-
  Prozessprofil `(version 1)(allow default)(deny network*)`. Der Modelldownload erfolgte
  vorher. Das belegt lokale Ausführung dieses OCR-Prozesses, keinen netzgetrennten Mac.
- Dieselben 35 PNGs / 79 Sollfelder aus `Fixtures/faint-line-corpus.json`; sämtliche
  Bild- und Apple-Belegdateien vor und nach dem Vergleich per SHA-256 unverändert.
  Apple Vision wurde in dieser Iteration cachefrei erneut ausgeführt.

## Ergebnisse

Jede Variante wird einheitlich auf alle 35 Bilder angewandt. Keine Auswahl anhand von
Dateinamen, Sollfeldern oder dem besten Ergebnis je Dokument; keine erwarteten Wörter
oder individuellen Zeichenlisten in der OCR. Das engere vollständige Literalmaß bleibt
unverändert, einschließlich Großschreibung und Zeichensetzung.

| Tesseract-Variante | Rohresultat | Verlorene bisher korrekte Felder | Neue korrekte Felder | Mit Belegschutz | Rückfälle auf bisherige Seite | Unerwartete Zusätze danach |
|---|---:|---:|---:|---:|---:|---:|
| `auto` | 9/79 | 43 | 0 | 52/79 | 22 | 0 |
| `block` | 9/79 | 43 | 0 | 52/79 | 22 | 0 |
| `adaptive-block` | 5/79 | 47 | 0 | 52/79 | 34 | 0 |
| `scale3-auto` | 9/79 | 43 | 0 | 52/79 | 22 | 0 |
| `scale3-block` | 9/79 | 43 | 0 | 52/79 | 22 | 0 |
| `contrast3-auto` | 39/79 | 14 | 1 | 52/79 | 9 | 0 |
| `contrast3-block` | 39/79 | 13 | 0 | 52/79 | 9 | 0 |
| `contrast3-sauvola` | 38/79 | 15 | 1 | 52/79 | 9 | 1 |

Die zwölf besonders blassen/verrauschten Vorlagen bleiben bei Apple Vision und allen
acht Tesseract-Varianten jeweils **0/24** vollständigen Feldern. Die acht direkten
Austauschkandidaten scheitern alle an Qualität und/oder Feldverlusten.

`original` nutzt das unveränderte PNG; `scale3` verwendet eine separat erzeugte
pixelgetreue dreifache Vergrößerung; `contrast3` ergänzt eine feste Kontrastspreizung
anhand des leeren Bildrands. Die Originale werden dabei nie überschrieben. Die
Vorverarbeitung verwendet nur Pixel, keine Wahrheitstexte. Größere Testbilder sind auf
vier Millionen Pixel begrenzt. `auto`/`block` verwenden Segmentierung 3/6; `adaptive-block`
und `contrast3-sauvola` prüfen zusätzliche Binarisierungsmethoden. Diese Wahl folgt den
[offiziellen Tesseract-Hinweisen zu Skalierung und Segmentierung](https://tesseract-ocr.github.io/tessdoc/ImproveQuality.html).
Die Varianten sind explorativ; auch das beste Ergebnis ist keine unabhängige Holdout-Abnahme.

### Ein Zusatztreffer ist kein sicherer Gesamtgewinn

Im unveränderten Fall `tilted-9-right.png` liest `contrast3-auto` tatsächlich
`Leistung: Zahnriemenwechsel am Aggregat`, wo Apple `Zahnriemerwechsel` liefert.
Tesseract verändert dabei jedoch den bisher korrekten Geltungsbereich und liefert
für den Betrag `5247 EUR`. Die Wortkonfidenz für `Zahnriemenwechsel` beträgt im TSV
**0,0**, für `Leistung:` etwa 60,2. Diese Tesseract-Werte sind keine Apple-Konfidenzen.

Eine theoretische Vereinigung der richtigen Treffer wäre eine Auswahl anhand der
Sollwahrheit. Sie wird nicht als 53/79 ausgegeben. Der tatsächliche bestehende Schutz
verwirft den Seitenersatz und erhält die alten Belegzeilen. Die Sauvola-Variante lässt
zusätzlich einen unerwarteten Textzusatz durch den reinen Altbelegschutz; das separate
Qualitätsgate lehnt auch diesen ab. Keine unbestätigten Zusätze wurden gespeichert.

## Belegschutz und tatsächliche Prüfungen

`LocalOCRAlternativeComparisonTests` lädt die tatsächlichen deutschen Tesseract-Ausgaben
aller acht Varianten und führt sie durch `EvidencePreservingLocalOCR.preserving`.
Es prüft für 280 Seitenvergleiche alle vorher richtigen Sollfelder, wörtliche Altzeilen
in Reihenfolge und unveränderte Quell-/Belegdateien. Beim Rückfall bleiben auch die
vorherige Geometrie und der Text erhalten. Der Testadapter stellt unbekannte externe
OCR ausdrücklich als unbestätigten Text ohne erfundene native Konfidenz/Geometrie dar;
er ist kein neuer produktiver OCR-Anbieter und schreibt keinen Bestand.

- Frische native Korpusmessung: **3 Tests / 1 Suite bestanden, 13,477 s**.
- Abschließende native Prüfung einschließlich tatsächlicher Tesseract-Ausgaben,
  Belegschutz, festem Korpus und Cache-/Retryregression: **13 Tests / 4 Suites
  bestanden, 15,825 s**. Vorangehender Testbuild: 45,98 s.
- Echter Worker-/MCP-Zeilentest bestanden: sechs native Sollfelder, fünf geschützte
  Auszüge, frische Wiederholung, stabile Prüfgründe, unveränderte Originale/Freigaben
  und drei Widerrufe. Diagnose blieb lokal.
- Drei Python-Konvertierungstests bestanden; Syntaxprüfung bestanden. Diese Prüfungen
  sind kein OCR-Qualitätsnachweis.
- Separates Qualitätsgate tatsächlich ausgeführt: **Exitcode 1 / NO-GO**, beste
  geschützte Variante **52/79**, kein verlorenes altes Sollfeld.

Alle produktiven Swift-Quellen sind gegenüber dem Beginn dieser Iteration bytegleich.
Die neun produktiven Dokumente, gespeicherte Belege, Freigaben, ChatGPT-Kopplung, Keychain
und lokale Installation wurden nicht verändert. Die vorherige 111-Tests-Abnahme ist
historisch und wurde hier nicht als neuer Gesamtlauf ausgegeben.

## Zeiten und Grenzen

Apple meldet für die 35 cachefreien Seiten insgesamt **7.690 ms**, Median **232 ms**,
P95 **395 ms**. `contrast3-block` benötigt in frischen Tesseract-Prozessen insgesamt
**10.142,505 ms**, Median **293,516 ms**, P95 **347,011 ms**. Der Swift-Prozessstart ist
nicht in Apples Seitenzeiten enthalten; Tesseract enthält Prozess- und Modellstart,
aber nicht die Vorverarbeitung. Diese Messung ist keine Chat-, Importstapel- oder
Kunden-Mac-Latenzabnahme. Der Korpus enthält überwiegend deutsche ASCII-Umschriften;
Umlaute, Fraktur und andere unabhängige Scans sind separat zu prüfen.

## Ausgeführte Befehle

Native Builds laufen in der gegen den Workspace bytegeprüften lokalen Kopie
`/private/tmp/vauldy-ocr-vector-wtr5pb1z`. Das Vergleichsskript läuft im MCP-Repository.

```sh
# In der lokalen Buildkopie: echte neue Apple-Fixtures erzeugen.
VAULDY_OCR_FAINT_FIXTURES=/private/tmp/vauldy-alt-ocr-zklrh9uc/apple-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter OCRFaintRasterTests

# Im MCP-Repository: acht deutsche lokale Varianten ausführen.
python3 scripts/mcp/local_ocr_comparison.py run --fixtures /private/tmp/vauldy-alt-ocr-zklrh9uc/apple-fixtures --tessdata /private/tmp/vauldy-alt-ocr-zklrh9uc/tessdata-deu-best --output /private/tmp/vauldy-alt-ocr-zklrh9uc/final

# In der Buildkopie: echte Ausgaben mit dem bestehenden Belegschutz prüfen.
VAULDY_OCR_ALTERNATIVE_RUN=/private/tmp/vauldy-alt-ocr-zklrh9uc/final swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'LocalOCRAlternativeComparisonTests|EvidencePreservingOCRTests|OCRFaintRasterTests|OCRTargetedRetryTests'

# Im MCP-Repository: striktes Qualitätsgate; tatsächlich Exitcode 1.
python3 scripts/mcp/local_ocr_comparison.py check /private/tmp/vauldy-alt-ocr-zklrh9uc/final
python3 scripts/mcp/local_ocr_comparison_test.py
python3 -m py_compile scripts/mcp/local_ocr_comparison.py scripts/mcp/local_ocr_comparison_test.py scripts/mcp/regression_test.py
```

`run` lädt keine Modelle herunter und installiert nichts. Es verlangt explizit das
bereitgestellte, gepinnte deutsche Modell und einen neuen Ausgabeordner. Der native
Vergleichstest ist ohne `VAULDY_OCR_ALTERNATIVE_RUN` deaktiviert; reguläre Tests benötigen
keine Tesseract-Installation. Das strikte Qualitätsgate bleibt separat vom erfolgreichen
Regressionslauf. Die vollständige Paket-/UI-/Relay-Regression wurde nicht ausgeführt.

## Dateien und nächste Arbeit

- Neu: `scripts/mcp/local_ocr_comparison.py`, reproduzierbarer Offline-Vergleich und
  separates Qualitätsgate mit festem deutschem Modell.
- Neu: `scripts/mcp/local_ocr_comparison_test.py`, Prüfungen der Konvertierung.
- Neu: `Tests/VauldyMCPRuntimeTests/LocalOCRAlternativeComparisonTests.swift`,
  tatsächliche externe Ergebnisse durch vorhandenen Belegschutz prüfen.
- Erweitert: `scripts/mcp/regression_test.py`, Konvertierungstest ohne Zusatzabhängigkeit.
- Dokumentation: diese Datei, `docs/local-first-todo.md` und der
  [vollständige Messnachweis](quality/ocr-local-alternative-2026-11-08.json).

**Entscheidung:** Apple Vision bleibt unverändert. Ein produktiver Tesseract-Einbau ist
für diesen Korpus nicht begründet. Der nächste Qualitätsschritt bleibt ein tatsächlich
über 52/79 hinausgehender, belegschützender lokaler Ansatz. Danach folgen unabhängige
deutsche Vorlagen mit Umlauten und gegebenenfalls eine separat beauftragte reale Nachprüfung.
Kein Commit, Push, PR oder neues Installationspaket wurde erstellt.

Zusätzlicher tatsächlich ausgeführter Worker-/MCP-Befehl in der Buildkopie:

```sh
python3 scripts/mcp/line_ocr_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp line-fixtures
```

210 relevante Quell-/Test-/Skript-/Paketdateien stimmen per SHA-256 mit der Buildkopie
überein. 108 produktive Swift-Quellen sind gegenüber Iterationsbeginn unverändert.
Die zwei ausschließlich selbst erzeugten Vergrößerungsordner der Vorversuche wurden
nach dem finalen Vergleich entfernt (254.017.190 Bytes). Der feste Korpus, das deutsche
Testmodell, die finalen Ausgaben und Messprotokolle bleiben lokal verfügbar.

## Recherche zum nächsten Prüfkandidaten

Auf die anschließende Frage nach einer stärkeren lokalen OCR ist die Empfehlung
**PaddleOCR PP-OCRv6 medium, Sprache `de`**. Dies ist eine begründete Kandidatenwahl,
noch kein Messergebnis am Vauldy-Korpus. Die offizielle Implementierung ordnet Deutsch
(`de`/`german`) den PP-OCRv6-Modellen zu; die Dokumentation beschreibt Erkennung kleiner,
dichter Textregionen, Mac-Unterstützung und lokale Apple-M4-Messungen. Ein Gewinn über
52/79 ist damit noch nicht nachgewiesen. In dieser Iteration wurde PaddleOCR weder
installiert noch ausgeführt oder in den Produktpfad eingebaut.

Primärquellen, am 08.11.2026 geprüft:

- [PP-OCRv6: Architektur und lokale Mac-Ausführung](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-OCRv6/PP-OCRv6.html)
- [Offizielle Sprachenliste mit `de` und `german`](https://github.com/PaddlePaddle/PaddleOCR/blob/main/paddleocr/_utils/langs.py)
- [Zuordnung der Sprachen zu PP-OCRv6 medium](https://github.com/PaddlePaddle/PaddleOCR/blob/main/paddleocr/_pipelines/ocr.py)
- [Offizielles Erkennungsmodell](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec)

Nachtrag: Der anschließend beauftragte [tatsächliche PaddleOCR-Vergleich](ocr-paddle-v6.md)
ist inzwischen abgeschlossen. Die obige Kandidatenrecherche beschreibt den damaligen Stand.
