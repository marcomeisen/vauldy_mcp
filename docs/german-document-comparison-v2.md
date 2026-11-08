# Deutscher Dokumentkorpus und lokaler OCR-/IDP-Vergleich V2

Stand: 08.11.2026. Apple M1 Pro, 8 CPU-Kerne, 16 GiB Unified Memory,
macOS 27.2 (26B123). Vauldy-Quellstand `f4abac14747be0d4b26fe334b96e5236ccc946c6`.

**Der breitere Korpus verändert das Ergebnis gegenüber dem alten Zeilentest:**
GLM-OCR liefert hier den besten fortlaufenden Text und alle 133 wörtlichen
Label-Wert-Angaben. Apple liefert diese Angaben fast vollständig und verarbeitet
die Inhaltsseiten im Median erheblich schneller. Docling liefert zusätzlich
Tabellenzellen mit expliziten Zeilen- und Spaltenpositionen.

## Neuer Korpus

15 ausschließlich synthetische Raster-PDFs mit 31 physischen Seiten:
12 Dokumente mit jeweils zwei oder drei Inhaltsseiten und drei separate
Leer-/Rauschkontrollen. Die PDFs enthalten keine Textebene. Die Pixel der einen
eingebetteten RGB-Grafik jeder Seite stimmen per Hash mit der jeweiligen PNG-Seite
überein. Originaldateien und Sollwerte wurden vor der Erkennung eingefroren.

| Dokument | Art | Seiten |
|---|---|---:|
| doc-001 | Werkstattrechnung mit Arbeitsnachweis | 2 |
| doc-002 | Versicherungsschein, Leistungen und Nachtrag | 3 |
| doc-003 | Kontoauszug und Entgeltübersicht | 2 |
| doc-004 | Mietvertrag, Kaution und Übergabeprotokoll | 3 |
| doc-005 | Betriebs-/Heizkostenabrechnung | 3 |
| doc-006 | Stromabrechnung und Abschlagsplan | 2 |
| doc-007 | Entgeltabrechnung und Arbeitszeitbescheinigung | 2 |
| doc-008 | Steuerbescheid mit Berechnung und Erläuterungen | 3 |
| doc-009 | Arztbefund und Laborwerttabelle | 2 |
| doc-010 | Schulzeugnis und Lernentwicklung | 2 |
| doc-011 | Mobilfunkrechnung und Einzelverbindungsnachweis | 2 |
| doc-012 | Gebührenbescheid und Zahlungszuordnung | 2 |

Der Bestand enthält **133 unterschiedliche Label-Wert-Solltexte**, 19 explizite
Tabellen mit 356 Zellen, davon **345 befüllt**, und 25.506 Quellzeichen. Dazu gehören
ä/ö/ü/Ä/Ö/Ü/ß, Akzente, €, negative Beträge, Dezimalkommas, Tausendertrennzeichen,
Datumsrollen, Kennungen, Uhrzeiten sowie Einheiten wie m³ und 10³/µl.
Schriftfamilien, zweispaltige Bereiche und die Scanprofile klar/leicht gedreht/
aufgehellt mit Unschärfe und ungleichmäßiger Belichtung variieren.

Die vollständigen Quellen und Annotationen stehen im
[Manifest](quality/german-document-corpus-v2-2026-11-08.json). Der
[Generator](../scripts/mcp/german_document_corpus.py) enthält ausschließlich
selbst verfasste Testdaten. Das gegenüber dem früheren 17-Text-Korpus breitere
Design ist keine statistisch repräsentative Stichprobe echter Kundenarchive.
Handschrift, Handyfotos, Stempelüberlagerungen, gemischte Dokumentstapel und
über Seiten fortgesetzte Tabellen sind nicht abgenommen.

## Vollständige Hauptläufe

| Lokaler Pfad | Label + Wert wörtlich | Zeichenfehlerrate | Tabelleninhalte als Text | Explizite Zellen an richtiger Position | Median s/Inhaltsseite | Prozess-RSS-Spitze |
|---|---:|---:|---:|---:|---:|---:|
| Vauldy / Apple Vision | 132/133 | 10,20 % | 311/345 | nicht ausgegeben | 0,61 | 1,25 GiB |
| Docling Python 2.149.0, CPU | 130/133 | 4,48 % | 338/345 | 338/345 | 2,43 | 2,61 GiB |
| docling.rs 2.67.1, CPU/FFI | 125/133 | 7,50 % | 340/345 | 340/345 | 4,40 | 2,17 GiB |
| GLM-OCR BF16, MLX/Metal, Textmodus | **133/133** | **0,48 %** | **344/345** | nicht ausgegeben | 25,65 | 1,31 GiB |

Jeder Pfad verarbeitete alle 31 physischen Seiten. Kein Hauptlauf erzeugte
sichtbaren Text auf den drei Leerbildern; GLM gab dort lediglich einen leeren
Markdown-Codeblock aus. Keine GLM-Seite erreichte das Limit von 2048 Ausgabetokens.

Die Zeitspalte ist der Median der Dokumentlaufzeit geteilt durch seine Inhaltsseiten,
über zwölf Dokumente. Drei Leerkontrollen und Modellinitialisierung werden dabei
nicht als Inhaltsseiten behandelt. Es handelt sich um je einen seriellen Lauf auf
einem benutzten Mac, ohne MPS-/CoreML-Optimierung der beiden Docling-Pfade.

RSS ist kein vollständiger Vergleich des gesamten RAM-Bedarfs: Apple-Hilfsdienste
und GPU-Zuordnung sind nicht vollständig enthalten. MLX meldet zusätzlich
**3,41 GiB Peak-Allokation**. Diese Zahl darf wegen möglicher überlappender
Speicherbereiche nicht auf RSS addiert werden.

### Erster Aufruf und gesamte Bearbeitungszeit

Die Summe der Dokumentzeiten einschließlich Leerkontrollen beträgt Apple
**106,56 s**, Python-Docling **74,31 s**, Rust **129,07 s**, GLM **786,13 s**.
Zusätzliche gemessene Prozess-/Modellinitialisierung: Python **13,81 s**, Rust
**0,83 s**, GLM **8,28 s**. Installation, Downloads und PDF-Erstellung zählen nicht.

Im ersten inhaltlichen Apple-Dokument dauerte allein Seite eins **90,53 s**;
die Ursache dieses Ausreißers ist nicht belegt. Ein separater cachefreier Nachlauf
derselben zwei Seiten brauchte insgesamt **1,92 s** und lieferte beide Texte
identisch. Die ursprüngliche lange Messung bleibt in der Gesamtsumme enthalten.
Damit ist Apple bei der typischen Folgeseite am schnellsten; der eine gemessene
Gesamtdurchlauf einschließlich dieses Ausreißers war bei Python-Docling kürzer.

## Was die Qualitätszahlen bedeuten

Die 133 Angaben werden als zusammenhängende **Label-Wert-Solltexte auf der richtigen
physischen Seite** geprüft. NFC, sichtbare HTML-/Markdown-Dekoration und Leerraum
werden normalisiert. Schreibweise, Umlaute, Interpunktion, Zahlen und Dezimalkommas
werden nicht repariert. Ein getrennt ausgegebenes Label und ein anderswo vorhandener
Wert erfüllen dieses strenge Textkriterium nicht. Eine fachliche, modellgestützte
Feldzuordnung oder Dokumentklassifikation wurde damit nicht bewertet.

Die Zeichenfehlerrate berücksichtigt auch die Lesereihenfolge. Zur Einordnung wurden
zusätzlich exakte Wort-Vorkommen ohne Reihenfolge deskriptiv verglichen:

| Pfad | Wiedergefundene Wort-Vorkommen | Präzision der ausgegebenen Wort-Vorkommen |
|---|---:|---:|
| Apple | 98,07 % | 98,90 % |
| Python-Docling | 96,44 % | 97,79 % |
| Rust | 99,61 % | 94,81 % |
| GLM Textmodus | 99,65 % | 99,71 % |

Somit bedeutet Apples höhere Zeichenfehlerrate nicht, dass zehn Prozent aller
Zeichen einzeln falsch gelesen wurden: andere Reihenfolgen, besonders in Tabellen,
gehen ebenfalls ein. Rust findet viele Wörter, wiederholt aber teilweise Fragmente.
Diese zusätzliche Wortauswertung verändert weder Sollwerte noch Hauptmetriken.

Konkrete Unterschiede:

- Apple verkürzt die künstliche Fahrgestellnummer `TESTWVWZZZ26K08417` zu
  `TESTWWZZZ26K08417`. GLM liest sie im Hauptlauf korrekt.
- Bei Python fehlen drei zusammenhängende Label-Wert-Stellen, bei Rust acht.
  Das umfasst auch getrennte oder anders zusammengesetzte Ausgaben; es ist kein
  Beweis, dass sämtliche entsprechenden Zeichen im Dokumenttext fehlen.
- Python und Rust erzeugen jeweils **15 von 19 Tabellen vollständig identisch**
  zum erwarteten Zellraster. Zellinhalt und Position werden gemeinsam bewertet;
  reine Wortlisten gelten nicht als rekonstruierte Tabelle.
- Native Vauldy-OCR gibt Text und Geometrie aus, aber kein explizites Tabellenraster.
  GLMs Hauptlauf mit `Text Recognition:` gibt hier ebenfalls flache Tabellenzeilen aus.
  Für beide wird keine Tabellenstruktur aus den Sollwerten nachträglich erfunden.

Gegenüber Apple gewinnt Python eine bisher fehlende Angabe und verliert drei;
Rust gewinnt eine und verliert acht; GLM gewinnt eine und verliert keine.
GLM erfüllt damit **in diesem Korpus** das Feldgate „mehr korrekte Angaben,
keine verlorene Apple-Angabe und keine neue Leerbild-Halluzination“.
Das ist keine Abnahme für beliebige Dokumente oder eine Produktintegration.

Die wörtlichen Angaben nach Dokumentart (jeweils ein synthetisches Dokument;
keine geschätzte Trefferquote für die ganze Dokumentklasse):

| Dokumentart | Apple | Docling Python | docling.rs | GLM |
|---|---:|---:|---:|---:|
| Werkstattrechnung | 9/10 | 10/10 | 9/10 | 10/10 |
| Versicherungspolice | 14/14 | 14/14 | 14/14 | 14/14 |
| Kontoauszug | 9/9 | 7/9 | 9/9 | 9/9 |
| Mietvertrag | 15/15 | 15/15 | 13/15 | 15/15 |
| Nebenkostenabrechnung | 15/15 | 15/15 | 15/15 | 15/15 |
| Stromabrechnung | 10/10 | 10/10 | 10/10 | 10/10 |
| Lohnabrechnung | 10/10 | 10/10 | 10/10 | 10/10 |
| Steuerbescheid | 13/13 | 13/13 | 13/13 | 13/13 |
| Arztbefund | 9/9 | 9/9 | 7/9 | 9/9 |
| Schulzeugnis | 9/9 | 9/9 | 8/9 | 9/9 |
| Telekommunikationsrechnung | 9/9 | 8/9 | 8/9 | 9/9 |
| Gebührenbescheid | 10/10 | 10/10 | 9/10 | 10/10 |

## Getrennter GLM-Tabellenmodus

Zusätzlich wurde der offizielle Prompt `Table Recognition:` an allen 19 Tabellen
getestet. Die Regionen stammen aus den bereits eingefrorenen Annotationen, mit
festem Randabstand. **Das ist ein Versuch mit vorgegebenen Regionen, kein Test
eines automatischen Tabellendetektors.** Er ersetzt keine Hauptlauf-Ausgabe.

Ergebnis: **243/345 Zellen** mit wörtlich korrektem Inhalt an korrekter Position,
**4/19 vollständige Raster**, Median **3,12 s pro Tabellencrop**. Eine Tabelle
wird trotz Tabellenprompt nur als flacher Text ausgegeben.

Die strenge Metrik zählt beispielsweise `86.000,00€` gegenüber `86.000,00 €` als
Abweichung. Eine getrennte nachträgliche Betrachtung ohne Leerzeichen ergibt
**311/345** Positionszellen: **68** Abweichungen betreffen nur Leerraum. Diese
Zusatzbetrachtung lockert das Hauptkriterium nicht. Für 20 Zellen fehlt ein
ausgegebenes Raster; daneben bleiben 14 Abweichungen von Zeichen oder Position.

Darunter sind relevante Zahlenfehler im Laborbeispiel: **`13,8` wird `138`,
`6,42` wird `642`, `0,81` wird `081`**. Dieselbe Tabelle wird im vollständigen
Textmodus deutlich zuverlässiger transkribiert. Der spezialisierte Prompt liefert
hier also keine pauschal bessere oder fachlich sichere Tabellenextraktion.

## MiniCPM-Jev: vollständiger Prüflauf

Jev ist **kein zusätzlicher OCR-Erkenner**. Alle **124 tatsächlichen Ausgaben**
(vier Erkenner × 31 physische Seiten) und **112 getrennte Referenz-/Fehlerkontrollen**
wurden ohne Scoringfehler geprüft. Die drei offiziellen Kalibrierfälle bestanden.
Kein Kontrolltext wurde als erkannter Text oder Qualitätsgewinn mitgezählt.

Bei Auswahl des höchsten Jev-Scores je Seite ergeben sich **133/133 Angaben**, kein
verlorener Apple-Treffer und keine Leerbild-Ausgabe. Gewählt wurden 13 GLM-, elf
Python-Docling-, eine Rust- und sechs Apple-Seiten. Gleichstände folgen der vorab
festen Engine-Reihenfolge. Die Auswahl benutzt keine Sollfelder. Ihre
Zeichenfehlerrate beträgt **0,79 %**, gegenüber **0,48 %** für GLM allein; ein
zusätzlicher Feldgewinn gegenüber GLM ist in diesem Korpus nicht nachgewiesen.

Die folgenden Kontrollen verändern pro Inhaltsseite nur die zu prüfende Ausgabe.
Das Scanbild bleibt unverändert. Die Schwelle 0,5 ist **Diagnostik**, keine auf
Kundendokumenten kalibrierte Freigabeschwelle:

| Kontrollausgabe | Anzahl | Bei Score ≥ 0,5 akzeptiert | Vollständige Referenz höher bewertet |
|---|---:|---:|---:|
| Vollständiger, vor OCR verfasster Solltext | 28 | 28 | — |
| Ein Zeichen im ersten kritischen Wert falsch | 28 | 0 | 28/28 |
| Erster Fließtextabsatz ausgelassen | 28 | **24** | 24/28 |
| Leere Ausgabe für eine nicht leere Seite | 28 | 0 | 28/28 |

Die Zeichenfehler und komplett leeren Ausgaben werden hier erkannt. Dagegen werden
**24 von 28 absichtlich unvollständigen Texten akzeptiert**. In vier Paaren wird
sogar die Ausgabe mit ausgelassenem Absatz höher bewertet als der vollständige
Solltext. Auch das relative Ranking ist damit kein Vollständigkeitsbeleg.

Unter den tatsächlichen 112 OCR-Ausgaben der 28 Inhaltsseiten liegen 32 mit allen
Prüffeldern über der Schwelle, 69 mit allen Prüffeldern darunter und elf mit
fehlenden Prüffeldern darunter. Keine Ausgabe mit fehlendem Prüffeld liegt darüber.
„Alle Prüffelder vorhanden“ beschreibt nur die 133 wörtlichen Ziele; es sagt nichts
über ausgelassene andere Absätze. Diese unterschiedlichen Prüfziele dürfen nicht
zu einem einzigen Status „modellvalidiert“ zusammengezogen werden.

Laufzeit der 124 tatsächlichen Kandidaten: **5,64 s Median** und **635,28 s gesamt**
zusätzlich zu allen vier OCR-Pfaden. Ihr Rendering benötigt separat **0,52 s Median**
und **61,95 s gesamt**. Die 112 Kontrollen benötigen separat **1214,30 s**; deren
Latenzmedian ist 12,58 s und wird nicht in den OCR-Kandidatenmedian eingemischt.
Serverinitialisierung **2,06 s**, Server-RSS-Spitze **4,88 GiB**, Python-Client
**0,073 GiB**. GPU-/Unified-Memory-Grenzen gelten auch hier. Der Prüfer beendet
seinen eigenen Server nach dem Lauf.

## Verfahren und Nachweise

Alle Gewichte und drei ursprünglichen Python-Umgebungen entsprechen dem
[vorherigen, versionsgebundenen Lizenz-/Modellaudit](local-idp-comparison.md).
42 Downloadartefakte wurden vor dem Lauf erneut gehasht. Native OCR verwendet
dieselben 40 bytegeprüften Vauldy-Core-/Document-Swift-Dateien wie der vorhandene
Release-Build; der Probeprozess ruft den produktiven `NativeLocalDocumentOCR`
direkt mit deaktiviertem Seitencache auf.

Apple und beide Docling-Pfade erhalten dieselben Raster-PDFs. GLM erhält über einen
expliziten Seitenadapter die pixelidentischen Bild-XObjects in physischer Reihenfolge.
Kein Erkenner erhält Dokumentart, Feldliste, Sollwerte oder den Text anderer Erkenner.
GLM arbeitet mit Temperatur 0 und maximal 2048 Ausgabetokens je Seite. Python nutzt
RapidOCR `iso:de`, PP-OCRv6 small, Heron und TableFormer auf CPU mit zwei Threads.
Rust nutzt FFI-JSON, explizite multilingual-v6-Gewichte und FP32/CPU mit zwei Threads.
Die v6-Detektor-/Erkennerbytes beider Docling-Pfade sind identisch; Layoutpfade und
TableFormer-Revisionen unterscheiden sich. Das ist kein isolierter Sprachvergleich
zwischen Python und Rust.

Der erste Python-PDF-Lauf scheiterte am gesperrten Font-Verzeichnis und zählt nicht
zur Qualität. Ein eng begrenzter Verzeichniszugriff korrigierte die Sandbox;
anschließend wurden alle 15 PDFs erfolgreich wiederholt. Das Modell wurde dafür
nicht gewechselt. Die Fehlversuchsdaten bleiben separat erhalten.

Jev verwendet dieselben F16-Gewichte und llama.cpp `b12110`. Der offizielle,
gehashte v8.5-Renderer mit Markdown-/HTML-/KaTeX-Unterstützung wird über eine eigene
temporäre Chrome-Instanz ausgeführt. Die macOS-Systemschriftumgebung ist nicht
identisch mit dem veröffentlichten Linux-Referenzrenderer. Die drei offiziellen
Kalibrierfälle verwenden deshalb unverändert ihre mitgelieferten Renderbilder.
63 benötigte Upstream-Dateien und 20 KaTeX-Fonts wurden gegen Git-Blob-Hashes geprüft.

Der erste unbeschränkte Jev-Pilot brauchte rund 22 s/Kandidat. Für die vollständige
Auswertung gilt einheitlich **maximal 1024 Bildtokens je Bild**, Kontext 32768,
ein Slot, Metal und zwei CPU-Threads. Alle 236 Kandidaten wurden unter diesem
Profil neu geprüft; die fünf Pilotfälle bleiben ausschließlich Laufzeitdiagnostik.
Die offiziellen drei Referenzprüfungen bestehen unter dem begrenzten Profil erneut
innerhalb 0,02 Abweichung. Die Eingabedateien wurden dabei nicht geändert.

Modellprozesse arbeiten mit gesperrtem externem Netzwerk und aufgabeneigenen Caches.
Der Renderer erlaubt nur zusätzlich notwendige Unix-Sockets in temporären Verzeichnissen;
sein bestehendes Nutzerprofil wird nicht verwendet. Jev spricht ausschließlich
mit dem eigenen Loopback-Server. Keine Produktionsarchive, Freigaben, App-Bundles
oder Anbieter wurden verändert; keine Dokumente wurden hochgeladen.

Neue Hilfsabhängigkeiten sind separat inventarisiert: Playwright 1.62.0,
Markdown 3.11.3, Pillow 12.3.0 sowie deren aufgelöste Pakete. Die MIT-Notice des
KaTeX-Renderers liegt bei. Vorhandenes Chrome und Systemschriftdateien werden
nicht mit dem Belegpaket weitergegeben. Das ist kein neues kommerzielles
Vauldy-Bundle mit eingebetteten Modellen oder Bibliotheken.

## Lizenzstand der wiederverwendeten Artefakte

Die konkreten Gewichte sind gegenüber V1 unverändert; ihre Hashes stehen im
Messprotokoll. Die vollständigen versionsgebundenen Belege und Notices bleiben im
[Lizenzinventar](quality/local-idp-licenses/) und im Belegpaket erhalten.

| Bestandteil | Lizenz des geprüften Stands |
|---|---|
| Docling 2.149.0 / docling.rs 2.67.1 | MIT für den jeweiligen Projektcode |
| Heron, RapidOCR / PP-OCRv6 | Apache-2.0 |
| TableFormer | Python CDLA-Permissive-2.0; Rust-Release-Notice zusätzlich Apache-2.0, beide Hinweise erhalten |
| GLM-OCR / MLX-BF16-Gewichte | MIT laut den gepinnten Original-/Konvertierungsmodellkarten |
| MLX / mlx-vlm | MIT; Transformers Apache-2.0 |
| MiniCPM-OCR-Jev / F16-GGUF / Scoring-Code | Apache-2.0; llama.cpp MIT samt Vendor-Notices |
| Apple Vision | Proprietäres macOS-/SDK-Framework |
| Neuer Renderer | Playwright Apache-2.0 samt Drittanbieter-Notices, Python-Markdown BSD-3-Clause, Pillow 12.3.0 MIT-CMU samt beigefügten Bibliotheksnotices, KaTeX MIT; greenlet MIT AND PSF-2.0, pyee und typing_extensions MIT |

Die Hauptprojektlizenzen allein beschreiben kein vollständiges Vertriebspaket.
Im unveränderten Audit sind 107/75/21 installierte Python-Distributionen und
691 Rust-Lockfile-Einträge erfasst. Insbesondere bleiben die LGPL-Anteile der
OpenCV-/FFmpeg-Wheels, SciPy-/NumPy-Runtime-Notices mit GCC-Ausnahme sowie
MPL-Komponenten relevant. Der optionale GPL-v3-Browser-Codegenerator des
Rust-Workspaces ist im geprüften OCR-FFI-Pfad nicht aktiviert. Der direkte MLX-Pfad
installiert nicht den GLM-SDK mit dessen zusätzlicher PyMuPDF-Abhängigkeit.

Lokale Nutzbarkeit und Weitergabe eines späteren Vauldy-Bundles sind getrennte
Fragen: Für dessen konkrete Binärdateien fehlen weiterhin eine auf enthaltene
Komponenten eingegrenzte Rust-SBOM und die abschließende Zusammenstellung aller
erforderlichen Lizenz-/Quelltext-/Relinking-Unterlagen. Dieser Versuch liefert
keine pauschale Freigabe eines solchen künftigen Vertriebspakets.

## Prüfnachweis und Einordnung für Vauldy

- [Vollständige maschinenlesbare Auswertung](quality/german-document-comparison-v2-2026-11-08.json)
  mit Rohtexten, allen Seiten, Dokumentarten, Scanprofilen, Zeiten, Speicherwerten,
  fehlenden Angaben und sämtlichen Jev-Scores.
- [Eingefrorenes Korpusmanifest](quality/german-document-corpus-v2-2026-11-08.json),
  [Auswertung](../scripts/mcp/german_document_comparison.py) und
  [Reproduktionsanleitung](../scripts/mcp/local_idp_benchmark/README.md).
- [Neue Renderer-Lizenzinventare und Herkunftsprüfung](quality/german-document-licenses-v2/),
  zusätzlich zu den unveränderten Modell-/Abhängigkeitsinventaren aus V1.
- Acht Prüfungen der Normalisierung, Feldrollen, Zellpositionen und Datenintegrität
  bestanden. Geänderte PDF-Bytes, verlorene physische Seiten, Scores für andere Texte
  und Wahrscheinlichkeiten außerhalb [0,1] werden abgewiesen. Die vollständige
  Auswertung besteht nur mit allen 124 OCR-Kandidaten, 112 Kontrollen und Kalibrierung.
  Alle 31 PDF-Seiten wurden nach dem Rendern visuell geprüft. `git diff --check` sauber.
- Bereitgestellt: `Vauldy-DE-Testkorpus-v2.zip` und
  `Vauldy-DE-OCR-Vergleich-v2-Belege.zip`. Beide enthalten eigene Eintragshashes;
  CRC und SHA-256 aller Einträge wurden aus den fertigen ZIPs erneut geprüft.

**Empfehlung aus diesem Versuch:** Apple bleibt der schnelle vorhandene Basisweg.
GLM ist der aussichtsreichste Kandidat für einen getrennten Zweitlauf bei schwierigen
Volltexten; es gewinnt hier ein Feld ohne Verlust und senkt die Zeichenfehlerrate,
kostet aber deutlich mehr Laufzeit. Die frühere pauschale Ablehnung aufgrund des
kleinen Zeilentests wäre für diesen Dokumentkorpus nicht zutreffend. Die damaligen
Fehler bleiben als eigene Regressionen erhalten und sind durch V2 nicht widerlegt.

Docling eignet sich hier insbesondere als Kandidat für explizite Tabellenraster.
Seine Zell-/Zeilennachweise müssen separat geprüft werden; das vollständige Dokument
ist damit nicht automatisch korrekt. Für Rust ist in dieser CPU-/FFI-Konfiguration
kein Geschwindigkeitsvorteil gegenüber Python nachgewiesen. Jev liefert keine
belastbare automatische Bestätigung vollständiger Dokumenttexte.

Vor einer produktiven Entscheidung fehlen weiterhin echte, unabhängig annotierte
deutsche Scans und ein zurückgehaltener Testbestand. Die vorhandenen Vauldy-Erkenner,
Prüfstatus, Speicherformate und App-Pakete wurden durch diesen Vergleich nicht geändert.
