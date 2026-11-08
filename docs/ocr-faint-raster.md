# Sehr blasse Rasterzeilen: fester Korpus und abgelehnter Kandidat

Stand 08.11.2026, Branch `codex/local-first-product-readiness`, Ausgangscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6`. **Qualitätsziel nicht erreicht: NO-GO.**
Die getestete Erweiterung liefert weiterhin 52/79 vollständige wörtliche Sollfelder.
Die Rasterfilter sind ausschließlich im Testziel enthalten. Produktive native OCR
und Cachekennung bleiben beim unveränderten v14-Stand vor dieser Iteration.

## Messung und Entscheidung

Der bisherige Korpus wurde vor den Filterversuchen eingefroren: 35 PNGs und 79
vollständige Sollfelder. `Fixtures/faint-line-corpus.json` enthält die bisherige Wahrheit
und SHA-256 jedes Bildes. Die native Prüfung erzeugt dieselben Vorlagen über den
bestehenden `LineScan`-Renderer und verlangt identische Bildbytes. Weder Schriftgröße,
Kontrast, Rauschseed noch erwartete Texte wurden für ein besseres Ergebnis geändert.

| Gruppe | Bilder | Vorher | Kandidat | Sollfelder |
|---|---:|---:|---:|---:|
| Gemäßigte Fälle | 7 | 18 | 18 | 19 |
| Sehr blass, klein und verrauscht | 12 | 0 | 0 | 24 |
| Dunkle Zeilen mit blassen Einzelwörtern | 6 | 12 | 12 | 12 |
| Kursive Zeilen | 6 | 12 | 12 | 12 |
| Geneigte Zeilen | 4 | 10 | 10 | 12 |
| Gesamt | 35 | **52** | **52** | **79** |

Der pixelbasierte Zeilendetektor findet in zehn der zwölf schwierigen Bilder insgesamt
18 bislang nicht durch OCR-Geometrie abgedeckte Bänder. Das ist ein Detektionsbefund,
kein Textgewinn: **keine zusätzliche Zeile** besteht die unveränderten Annahmegates.
Die zwölf schwierigen Bilder bleiben bei **0/24** vollständigen Feldern. Die beiden
nicht lokalisierten Fälle sind `grid-11-93-25` und `grid-9-93-25`.

Erprobt wurden unter anderem Rauschglättung, Kontrastspreizung, hysteretische Maskierung,
kleine Lückenschließung, verschiedene Vergrößerungen, Binärschwellen, Wiener- und
Patch-Glättung sowie größere Zeilenkontexte. Zusätzliche lokale Diagnosen mit älteren
Vision-Revisionen und der neueren Apple-Dokumenterkennung brachten an den verwendeten
Proben ebenfalls keinen verlässlichen Zusatz. Nicht jede Diagnosevariante wurde über
alle 35 Bilder geprüft. Der Binärschwellen-Sweep wurde nach erfolglosen Teilproben
abgebrochen. Die vollständigen A/B-Läufe mit dem nativen Prototyp sowie dem finalen
Testkandidaten erreichten jeweils 52/79; sie begründen keine allgemeine Grenze der OCR.

Ein Warnbeispiel aus den ausschließlich synthetischen Diagnosen:

| Originaltext | Beobachtetes Filterergebnis | Mögliche Wirkung im Chat |
|---|---|---|
| `Schutz fuer Fahrrad und Hausrat` | Ausschnitt `Schutz` als `Schatz`, in beiden Lesungen mit Konfidenz 1,0 | Begriff und Themenzuordnung können verfälscht werden. Hohe Konfidenz allein reicht nicht als Beleg. |
| `Leistung: Wartung der Heizungsanlage` | beispielsweise `Leistung Wartung der Heizungsenlage` mit Konfidenz 1,0 nach Sprachkorrektur | Die Leistungsbeschreibung wäre fehlerhaft durchsuchbar und zitierbar. Der Kandidat wurde nicht übernommen. |

Es wurden keine Solltexte, Wortlisten aus dem Korpus oder ersetzten erwarteten Werte
an die OCR übergeben. Ein bloßer Filteraufruf, eine zusätzliche Markierung oder mehr
erkannte Zeichen werden nicht als Gewinn vollständiger Felder gewertet.

## Sichere technische Grenze

`OCRFaintRasterRegions` und `FaintRasterOCRExperiment` liegen ausschließlich unter
`Tests/VauldyMCPRuntimeTests`. Es gibt keinen produktiven Schalter, keine neue MCP-
Schnittstelle und keine automatische Nachbearbeitung vorhandener Bestände.

Der Testkandidat arbeitet mit begrenzten pixelbasierten Bandvorschlägen, zwei lokalen
Vision-Lesungen je Ausschnitt und bestehenden `OCRRegionRecovery`-Gates:

- Zwei räumlich passende, wörtlich übereinstimmende Lesungen mit Konfidenz mindestens
  0,85; eine davon ohne Sprachkorrektur. Keine Lockerung von Kennungs-/Zahlenkonflikten.
- Vorhandene OCR-Geometrie und Belegzeilen erhalten; ausschließlich Anhängen bestätigter
  Zusätze. Der übergeordnete `EvidencePreservingLocalOCR` bleibt ebenfalls unverändert.
- Zusammen mit bereits verbrauchtem Seitenbudget höchstens vier Ausschnittversuche und
  acht Millionen Retrypixel; ein vergrößerter Ausschnitt höchstens eine Million Pixel.
- Keine Änderungen an Originalbytes. Abbruch- und Größenlimits separat geprüft.
- Drei negative Vorlagen mit leerem Dokumentkörper und unterschiedlichem Rauschen
  erzeugen keine zusätzlichen Textzeilen.

`NativeLocalDocumentOCR.swift` und `LocalOCRPageCache.swift` wurden nach Ablehnung des
Prototyps bytegenau auf den gesicherten Stand vor dieser Iteration zurückgesetzt.
Keine produktiven Originale, neun Dokumente, Freigaben, gespeicherten Belege,
ChatGPT-Kopplungen oder Schlüsselbundeinträge wurden angefasst.

## Reproduzieren und Qualitätsgate

Der erfolgreiche Build benutzt die lokale identische Arbeitskopie
`/private/tmp/vauldy-ocr-vector-wtr5pb1z`, um FileProvider-Materialisierungsprobleme im
Workspace zu vermeiden. Quellen, Swift-Tests, Python-Skripte, Paketdateien und das
Korpusmanifest wurden vor den finalen Prüfungen per SHA-256 verglichen.

Ausgeführt im lokalen Buildverzeichnis:

```sh
VAULDY_OCR_FAINT_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/faint-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter OCRFaintRasterTests
python3 scripts/mcp/faint_ocr_quality_gate_test.py
python3 scripts/mcp/faint_ocr_quality_gate.py faint-fixtures --report faint-quality.json
```

Die isolierten drei nativen Regressionstests bestanden in 11,037 s. Die fünf Python-
Tests prüfen ausschließlich die Gatepolitik mit erfundenen Zeichenketten; ihr künstlicher
53-Felder-Positivfall ist **kein OCR-Ergebnis**.

**Das separate native Qualitätsgate liefert Exitcode 1 / NO-GO.** Es verlangt weiterhin
mindestens 53/79 vollständige Felder, keinen Verlust bisheriger Felder oder Belegzeilen,
identische Eingabebilder und keine unerwarteten neuen Zeilen. Die Regression prüft
Nichtverschlechterung und Sicherheitsgrenzen; ihr Bestehen ist keine Qualitätsfreigabe.
Der vollständige Regressionsstarter exportiert künftig zusätzlich `VAULDY_OCR_FAINT_FIXTURES`
und führt die Gatepolitik-Tests aus. Das bekannte gescheiterte experimentelle Qualitätsgate
wird separat ausgewertet und darf bei einer späteren Aktivierung nicht ausgelassen werden.

Die abschließenden gezielten Swift- und Worker-/MCP-Läufe sowie ihre tatsächlichen
Ergebnisse stehen im [maschinenlesbaren Prüfnachweis](quality/ocr-faint-raster-2026-11-08.json).
Die gesamte Paket-/UI-/Relay-Abnahme wurde in dieser Iteration nicht ausgeführt.

## Nächste Arbeit

Der Textgewinn bleibt offen. Weitere native Ansätze müssen zuerst auf exakt demselben
Korpus mindestens 53/79 erreichen und alle bisherigen Belege erhalten; erst danach kommt
ein produktiver Einbau mit eigener Cacheversion infrage. Ein Vergleich mit einem anderen
lokalen OCR-Verfahren wäre eine separate bewusste Entscheidung, keine automatische
Anbieterumschaltung oder Modellinstallation. Für reale Dokumente bleibt anschließend
eine gesondert beauftragte Nachprüfung erforderlich.

## Abschließende Regression und Dateiliste

Die gezielte Regression bestand mit **111 Swift-Tests in 20 Suites, 49,713 s**
(Testzeit; Prozess einschließlich Build 54,411 s). Vier tatsächliche isolierte
Worker-/stdio-Prüfungen bestanden: Zeilen 4,360 s, dichte Seite 2,023 s,
Regionsnachlesen 3,335 s und Rasterfälle 2,320 s. Sie prüfen unter anderem frisches
Nachlesen, alte Belege, unveränderte Freigaben, Privacy und Widerruf. Die strikte
Qualitätsprüfung wurde nach diesem Lauf erneut ausgeführt: **Exitcode 1, 52/79**.

Die ausgeführte Swift-Auswahl:

```sh
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'OCRFaintRasterTests|OCRConsistentLineTests|OCRDensePageTests|OCRLineContextTests|LocalWorkerTests|OCRSmallRegionTests|OCRSmallTextMCPFixturesTests|EvidencePreservingOCRTests|OCRMarkedRegionRecoveryTests|OCRBlockCoverageTests|OCRLayoutTests|PDFVectorTextOCRTests|OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalImportTests|LocalOriginalReferenceTests|BaseAnalysisMCPTests|LocalDocumentReviewTests|SQLiteIntegrationTests|MCPFieldExtractionTests'
python3 scripts/mcp/line_ocr_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp line-fixtures
python3 scripts/mcp/dense_ocr_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp dense-fixtures
python3 scripts/mcp/visual_coverage_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp region-fixtures
python3 scripts/mcp/raster_ocr_quality_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp raster-fixtures
```

Vor dem Lauf waren die sieben bisherigen Fixture-Umgebungsvariablen `VAULDY_OCR_LINE_FIXTURES`,
`VAULDY_OCR_DENSE_FIXTURES`, `VAULDY_OCR_SMALL_FIXTURES`, `VAULDY_OCR_REGION_FIXTURES`,
`VAULDY_OCR_COVERAGE_FIXTURES`, `VAULDY_OCR_VECTOR_FIXTURES`, `VAULDY_OCR_AB_FIXTURES`
auf die zugehörigen Verzeichnisse der lokalen Buildkopie gesetzt; zusätzlich
`VAULDY_OCR_FAINT_FIXTURES` auf `faint-fixtures`. Die vollständigen Argumentlisten,
Logs, Exitcodes, Laufzeiten und Prüfsummen stehen im JSON-Nachweis. 207 relevante
Quell-/Test-/Skript-/Paketdateien waren mit dem Workspace identisch.

Dateien dieser Iteration zusätzlich zum vorherigen Arbeitsstand:

- `Tests/VauldyMCPRuntimeTests/OCRConsistentLineTests.swift`: optionaler Export der
  bisherigen eingefrorenen Vorlagen, gemeinsamer unveränderter `LineScan`-Renderer.
- `Tests/VauldyMCPRuntimeTests/Fixtures/faint-line-corpus.json`: eingefrorene Wahrheit
  und Bildprüfsummen.
- `Tests/VauldyMCPRuntimeTests/OCRFaintRasterRegions.swift`: nur experimentelle
  Pixeldetektion und Aufbereitung im Testziel.
- `Tests/VauldyMCPRuntimeTests/FaintRasterOCRExperiment.swift`: begrenzter nativer
  Testadapter mit bestehenden Beleg- und Konfidenzgates.
- `Tests/VauldyMCPRuntimeTests/OCRFaintRasterTests.swift`: natives A/B, Belegerhalt,
  Negativkontrollen, Eingabeidentität, Größen-/Abbruchgrenzen und Fixtureexport.
- `scripts/mcp/faint_ocr_quality_gate.py`: echte Abnahme nur bei mehr als 52/79 ohne
  Verluste oder unerwartete Zusätze; aktuell gescheitert.
- `scripts/mcp/faint_ocr_quality_gate_test.py`: fünf Tests dieser Gatepolitik.
- `scripts/mcp/regression_test.py`: Fixtureexport und Gatepolitikprüfung einbinden.
- Diese Dokumentation, `docs/local-first-todo.md` und der JSON-Prüfnachweis.

Kein Commit, Push, Pull Request oder Installationspaket wurde erstellt.
