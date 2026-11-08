# Kleinstschrift: lokale Detailerkennung und Chatwirkung

Stand: 07.11.2026, Branch `codex/local-first-product-readiness`, auf Basis von
`87ab76c3d7f79b53a2723235c036bf224c7573d6` mit vorhandenem Arbeitsbaum.
Kein Commit, Release, produktiver Bestandslauf oder Installationsupdate dieser Iteration.

## Ursache und Änderung

Die bisherigen 4-/5-Punkt-Proben sind synthetische PDFs mit als Vektorpfade gezeichneten
Buchstaben und einem unabhängig eingebetteten Kopftext. Sie sind keine repräsentative
Messung realer Scans. Der eingebettete Kopftext war lesbar, der normale Textdetektor
übersah jedoch den ganzen bzw. einen Teil des winzigen Körpers. Ohne Markierung startete
keine Regionserkennung. Bei 4 Punkt war sogar `needsReview=false` möglich, obwohl drei
sichtbare Angaben fehlten. Ein verarbeiteter Seitenzähler beweist keine fehlerfreie OCR.

`OCRSmallTextRegions` sucht deshalb auf einer begrenzten Graustufenkopie nach kleinen,
mehrfach unterbrochenen Druckbändern. Dunkle Pixel liefern ausschließlich Vorschläge:
Sie sind weder Schriftbeweis noch Konfidenz oder Solltext. Ein lokaler Vision-Textdetektor
prüft vergrößerte Ausschnitte. Seine Zeichenkoordinaten werden auf die ursprüngliche Seite
zurückgeführt und überlappende Erkennungen zusammengeführt.

Die vorhandene Regionserkennung liest neue Lücken weiterhin zweimal mit/ohne Sprachkorrektur.
Beide Lesungen müssen wörtlich übereinstimmen, ausreichend sicher sein und geometrisch passen.
Zahlenkonflikte und Überlappungen überschreiben keine vorhandene Evidenz. Für kleine Bereiche
unrotierter PDFs werden Vektoren im betreffenden Originalausschnitt erneut gerastert:
Eine bloße Vergrößerung der bereits gerasterten 4-Punkt-Buchstaben reichte nicht aus.
Rotierte Seiten behalten den bisherigen Bildpfad.

Grenzen: höchstens 3072 × 3072 Pixel für die Vorschlagssuche, 129 Vorschläge,
16 zusätzliche Detektorausschnitte bzw. 8 Mio. Detektorpixel pro physischer Seite.
Das bisherige OCR-Budget bleibt bei vier Regionen, zwei bestätigenden Lesungen,
maximal 1 Mio. Pixel je Ausschnitt und 8 Mio. OCR-Eingabepixeln pro Seite.
Erschöpfte Detektorbudgets bleiben als `limited` prüfbedürftig. Die neuen Metriken sind
optional und lokal; MCP-Ausgaben enthalten keine Geometrie oder Hashmetadaten.
Cachekonfiguration `ocr-v12-small-text-detection-…` verhindert die Wiederverwendung alter
abgeschlossener v11-Checkpoints. Bestehende Dokumente werden dadurch nicht automatisch neu gelesen.

## Exakte Ergebnisse und Chatwirkung

Identische Originale, sequenziell am selben Mac. Der Vergleich schaltet ausschließlich den
neuen Detailpfad aus/ein und erhält die bisherigen v11-Regeln für Skalierung und Bestätigung.
Die Sollwerte stehen allein in den synthetischen Testvorlagen, nicht in der Erkennung.

| Probe | Bisheriger Pfad | Neuer Pfad | Auswirkung auf die Antwort |
| --- | --- | --- | --- |
| 4 Punkt | 0/3 exakte Felder | 3/3 | Beitrag, Beginn und Versicherungsart werden erstmals belegbar. |
| 5 Punkt | 2/3 | 3/3 | Die bisher fehlende Versicherungsart wird belegbar. |
| 6 Punkt, Kontrolle | 3/3 | 3/3 | Keine Verschlechterung der vorhandenen Felder. |

Exakte Sollfelder: `Beitrag: 49,99 EUR`, `Beginn: 27.01.2026`,
`Versicherungsart: Hausrat`. Der unabhängig eingebettete `Selbstbehalt: 110,00 EUR`
bleibt erhalten und wird nicht zum Beitrag umgedeutet. Originalbytes bleiben gleich.

Normale Importe mit beiden Konfigurationen erzeugen vier isolierte Bestände. Der Wiretest
verändert deren OCR-Datensätze nicht. Über echte stdio-MCP-Aufrufe liefert `read_document`
die oben genannten 0/3, 3/3, 2/3 und 3/3 Felder mit physischer Seite 1.
Die Suche nach `Hausrat` findet beide neuen Bestände und keinen der beiden alten.
Widerruf sperrt danach sowohl Lesen als auch Feldauslese. Bestand und Freigabe bleiben
bis zum ausdrücklich getesteten Widerruf bytegleich.

**Die strukturierte Feldauslese ist ein eigener Vertrag:** `cost` liefert nach erfolgreicher
OCR `49,99 EUR` als belegten Beitrag. Die generischen Labels `Beginn` und
`Versicherungsart` sind bislang keine expliziten Regeln für `startDate` bzw. `contractType`.
Diese beiden Felder bleiben dort `not-evidenced`; im Dokumenttext sind sie lesbar.
OCR-Fortschritt wird nicht als erledigte Analyse- oder Rollenentwicklung ausgegeben.

Die abschließenden nativen Einzelläufe benötigten bei 4 Punkt 17 → 393 ms,
bei 5 Punkt 225 → 387 ms und bei 6 Punkt 375 → 374 ms. Dies sind einzelne, bereits
warme Seitenmessungen ohne P95-Aussage. Der Mehraufwand entsteht beim lokalen Import
bzw. expliziten Nachlesen, nicht erneut bei jedem Chatabruf. Auswahl und Volltextlesung
über den lokalen MCP benötigten im abschließenden Wirelauf zusammen 99.236 ms im ersten Vergleichsfall;
die vollständigen vier Messungen stehen im JSON-Nachweis. Diese Werte enthalten keine
Chatmodell- oder Relay-Latenz.

## Beobachteter regulärer Chat

[Testchat „Versicherungsdaten vergleichen“](https://chatgpt.com/c/6aef4ec7-48a0-83ed-8da3-7c5378a562e7).
Ein frischer Safari-Chat erhielt ausschließlich die vier geschützten synthetischen
`read_document`-Ergebnisse als ausdrücklich benannten manuellen Replay. Kein Plugin
war ausgewählt, keine echte Quelle und kein produktives Profil wurden übertragen.
Der Prompt verlangte unabhängige Auswertung, offene fehlende Werte, Trennung des
Selbstbehalts und einen ausdrücklichen Nachweis für einen aktiven Vertrag.

Beobachtete Tabelle:

| Fall | Versicherungsart | Beitrag | Beginn |
| --- | --- | --- | --- |
| 4pt-v11 | Nicht belegt | Nicht belegt | Nicht belegt |
| 4pt-current | Hausrat | 49,99 € | 27.01.2026 |
| 5pt-v11 | Nicht belegt | 49,99 € | 27.01.2026 |
| 5pt-current | Hausrat | 49,99 € | 27.01.2026 |

Alle Zeilen nennen Seite 1. Der Chat behauptet keinen aktiven Vertrag und verwechselt
110,00 € Selbstbehalt nicht mit dem Beitrag. Die Tabelle samt abgeschlossener Antwort
war bei der Beobachtung 27,228 s nach Absenden sichtbar. Das ist eine obere Beobachtungsgrenze,
keine genaue Messung der ersten sichtbaren Tabellenzeile. Die Modellkennung wurde nicht ermittelt.
Der Chat übernimmt außerdem die Verarbeitungsangabe `all-declared-pages-processed` als
„Quellenabdeckung vollständig“. Das bedeutet hier nur: alle deklarierten Seiten verarbeitet;
gerade die alte 4-Punkt-Probe beweist, dass es keine Garantie vollständiger Texterkennung ist.

Diese Prüfung belegt die Modellreaktion auf tatsächliche neue Werkzeugdaten. Sie ersetzt
keinen Live-MCP-/Relay-Test mit automatischer Werkzeugwahl aus einem separaten synthetischen
Anschluss. Die produktive Installation und ihre neun Dokumente wurden nicht umgestellt.

## Ausführung und Grenzen

Build-/Testkopie: `/private/tmp/vauldy-ocr-vector-wtr5pb1z`, Quellen und Tests vor dem Lauf
bytegeprüft gegen das MCP-Checkout; festgeschriebene Abhängigkeiten unverändert.
Abschluss: 88 Tests in 15 Suites bestanden / 26,835 s. Neue Grenzfälle prüfen
verschobene PDF-Crop-Koordinaten und einen widersprüchlichen Betrag in 4-Punkt-Schrift.
Zwei stdio-Prüfungen bestanden: vier synthetische Vorher-/Nachher-Bestände mit acht
Widerrufsprüfungen sowie die vorhandene Regionserkennungsprüfung mit drei PDFs,
Zahlenkonflikt, Cache, Frischerkennung und Verfeinerung. Der neue Wiretest ist in
`regression_test.py` eingebunden; die gesamte Release-/Installerregression wurde
in dieser Iteration nicht ausgeführt.

Die abschließenden Befehle und Ergebnisse stehen im
[maschinellen Nachweis](quality/ocr-small-text-2026-11-07.json).

Ein erster sandboxbeschränkter Start scheiterte am Swift-Modulcache, bevor Tests liefen.
Der erste native Qualitätslauf mit Detaildetektor, aber ohne Neurasterung, verfehlte
noch die 4-Punkt-Versicherungsart (2/3). Dieser Fehler blieb ein echter Fehler; der
strikte 3/3-Test wurde beibehalten. Der erste neue Wiretest verwendete irrtümlich das
nur im Fundstellenvertrag vorhandene `retrievalComplete` für eine Volltextantwort und
brach mit `KeyError` ab. Korrigiert wurde der Test auf den tatsächlichen Vertrag
`containsEntireAvailableText` plus fehlenden Folgecursor. Keine dieser Ausführungen
wird als bestanden gezählt.

Offen bleiben insbesondere niedrig aufgelöste Rasterquellen ohne rekonstruierbare
Vektorinformation, helle/berührende Druckbänder und Tabellen, die das Vorschlagsraster
nicht trennt, sowie reale Quellenprüfungen der fünf zuvor offenen Dokumente.
Eine allgemeine Genauigkeitsquote lässt sich aus den wenigen synthetischen Feldern nicht ableiten.

## Geänderte Dateien dieser Iteration

- `Sources/VauldyCore/OCRSmallTextRegions.swift` (neu): begrenzte Druckbandvorschläge.
- `Sources/VauldyCore/NativeLocalDocumentOCR.swift`: Detaildetektor, deduplizierte
  Zeichenkoordinaten, PDF-Ausschnitt-Neurasterung und getrenntes Detektorbudget.
- `Sources/VauldyCore/LocalOCRMetrics.swift`: optionale lokale Detektor-Arbeitsmetriken.
- `Sources/VauldyCore/LocalOCRPageCache.swift`: eigene v12-Konfiguration.
- `Tests/VauldyMCPRuntimeTests/OCRSmallRegionTests.swift`: bisherige 4-/5-Punkt-Proben
  jetzt strikte 3/3-Gates statt reiner Beobachtung.
- `Tests/VauldyMCPRuntimeTests/OCRSmallTextMCPFixturesTests.swift` (neu): normale
  A/B-Importe, alter Cache, PDF-Crop, Zahlenkonflikt, Abbruch und Linien-Negativfall.
- `scripts/mcp/small_text_chat_smoke_test.py` (neu): reale geschützte stdio-Ausgaben,
  exakte Felder, Suchbarkeit, Feldrollen, Freigabe und optionaler synthetischer Chat-Replay.
- `scripts/mcp/regression_test.py`: Fixtureexport und neuer Wiretest eingebunden.
- `docs/local-first-todo.md`, diese Datei und
  `docs/quality/ocr-small-text-2026-11-07.json`: Fortschritt, Ergebnisse und offene Grenzen.
