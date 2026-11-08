# Dichte OCR-Seiten und Dokumentenfenster · 08.11.2026

Branch: `codex/local-first-product-readiness`, Basiscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6`, bestehender Arbeitsbaum mit lokalen
Vorarbeiten. Diese Iteration erstellt weder einen Commit noch eine Veröffentlichung
oder ein produktives Update. Produktversion weiterhin 0.13.0, OCR-Konfiguration v13.

## Ergebnis und Bedienung

Im Dokumentenfenster mehrere Dateien anhaken oder **Treffer auswählen** benutzen,
danach **OCR erneut starten**. Die Trefferaktion umfasst auch Dokumente unterhalb
des sichtbaren Fensterausschnitts. Ausgeblendete ausgewählte Treffer werden gezählt
und ausdrücklich angekündigt. Ein gemeinsamer Fortschritt zeigt abgeschlossene
Dokumente sowie die Seitenverarbeitung des aktuellen Dokuments. Der lokale Worker
arbeitet die Auswahl nacheinander ab. Es entstehen keine parallelen OCR-Prozesse.

**OCR abbrechen** stoppt die weitere Verarbeitung; erfolgreiche Dokumente werden aus
der Auswahl entfernt, abgebrochene, fehlgeschlagene und noch nicht gestartete bleiben
ausgewählt. Diese Auswahl kann erneut gestartet werden. Die gesamte Restliste wird
noch nicht dauerhaft gespeichert: Abbruch/Fortsetzung im offenen Fenster ist geprüft,
Wiederherstellung des ganzen Stapels nach Beenden oder Absturz der Einrichtung nicht.
Bereits eingereichte Einzeljobs behalten die vorhandene Worker-Persistenz.

Importquellen stehen oben. Chatbot-Freigaben liegen in einem getrennten aufklappbaren
Bereich, mit eigener Auswahl, ausdrücklichem Speichern und unveränderter Zustimmung
bei Zugriffserweiterung. Standardmäßig gelten die Häkchen ausschließlich der OCR.
OCR-Prüfbedarf und Basisanalyse haben eigene Filter und Zustandsanzeigen. Generische
Titel werden in dieser Oberfläche durch den Originaldateinamen unterscheidbar;
Dateinamen werden damit nicht zu fachlichen Belegen. Basisangaben sind einklappbar.

## OCR und Datenerhalt

- Dichte Seiten werden in höchstens acht Gruppen zu 128 Zeichenregionen verglichen.
  Native Regionen werden in Gruppen von höchstens 256 Zeichen geteilt; insgesamt
  bleiben höchstens 1.024 Gruppen zulässig. Gespeicherte Geometrie bleibt auf 128
  Regionen begrenzt und priorisiert Lücken. Optionale validierte Summen erfassen auch
  verglichene, nicht gespeicherte abgedeckte Regionen. Überlauf bleibt `limited`.
- Benachbarte Lücken teilen sich ein räumlich begrenztes Nachlesefenster. Bei fehlender
  Bestätigung kann eine einzelne Restzeile das verbleibende ursprüngliche Budget
  nutzen. Höchstens vier Regionsversuche und acht Millionen Nachlesepixel pro Seite;
  keine pauschale Lockerung von Konfidenz oder Zahlen-/Kennungsregeln.
- Die Kleinschrift-Vorplanung trennt Spalten anhand breiter Zwischenräume. Bereits
  erkannte Spalten verbrauchen damit nicht alle Detailversuche. Bestehende Grenzen
  von 16 Detailversuchen und acht Millionen Detailpixeln bleiben erhalten.
- Unsichere Zeilen werden im Kontext geometrisch eindeutig ausgewählt. Eine Änderung
  benötigt zusätzlich dieselbe Beobachtung in einem zweiten Kontext ohne
  Sprachkorrektur. Mehrdeutige/zusammengeführte Zeilen und Zahlenkonflikte bleiben
  prüfbedürftig. Die Auswahl- und Konfliktregeln sind gezielt getestet; eine allgemeine
  Verbesserung beliebiger unscharfer Einzelzeilen ist damit nicht nachgewiesen.
- Jeder explizite frische Worker-Nachlauf nutzt den bestehenden Belegerhalt und
  prüft die erwartete Dokumentversion beim Commit. Bei Verlust oder Konflikt bleibt
  die bisherige belegte Seite erhalten. Originalhash, IDs und Freigaben bleiben
  gebunden; ein Nachlauf ist keine Zugriffsfreigabe. Worker-Protokoll 3 verhindert
  Einreichung bei einem alten laufenden Worker; dieser wird nicht automatisch beendet.
- Cachekennung `ocr-v13-dense-and-line-recovery-…` schließt alte Checkpoints aus.
  Ergänzte Abdeckungssummen sind optionale lokale Metadaten, keine MCP-Ausgabefelder.

## Tatsächlich ausgeführte Prüfungen

Ausführung im byteverglichenen Build-Checkout
`/private/tmp/vauldy-ocr-vector-wtr5pb1z`. Der Quellvergleich umfasst 197 Dateien
(Sources, Tests, Package und MCP-Pythonskripte), SHA-256:
`6830fa2e110e245aeb3717b8a6e86786debc663181889c82efb8ffec8c9c669d`.
Der temporäre Checkout umgeht die Buildprobleme im File-Provider-Verzeichnis;
Abhängigkeitspins wurden erhalten.

```sh
VAULDY_OCR_DENSE_FIXTURES="$PWD/dense-fixtures" \
VAULDY_OCR_SMALL_FIXTURES="$PWD/small-fixtures" \
VAULDY_OCR_REGION_FIXTURES="$PWD/region-fixtures" \
VAULDY_OCR_COVERAGE_FIXTURES="$PWD/coverage-fixtures" \
VAULDY_OCR_VECTOR_FIXTURES="$PWD/vector-fixtures" \
VAULDY_OCR_AB_FIXTURES="$PWD/raster-fixtures" \
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 \
  -debug-info-format none --no-parallel \
  --filter 'OCRDensePageTests|OCRLineContextTests|LocalWorkerTests|OCRSmallRegionTests|OCRSmallTextMCPFixturesTests|EvidencePreservingOCRTests|OCRMarkedRegionRecoveryTests|OCRBlockCoverageTests|OCRLayoutTests|PDFVectorTextOCRTests|OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalImportTests|LocalOriginalReferenceTests|BaseAnalysisMCPTests|LocalDocumentReviewTests|SQLiteIntegrationTests|MCPFieldExtractionTests'

python3 scripts/mcp/dense_ocr_smoke_test.py \
  .build/out/Products/Release/vauldy-local \
  .build/out/Products/Release/vauldy-mcp dense-fixtures
python3 scripts/mcp/visual_coverage_smoke_test.py \
  .build/out/Products/Release/vauldy-local \
  .build/out/Products/Release/vauldy-mcp region-fixtures

swift build -c release --product vauldy-mcp-setup --disable-sandbox \
  --disable-automatic-resolution --jobs 4 -debug-info-format none
python3 scripts/mcp/run_ui.py --skip-build --no-open
```

- **97 Swift-Tests / 18 Suites bestanden**, letzter akzeptierter Lauf am 08.11.,
  27,110 s. Danach nur UI-Pfadidentität und Auswahlzählung korrigiert; finaler nativer
  UI-Build erfolgreich (11,51 s) und abschließender nativer Sechserlauf erfolgreich.
- Native synthetische PDF-Seite: 140 eingebettete kleine Textzeilen und fünf als
  Vektoren gezeichnete Sollfelder. Vorher **0/5**, danach **5/5** exakte Felder;
  147 Regionen verglichen, 128 gespeichert, drei Regionsversuche. Alter Textpräfix,
  Selbstbehalt und Originalbytes erhalten. Das ist ein schwieriger synthetischer
  PDF-Fall, kein Genauigkeitsmaß für beliebige reale Rasterarchive.
- Bestehende Kleinstschriftkontrollen: 4 Punkt **0/3 → 3/3**, 5 Punkt **2/3 → 3/3**,
  6 Punkt weiterhin **3/3**. Strikte Raster-Sollfelder bestehen; ein mehrdeutiger
  Kennungsfall bleibt 3/4 und prüfbedürftig. Zeichenfehler in schwierigem Rastertext
  sind damit nicht allgemein beseitigt.
- Neuer tatsächlicher CLI/stdio-Lauf: Import, fünf exakte Felder, geschütztes Lesen,
  erneute frische OCR mit demselben Worker und Widerruf bestanden. Abdeckungssummen,
  Geometrie und lokale Pfade werden nicht ausgegeben. Bestehender Wiretest mit drei
  PDFs, sechs Zusatzfeldern, drei erhaltenen Werten, Zahlenkonflikt, Cache/Nachlauf
  und Widerruf ebenfalls bestanden. Kein regulärer Live-ChatGPT-Test dieser Iteration.
- Native UI ausschließlich mit sechs synthetischen PDFs und einer isolierten
  Freigabe von zwei Dokumenten: sechs auswählen, Suche auf einen Treffer einschränken,
  Hinweis auf fünf versteckte Auswahlen, Start/Fortschritt/Ergebnis **6 erneut gelesen**.
  Separater Durchlauf nach drei abgeschlossenen Dokumenten abgebrochen; drei blieben
  ausgewählt und wurden erfolgreich fortgesetzt. Im finalen Build nochmals sechs
  nach Wechsel in/aus Freigaben verarbeitet. Alle sechs IDs, Originalhashes und
  bisherigen OCR-Texte sowie die byteidentische Zweierfreigabe verifiziert.
- Filterprüfung: OCR-Prüfbedarf null Treffer, Basisanalyse sechs Treffer. Geöffnete
  Freigaben zeigen genau zwei Häkchen, Speichern ohne Änderung deaktiviert. Nach
  Einklappen sind die OCR-Aktionen wieder verfügbar. Screenshot visuell geprüft.
- Produktiver Erhalt nur lesend geprüft: neun Originale, neun OCR-Texte, zwei
  Verbindungsdateien und eine Clientkonfiguration unverändert; kein produktiver
  v13-OCR-Lauf. Bestehende ChatGPT-Kopplung nicht geändert.
- `git diff --check` und Python-Syntaxprüfung ausgeführt. Die neue Wireprüfung ist
  in `regression_test.py` eingebunden; die gesamte Release-/Installerregression wurde
  in dieser Iteration nicht ausgeführt. VoiceOver bleibt nach Nutzerwunsch übersprungen.

### Gefundene Fehler und Korrekturen

Ein erster Compileversuch scheiterte an fehlendem `try`. Erste native Ergebnisse
0/5 und 4/5 wurden nicht als Erfolg gewertet. Spaltentrennung und begrenzte
Einzelzeilenfortsetzung führten zum abschließenden 5/5-Ergebnis. Ein nativer
`Menu`-Button innerhalb der Lazy-Zeilen erzeugte eine SwiftUI-Layoutschleife mit
hoher CPU-/Speicherlast; durch einen einfachen OCR-Button ersetzt und erneut nativ
geprüft. Die korrigierte Ansicht war im Stichprobenprozess idle (kein Lastbenchmark).
Freigabeinitialisierung und `/tmp`-/`/private/tmp`-Pfadidentität wurden korrigiert;
Dateisystemauflösung erfolgt nur bei Quellenwechsel, nicht pro gerenderter Zeile.

Bei der UI-Automation startete ein Zugriff nach dem Beenden die Test-App einmal
ohne Testargumente neu. Es wurden keine Datenaktionen ausgeführt. Nur der eigene
Testprozess wurde beendet und der produktive Erhalt wie oben geprüft. Ein danach
versuchter reiner Test-Launcher zeigte kein Fenster und wurde verworfen. Der finale
Nachweis stammt aus dem regulären vollständigen Bundle mit explizitem `--setup-root`.
Zum Abschluss nur eigene isolierte Testprozesse beendet.

## Geänderte Dateien dieser Iteration

| Bereich | Dateien und Codebeleg |
| --- | --- |
| Dichte Abdeckung | `Sources/VauldyCore/LocalOCRVisualCoverage.swift` (`segmented`, Summen, begrenzte Geometrie), `LocalOCRLayout.swift` (Validierung) |
| Native OCR | `NativeLocalDocumentOCR.swift` (Detektion, Kontext, Restzeilen), `OCRRegionRecovery.swift` (`windows`), `OCRSmallTextRegions.swift` (Spaltentrennung), `OCRLineRecovery.swift` (`select`), `LocalOCRPageCache.swift` (v13) |
| Worker | `Sources/VauldyCore/LocalImportWorker.swift` (Protokoll 3, frischer Belegerhalt) |
| Dokumentenfenster | `Sources/VauldyMCPSetup/SetupModel.swift`, `SetupModel+Management.swift`, `SetupDetailViews.swift`, `SetupImportStatusView.swift`, `SetupView.swift` |
| Gezielte Tests | `Tests/VauldyMCPRuntimeTests/OCRDensePageTests.swift`, `OCRLineContextTests.swift`, `OCRMarkedRegionRecoveryTests.swift`, `PDFVectorTextOCRTests.swift`, `LocalWorkerTests.swift` |
| Wire/Regression | `scripts/mcp/dense_ocr_smoke_test.py`, `scripts/mcp/regression_test.py` |
| Nachweise | Dieses Dokument, `quality/ocr-dense-batch-ux-2026-11-08.json`, `local-first-todo.md` |

Die komplette Git-Differenz enthält zusätzlich vorhandene Änderungen früherer
Iterationen. Diese Liste grenzt den aktuellen Arbeitsumfang ab.

## Nächste Abnahmekriterien

1. Native Regionen mit über 256 Zeichen und unabhängige dichte Raster-/Tabellenseiten
   sowie verrauschte Einzelzeilen gegen exakte Sollwerte und Konfliktfälle prüfen.
   Oberhalb des Budgets weiterhin sichtbarer Prüfhinweis statt Vollständigkeitszusage.
2. Ganzen ausgewählten OCR-Stapel persistent und abbruchfest machen; nach Beenden,
   Prozessabbruch und Neustart Restliste, Belegerhalt und unveränderte Freigaben prüfen.
3. Eigenes neues Paket prüfen und erst bei entsprechendem Auftrag produktiv anwenden;
   fünf reale offene Dokumente / 13 markierte Seiten gesondert nachprüfen. Keine
   reale Qualitätsverbesserung aus dem synthetischen Ergebnis ableiten.
4. Native große Dokumentenliste und vollständige Releasegates separat prüfen.
   Developer-ID-/Notarisierung und physischer Offline-Kundenmac bleiben offen.

[Maschinenlesbarer Nachweis](quality/ocr-dense-batch-ux-2026-11-08.json).
