# Vorhandene Dokumente eindeutig kennzeichnen · 08.11.2026

Im MCP-Branch `codex/local-first-product-readiness` umgesetzt. Ein Prüfhinweis zur
Basisanalyse oder Texterkennung bedeutet nicht, dass ein Dokument erneut importiert
werden muss.

## Verhalten

- Die Dokumentenliste kennzeichnet Datensätze als **Im Bestand**. Textzustand und
  Basisanalyse stehen separat daneben. Bei einer fehlenden Basisanalyse wird nicht
  mehr fälschlich „Kein Text für Basisanalyse“ angezeigt.
- **Neue Dateien hinzufügen …** bezeichnet den Import. Die Kopfzeile und ein Hinweis
  über dem Bestand unterscheiden ihn vom Prüfen bereits vorhandener Dokumente.
- **Text prüfen** öffnet direkt den vorhandenen Vergleich von Original und gespeichertem
  Text. Dabei wird keine OCR gestartet. Der bisherige direkte Wiederholungspfeil in
  der Zeile entfällt. **Original öffnen** ist separat beschriftet.
- **Text erneut lesen** bleibt im Prüffenster ausdrücklich wählbar. Die Aktion ist
  nicht mehr als hervorgehobene Empfehlung gestaltet. Ein Textlauf für eine bewusste
  Mehrfachauswahl bleibt möglich und wird als optional erklärt.
- Fehlende oder unklare Basisangaben allein empfehlen weder Neuimport noch neue OCR.
  Originalzugriff, historische Texte, fehlender Text und laufende Verarbeitung
  behalten jeweils eigene Hinweise; vorhandene Prüfgründe werden nicht entfernt.
- Ein gespeichertes Dokument mit fehlgeschlagener oder unterbrochener OCR heißt im
  Bericht **Im Bestand · Texterkennung offen**. Fehler beim erneuten Lesen behalten
  die bekannte Dokument-ID. Ein Fehler vor einem bestätigten Import wird dadurch
  nicht fälschlich als vorhandenes Dokument ausgegeben.

## Neu ausgeführte Prüfungen

**18 Swift-Tests in zwei Suites bestanden, 1,725 s.** Enthalten sind sechs neue
Präsentations-/Berichtstests mit parametrisierten Zuständen und die bestehenden
`LocalImportTests` mit nativen PDF-/Bildimporten, Belegerhalt und Duplikaterkennung.
Der Duplikattest verwendet für den zweiten Import absichtlich einen ablehnenden
OCR-Adapter: gleiche ID, nur ein Datensatz, keine erneute OCR. Das ist ein lokaler
Regressionsnachweis; es wurde kein produktives Archiv neu importiert.

Der erste Testbuild scheiterte am fehlenden `@testable`-Import für den Testkonstruktor.
Nach dessen Korrektur bestanden alle 18 Tests. Der finale Release-Build der Einrichtung
bestand ebenfalls, zuletzt in 10,28 s.

Native Sichtprüfung als vollständiges, lokal ad-hoc-signiertes Testbundle, vorbereitet
über `scripts/mcp/run_ui.py`, mit explizitem isoliertem `--setup-root`: acht synthetische
Dokumente, Bestandskennzeichnung und getrennte Status sichtbar, Mehrfachaktion ohne
Auswahl deaktiviert, **Text prüfen** öffnet Originalvorschau und gespeicherten Text.
Anschließend waren alle **22 vorher vorhandenen Dateien des Testbestands bytegleich**;
kein OCR-Worker lief. Der eigene Testprozess wurde beendet. Kein Installieren,
Kopplungs- oder Freigabevorgang wurde ausgelöst.

Die Laufzeitlogik in Core, OCR, Privacy und MCP wurde nicht verändert. Die 79-Felder-
OCR-Suite wurde für diese UI-Iteration nicht erneut ausgeführt; frühere 52/79 bleiben
historischer Nachweis. Produktive Dokumente, Freigaben und Installation wurden nicht
als Testumgebung verwendet. Das vorbereitete temporäre Bundle ist keine neue
Developer-ID-signierte oder notarisierte Kundenrelease.

## Dateien

- `Sources/VauldyMCPSetup/SetupDocumentGuidance.swift`: reine Präsentationszuordnung;
  keine OCR, kein Schreiben und keine Umdeutung des gespeicherten Verarbeitungszustands.
- `SetupDetailViews.swift`, `SetupView.swift`, `SetupDocumentAnalysisView.swift`:
  Bestandskennzeichnung, getrennte Hinweise und Prüfaktion.
- `SetupQualityReviewView.swift`: aus der Bestandsliste ohne Importbericht öffnen;
  expliziter optionaler Textlauf bleibt erhalten.
- `SetupImportReport.swift`, `SetupImportStatusView.swift`, `SetupModel.swift`:
  vorhandenes Dokument und offene Verarbeitung unterscheiden, IDs bei Retryfehlern erhalten.
- `Tests/VauldyMCPRuntimeTests/SetupDocumentGuidanceTests.swift` und `Package.swift`:
  direkte Tests der tatsächlichen UI-Präsentationslogik und Importberichte. Die
  Testsuite hängt zusätzlich vom Setup-Modul ab; keine neue externe Abhängigkeit.
- `docs/local-first-todo.md` und
  [Messnachweis](quality/import-guidance-ui-2026-11-08.json): Iterationsstand und Kommandos.

Die Quell-/Buildkopie wurde mit 221 Dateien bytegleich geprüft. Ausgeführt im lokalen
Buildverzeichnis `/private/tmp/vauldy-ocr-vector-wtr5pb1z`:

```sh
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'SetupDocumentGuidanceTests|LocalImportTests'
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --product vauldy-mcp-setup
python3 scripts/mcp/run_ui.py --skip-build --no-open
```

Alle drei abschließenden Kommandos lieferten Exitcode 0. Das Bundle wurde mit
`--setup-root /private/tmp/vauldy-import-guidance-vm48gkbb/ui-root --section overview`
gestartet und ausschließlich dieser Testbestand bedient.

Nächster Auslieferungsschritt: ein neues Kundenpaket aus diesem Branch bauen, damit
die UI-Anpassung in einer aktualisierten Installation verfügbar wird. Die offene
reguläre ChatGPT-Fragenabnahme bleibt ein separater Roadmap-Punkt.
