# Lokaler Vergleich: Docling, docling.rs, GLM-OCR und MiniCPM-Jev

**Historischer Zeilentest V1.** Der anschließende
[deutsche Mehrseitenvergleich V2](german-document-comparison-v2.md) erweitert den
Korpus auf 31 Seiten und verändert das Qualitätsbild. Die folgenden Ergebnisse
und Austauschgates beziehen sich ausschließlich auf den damaligen kleinen Korpus.

Gemessen am 08.11.2026 auf **Apple M1 Pro, 8 CPU-Kernen, 16 GiB Unified Memory,
macOS 27.2 (26B123)**. Vauldy-Ausgangscommit: `f4abac14747be0d4b26fe334b96e5236ccc946c6`.

**Apple Vision bleibt für Vauldy der belegte Standard.** Keine getestete Alternative
verbessert die exakten Felder ohne Verlust bereits richtiger Felder. GLM liefert
teilweise besseren Fließtext, erzeugt aber auch Text ohne Bildbeleg. Jev erkennt
gezielte Zeichenfehler, bestätigt jedoch teilweise unvollständige Ergebnisse.

## Messwerte

| Tatsächlich getesteter Pfad | Exakte Felder | Vollständige Bilder | Verlorene / zusätzliche Apple-Felder | Median je Folgebild | Prozess-RSS-Spitze |
|---|---:|---:|---:|---:|---:|
| Vauldy / Apple Vision | **52/79** | 21/35 | 0 / 0 | **0,18 s** | 0,12 GiB |
| Docling 2.149.0, Python, CPU | 31/79 | 8/35 | 23 / 2 | 1,21 s | 1,95 GiB |
| docling.rs 2.67.1, FFI, CPU | 46/79 | 14/35 | 9 / 3 | 1,60 s | 1,13 GiB |
| GLM-OCR BF16, MLX/Metal | 51/79 | 19/35 | 3 / 2 | 1,32 s | 2,29 GiB |
| MiniCPM-Jev F16, Metal | Prüfer, keine Texterkennung | — | siehe unten | 1,29 s je Kandidat zusätzlich | 4,39 GiB Server |

Median der 34 Bilder nach dem ersten Bild; Jev: 140 Kandidaten. RSS ist **kein
vollständiger RAM-Vergleich des Systems**: Apple-Hilfsdienste werden nicht mitgezählt;
GPU-/Unified-Memory-Zuordnung ist ebenfalls nicht vollständig durch RSS abgedeckt.
MLX meldet zusätzlich **2,99 GiB Peak-Allokation**. Diesen Wert nicht zu RSS addieren:
die Messgrößen können dieselben Speicherbereiche enthalten. Jevs Python-Client
erreichte zusätzlich 0,04 GiB RSS. Modelle liefen nacheinander.

Der erste Apple-Systemaufruf brauchte 58,39 s, danach lag der Median bei 0,18 s.
Eine zweite cachefreie Erkennung aller 35 Bilder reproduzierte **alle 35 Texte und
52/79 Felder identisch**: insgesamt 7,27 s, Median 0,21 s, erster Aufruf 0,67 s.
Der erste langsame Aufruf ist separat dokumentiert; seine Ursache ist nicht belegt.
Docling-Python: 28,24 s Import/Initialisierung plus 2,51 s erstes Bild.
Rust-FFI: 0,72 s Bibliotheksinitialisierung plus 2,10 s erste Konvertierung;
die FFI erzeugt pro Aufruf einen Converter, ihre Ladeanteile sind in den Zeiten enthalten.
GLM: 6,87 s Initialisierung plus 4,52 s erstes Bild. Jev: 10,23 s bis Serverbereitschaft.
Downloads und Installation zählen nicht als Inferenzzeit.

## Qualität und Grenzen des Korpus

Primärmaß bleibt der vorhandene Vertrag: **35 per SHA-256 eingefrorene PNGs,
79 vollständige, wörtliche Sollfelder**, ohne tolerantere Kennungs- oder Zahlengrenzen.
Die Bilder enthalten schwierige kleine, blasse, verrauschte und gedrehte deutsche
Zeilen. Solltexte wurden keinem OCR-Modell als Prompt gegeben. GLM erhielt allein
das Bild und den konstanten Prompt `Text Recognition:`, Temperatur 0, maximal 1024
Tokens. Kein Hauptlauf erreichte diese Tokenbegrenzung.

Der Korpus verwendet ASCII-Umschreibungen wie `fuer`. Er ist **kein Nachweis für
allgemeine deutsche Archiv-, Tabellen-, Handschrift-, Mehrseiten- oder IDP-Qualität**.
Docling ist ein Parser mit OCR-Backend, kein einzelnes OCR-Modell. Seine hier
gemessene Ausgabe umfasst auch Layout-/Serialisierungseffekte.

Eine ergänzende, nachträglich definierte Zeichen-/Wortfehlerauswertung nutzt den
unabhängigen Quelltext aus `LineScan.write`: Überschrift plus Sollzeilen. NFC,
Entfernung von Markdown-Überschriftmarkern und Zusammenfassung von Leerraum;
keine Korrektur von Buchstaben, Großschreibung oder Interpunktion. Über 3354
Quellzeichen beträgt die Zeichenfehlerrate: Apple **24,84 %**, Docling-Python
**25,67 %**, Rust **28,71 %**, GLM **16,46 %**. GLM hat damit weniger Zeichenfehler,
obwohl es drei zuvor vollständig richtige Felder verliert. Diese deskriptive
Zusatzmetrik ersetzt das unveränderte Feldgate nicht.

Konkrete Befunde:

- GLM liest `Policennummer: IO0O-171` korrekt, verliert aber unter anderem ein
  bereits korrektes `Beitrag: 82,47 EUR` und schreibt einmal `fuel` statt `fuer`.
- Auf `grid-11-93-15.png` erzeugt GLM etwa „Robustes Fertilisierendes Rezept“;
  die Quelle enthält stattdessen Zeilen zu Fahrrad/Hausrat und Heizungswartung.
- Rust fügt teilweise doppelte Textfragmente ein. In `clean.png` stehen zusätzlich
  etwa ein isoliertes `VX-739245` und `Beitrag:` neben den vollständigen Zeilen.
- Fünf **getrennte Zusatzkontrollen**, nicht in die 79 Felder eingerechnet:
  zwei deutsche Umlaut-/ß-/€-Vorlagen und drei echte Leer-/Rauschbilder.
  Apple, Python-Docling und GLM erreichen 10/10 Zusatzfelder; Rust 9/10 wörtlich
  (ein Feld wird durch einen Absatz getrennt). Apple und beide Docling-Pfade
  lassen alle Leerbilder leer. **GLM erzeugt auf allen drei `www.ibm.com`.**

## MiniCPM-Jev als Prüfer

Verwendet: offizieller F16-GGUF und F16-Visionprojektor, llama.cpp `b12110`,
Commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8`; Metal, ein Slot, 8192 Kontexttokens,
zwei CPU-Threads. Keine Quantisierung, keine Textgenerierung und kein Cloud-Aufruf.

Die drei unveränderten offiziellen Referenzfälle wurden mit ihren mitgelieferten
Original- und Renderbildern geprüft. Alle liegen innerhalb der vorgeschriebenen
Abweichung von 0,02: **0,00467 / 0,00106 / 0,00017**. Der Server erkennt den
Modelltyp `openbmb-minicpm-ocr-jev` und liefert zwei Klassenwahrscheinlichkeiten.

Danach wurden alle **140 tatsächlichen OCR-Texte** bewertet. Für unseren Korpus
wurden die unveränderten Texte mit Pillow 12.3.0 und Arial 24 px als wörtlicher Text
gerendert; Font- und Render-Prüfsummen sind gespeichert. Dies ist eine eigene
macOS-Konfiguration, **nicht** der offizielle Linux-/Chromium-/Markdown-Renderer.
Absolute Korpusscores sind daher nicht mit veröffentlichten Modellbenchmarks
gleichzusetzen. Insbesondere Markdown wird hier wörtlich gerendert.

Die Auswahl des höchsten Scores pro Bild erfolgt ohne Sollwertwissen und ergibt
**54/79**, mit drei zusätzlichen und **einem verlorenen** Apple-Feld. Gewählt:
25-mal Apple, 9-mal GLM und einmal Rust. Auch diese Auswahl verfehlt das Gate
„mehr als 52 richtige Felder und kein verlorenes bisheriges Feld“.

Bei einem rein diagnostischen Schwellenwert von 0,5 passieren **31 von 78
feldunvollständigen Kandidaten**; nur 22 von 62 feldvollständigen Kandidaten
passieren. AUROC für Feldvollständigkeit: **0,587**. „Feldvollständig“ bedeutet
hier nur, dass alle Sollfelder vorkommen, nicht dass jedes zusätzliche Wort korrekt
ist. Die 140 Kandidaten sind korrelierte Ausgaben von 35 Bildern.

Sechs explizite Kontrollpaare enthalten den bekannten synthetischen Quelltext
bzw. einen absichtlich veränderten Buchstaben/eine Ziffer. Jev ordnet **6/6 Paare**
richtig; sämtliche fehlerhaften Varianten liegen unter 0,0001. Zwei korrekte
Kontrolltexte liegen dennoch unter 0,5. Ein guter Zeichenfehlerprüfer ist somit
noch kein verlässlicher Vollständigkeitsnachweis. Die Kontrolltexte zählen nicht
als OCR-Verbesserung.

## Konkrete Modelle und Lizenzen

| Komponente | Gepinnter Stand / tatsächlich verwendete Lizenz |
|---|---|
| Docling / docling-slim | 2.149.0, MIT; Core 2.106.0, IBM-Models 4.0.4 und Parse 7.24.2 ebenfalls MIT |
| docling.rs / FFI | 2.67.1, Commit `1f9424bcaa813eb315984bcec144b307a434f09d`, MIT |
| Heron-Layout | `docling-project/docling-layout-heron@8f39ad3c0b4c58e9c2d2c84a38465abf757272d8`, Apache-2.0; Python Safetensors / Rust ONNX |
| TableFormer Python | `docling-project/docling-models@fc0f2d45e2218ea24bce5045f58a389aed16dc23` (`v2.3.0`), Modellkarte CDLA-Permissive-2.0 |
| TableFormer Rust-ONNX | Upstream `2199320848bb9a8a519d22e4b528185a4f9a6f64`; Release-Notice nennt CDLA-Permissive-2.0 und Apache-2.0; beide Hinweise erhalten |
| RapidOCR / PP-OCRv6 small | RapidOCR 3.10.0, Apache-2.0; deutsche Auflösung `iso:de`, ONNX-Runtime 1.31.1 (MIT). Detektor und Erkenner beider Docling-Pfade sind byteidentisch; Modell-/Wörterbuchlizenzen Apache-2.0 |
| Docling-Tensorbackend | PyTorch 2.15.0, mehrteilige Apache-/BSD-/MIT-/weitere Notices laut Inventar; Torchvision 0.29.2, BSD. Die Wheel-Lizenztexte wurden vollständig erfasst |
| GLM-OCR-Gewichte | Original `zai-org/GLM-OCR@2e85a62840ccac27daa451df36c736c4636b8628`, MIT laut Modellkarte; MLX-BF16-Konvertierung `mlx-community/GLM-OCR-bf16@24f15402e83baa0a80eeeaecf5480e172abc6f2e`, MIT laut Modellkarte |
| GLM-Ausführung | mlx-vlm 0.7.12, MLX/MLX-Metal 0.32.4, MIT; Transformers 5.22.2 Apache-2.0. Der GLM-SDK-Code ist Apache-2.0, wurde aber nicht installiert/benutzt |
| MiniCPM-Jev-Gewichte | Original `openbmb/MiniCPM-OCR-Jev@a0ed278eb6aa1f333a711665ab610055a4a816ab`, Apache-2.0; offizieller GGUF `6bd2b4b932bbab92de97cea4cc6a754db96fc848`, Apache-2.0 |
| Jev-Scoring-Code / llama.cpp | OpenBMB `b40c34d6a17f1fe609b7b7a8007f47e94ff244dc`, Apache-2.0; llama.cpp genannter Commit, MIT samt archivierten Vendor-Notices |
| Apple Vision | Proprietärer Bestandteil von macOS/Apple-SDK; keine separat weiterverteilten OCR-Gewichte, kein Open-Source-Lizenzversprechen |

Primärbelege: [Docling MIT](https://github.com/docling-project/docling/blob/main/LICENSE),
[Rust-Modellnotices](https://github.com/docling-project/docling.rs/blob/v2.67.1/docs/MODELS_NOTICE.md),
[GLM-Modellkarte](https://huggingface.co/zai-org/GLM-OCR/blob/2e85a62840ccac27daa451df36c736c4636b8628/README.md),
[MLX-Konvertierung](https://huggingface.co/mlx-community/GLM-OCR-bf16/blob/24f15402e83baa0a80eeeaecf5480e172abc6f2e/README.md),
[Jev-GGUF](https://huggingface.co/openbmb/MiniCPM-OCR-Jev-gguf/blob/6bd2b4b932bbab92de97cea4cc6a754db96fc848/README.md).
Die GLM-Gewichtsrepositories enthalten keine separate LICENSE-Datei; ihre gepinnten
Modellkarten erklären MIT ausdrücklich. Vor Mitlieferung Originalattribution
und Lizenztext im eigenen Paket sicherstellen.

### Abhängigkeiten und Weitergabe in Vauldy

Erfasst wurden **107 Python-Distributionen für Docling, 75 für MLX und 21 für die
separate Jev-Umgebung**: Version, Lizenzmetadaten, deklarierte Abhängigkeiten und
Hashes der Notice-Dateien. Das ist der installierte Umfang; nicht jede installierte
Distribution wurde bei jeder Konvertierung geladen. Fehlende Wheel-Notices von
FlatBuffers, latex2mathml, Tokenizers und SentencePiece wurden aus passenden
verifizierten Quellveröffentlichungen ergänzt. Docling selbst ist ein Metapaket;
die gleichversionierte docling-slim-Distribution enthält den MIT-Text.

Zusätzlich wurden **alle 691 Einträge des exakten Rust-Workspace-Lockfiles** gegen
Registry-Prüfsummen und Lizenzangaben aufgelöst. Diese konservative Liste umfasst
auch andere Plattformen, Build-, Test- und optionale Features; sie ist **keine
verifizierte Liste ausschließlich der in der Release-Binärdatei enthaltenen Crates**.

Konkrete Befunde für eine spätere kommerzielle Auslieferung:

- MIT, BSD, Apache-2.0 und CDLA-Permissive-2.0 der aufgeführten Hauptkomponenten
  gestatten grundsätzlich kommerzielle Nutzung unter ihren Bedingungen.
  Lizenz-/Copyrighttexte und erforderliche NOTICE-Angaben gehören ins Paket;
  Änderungen und die getrennten Gewichtsbedingungen müssen berücksichtigt werden.
- **OpenCV-Wheels 5.0.0.93:** Python-Wrapper/OpenCV Apache-2.0, aber tatsächlich
  verlinkte FFmpeg-Bibliotheken und weitere macOS-Bibliotheken mit **LGPL-2.1**-
  Hinweisen. Eine reine Apache-2.0-Deklaration für das Gesamtwheel wäre falsch.
- **SciPy 1.18.1:** BSD-Hauptlizenz, tatsächlich mitgelieferte `libquadmath`
  LGPL-2.1-or-later sowie GCC-Runtimes GPL-3.0-or-later mit GCC-Runtime-Ausnahme.
  Dieselben Runtime-Hinweise stehen auch in NumPy-Notices. Die Runtime-Ausnahme
  nicht als pauschale GPL-Freiheit oder als GPL-Pflicht der ganzen App interpretieren.
- **Certifi 2026.10.23:** MPL-2.0; **tqdm 4.70.1:** MPL-2.0 AND MIT. Im Rust-Lockfile
  außerdem 17 MPL-2.0-Einträge, u. a. CSS-Parser/Selectors und Symphonia-Codecs.
  Bei Weitergabe Datei-/Quelltextpflichten der tatsächlich enthaltenen Komponenten
  prüfen; bloßes Beilegen des MIT-Hauptprojekttexts reicht nicht.
- **`auto_generate_cdp 0.4.6`:** Registry nennt „non-standard“, das per Lockfile-Hash
  geprüfte Quellarchiv enthält tatsächlich einen **GPL-v3-Lizenztext**.
  Das ist der optionale Browser-Codegenerator über `headless_chrome`;
  `web-browser` ist im getesteten FFI und in der CLI-Featureliste nicht aktiviert.
  Daraus folgt keine belegte GPL-Pflicht für den getesteten OCR-Pfad. Ein späterer
  Browser-Build und die Rechte am generierten Code benötigen eine eigene Prüfung.
- Der **nicht benutzte GLM-SDK-Installationspfad** deklariert `pymupdf>=1.24.0`.
  Er ist deshalb kein austauschbarer Ersatz für den hier geprüften direkten MLX-Pfad;
  die Lizenz des dann tatsächlich installierten PyMuPDF-Artefakts wäre separat zu prüfen.

Ergebnis: Der lokale Versuch ist durchführbar; eine kommerzielle Paketierung ist
an die konkrete Zusammenstellung und deren Lizenzpflichten gebunden. Dieser
Bestandsnachweis ersetzt keine abschließende Freigabe eines noch nicht erstellten
Vauldy-Bundles mit eingebetteten Fremdbibliotheken.

## Nachweise und Reproduktion

- [Maschinenlesbarer vollständiger Messnachweis](quality/local-idp-comparison-2026-11-08.json)
  mit allen Texten, Timings, verlorenen Feldern, Jev-Scores und Artefakt-Hashes.
- [Konkrete Lizenzinventare und Versionslisten](quality/local-idp-licenses/).
- [Auswertungsskript](../scripts/mcp/local_idp_comparison.py) und
  [Worker-/Reproduktionsanleitung](../scripts/mcp/local_idp_benchmark/README.md).
- Isolierter Arbeitsordner: `/private/tmp/vauldy-local-idp-20261108-9kzyjdam`.
  Gewichte und Umgebungen verbleiben dort; das Beleg-ZIP enthält keine Gewichte.

Alle 35 Hauptbilder, fünf Zusatzbilder und heruntergeladenen Artefakte wurden erneut
per Hash geprüft. 40 relevante Swift-Dateien stimmen mit den wiederverwendeten
Release-Objekten aus dem vorherigen Buildstand überein. Es wurde keine neue
Swift-Suite behauptet: der native Produktions-OCR-Einstieg wurde direkt aufgerufen.
Ein erster Lauf mit vollständig gesperrtem Benutzerordner lieferte systembedingt
unlesbare Seiten und wurde verworfen. Der gültige Apple-Lauf erlaubte Systemdateizugriff
bei gesperrtem Netzwerk. Modellworker sperrten zusätzlich den Benutzerordner.
Jevs Server akzeptierte ausschließlich Loopback-Verbindungen. Lokale Caches lagen
im eigenen Testordner. Produktionsarchive, Anbieter, Freigaben und App-Bundles
wurden nicht verändert; keine Dokumente wurden hochgeladen.

Zwei Integritätstests bestanden: veränderte Bildbytes werden vor der Auswertung
abgewiesen; ein Jev-Score mit abweichendem Texthash wird ebenfalls abgewiesen.
Die vollständige Auswertung und `git diff --check` bestanden. Die Datenprüfung
besteht, während die Qualitätsgates der Alternativen ausdrücklich **NO-GO** bleiben.

Nächster sinnvoller Schritt: Apple beibehalten; GLM/Jev nur als getrenntes Experiment
an einem unabhängig annotierten deutschen Dokumentkorpus mit Tabellen, echten
Umlauten, Leerbildern und explizit markierten Auslassungen weiterbewerten.
Ein Status „modellvalidiert“ darf aus den jetzigen Jev-Scores nicht entstehen.
