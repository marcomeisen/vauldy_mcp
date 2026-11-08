# Unsichere Einzelzeilen und nachvollziehbare Prüfmarkierungen · 08.11.2026

Branch `codex/local-first-product-readiness`, Basiscommit `87ab76c3d7f79b53a2723235c036bf224c7573d6`,
vorhandene Änderungen erhalten. Produktversion weiterhin 0.13.0, neue OCR-Konfiguration
v14. Keine Installation, echte Dokumentnachbearbeitung oder Änderung der Freigaben.

## Ursache der wechselnden Markierungen

Die bisherige Zeilenprüfung hatte unterschiedliche Folgewirkungen für dieselbe
unbestätigte schwache Quellzeile:

- Bei `.keep` blieb ein bereits schwaches, unverändertes Ergebnis teilweise unmarkiert.
- Ohne geometrisch passende Retry-Zeile wurde nur bei Kennungen oder Konfidenz unter
  0,55 markiert. Ein Fehler des Retry-Aufrufs oder fehlende Reparaturbestätigung
  markierte dagegen unabhängig davon.
- Bereits vor dem Nachlesen schwache Zeilen außerhalb des Viererbudgets fehlten
  teilweise in der Entscheidung. Klare kleine Kennungen konnten das Budget vor
  einer unsicheren Wortzeile verbrauchen.
- Der Seitenmittelwert kann einzelne schwache Zeilen verdecken. Gleicher Vollseitentext
  und gleiche erste Zeilenkonfidenzen bedeuten außerdem nicht gleiche Crop-Ergebnisse.

Damit sind konkrete Implementierungswege erklärt. Die historische einzelne Entscheidung
auf D1 Seite 4/6/8 aus der [realen v13-Prüfung](ocr-v13-real-review.md) wurde damals nicht
mit einem Grund protokolliert und kann nicht nachträglich einem bestimmten Pfad sicher
zugeordnet werden. Diese Dokumente wurden hier nicht erneut gelesen.

## Umsetzung

Die neue Entscheidung erfasst alle anfänglich unsicheren Zeilen, bevor das Nachlesebudget
verteilt wird. Nicht bestätigte Zeilen bleiben unabhängig vom fehlgeschlagenen Retry-Pfad
prüfbedürftig, auch außerhalb des Budgets. Mehrdeutige Kennungen bleiben offen. Es wird
kein alter Prüfstatus pauschal gelöscht oder über mehrere Läufe festgehalten.

Zwei räumlich passende starke Lesungen in verschiedenen Ausschnitten können eine
unsichere Zeile bestätigen. Bei unverändertem Wortlaut bleibt der Originaltext exakt
erhalten; die akzeptierte Konfidenz ist das Minimum der beiden tatsächlichen Lesungen.
Kennungen benötigen mindestens 0,94, andere bestätigte Zeilen mindestens 0,85. Eine
Reparatur muss zusätzlich die bisherigen Wort-, Alternativen-, Zahlen- und Kennungsgates
erfüllen. Ein bloßes `.keep` bestätigt keine schwache Zeile. Die mittlere Konfidenz wird
aus den tatsächlich akzeptierten Zeilen berechnet; sie bleibt eine Modellschätzung.

Die Erkennung erhält drei gezielte Änderungen:

1. Mehrdeutige Kennungen und tatsächlich unsichere Zeilen vor optionaler Nachlese
   bereits klarer Kleinschrift priorisieren. Ein nicht erstellbarer Ausschnitt verbraucht
   keinen nativen Versuch und verhindert nicht die Bearbeitung späterer Zeilen.
2. Bis zu vier getrennte Beobachtungen derselben räumlichen Zeile konservativ verbinden.
   Überlappende Duplikate, verschiedene Zeilen und zu große Abstände werden verworfen.
   Bestätigung, Zahlen- und Kennungsregeln gelten auch für zusammengesetzte Kandidaten.
3. Im begrenzten Zeilenausschnitt Graustufen strecken beziehungsweise eine Tonkurve
   anwenden, um blasse Wortteile hervorzuheben. Keine Binarisierung und keine globale
   Bildänderung. Erste/zweite Lesung verwenden unterschiedliche Ausschnitte und maximal
   Faktor 3/2; die zweite verwendet keine Sprachkorrektur. Originalbytes bleiben erhalten.

Weiter höchstens vier Zeilenversuche mit höchstens zwei nativen Lesungen je Versuch,
eine Million Pixel pro Lesebild. Keine Konfidenzlockerung, Modellinstallation oder Cloud-OCR.
Die vorhandenen Regions-, Kleinschrift- und Seitenbudgets bleiben getrennt begrenzt.

## Gespeicherte Gründe und Belegerhalt

`LocalOCRMetrics.lineReview` ist eine optionale, inhaltsfreie Zusammenfassung:
unbestätigte Zeilen, mehrdeutige Kennungen, widersprüchliche Lesungen, Budgetgrenze,
mittlere Konfidenz und sehr kurze Textbereiche. Bestätigungen, Reparaturen und
Kontrastversuche werden getrennt gezählt. Gründe erscheinen über `LocalDocumentReview`
in der bestehenden lokalen Prüfansicht. Geometrische Lücken und Belegschutz-Fallback
werden zusätzlich erklärt. Die visuelle UI wurde hier nicht separat abgenommen.

Die Zusammenfassung beschreibt die gespeicherte Erkennung und bleibt bei einem gültigen
Cachetreffer erhalten; Lookup-Zeit und `cacheHit` werden separat neu gemessen. Alte
Metriken ohne `lineReview` sind lesbar und bekommen weiterhin den bisherigen allgemeinen
Hinweis. `ocr-v14-consistent-line-review-…` schließt v13-Checkpoints aus. Keine automatische
Migration abgeschlossener echter Bestände.

Frische Worker-Nachläufe behalten den bestehenden Belegschutz: verloren gegangene oder
veränderte alte Zeilen, Zahlen und Wiederholungen halten die frühere Seite prüfbedürftig
fest. Eine neue synthetische Reparatur ist keine Berechtigung, historische Belege zu
ersetzen. Bei Fallback gehören Reparaturzähler zum verworfenen Kandidaten; die Anzeige
nennt ausdrücklich den erhaltenen früheren Text.

Neue Diagnosemetadaten bleiben lokal. Die acht lesenden MCP-Werkzeuge, Privacy-Verträge
und geschützten Ausgabeobjekte bleiben unverändert.

## Tatsächliche Prüfergebnisse

**108 Swift-Tests / 19 Suites bestanden, 39,017 s Testzeit.** Enthalten sind die
bestehenden Raster-Sollwerte, Kleinstschrift, dichte Seiten, Quellen-/Privacy-Grenzen,
Originalreferenzen, Belegerhalt, Worker, Cache und SQLite-Integration.

Neue gezielte Prüfungen belegen insbesondere identischen offenen Status für vier
fehlgeschlagene Bestätigungspfade, unbeantwortete Zeilen außerhalb des Budgets,
Kennungs-/Zahlenkonflikte, korrekte Priorisierung, Fragmentgeometrie und lokale Gründe.
Graustufen bleiben mehrstufig; flache und zu große Bilder werden nicht normalisiert.
Sieben native Vorlagen wurden wiederholt frisch gelesen: Text und Diagnosezusammenfassung
stimmen überein. Das ist keine Garantie für alle Vision-Versionen und Bilder.

Zusätzlicher nativer A/B-Korpus im selben Build, mit internem bisherigem Retry-Pfad
gegen neue Zeilenprüfung, ohne Cache und mit unabhängig gezeichneten Solltexten:

| Gruppe | Bilder | Vollständige Sollfelder vorher → nachher |
| --- | ---: | ---: |
| Kontrolle, blass, Rauschen, Kennung, dichte Zeilen | 7 | 18/19 → 18/19 |
| Kleine, sehr blasse, stark verrauschte Zeilen | 12 | 0/24 → 0/24 |
| Einzelne blasse Wörter in dunklen Zeilen | 6 | 12/12 → 12/12 |
| Kursivschriften | 6 | 12/12 → 12/12 |
| Schrägstellung und kleine Schrift | 4 | 10/12 → 10/12 |
| **Gesamt** | **35** | **52/79 → 52/79** |

**Kein gemessener Gewinn bei vollständig richtigen Feldern in diesem Korpus.** Die
vorher korrekt erkannten Felder bleiben erhalten. Die Status- und Auswahlkorrekturen
sind nachgewiesen; die neue Kontrast-/Fragmentbehandlung begründet hier noch keine
allgemeine Steigerung der Transkriptionsqualität. Der Fragment-Sollfall mit zusätzlichem
Wort ist ein Geometrie-/Entscheidungstest, kein gemessener nativer Textgewinn.

Insbesondere sehr blasse Rasterkleinschrift wird im Erstlauf teils nicht oder nur in
Fragmenten gefunden; ein Zeilen-Retry hat dann keinen ausreichenden Ansatz. Auch hohe
Konfidenz und fehlende Prüfmarkierung können bei einem falschen vollständigen Sollfeld
auftreten, beispielsweise im kleinen rechts geneigten Testfall. Keine Markierung
bescheinigt fehlerfreie oder vollständige OCR.

Vier tatsächliche Worker-/stdio-Prüfungen bestanden:

- Drei neue synthetische Zeilenvorlagen: sechs exakte native Felder, fünf erlaubte
  Auszüge über MCP, Vertragskennung geschützt, Diagnosegründe gespeichert und lokal,
  derselbe Worker, frische Nachlese mit gleichem Text/Prüfstatus, drei Widerrufe.
- Dichte Seite: fünf Zusatzfelder, 147 verglichene / 128 gespeicherte Regionen,
  Selbstbehalt erhalten, frischer Worker-Nachlauf und Widerruf.
- Regionsnachlese: drei PDFs, sechs Zusatzfelder, drei erhaltene Werte,
  Zahlenkonflikt, Privacy, Cache, Belegschutz und Widerruf.
- Drei schwierige Raster-PDFs: zwölf exakte gespeicherte Sollfelder; zwei vollständig
  verarbeitet, `raster-light` weiterhin prüfbedürftig. Freigaben, Privacy, Seitenbelege,
  Cache, frischer Nachlauf und Widerruf erfolgreich.

## Ausführung, Korrekturen und Grenzen

Build-Checkout `/private/tmp/vauldy-ocr-vector-wtr5pb1z`, bytegleich mit den relevanten
Dateien des MCP-Arbeitsbaums. Der finale Vergleich umfasst 201 Source-/Test-/Package-/
MCP-Pythonskriptdateien. Fingerprint:
`3c627dc409d902253b5788abe152a323ff0abd531c0b11fd8eb149a84d841782`.
Der nach dem Swift-Lauf korrigierte Python-Pfadhelfer wurde tatsächlich erneut geprüft;
Swift-Quellen und Tests blieben seit dem abschließenden 108-Test-Lauf unverändert.

```sh
python3 /private/tmp/vauldy-v14-final-checks.py
python3 scripts/mcp/line_ocr_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp line-fixtures
python3 scripts/mcp/dense_ocr_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp dense-fixtures
python3 scripts/mcp/visual_coverage_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp region-fixtures
python3 scripts/mcp/raster_ocr_quality_smoke_test.py .build/out/Products/Release/vauldy-local .build/out/Products/Release/vauldy-mcp raster-fixtures
```

Exakter Swift-Testfilter, Fixture-Umgebung, ausgeführte Argumentlisten und Protokolle
stehen im [maschinellen Nachweis](quality/ocr-consistent-lines-2026-11-08.json).
Erste neue Testbuilds scheiterten an einer escapten Key-Path-Syntax und fehlenden
Fixture-Initialisierungsargumenten. Ein erster Wiretest erwartete den ganzen unmaskierten
Satz; bestehende NER schützt darin „Schutz“ als vermeintlichen Ort. Nachweis getrennt
auf vollständigen nativen Text, erlaubten Auszug und Kennungsschutz umgestellt;
Privacy unverändert. Ein weiterer Wireaufruf scheiterte vor OCR am relativen Fixturepfad;
Pfadauflösung korrigiert und Rasterprüfung erfolgreich wiederholt. Diese Versuche
werden nicht als bestandene Läufe ausgegeben.

Keine gesamte Release-/Installerregression, keine notarisierten Pakete, kein regulärer
Live-ChatGPT-Antwortvergleich und keine erneute Bearbeitung der fünf realen Fälle.
Die dortigen v13-Befunde bleiben historisch gültig. Nächster Qualitätsnachweis ist ein
tatsächlicher Gewinn im festen schwierigen Korpus mit Kontrollen gegen Fehlkorrekturen.

## Geänderte Dateien dieser Iteration

| Bereich | Dateien / Codebelege |
| --- | --- |
| Native Zeilenprüfung | `Sources/VauldyCore/NativeLocalDocumentOCR.swift`: `recovery.lineRecovery`, Zustandsauswertung, bestätigte unveränderte Zeilen |
| Auswahl / Bilder | `OCRLineRecovery.swift`: `priority`, `select`; neu `OCRLineContrast.swift`: begrenzte Graustufenbehandlung |
| Diagnose | neu `LocalOCRLineReview.swift`: `OCRLineReviewState`, feste Gründe; `LocalOCRMetrics.swift`, `LocalDocumentReview.swift` |
| Cache | `LocalOCRPageCache.swift`: v14-Konfiguration; Cachetreffer bewahren Diagnosezusammenfassung |
| Swift-Tests | neu `Tests/VauldyMCPRuntimeTests/OCRConsistentLineTests.swift`; `OCRTargetedRetryTests.swift`: v13-Checkpoint und Diagnose beim Cachetreffer |
| Wiretests | neu `scripts/mcp/line_ocr_smoke_test.py`; `dense_ocr_smoke_test.py`, `raster_ocr_quality_smoke_test.py`, `regression_test.py` |
| Dokumentation | dieses Dokument, JSON-Nachweis und `local-first-todo.md` |

Die gesamte Git-Differenz enthält zusätzlich Vorarbeiten früherer Iterationen.
