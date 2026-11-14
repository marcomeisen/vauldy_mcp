# OCR-Korrekturen und unveränderter Prüfkorpus · 11.11.2026

Der native OCR-Pfad erreicht auf denselben 35 Bildern **53/79 statt 52/79 exakte
Sollfelder**, ohne eines der zuvor richtigen Felder zu verlieren. Auch die
belegschützende frische Nachlese erreicht 53/79. Der bisher unmarkierte Fehlerfall
ist jetzt prüfpflichtig. Das ist ein begrenzter, nachgewiesener Fortschritt;
die vollständige OCR-Qualitätsabnahme bleibt offen.

## Umsetzung

Bei schrägen, langen Textzeilen überschätzte das umschließende Rechteck die
Schrifthöhe. Kleine Schrift wurde dadurch nicht gezielt nachgelesen. Der Pfad
misst jetzt die Seitenkanten des erkannten Vierecks und entzerrt geeignete
Zeilenausschnitte lokal. Die Transformation bleibt auf die Originalkoordinaten
zurückführbar; Ausschnitt, Winkel, Pixelzahl und Retrybudget sind begrenzt.
Originalbilder und die globale Auflösung werden nicht geändert.

Eine zusätzliche Wortkorrektur setzt kleine Schrift, zwei räumlich passende
Nachlesungen aus unterschiedlichen Kontextausschnitten und mindestens 0,95
Konfidenz voraus. Nur ein einzelner Buchstabentausch in einem mindestens sechs
Buchstaben langen Wort kommt dafür infrage. Zahlenabweichungen und erkannte
Kennungen werden nicht auf diese Weise korrigiert. Änderungen bleiben
prüfpflichtig. Konfidenzschwellen wurden nicht gesenkt; Solltexte fließen
ausschließlich in die nachträgliche Auswertung ein.

Der konkrete Gewinn lautet `Zahnriemerwechsel` → `Zahnriemenwechsel` im Fall
`tilted-9-right`. Die fehlerhafte Zahl `82.47` wird **nicht** anhand des Sollwertes
zu `82,47` umgeschrieben; die Seite fordert weiterhin eine Originalprüfung.
Unbestätigte Kleinschrift bleibt auch bei hoher nativer Konfidenz prüfpflichtig.
Dadurch entstehen zusätzliche Prüfhinweise, auch bei einzelnen vollständig
richtig gelesenen Vorlagen. Diese zählen nicht als Textgewinn.

Die frühere wörtliche Lesung bleibt in der lokalen, quell- und textgebundenen
Zeilengeometrie erhalten. Die frische Nachlese darf eine passende Korrektur
übernehmen, wenn die frühere Lesung und derselbe Quellbereich nachgewiesen sind.
Bei ungestützten Änderungen, verlorenen Zeilen, Zahlenabweichungen oder nicht
erhaltbarer Historie greift weiterhin der bisherige Seitenschutz. Weitere
Nachlesungen erhalten auch die Historie. Sie wird im lokalen Qualitätsdialog
zum Vergleich angeboten und nicht als zusätzliche Tatsache über MCP ausgegeben.

Die OCR-Konfiguration ist `ocr-v15-rectified-line-evidence-<Systemstand>`.
Alte v14-Checkpoints werden ausgeschlossen. Bestehende fertige Archive werden
nicht automatisch umgeschrieben; die Übernahme erfolgt beim ausdrücklich
angeforderten erneuten Lesen.

## Nachweise

- 108 native Swift-Tests in 24 Suites bestanden (58,758 s Testzeit), einschließlich
  Raster-PDF/PNG, weißer Ränder, Koordinaten, gezielter Nachlese, Cache, Import,
  Originalverweise, Historienpersistenz und lokaler Qualitätsanzeige.
- Die 35 unveränderten PNG-Hashes und alle 79 unveränderten Sollfelder sind
  gegen das vorhandene Manifest geprüft. Die gespeicherten tatsächlichen
  v14-Ergebnisse bilden die feste Ausgangsmessung, keine nachgebaute Mock-OCR.
- Das neue unabhängige Qualitätsgate verlangt echten Gewinn, null Verlust alter
  richtiger Felder, erhaltene frühere Lesungen, keine unerwarteten Textzusätze
  und dieselbe Verbesserung nach frischer Nachlese. Ergebnis: **GO** für diese
  Änderung; **0** unmarkierte fehlerhafte Fälle im festen Korpus. Historische
  Lesungen werden niemals als aktuell richtiges Feld gezählt.
- Die Prüfhinweise steigen im schwierigen Korpus von 13 auf 17 Seiten. Nur eine
  Seite ändert ihren Text; drei zusätzliche Hinweise betreffen vollständig
  richtig gelesene Vorlagen. Das ist die gemessene konservative Nebenwirkung.
- Zusätzlicher echter Vorher-/Nachherlauf auf denselben 15 deutschen PDFs mit
  31 Seiten: **132/133 → 132/133** Felder, **311/345 → 311/345** nichtleere
  Tabelleninhalte als Text. Alle 31 Seitentexte sind wortgleich; kein zuvor
  richtiges Wortvorkommen oder Tabelleninhalt ging verloren. Jeweils zehn Seiten
  mit Prüfhinweis, keine Leerbild-Halluzination. PDF- und PNG-Hashes geprüft.
- Fünf neue Gate-Policytests und die fünf bestehenden Tests des separaten
  Faint-Experiments bestanden. Das testinterne Kontrastexperiment bleibt getrennt;
  sein historisches NO-GO wird nicht in einen Erfolg umgedeutet.
- Echter alter Worker → neuer Worker: zweimalige frische Nachlese übernimmt die
  Wortkorrektur und erhält die Historie. Original, Identität und Freigabe bleiben
  unverändert. MCP zeigt die aktuelle Lesung und den Prüfstatus, keine lokale
  Historie, Pfade oder Archiv-ID; Widerruf sperrt den Zugriff.
- Bestehende echte Worker-/Wiretests bestanden: drei Raster-PDFs mit 12/12
  Feldern, drei Zeilenbilder mit 6/6 nativen Feldern und fünf geschützten Auszügen,
  Import/Queue/Wiederanlauf sowie Originalverweise. `raster-light` bleibt mit
  allen vier richtigen Feldern nun vorsorglich prüfpflichtig.
- Vollständiges natives Test-Bundle mit eigenem `--setup-root` geöffnet:
  Originalausschnitt, aktueller Text, Prüfgrund und aufgeklappte frühere Lesung
  gemeinsam sichtbar. Kein erneuter Import und keine Installation erforderlich.

Die native Buildkopie stimmt für sämtliche Source- und Testdateien bytegleich
mit dem Abschlussstand überein (`source-proof.json`). Während der Arbeit wurde
der unabhängige UX-Stand als `e40c35f` integriert; diese Änderungen wurden erhalten.
Die Paketierung musste in der temporären Skriptkopie ausdrücklich das native
SwiftPM-Buildsystem verwenden, da der Standardpfad auf nicht vorhandene
Xcode-Produkte zeigte. Der erste Paketierungsversuch ist kein bestandener Test;
das anschließend erzeugte Bundle wurde ad-hoc signiert und strikt geprüft.

Reproduktionsschritte (isolierte Buildkopie, native macOS-Vision-Laufzeit):

```sh
VAULDY_OCR_IMPROVED_FIXTURES="$PWD/ocr-improved" \
VAULDY_OCR_LINE_FIXTURES="$PWD/ocr-lines" \
swift test --build-system native -c release --disable-sandbox \
  --disable-automatic-resolution --jobs 4 -debug-info-format none \
  -Xswiftc -parse-as-library --no-parallel \
  --filter 'OCR|LocalImportTests|LocalOriginalReferenceTests|LocalDocumentReviewTests|LocalDocumentQualityTests'
python3 scripts/mcp/ocr_improvement_quality_gate_test.py
python3 scripts/mcp/ocr_improvement_quality_gate.py ocr-improved --report ocr-improvement.json
python3 scripts/mcp/ocr_repair_smoke_test.py OLD_LOCAL NEW_LOCAL NEW_MCP FROZEN_TILTED_IMAGE
```

Das zusätzliche Qualitätsgate ist in `regression_test.py` eingebunden. Die gesamte
Release-Regression wurde hier nicht erneut ausgeführt; die genannten Tests sind
die gezielte OCR-Abnahme. Ein optionaler externer Anbieter-Swifttest blieb mangels
konfiguriertem Modell ausdrücklich übersprungen.

Die vollständigen Messungen und Laufprotokolle liegen unter
[`quality/ocr-improvements-2026-11-11`](quality/ocr-improvements-2026-11-11/).
Die Ausgangsprüfung ist [separat dokumentiert](ocr-quality-audit-2026-11-10.md).

## GitHub, andere OCR und geprüfte Alternativen

Die Bewertung verbindet die neuen Versuche mit den bereits vorhandenen
[V1-Messungen](local-idp-comparison.md), dem
[deutschen V2-Vergleich](german-document-comparison-v2.md),
[Paddle-Vergleich](ocr-paddle-v6.md) und
[Tesseract-Vergleich](ocr-local-alternative.md). Historische Modellmessungen
sind nicht als neue Läufe ausgegeben. Es wurden keine Modelle heruntergeladen,
keine neuen Provider aktiviert und keine Dokumente an Cloud-OCR übertragen.

| Möglichkeit | Erkenntnis und Entscheidung |
|---|---|
| Apple `RecognizeDocumentsRequest` | Neuer lokaler Versuch auf den gleichen 35 PNGs: 52/79, kein Zugewinn. Auf 31 V2-Seitenbildern: 130/133 Felder, 257/345 nichtleere Zellen an korrekter Position, 3/19 Tabellen exakt, keine Leerbild-Halluzination. Kein Ersatz. Der PNG-Versuch ist nicht unmittelbar mit einem PDF-Engine-Lauf gleichzusetzen. |
| GLM-OCR / MLX | Lokale macOS-Option bleibt interessant: historisch V2 133/133 Felder und 344/345 Tabelleninhalte als Fließtext, aber kein belastbares Zellraster. Historisch V1 51/79, drei zuvor richtige Felder verloren und erfundene Webadresse in drei Leerbildkontrollen. Kein sicherer pauschaler Ersatz. |
| PaddleOCR / PP-OCRv6 | Weiterhin Kandidat für gezielte Ergänzungen. Historischer bester Rohkandidat: 54/79, jedoch ein zuvor richtiges Feld verloren. Der bisherige Belegschutz verhinderte deshalb die Übernahme. |
| Docling | Für Tabellenstruktur aussichtsreich: historisch Python 338/345 positionierte Zellen und 15/19 exakte Tabellen. Gleichzeitig 130/133 Felder statt Apples 132/133. Als pauschaler Textersatz nicht verlustfrei. |
| Tesseract | Bereits geprüfte lokale Varianten belegen keinen sicheren Gesamtgewinn gegenüber der bisherigen Basis. |
| ocrmac / swift-ocr | Wrapper beziehungsweise Integrationen nativer Apple-Erkennung; allein kein Nachweis eines zusätzlichen Erkenners oder besseren Ergebnisses. |
| mlx4ocr | Das geprüfte Repository ist archiviert. Kein ungeprüfter neuer Laufzeitbaustein. |

Zusätzlich wurden lokale Kontrastverstärkung, geglättete Ausschnitte,
Median-/gewichtete Filter und eine rauschangepasste Weißpunktwahl an den zwölf
extremen Rastervorlagen ausprobiert: weiterhin **0/24** exakte Felder, teils
unbrauchbare Zeichenfolgen. Auch ein niedrigeres `minimumTextHeight` brachte
keinen Gewinn. Diese Änderungen wurden nicht in den Produktpfad übernommen.

Primärquellen, geprüft am 11.11.2026:

- [Apple: RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest)
  und [minimumTextHeight](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/minimumtextheight).
- [GLM-OCR](https://github.com/zai-org/GLM-OCR),
  [macOS/MLX-Anleitung](https://github.com/zai-org/GLM-OCR/blob/main/examples/mlx-deploy/README.md),
  [MLX-VLM-Integration](https://github.com/Blaizzy/mlx-vlm/blob/main/mlx_vlm/models/glm_ocr/README.md).
- [PaddleOCR-Releases](https://github.com/PaddlePaddle/PaddleOCR/releases),
  [Docling](https://github.com/docling-project/docling),
  [Tesseract-Bildvorbereitung](https://tesseract-ocr.github.io/tessdoc/ImproveQuality.html).
- [ocrmac](https://github.com/straussmaximilian/ocrmac),
  [swift-ocr](https://github.com/kibotu/swift-ocr),
  [mlx4ocr](https://github.com/shuuul/mlx4ocr).

## Offene Qualitätslücken

Die zwölf extrem blassen, kleinen und verrauschten Bilder bleiben bei 0/24.
Im Gesamtkorpus fehlen weiterhin 26/79 exakte Felder. Der native Produktpfad
liefert weiterhin kein separat validiertes Tabellenraster. Zwei passende
Nachlesungen sind keine universelle Richtigkeitsgarantie. Die synthetischen
Verlustfreiheitstests begründen keine Zusage für sämtliche realen Archive.

Der nächste belastbare Versuch wäre eine räumlich gebundene, zusätzliche
Kandidatenlesung für nachweislich unvollständige Bereiche beziehungsweise eine
separate Tabellenprüfung. Dafür müssen die bisherigen Negativkontrollen und
einzelnen Verlustfälle mitgeprüft werden; ein höherer Gesamtscore allein reicht
nicht. Der vorhandene Original- und Belegschutz bleibt dabei zwingend.

Keine Produktivinstallation, Archivmigration, Freigabeänderung oder Veröffentlichung
ist Teil dieser Iteration. Das parallel erstellte Release 0.14.1 enthält diese
noch uncommitteten OCR-Änderungen nicht.
