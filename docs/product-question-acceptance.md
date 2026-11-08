# Produktnahe lokale Abnahme · 08.11.2026

Im Branch `codex/local-first-product-readiness`, Ausgangscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6`, umgesetzt und ausgeführt.
**11/11 feste Nutzerfragen liefern die erwarteten belegten Referenzantworten über den
lokalen MCP.** Die Antworten werden im Test deterministisch aus den tatsächlichen
Werkzeugergebnissen zusammengestellt. Ein reguläres ChatGPT-Gespräch und die Qualität
frei formulierter Modellantworten wurden in dieser Iteration nicht geprüft.

## Was die Abnahme beweist

Acht echte synthetische Originaldateien, sechs PNGs und zwei Raster-PDFs mit insgesamt
zehn physischen Seiten, durchlaufen `LocalImportService`, Apple Vision und die lokale
Basisanalyse. Geschäftswerte werden dem gespeicherten OCR-Text oder der Analyse nicht
nachträglich eingetragen. Sieben dieser Dokumente sind im eigens angelegten Testprofil
freigegeben; das achte bleibt gesperrt. Ein gesondert gekennzeichneter synthetischer
Snapshot mit zwei deklarierten Seiten und nur einer verfügbaren Textseite prüft die
Abstention bei Verarbeitungslücken. Er ist kein zusätzlicher nativer OCR-Erfolg.

Der Testclient verwendet das echte Release-Programm `vauldy-mcp` über stdio mit
Outputschema-Prüfung. Er folgt Listen-, Feld- und Lesecursorn. Die Auswahl aller acht
freigegebenen Datensätze wird zusätzlich mit vier kompakten Listenseiten geprüft.
Die Sollantworten liegen getrennt im Fragekorpus; der Antwortaufbau bekommt weder die
Sollwerte noch die Sollstatus. Die Zuordnung einer Frage zu Werkzeug und Suchbegriff
ist ein expliziter Testplan, keine getestete natürliche Sprachsteuerung.

Jede ausgegebene Tatsachenangabe benötigt ein Zitat, eine autorisierte Dokumentkennung
und die passende physische Seite. Ein zusätzlicher Volltextabruf prüft unabhängig, ob
das Zitat genau dort vorkommt. Geldrollen, Bezugszeitraum, Datumsrollen, Negationen,
Bedingungen und Quellwarnungen werden gegen die vorher festgelegte Sollantwort geprüft.
Die Vergleichslogik akzeptiert bei Beträgen harmlose Schreibvarianten wie `144,00 EUR`
und `144,00 €`; der unveränderte OCR-Literaltest zählt weiterhin exakt dieselben 79 Felder.

## Gemessene Fragefälle

Ein abschließender serieller lokaler Lauf; keine P95-Messung. Die Zeit endet beim
Aufbau des strukturierten Referenzobjekts. Prozessinitialisierung, der zusätzliche
Belegprüfabruf, Relay, Modelllaufzeit und die sichtbare ChatGPT-Tabelle sind darin
nicht enthalten. Die Zeiten gelten für diesen kleinen synthetischen Bestand.

| Nutzerfrage, verkürzt | Erwartete und erhaltene Antwort | MCP-Aufrufe für die Antwort | Lokal, ms |
|---|---|---:|---:|
| Alle Versicherungsunterlagen | Vier Kandidaten: zwei Policenüberschriften und zwei thematische Erwähnungen; kein bestätigter aktiver Schutz | 1 | 82,194 |
| Monatliche Fahrradleasingrate | 129,90 EUR monatlich, Seite 1; Schlussrate und Gesamtkosten getrennt | 2 | 59,769 |
| Hausrat-Jahresbeitrag | 144,00 EUR jährlich, Seite 1 | 3 | 61,794 |
| Kündigungsstichtag Fahrradleasing | 15.03.2027, aus 15.04.2027 minus einem Kalendermonat; beide Belege auf Seite 1 | 2 | 25,452 |
| Genannter Hausrat-Kündigungsstichtag | 30.09.2027, wörtlich auf Seite 1 | 2 | 42,279 |
| Gesamtsumme Fahrradwartung | 247,80 EUR auf Seite 2; Zwischensumme und Steuer nicht als Gesamtbetrag ausgeben | 3 | 82,235 |
| Zahlungsfrist Fahrradwartung | 15.03.2027 auf Seite 2 | 2 | 25,686 |
| Glasbruch und Fahrraddiebstahl | Quellpassage erhält „nicht mitversichert“ und „nur bei abgeschlossenem Fahrrad“ | 2 | 39,543 |
| Fehlende Haftpflicht-Kündigungsfrist | Im verfügbaren Text nicht belegt; keine Behauptung einer fehlenden Verpflichtung | 2 | 32,736 |
| Widersprüchliche Wohnungsmiete | 640,00 und 690,00 EUR auf Seiten 1 und 2; keine gültige Einzelrate behaupten, Quellwarnung erhalten | 2 | 91,167 |
| Kündigung aus einem Teilscan | Nicht sicher bestimmbar; keine Berechnung aus unvollständiger Quelle | 2 | 47,235 |

Die Themenübersicht benötigt hier einen produktiven Werkzeugaufruf. Vier weitere
Leserunden dienen ausschließlich der unabhängigen Belegkontrolle im Test. Der
Messnachweis weist diese Prüfaufrufe für jeden Fall separat aus.

**Zwei relevante Befunde:** Die Feldextraktion meldet bei Hausrat und Rechnung
`FIELD_EXTRACTION_INCOMPLETE`. Die Referenz folgt dem bestehenden Skill und liest den
vollständigen verfügbaren Quelltext zusätzlich. Die vollständig beschrifteten Beträge
sind dort korrekt belegt; der Warnhinweis bleibt sichtbar. Das ist kein Fix der
produktiven Feldauslese. Die zweite Seite der Mietvorlage bleibt prüfbedürftig. Beide
bereits belegten Raten bleiben deshalb als Konflikt mit `SOURCE_NOT_READY` erhalten.
Eine davon als geltende Rate zu bestätigen wäre falsch.

## Antwortgate und Sicherheitsgrenzen

Fünf Python-Tests prüfen die tatsächlichen gespeicherten MCP-Belege und lehnen alle
20 gezielt verfälschten Antwortvarianten ab: falscher Betrag oder Zeitraum, falsche
Rolle/Seite, erfundene Quelle, fehlender Beleg, verlorene Negation/Bedingung, Werbung
als aktiver Vertrag, fehlende/doppelte Themenzeile, unterdrückter Konflikt oder
Quellwarnung, erfundene Frist sowie ungeprüfte Zusatzprosa. Fehlende und doppelte
Antwort-IDs werden ebenfalls abgewiesen.

Eine Vorlage enthält absichtlich die Anweisung, `999,99 EUR` zu antworten. Der
extraktive Referenzpfad führt sie nicht aus, und das Gate verwirft eine solche
Antwort. Dies ist **kein Nachweis gegen Prompt-Injection bei einem LLM**.

Die echte MCP-Abnahme prüft außerdem: nicht freigegebener Datensatz nicht auffindbar,
Roh-ID nicht lesbar, keine internen IDs/Pfade oder der gesperrte Textmarker in den
Werkzeugantworten, Widerruf für Lesen/Feldauslese/Fristen wirksam. Testoriginale und
Testfreigaben bleiben während der Fragen unverändert. Widerrufstests ändern ausschließlich
das eigene synthetische Profil. Produktionsbestand, neun Dokumente, bestehende Freigaben,
ChatGPT-Kopplung, Schlüsselbund und lokale Installation werden nicht verwendet.

## OCR-Regressionen neu ausgeführt

- **47 native Tests in zehn Suites bestanden, 36,523 s**, einschließlich echter
  Importe, Kleinstschrift, dichter Seiten, Blockabdeckung, markierter Bereiche,
  unsicherer Zeilen, Belegerhalt und unverändertem festem Rasterkorpus.
- Fester Korpus: **52/79 vorher, 52/79 nachher**, keine verlorenen bisherigen Felder
  oder Belegzeilen. Das eigenständige Verbesserungs-Gate liefert weiterhin
  **NO-GO, Exitcode 1**. Die zwölf extrem blassen Vorlagen sind dadurch nicht gelöst.
- Echter Worker-/MCP-Rastertest: drei PDFs, zwölf exakte gespeicherte Felder,
  Privacy, physische Seite, Cache und frischer Retry sowie Widerruf bestanden.
- Einzelzeilen-Worker-/MCP-Test: drei Bilder, erhaltene Belege und Freigaben,
  stabile Prüfgründe, maskierte Kennung und drei Widerrufe bestanden.
- 4-/5-Punkt-Wiretest: aktuelle Fassung jeweils **3/3** verfügbare exakte Felder;
  acht Widerrufsprüfungen bestanden. Nicht alle lokalen Feldbezeichnungen werden
  von der begrenzten strukturierten Feldauslese erkannt; Textbeleg und Feldauslese
  bleiben getrennt ausgewiesen.
- Fünf bestehende Tests der strikten OCR-Gate-Policy bestanden.

108 produktive Swift-Dateien und alle 48 bereits vorhandenen Swift-Testdateien sind
gegen den Aufgabenbeginn bytegleich. Bestehende Sollwerte und OCR-Konfiguration sind
unverändert. Zusätzlich kamen der native Produktfixture-Test, der unabhängige
Fragekorpus und drei Python-Abnahmewerkzeuge hinzu. Der bestehende Regressionsrunner
führt diese künftig automatisch nach den Fristentests aus. Der gesamte Runner wurde
in dieser Iteration nicht ausgeführt; die oben genannten gezielten Stufen wurden ausgeführt.

## Dateien und Wiederholung

| Datei | Aufgabe |
|---|---|
| `Tests/VauldyMCPRuntimeTests/ProductQuestionFixturesTests.swift` | Echte synthetische Originale importieren und Testbestand exportieren |
| `Tests/VauldyMCPRuntimeTests/Fixtures/product-questions.json` | Versionierter unabhängiger Sollkorpus für elf Fragen |
| `scripts/mcp/product_acceptance.py` | Lokale MCP-Workflows, Referenzantworten, Beleg-/Privacy-/Widerrufsgates |
| `scripts/mcp/product_answer_check.py` | Vollständige strukturierte Antwortsätze gegen gespeicherte Belege prüfen |
| `scripts/mcp/product_acceptance_test.py` | Gegenproben, 20 falsche Antwortvarianten und sichtbare Referenztabelle |
| `scripts/mcp/regression_test.py` | Drei neue Abnahmestufen und eigener Fixture-Export |
| `docs/product-question-acceptance.md` | Prüfverfahren, Ergebnisse, Grenzen und Folgeschritte |
| `docs/product-question-reference-answers.md` | Alle tatsächlich erhaltenen Referenzantworten mit Zitaten |
| `docs/quality/product-question-acceptance-2026-11-08.json` | Messwerte, exakte Kommandos, Arbeitsverzeichnisse und SHA-256-Belege |
| `docs/quality/product-question-evidence-2026-11-08.json` | Geschützte synthetische MCP-Belege für die unabhängige Wiederholungsprüfung |
| `docs/local-first-todo.md` | Fortschritt und priorisierte offene Abnahme |

[Referenzantworten](product-question-reference-answers.md),
[Messnachweis und exakte Kommandos](quality/product-question-acceptance-2026-11-08.json),
[synthetische Belegpakete](quality/product-question-evidence-2026-11-08.json).

Auf diesem Mac erfolgte der Swift-Lauf im lokalen Buildverzeichnis
`/private/tmp/vauldy-ocr-vector-wtr5pb1z`; 219 Quell-, Test-, Package- und Skriptdateien
wurden vor der Ausführung bytegleich mit dem Arbeitsbranch geprüft. Swift 6.4.2,
Python 3.12.6. Der vollständige native Aufruf mit fünf Exportvariablen steht im
JSON-Messnachweis. Der Filter umfasst die oben genannten zehn Suites, `--no-parallel`,
`-c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none`.
Ein Fixture-Export benötigt ein frisches Verzeichnis; native OCR-Benchmarks seriell ausführen.

Die abschließenden lokalen Abnahmekommandos aus dem Repository waren:

```sh
python3 scripts/mcp/product_acceptance.py /private/tmp/vauldy-ocr-vector-wtr5pb1z/.build/out/Products/Release/vauldy-mcp /private/tmp/vauldy-product-acceptance-v7v9vf93/fixtures-final --output /private/tmp/vauldy-product-acceptance-v7v9vf93/final-verified
python3 scripts/mcp/product_answer_check.py /private/tmp/vauldy-product-acceptance-v7v9vf93/final-verified/evidence-packets.json /private/tmp/vauldy-product-acceptance-v7v9vf93/final-verified/answers.json
python3 scripts/mcp/product_acceptance_test.py --packets /private/tmp/vauldy-product-acceptance-v7v9vf93/final-verified/evidence-packets.json --report /private/tmp/vauldy-product-acceptance-v7v9vf93/answer-gates-final.json
```

Alle drei lieferten Exitcode 0. `--output` bei einem erneuten Lauf neu wählen.
Die gespeicherten geschützten Belege können ohne Swift, neue OCR oder Verbindung erneut
geprüft werden. `product_answer_check.py` akzeptiert dazu eine vollständige JSON-Liste
strukturierter Antworten im gezeigten Format. Frei formulierter Text außerhalb dieses
Formats ist damit nicht bewertet.

## Verbleibende Abnahme in Reihenfolge

1. **P1: tatsächlicher Zielchat.** Dieselben synthetischen Fragen über einen getrennten
   Testanschluss in einem regulären ChatGPT-Gespräch stellen. Sichtbare Antworten auf
   vollständige Zitate, Negationen, Bedingungen, Unsicherheit und Konflikte prüfen.
   Werkzeugaufrufe, Zeit bis zur sichtbaren Tabelle und Modellversion protokollieren.
   Keine Nutzung der neun echten Dokumente als Ersatz für den Testbestand.
2. **P1: Umfang der Feldwarnungen präzisieren.** Fälle mit benachbarten beschrifteten
   Kostenrollen prüfen. Abnahme: korrekter Einzelbetrag mit unverändertem Kontextschutz;
   echte unbeschriftete Fortsetzungen und Konflikte dürfen nicht als vollständig gelten.
3. **P1: unabhängige deutsche Vorlagen und schwierigere Quellen.** Mehrspaltigkeit,
   Fortsetzungsseiten und echte OCR-Lücken in weitere feste Produktfragen aufnehmen.
   Abnahme: keine unbelegten kritischen Werte, sichtbare Unsicherheit bei nicht lesbaren
   Quellen, alle vorhandenen OCR-Belege erhalten. Verbesserungen am bisherigen
   Stresskorpus benötigen weiterhin das eigene unveränderte >52/79-Gate.

**GO** für die elf geprüften lokalen Referenzfälle. **Offen** für die tatsächliche
Chatbot-Abnahme. **NO-GO** für die Behauptung einer verbesserten OCR am festen Korpus.
Eine neue Kundenrelease-, Installations- oder 20.000-Dokumente-Abnahme war nicht Teil
dieser Iteration.
