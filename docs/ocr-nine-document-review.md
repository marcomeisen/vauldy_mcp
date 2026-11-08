# Gezielte lokale OCR- und Analyseprüfung vom 07.11.2026

Arbeitsbranch `codex/local-first-product-readiness`, Basiscommit `87ab76c` mit den
vorhandenen lokalen Änderungen. Auf ausdrücklichen Auftrag wurde der tatsächliche
Neun-Dokumente-Bestand lokal bearbeitet. Die Codeprüfung verwendet getrennte synthetische
Dokumente. Keine echten Dokumenttexte, Originale, Dateinamen oder dauerhaften Dokument-IDs
stehen in diesem Bericht oder den Repository-Nachweisen.

## Ergebnis im bestehenden Bestand

Die sechs als unvollständig gemeldeten Dokumente enthalten 24 der insgesamt 27 Seiten.
Es fehlten keine vollständigen Seiten. Vorher waren 15 Seiten markiert: unsichere Zeilen,
visuell unzureichend abgedeckte kleine Bereiche oder begrenzte Abdeckungsprüfung.
Vor jeder Änderung wurde der Bestand privat lokal gesichert. Eine separate lokale
Kandidatenkopie lieferte den Vergleich vor der Anwendung.

| Fall | Zeichen vorher → nachher | Zusätzliche Zeilen | Markierte Seiten vorher → nachher |
| --- | --- | --- | --- |
| D1 | 29.323 → 29.332 | 1 | 5 → 4 |
| D2 | 1.147 → 1.147 | 0 | 1 → 1 |
| D3 | 9.410 → 9.410 | 0 | 1 → 1 |
| D4 | 1.472 → 1.481 | 1 | 1 → 0 |
| D8 | 3.294 → 3.294 | 0 | 2 → 2 |
| D9 | 7.575 → 7.595 | 5 | 5 → 5 |

D5–D7 wurden nicht erneut mit OCR gelesen. Insgesamt kamen sieben Zeilen bzw. 38 Zeichen
hinzu. Alle vorherigen nichtleeren Belegzeilen bleiben pro physischer Seite in derselben
Reihenfolge vorhanden. Zahlen oder vorhandene Textzeilen wurden nicht ersetzt. Vier statt
drei Dokumenten haben nun den Zustand vollständig quellseitig verarbeitet. Fünf Dokumente
mit 13 markierten Seiten bleiben offen. Dieser Zustand belegt keine fehlerfreie OCR.

Alle neun verwalteten Originaldateien sind per SHA-256 unverändert. Originalreferenzen,
Dokument-IDs und vorhandene Freigabedateien blieben erhalten. OAuth, Schlüsselbund und
Relay wurden nicht umkonfiguriert. Sieben lokale Suchabfragen über den installierten MCP
finden die sieben hinzugefügten Zeilen, ohne Auszüge oder Suchbegriffe auszugeben. Der
bestehende ChatGPT-Anschluss bestätigt weiterhin neun durchsuchbare Dokumente, davon vier
quellseitig vollständig verarbeitet; keine fehlen oder warten auf Verarbeitung.

## Basisanalyse aller neun Dokumente

Alle neun wurden ausdrücklich neu analysiert. Die fünf gespeicherten belegten Felder
haben weiterhin ein wörtliches Zitat auf ihrer zugeordneten physischen OCR-Seite. Die
gemeinsame Analysepipeline validiert zusätzlich Rolle, Wert und Seitenbesitz. Das ist
keine unabhängige Sichtprüfung dieser Werte am Scan und keine vollständige fachliche
Vertragsprüfung.

Alle neun Analysen bleiben `needsReview`. Gründe können gemeinsam auftreten:

- Neun Dokumente ohne eindeutig belegten Betreff.
- Acht ohne zulässige wörtliche Übersicht.
- Sechs ohne unterstützten eindeutigen Dokumenttyp.
- Ein Dokument mit mehrdeutiger Struktur.
- Fünf weiterhin mit Quellenverarbeitungshinweisen.

Kein Betreff wurde aus einem Dateinamen erraten. Fehlende Rollenwerte bleiben offen.
Für diese Befunde wurden keine Modellinferenz, Cloud-OCR oder neuen Anbieter eingeführt.
Ein privater lokaler Detailbericht neben der Rücksicherung ordnet D1–D9 den Dateinamen zu.

## Codeänderungen

- `Sources/VauldyCore/OCRRegionRecovery.swift`: Größenwahl ausschließlich für markierte
  kleine Ausschnitte. Höchstens 3× Vergrößerung, eine Million Pixel pro Lesebild.
- `Sources/VauldyCore/NativeLocalDocumentOCR.swift`: tatsächliche vergrößerte Bildarbeit
  dem bestehenden Budget belasten. Vier Zielbereiche, zwei bestätigende Lesungen je Ziel,
  höchstens acht Millionen Pixel pro Seite. Koordinaten bleiben an den Originalausschnitt
  gebunden. Konfidenz-, Übereinstimmungs-, Überlappungs- und Zahlenkonfliktgates erhalten.
- `Sources/VauldyCore/EvidencePreservingLocalOCR.swift`: explizite Verfeinerung nimmt einen
  neuen Seitenstand nur an, wenn sämtliche bisherigen nichtleeren Zeilen exakt, einschließlich
  Wiederholungen und Reihenfolge, erhalten bleiben. Andernfalls bleibt die frühere Seite
  prüfbedürftig erhalten. Die neue Laufzeit wird separat erfasst, nicht als alte Messung ausgegeben.
- `Sources/VauldyCore/LocalImportService.swift`, `LocalDocumentStore.swift`: optionalen
  erwarteten Datensatz unter der Speichersperre prüfen, bevor ein Verfeinerungsentwurf den
  Importzustand ändert. Zwischenzeitliche Änderungen führen zu `staleAttempt`.
- `Sources/VauldyCore/LocalOCRMetrics.swift`: optionale, rückwärts lesbare Fallbackmarkierung.
- `Sources/VauldyCore/LocalOCRPageCache.swift`: Konfiguration v11 schließt alte Checkpoints aus.
- `Sources/VauldyLocalCLI/main.swift`: lokaler `refine`-Befehl über regulären Original-Lease,
  OCR-Sperre, Quellenprüfung und atomaren Importabschluss; keine neue MCP-Schreibschnittstelle.
- Neue Swift-Prüfungen `OCRSmallRegionTests` und `EvidencePreservingOCRTests`; bestehende
  synthetische PDF-Fixture um Schriftgröße erweitert; Wireprüfung um `refine` ergänzt.

```sh
vauldy-local refine --store /absoluter/bestand --document UUID
vauldy-local analyze --store /absoluter/bestand --document UUID
```

`refine` liest cachefrei mit Erhalt bisheriger Zeilen. Für bewusste Korrekturen bestehender
Fehler bleibt der getrennte vollständige Retry mit Sichtprüfung erforderlich. Exitcode 2
kennzeichnet einen weiterhin prüfbedürftigen Zustand; er wurde bei diesen Läufen nicht als
fehlgeschlagene Ausführung oder als vollständiger Erfolg umgedeutet.

## Tatsächlich ausgeführte Codeprüfungen

Die endgültigen 149 Quell-/Test-/Package-Dateien wurden bytegleich mit der lokalen
Buildkopie verglichen. Abschließend 78 Swift-Tests in 13 Suites bestanden, 16,913 Sekunden.
Die acht bestehenden Rasterfälle bleiben strikte Sollwerttests. Die neue Prüfung deckt
auch geänderte Zahlen, verlorene Zeilen/Wiederholungen, Stale-Entwürfe, Originalvalidierung
und tatsächliche Persistenz ab. Die finale echte Import-/MCP-Prüfung besteht einschließlich
Verfeinerung, alter belegter Werte, Quellenbindung, Privacy, Cache, Fresh-Retry und Widerruf.

Zwei frühe neue Stressläufe verlangten zunächst alle drei Sollfelder auch bei 4-/5-Punkt-
Vektorpfaden. Dabei fehlten jeweils vier Felder. Die Diagnose zeigt eine Grenze vor dem
Zweitlauf: Der unabhängige Detektor markiert die drei 4-Punkt-Felder und ein 5-Punkt-Feld
gar nicht. Diese vollständigen Qualitätsziele sind **nicht bestanden**. Der endgültige
Test trennt den strikten 6-Punkt-Fall von den explorativen 4-/5-Punkt-Proben, die Erhalt,
Arbeitsbudget und Nichtverschlechterung prüfen. Deren volle Textrichtigkeit wird dadurch
nicht als bestanden erklärt:

| Schriftgröße | Unvergrößerte Bereiche | Vergrößerte Bereiche | Vollständiges 3-Feld-Ziel |
| --- | --- | --- | --- |
| 4 Punkt | 0/3 | 0/3 | Offen |
| 5 Punkt | 0/3 | 2/3 | Offen |
| 6 Punkt | 3/3 | 3/3 | Bestanden |

Die erste Kandidatenvorprüfung wurde versehentlich gestartet, während die synthetische
Wireprüfung noch lief. Nur der Kandidatenprozess wurde gestoppt; der aktive Bestand war
unverändert. Die Vorprüfung wurde danach aus einer neuen Kopie sequenziell wiederholt.
Der abgebrochene Versuch ist kein Erfolgs- oder Laufzeitnachweis. Die tatsächliche Anwendung
benutzte außerdem einen Vergleich gegen den gesamten Ausgangsbestand vor Beginn; der
zusätzliche generische Stale-Entwurfsschutz kam danach hinzu und wurde synthetisch geprüft.
Ein unnötiger erneuter Lauf auf den echten Dokumenten erfolgte dafür nicht.

Ausgeführt in `/private/tmp/vauldy-ocr-vector-wtr5pb1z`:

```sh
VAULDY_OCR_REGION_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/region-fixtures VAULDY_OCR_COVERAGE_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/coverage-fixtures VAULDY_OCR_VECTOR_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/vector-fixtures VAULDY_OCR_AB_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/raster-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'OCRSmallRegionTests|EvidencePreservingOCRTests|OCRMarkedRegionRecoveryTests|OCRBlockCoverageTests|OCRLayoutTests|PDFVectorTextOCRTests|OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalImportTests|LocalOriginalReferenceTests|BaseAnalysisMCPTests|LocalDocumentReviewTests|SQLiteIntegrationTests'
python3 scripts/mcp/visual_coverage_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp region-fixtures
```

Die tatsächliche Wartung nutzte die gebaute lokale CLI mit `refine` für D1/D2/D3/D4/D8/D9
und `analyze` für D1–D9. Identitäten und Originalnamen stehen ausschließlich in der privaten
lokalen Aufzeichnung. [Maschinenlesbarer Nachweis](quality/ocr-nine-document-review-2026-11-07.json).

## Verbleibend

Unmarkierte Kleinstschrift, überlappende Tabellenbereiche und widersprüchliche Erkennungen
brauchen weitere getrennte Qualitätsfälle. Verbleibende Originalwerte müssen lokal am Scan
geprüft werden, bevor bestehende Zeilen korrigiert werden. Für die Analyse braucht es eine
gesonderte Verbesserung belegbarer Dokumentstruktur und nicht beschrifteter Inhalte.

Die installierte App und der Relay wurden nicht ersetzt. Der installierte MCP liest den
verfeinerten Bestand nachweislich kompatibel. Für künftige Importe und die Anzeige der neuen
v11-Geometrie muss der Branchstand in das nächste Installationspaket übernommen werden;
die bisherige UI kann Geometrie einer unbekannten OCR-Konfiguration bewusst zurückhalten.

Nachfolgend wurde auf weiteren Auftrag das [v11-Paket erstellt und lokal installiert](v11-package-update.md).
Die neuen Programme sind damit auch für künftige Importe verfügbar; der tatsächliche
Neun-Dokumente-Bestand und die bestehende ChatGPT-Kopplung blieben dabei erhalten.
