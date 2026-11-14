# OCR Korrekturen für Kennungen Tabellenwerte und Einheiten

Die sieben beanstandeten Stellen werden im vollständigen nativen PDF-Pfad jetzt
korrekt gelesen. Im unveränderten deutschen V2-Korpus steigen die exakten Felder
von **132/133 auf 133/133**, die exakten nichtleeren Tabelleninhalte als Text von
**311/345 auf 316/345**. Kein zuvor richtiges Feld, Tabelleninhalt oder korrektes
Wortvorkommen geht verloren. Genau die drei betroffenen Seitentexte ändern sich;
die übrigen 28 bleiben wortgleich.

## Korrigierte Originalstellen

| Original | Seite und Stelle | Vorher | Jetzt |
|---|---|---|---|
| [Werkstattbeleg](../Tests/VauldyMCPRuntimeTests/Fixtures/ocr-v2-workshop.pdf) | 2, Fahrgestellnummer | `TESTWWZZZ26K08417` | `TESTWVWZZZ26K08417` |
| [Mietvertrag](../Tests/VauldyMCPRuntimeTests/Fixtures/ocr-v2-lease.pdf) | 3, Wohnung | Anzahl fehlte in der Tabellenzeile | `Wohnung 3 beide Schließzylinder` |
| Mietvertrag | 3, Keller | Anzahl fehlte | `Keller 1 gekennzeichnet` |
| Mietvertrag | 3, Briefkasten | Anzahl fehlte | `Briefkasten 0 Nachlieferung vereinbart` |
| [Laborbefund](../Tests/VauldyMCPRuntimeTests/Fixtures/ocr-v2-laboratory.pdf) | 2, Hämoglobin | `g/dI` | `g/dl` |
| Laborbefund | 2, Leukozyten | `10/u1` | `10³/µl` |
| Laborbefund | 2, CRP | `mg/1` | `mg/l` |

Die zwei zuvor richtigen Vorkommen von `mg/dl` bleiben erhalten. Die bereits
erkannte Haustüranzahl `2` wird nicht geändert. Der globale Tabellenwert misst
Textvorkommen mit Wortgrenzen und Häufigkeiten, keine vollständige Tabellenstruktur.
Insbesondere die Wohnungsanzahl `3` wurde im alten globalen Maß durch eine andere
`3` auf derselben Seite verdeckt; die zusätzliche Prüfung verlangt deshalb die
richtige **zusammenhängende Zeile**. Alle sieben Stellen werden separat geprüft,
auch wenn der globale Tabellenzähler nur um fünf steigt.

## Umsetzung und Schutz vorhandener Inhalte

- Beschriftete Fahrzeugkennungen erhalten zwei lokale Ausschnittlesungen ohne
  Sprachkorrektur. Eine Änderung braucht dieselbe Lesung in beiden Ansichten und
  mindestens 0,95 native Konfidenz. Zulässig ist nur ein zusätzlich gelesener
  Buchstabe bei unverändertem Label und unveränderter Ziffernfolge. Die Länge ist
  lediglich eine Arbeitsgrenze; die synthetische Testkennung hat 18 Zeichen und
  wird nicht durch eine angenommene 17-Zeichen-Regel ergänzt.
- Geschlossene, achsenparallele Tabellenraster werden aus Linienpixeln erkannt.
  Für die Nachlese werden ausschließlich vorhandene Zellpixel mit weniger
  horizontalem Leerraum nebeneinandergestellt. Zeichen werden über ihre
  Geometrie in die ursprüngliche Zelle zurückgeordnet; Leerzeichen innerhalb
  einer Zelle bleiben wörtlich erhalten.
- Fehlende Zahlen werden nur nach zwei übereinstimmenden Kontextlesungen mit
  mindestens 0,95 Konfidenz ergänzt. Mindestens zwei vorhandene Nachbarzellen
  müssen exakt übereinstimmen, ebenso jede weitere sichtbare Zelle. Die neue
  Kontextzeile ergänzt den Seitentext; vorhandene Zahlen und Zeilen bleiben
  unverändert. Leere Zellen werden nicht als `0` ausgefüllt.
- Bei mehrdeutigen Einheiten werden zwei Ausschnittgrößen verglichen. Für
  `10³/µl` wird zusätzlich die Typografie vermessen: sechs getrennte Zeichen,
  kleines hochgestelltes Zeichen und Unterlänge beim als `u` gelesenen Zeichen.
  Das hochgestellte Originalzeichen wird vorübergehend auf die Grundlinie
  vergrößert. Vision liest dessen Ziffer; die gemessene Hochstellung und das
  Mikrozeichen werden anschließend wiederhergestellt. Das ist eine aus
  Quellgeometrie und nativer Lesung abgeleitete Rekonstruktion, kein unverändertes
  Unicode-Rohergebnis von Vision. Der Exponent wird nicht vorgegeben.
- Bereits gültige Einheiten werden nicht ersetzt. Bereits gelesene Exponenten,
  Ziffern, Beträge und Einheitenpräfixe dürfen nicht beliebig geändert werden.
  Jede Ersetzung erhält die frühere Lesung lokal am ursprünglichen Quellausschnitt.
  Die frische Nachlese eines Bestands akzeptiert diese Änderung nur mit passender
  Geometrie, Historie und Konfidenz; andernfalls bleibt die bisherige Seite erhalten.
- Pro physischer Seite sind höchstens acht Paare von Feldnachlesungen und zusammen
  acht Millionen zusätzliche Rasterpixel erlaubt. Abbruch bleibt wirksam;
  technische Fehler in der optionalen Ergänzung verwerfen nicht die Erstlesung.
  `ocr-v16-source-cell-context-` schließt alte OCR-Checkpoints aus.

Die Raster- und Typografieregeln sind bewusst begrenzt. Gedrehte oder ungerahmte
Tabellen und verbundene Zeichen sind damit nicht allgemein gelöst. Die
[bereits geprüften OCR-Alternativen](ocr-quality-improvements-2026-11-11.md)
bleiben die Vergleichsbasis; diese Änderung benötigt keinen neuen Anbieter oder
Modell-Download.

## Nachweise am unveränderten Korpus

Der komplette Vergleich umfasst 15 PDF-Dateien, 31 physische Seiten, 133 Felder,
345 nichtleere Tabellenzellen und drei Leerbildkontrollen. PDF- und PNG-Hashes
wurden gegen das eingefrorene Manifest geprüft. Manifest-SHA-256:
`e8d6d5a7bb874081381eacdd541b686acb0643d1249bd36cc4785fb5ace947c0`.
Die drei zusätzlich ins Testbundle aufgenommenen PDFs sind bytegleiche Kopien;
Sollwerte und Referenztexte wurden nicht geändert.

| Prüfung | Ergebnis |
|---|---|
| Sieben beanstandete Stellen | 7/7 korrekt, auch nach frischer Bestandsnachlese |
| Deutsche V2-Felder | 132/133 → 133/133, kein Verlust |
| V2-Tabelleninhalte als Text | 311/345 → 316/345, kein Verlust |
| Zuvor korrekte Wortvorkommen | Kein Verlust, einschließlich Wiederholungen |
| Frühere wörtliche Zeilen | Aktuell oder in lokaler Historie erhalten |
| Unveränderte Seiten | 28/31 PDF-Seitentexte wortgleich |
| Separater 35-Bilder-Korpus | 53/79 → 53/79, auch frisch; 35/35 Texte wortgleich |
| Leerbildkontrollen | Kein erfundener Text |
| Zusätzliche Typografiekontrollen | `10²/µl`, `10⁶/µl` korrekt; ASCII-Ziffern, `ul`, `pl` und leere Zellen nicht umgedeutet |
| Qualitätsgate mit absichtlichen Fehlern | Geänderte korrekte Zahl, falsche Wohnungsanzahl, verlorenes `mg/dl` und falscher Exponent werden abgewiesen |

Der abschließende native Lauf meldet **113 Tests in 25 Suites ohne Fehler**.
Ein optionaler Test eines gesonderten OCR-Anbieterkorpus blieb mangels vorbereiteter
Konfiguration übersprungen; er ist kein Nachweis eines neuen Anbieter-Vergleichslaufs.
Auch die bestehenden Worker-/Wiretests für Raster-PDFs (12/12 Felder), Zeilen (6/6 Felder),
Import/Queue, Originalverweise und die frühere Wortkorrektur sind bestanden.

Die neue Referenz `ocr-v15-correct-fields.json` sichert genau die 53 bereits
richtigen Felder der vorherigen Version zusätzlich zum bestehenden v14-Vergleich.
Sie verändert weder den 35-Bilder-Korpus noch dessen 79 Sollwerte.

Der echte Worker-Test importiert die drei PDFs zuerst mit dem bisherigen
v15-Programm und liest jedes anschließend zweimal mit dem neuen Worker frisch.
Korrekturen, frühere Lesungen, Originalbytes, Dokumentidentität und Freigaben
bleiben über den Worker-Neustart erhalten. MCP liefert die aktuelle geschützte
Lesung mit physischen Seitenbelegen, keine lokale Historie, Archiv-ID oder
Dateipfade. Ein Widerruf sperrt die bisherigen Handles.

Die drei korrigierten Seiten bleiben zur Kontrolle markiert; dadurch steigt die
Zahl der Prüfseiten von zehn auf 13. MCP meldet bei diesen Dokumenten weiterhin
`incomplete-or-unknown`, statt eine uneingeschränkte Vollständigkeit zu behaupten.

Die zusätzlichen Typografietests werden getrennt vom eingefrorenen Korpus erzeugt.
Im ersten Aufbau berührten sich die getrennt gesetzten CoreText-Läufe für Hochzahl
und Schrägstrich und fielen deshalb korrekt durch die Sechs-Zeichen-Bedingung.
Der Testaufbau erhielt den fehlenden Zeichenabstand; Produktbedingungen und
Konfidenzgrenzen wurden dafür nicht gelockert.

## Reproduktion

Native macOS-Vision-Laufzeit; isolierte Buildkopie mit den festgeschriebenen
Abhängigkeiten. Die Source- und Testdateien der Buildkopie sind bytegleich mit
dem dokumentierten Projektstand.

```sh
VAULDY_OCR_IMPROVED_FIXTURES=/tmp/ocr-fields-faint \
VAULDY_OCR_LINE_FIXTURES=/tmp/ocr-fields-lines \
VAULDY_OCR_AB_FIXTURES=/tmp/ocr-fields-raster \
swift test --build-system native -c release --disable-sandbox \
  --disable-automatic-resolution --jobs 4 -debug-info-format none \
  -Xswiftc -parse-as-library -Xswiftc -enable-testing --no-parallel \
  --filter 'OCR|LocalImportTests|LocalOriginalReferenceTests|LocalDocumentReviewTests|LocalDocumentQualityTests'
python3 scripts/mcp/ocr_field_quality_gate.py FROZEN_V2 APPLE_RESULTS --report report.json
python3 scripts/mcp/ocr_improvement_quality_gate.py /tmp/ocr-fields-faint
python3 scripts/mcp/ocr_field_recovery_smoke_test.py V15_LOCAL NEW_LOCAL NEW_MCP
```

Messwerte und Protokolle: [Prüfnachweise](quality/ocr-fields-2026-11-13/).
Dies ist die gezielte OCR-Abnahme im Projekt. Eine Produktivinstallation oder
vollständige Release-Abnahme ist damit nicht erfolgt.
