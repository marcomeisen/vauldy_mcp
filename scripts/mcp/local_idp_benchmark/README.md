# Isolierter lokaler IDP-Benchmark

Diese Worker installieren und laden keine Modelle herunter und ändern keinen Vauldy-Bestand.
Ergebnisse und Grenzen stehen in `docs/local-idp-comparison.md`; die Versions-/Lizenzinventare
liegen in `docs/quality/local-idp-licenses`. Alle Modellgewichte bleiben außerhalb des Repositories.

Der ausgeführte Arbeitsordner ist `/private/tmp/vauldy-local-idp-20261108-9kzyjdam`.
Das separate Beleg-ZIP enthält seine Eingaben, Ergebnisse, Quell-/Downloadmetadaten,
Installationsberichte mit Wheel-Hashes, Notices und Startskripte, aber keine Gewichte,
ausführbaren Fremdbinärdateien oder virtuellen Umgebungen. Alle Dokumente sind synthetisch;
die drei unveränderten Jev-Kalibrierfälle stammen aus dem gepinnten Upstream-Repository.

## Wiederholen

1. Belege in einen isolierten temporären Ordner entpacken. Die 35 Haupt-PNGs müssen zum
   versionierten Manifest passen. Fünf Zusatzkontrollen bleiben eine eigene Auswertung.
2. Die getrennten Python-3.12-Umgebungen anhand der drei `*-requirements.txt` und der
   Installationsberichte herstellen. Modelle/Binärdateien vor der Offline-Messung anhand
   der archivierten, versionsgebundenen URLs beschaffen. SHA-256, Dateigrößen und Modellkarten
   prüfen. `licenses/artifact*.json` nennt portable `relativePath`-Ziele; `path` dokumentiert
   nur den historischen Downloadort. Die Docling-FFI-/llama-Release-Metadaten liegen ebenfalls
   im Belegpaket. Die `tableformer`-Unterstruktur muss die ONNX-Sidecars neben ihren Graphen
   enthalten. Keine unversionierte Auto-Download-Fallbackkonfiguration verwenden.
3. Für Apple die drei Vauldy-Core-Objekte mit identischem Quellstand in einem isolierten
   Release-Build erzeugen und `AppleProbe.swift` dagegen linken. Der tatsächlich verwendete
   Build hatte 40 byteidentische Core-/Document-Swift-Dateien; Prüfsummen stehen im Nachweis.
   Der Probeaufruf ist `apple-probe ROOT [input|warm|controls]`; `cacheRoot` bleibt nil.
4. Modellworker: `PYTHON ocr_worker.py ROOT docling-py|docling-rs|glm [input|controls]`.
   Das ZIP archiviert die tatsächlich ausgeführten Varianten als `source/ocr-worker.py`
   und die Umgebungs-/Sandboxoptionen in `source/run-supplemental.py` bzw. den Konfigurations-
   und Messdateien. Für Hauptläufe dasselbe Profil verwenden, den Suiteparameter weglassen.
   CPU-Threads: zwei. Keine OCR-Engines parallel betreiben. Modellinitialisierung ist ein
   eigener Messpunkt; das erste Bild bleibt getrennt von den Folgebildern.
5. Jev: `venv-jev/bin/python jev_benchmark.py ROOT`. Erwartet die archivierte, gepinnte
   OpenBMB-Quellstruktur unter `source/jev`. Es startet nur einen eigenen Loopback-Server,
   prüft zuerst alle drei offiziellen Kalibrierfälle und beendet ihn im `finally`-Pfad.
   Bei gescheiterter Kalibrierung werden keine Korpusscores erzeugt. Die sechs künstlichen
   Fehlerpaare sind Diagnostik, keine erkannten Dokumente. Die Pillow-Renderkonfiguration
   ist absichtlich als eigener Versuch gekennzeichnet; sie ersetzt keinen Upstream-Renderer.
6. Auswertung aus dem Repository:

   ```sh
   python3 scripts/mcp/local_idp_comparison.py --root /private/tmp/DEIN-TESTORDNER --output /private/tmp/dein-messnachweis.json
   ```

Die Auswertung prüft Original-/Modellhashes, vollständige Fallzahlen, native Cachefreiheit,
GLM-Tokenbegrenzung, Jev-Kalibrierung und die Bindung der Scores an die tatsächlichen Texte.
Sie wählt Kandidaten nur anhand der Scores; Sollwerte werden erst danach zur Bewertung benutzt.
Das Feldgate verlangt mehr als 52 exakte Felder und keinen verlorenen Apple-Treffer.

## Interpretation

Docling-Python wurde auf CPU mit RapidOCR `iso:de`, Heron, TableFormer und vollständiger
Seiten-OCR getestet. Rust verwendete die FFI mit explizitem multilingualem v6-Erkenner und
Wörterbuch; der CLI-Sprachschalter ist dadurch übersteuert. Die Detektor-/Erkennerbytes sind
dieselben wie bei Python, aber Konvertierungs-/Layoutpfad und TableFormer-Revisionen unterscheiden
sich. Das ist ein Pipelinevergleich, kein isolierter Vergleich von Python und Rust als Sprachen.
MPS/CoreML, andere Modelle, Prompts, Quantisierung oder Bildtransformationen wurden nicht getestet.

RSS enthält nicht alle Apple-Service-/GPU-Speicherbereiche. MLX-Speicher nicht auf RSS addieren.
Ein einzelner Lauf auf einem benutzten Mac begründet keine allgemeine Leistungszusage.
Der vollständige Bericht benennt Lizenzpflichten und die noch fehlende binärspezifische
Rust-SBOM; ein MIT-Hauptprojekt bedeutet keine reine MIT-Lizenz des gesamten Installationspakets.

## Deutscher Mehrseitenkorpus V2

Der anschließende Vergleich steht in `docs/german-document-comparison-v2.md`.
Sein Arbeitsordner ist `/private/tmp/vauldy-german-docs-v2-lx9hv1gd`. Modelle und
die drei OCR-/Jev-Umgebungen werden unverändert aus dem oben genannten V1-Ordner
referenziert; neue Renderabhängigkeiten sind separat inventarisiert.

1. `german_document_corpus.py --help` beschreibt die Erzeugung. Die ausgelieferten
   `corpus/frozen`-Dateien sind die maßgebliche Eingabe: 15 Raster-PDFs, 31 PNG-Seiten,
   `manifest.json` mit Sollwerten und `requests.json` ohne Solltexte. Erneutes Rendern
   auf einer anderen Schrift-/Bibliotheksversion kann andere Bytes erzeugen.
2. Native Probe: `GermanPDFProbe.swift` gegen die drei identischen Vauldy-Module
   linken; Aufruf `german-pdf-probe ROOT`. `cacheRoot` ist nil. Die Build-/Quellhashes
   stehen unter `source/` im Belegpaket.
3. `german_pdf_worker.py ROOT docling-py|docling-rs|glm` verarbeitet alle PDFs bzw.
   deren pixelidentische Seitenbilder in der eingefrorenen Reihenfolge. Die
   tatsächlich verwendeten Sandboxprofile und Prozessaufrufe stehen in
   `source/run_german_pdf*.py`. Engines seriell ausführen. Die anfänglich wegen
   Font-Verzeichnisrechten gescheiterte Python-Ausführung ist separat archiviert.
4. `german_glm_tables.py ROOT` ist ausschließlich die zusätzliche Tabellen-Diagnostik
   mit vorgegebenen Regionen. Sie darf die Vollseiten-Hauptergebnisse nicht ersetzen.
5. `render_german_jev.py ROOT` rendert 124 unveränderte OCR-Ausgaben und 112 getrennte
   Fehler-/Referenzkontrollen mit dem gepinnten Upstream-Renderer. Benötigt die
   Renderumgebung, das archivierte `source/jev` und vorhandenes Chrome; keine
   bestehende Browser-Session verwenden. Sandboxprofile erlauben ausschließlich
   notwendige temporäre Unix-Sockets, keinen externen Netzwerkzugriff.
6. `german_jev_benchmark.py ROOT` startet den eigenen Loopback-Server, kalibriert
   zuerst an drei offiziellen Fällen und bewertet dann alle 236 Renderpaare mit
   einheitlich maximal 1024 Bildtokens je Bild. Der frühere unbeschränkte Pilot
   gehört nicht in diese Qualitätsauswertung. Jev ist ein Prüfer, kein OCR-Erkenner.
7. Vollständige Auswertung und Prüflauf aus dem Repository:

   ```sh
   python3 scripts/mcp/german_document_comparison.py --root ROOT --output Ergebnis.json --require-jev
   VAULDY_GERMAN_CORPUS_ROOT=ROOT PYTHONDONTWRITEBYTECODE=1 python3 scripts/mcp/german_document_comparison_test.py
   ```

Der Prüflauf weist unter anderem veränderte PDF-Bytes, verlorene physische Seiten,
Scores für fremde Texte und ungültige Wahrscheinlichkeiten ab. Das V2-Feldgate
verlangt mehr als Apples 132 exakte Label-Wert-Texte, keinen verlorenen Apple-Treffer
und keine neue Leerbild-Ausgabe. Das ist keine fachliche IDP- oder Produktabnahme.
