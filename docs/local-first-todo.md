# Vauldy Local-First · Entwicklungsstand

Integrationsstand `main` (zuvor Arbeitsbranch `codex/local-first-product-readiness`). Jede Verbindung nutzt den MCP auf dem Mac des jeweiligen Kunden. JSON und das vorhandene Backup bleiben führend. Die Kundenabnahme folgt auf die intern geprüfte lokale Architektur.

Die Weiterentwicklung konzentriert sich auf den eigenständigen Vauldy MCP. Der Chatbot ist die einzige Oberfläche für die Dokumentarbeit. Die Vauldy-Hauptapp ist aus dem Entwicklungsumfang ausgeschieden. Der vorhandene MCP-Einrichtungsassistent ist ein technischer Installations- und Verbindungsweg. Die künftige Einrichtung und Freigabeverwaltung werden separat vom Chatbetrieb festgelegt.

Nach jeder Iteration werden die betreffenden Aufgaben abgehakt und der tatsächliche Prüfnachweis, offene Punkte und der nächste Schritt unten ergänzt. Die Reihenfolge in den offenen Abschnitten gilt als Arbeitsreihenfolge.

## Git-Integration und temporäre Dateien · 08.11.2026

Auf Nutzerauftrag alle vorhandenen Branchänderungen für `main` zusammengeführt: 15 bereits
vorhandene Commits sowie der anschließend versionierte Arbeitsstand. Generiertes `.build/`,
Python-Caches und Finder-Metadaten im MCP-Checkout entfernt. Installationspakete unter `dist/`
und die versionierten fachlichen Prüfnachweise erhalten.

Aktuelle Prüfungen mit synthetischen Beständen:

- 228 Quell-, Test-, Manifest- und Skriptdateien mit der lokalen Buildkopie byteverglichen;
  alle Abhängigkeits-Commits entsprechen `Package.resolved`.
- `swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --no-parallel`:
  308 Tests in 49 Suites ausgeführt. Ein Test scheiterte am fehlenden fest codierten
  `.build/debug/vauldy-local`-Pfad der temporären Release-Buildkopie. Dort den Debug-Pfad
  auf die aktuellen Release-Programme verlinkt und `--filter InventoryWorkflowTests`
  wiederholt: alle 18 Tests bestanden (60,560 s). Keine Swift-Quelländerung dafür erforderlich.
- Echte stdio-Prüfung (`smoke_test.py`), Relay-Werkzeugparität (`export_relay_tools.py --check`),
  Feldauslese, Fassungsvergleich und Fristenübersicht bestanden.
- Alle zehn Relay-Worker-Tests sowie fünf Faint-OCR-Gate-, drei lokale OCR-Konvertierungs-
  und vier Paddle-Konvertierungstests bestanden. Letztere mit vorhandenem Python 3.11/Pillow;
  keine Modelle oder Pakete installiert.
- 57 Python-Skripte syntaktisch und 50 JSON-Prüfberichte auf gültiges JSON geprüft.
  `git diff --cached --check` bestanden; zwei zusätzliche Leerzeilen am Dateiende entfernt.

Die erste Swift-Ausführung im synchronisierten Checkout scheiterte am gesperrten Modulcache;
ein weiterer Versuch hing bei der Git-Prüfung einer synchronisierten Abhängigkeit. Diese
Versuche zählen nicht als bestanden. Die erfolgreichen nativen Prüfungen liefen in der
bytegeprüften lokalen Buildkopie mit getrennten Modulcaches. Der gesamte Paket-/UI-Regressionsrunner
und eine neue Zielchat-Abnahme wurden für diesen Git-Abschluss nicht ausgeführt.

Nächster fachlicher Schritt bleibt die nachfolgend beschriebene Paket-/Discovery-Aktualisierung
für das Dokumentinventar und die getrennte synthetische Zielchat-Abnahme.

## Dokument-ID, Importzeitpunkt und Inhalts-Hash · 08.11.2026

Fortschritt: **im MCP-Branch implementiert und mit synthetischen Beständen bis
20.000 Dokumente geprüft.** 56 native Tests / zehn Suites neu bestanden (18,778 s).
Fünf neueste Importe: ein lokaler MCP-Aufruf, 737 ms erstmals / Median 287 ms warm.
Paket, lokale Installation und bestehende ChatGPT-Verbindung nicht verändert.

- [x] Dokument-ID und ursprüngliches Importdatum im Core unveränderlich machen;
  gleiche importierte Bytes behalten beide Werte. Geänderte Bytes erzeugen einen
  neuen Datensatz und erhalten den alten samt Belegen.
- [x] Importdatum und Uhrzeit pro Dokument im Setup anzeigen. Lokale Zeitzone,
  Sommer-/Winterzeit und unbekannte Altzeitpunkte prüfen; keine Ersatzdaten erfinden.
- [x] Neuntes MCP-Werkzeug `get_document_inventory` mit stabiler pseudonymer
  Dokumentreferenz, UTC-Importzeit und vorhandenem Original-SHA-256 ergänzen.
  Aktuelle Lesehandles bleiben getrennt und widerrufbar. Vier v1-Verträge erhalten.
- [x] Global vor Pagination nach Importdatum sortieren; unbekannte Zeitpunkte
  zuletzt, vollständige Cursorfolgen sowie veränderte/entzogene Freigaben testen.
- [x] JSON, SQLite und alte SQLite-Projektionen ausschließlich lesend prüfen.
  20.000 Vollfreigaben: erste fünf Importe in einem echten lokalen MCP-Aufruf;
  vollständiges Inventar über 200 Seiten ohne Quell-/Profiländerung.
- [x] Native OCR-/Belegerhalt-Regressionen, bestehenden stdio-Smoke-Test, lokale
  Relay-Tests und exakte Discovery-Parität neu ausführen. Kein Cloud-Deployment.
- [x] Skill und Regressionsrunner um Inventarvertrag ergänzen. Den gesamten Runner
  und das feste 79-Sollfelder-OCR-Gate in dieser Iteration nicht neu ausführen.
- [ ] **Als Nächstes P1:** Paket/Installation und private Discovery gezielt auf neun
  Werkzeuge aktualisieren; bestehenden Bestand und Kopplung unverändert nachweisen.
  Aktuelle produktive Installation hat diese neue Funktion noch nicht.
- [ ] **Danach P1:** reguläre ChatGPT-Abnahme am synthetischen Testanschluss:
  letzte Importe korrekt benennen; Aufrufe und Zeit bis zur sichtbaren Antwort messen.
- [ ] **P2:** logische Dokumentfamilien, Änderungsjournal und Löschmarkierungen mit
  expliziter Abgrenzung zu Widerruf entwerfen. Fehlende Zeilen dürfen nicht als
  gelöschte Originale gelten; bestehende Versionen/Belege bleiben erhalten.

[Vertrag, Dateien, Befehle und Grenzen](document-inventory.md),
[tatsächlicher Prüfnachweis](quality/document-inventory-2026-11-08.json).

## UI-Paket und lokale Aktualisierung · 08.11.2026

Fortschritt: **Vauldy.zip erstellt, lokale Installation aktualisiert, neun Dokumente
und die bestehende ChatGPT-Verbindung erhalten.** 30 Swift-Tests / fünf Suites neu
bestanden (5,942 s); paketierte Signatur-, Update-/Rollback-, stdio-, OCR-Worker- und
Setup-Startprüfungen bestanden. **Ad hoc signiert; Developer ID in Xcode blockiert.**

- [x] Aktuellen MCP-Arbeitsbaum über 221 Dateien bytevergleichen und alle Programme
  bauen. Neues Paket mit Bestandskennzeichnung und direktem Textvergleich erstellen.
- [x] ZIP neu entpacken und tief/strikt signaturprüfen. Synthetisches Update/Rollback
  mit Absturz und Wiederanlauf sowie nativen Setup-Start ohne Importworker prüfen.
- [x] Vollständige private Sicherung vor Update; neun ganze Dokumentdatensätze,
  neun Originale, 26 geschützte Dateien und eine Clientkonfiguration unverändert bestätigen.
- [x] Aktualisierte App und lokalen Programmplatz aktivieren. Paketübereinstimmung,
  Signaturen und neuen lokalen Start-/Discoverytest mit neun Freigaben bestätigen.
- [x] Bestehenden Schlüsselbundzugriff nach Nutzerbestätigung frisch im Hintergrund
  prüfen. Neuen Relay ohne Neukopplung starten. Tatsächlicher Anschluss danach erreichbar:
  **9/9 freigegeben/durchsuchbar**, Profil/Kopplung/Ablaufdatum erhalten.
- [x] Xcode Apple Accounts → Team → Manage Certificates → Developer ID Application
  tatsächlich versuchen. Apple verweigert: **Account Holder erforderlich**, aktuelle
  Rolle Admin. Bestehende Zertifikate nicht widerrufen; keine Zugangswerte exportieren.
- [ ] **Signierung extern blockiert:** Account Holder erstellt die lokale Developer-ID-
  Application-Identität. Danach sauberer Releasecommit, Developer-ID-Build und Notarisierung.
  Aktuelles ZIP ist kein signierter/notarisierter Kundenkandidat dieser Kategorie.
- [ ] Physischer Offline-Kundenmac und reguläre fachliche ChatGPT-Fragenabnahme bleiben
  offen. Statusabruf bestätigt die Verbindung und ersetzt keine fachliche Antwortprüfung.

Paket: `dist/mcp/vauldy-ui-package-onjunyd_/Vauldy.zip`.
[Installation, Erhalt, Xcode-Schritte und Befehle](ui-package-update.md),
[Messnachweis](quality/ui-package-update-2026-11-08.json).

## UI: Vorhandene Dokumente nicht erneut importieren · 08.11.2026

Fortschritt: **umgesetzt und nativ mit acht synthetischen Dokumenten geprüft.**
18 Swift-Tests / zwei Suites neu bestanden (1,725 s), finaler UI-Release-Build bestanden.

- [x] „Im Bestand“, Textzustand und Basisanalyse getrennt anzeigen. Prüfhinweise
  erklären, ohne daraus einen fehlenden Import oder eine automatische OCR-Empfehlung abzuleiten.
- [x] „Kein Text für Basisanalyse“ bei nicht verfügbarer Analyse korrigieren;
  fehlende Basisangaben allein empfehlen weder Neuimport noch erneute Texterkennung.
- [x] Direkten Textvergleich aus der Dokumentenliste anbieten. Der Vergleich startet
  keine OCR. Erneutes Lesen bleibt eine ausdrückliche optionale Aktion, auch für Mehrfachauswahl.
- [x] Gespeicherte Dokumente mit offener/fehlgeschlagener OCR im Bericht von nicht
  bestätigten Importen unterscheiden; bekannte ID bei Fehlern eines Text-Retrys erhalten.
- [x] Duplikatregression bestätigen: gleiche Datei behält ID, erzeugt keinen zweiten
  Datensatz und startet keine weitere OCR. Core-/OCR-/MCP-Verträge bleiben unverändert.
- [x] Vollständiges Testbundle mit isoliertem `--setup-root` visuell prüfen: Original
  und gespeicherter Text sichtbar; alle 22 vorhandenen Testbestandsdateien bytegleich,
  kein OCR-Worker gestartet. Produktive neun Dokumente und Freigaben unberührt.
- [x] Neues Paket mit diesen UI-Änderungen bauen und lokal aktualisieren.
  Nachfolgende Paketiteration oben dokumentiert; Developer-ID-Abnahme bleibt offen.
- [ ] Reguläre ChatGPT-Fragenabnahme und die offenen OCR-Verbesserungsgates bleiben
  separat offen; historische Messwerte nicht als neue Prüfungen verwenden.

[Änderungen, Dateien und Befehle](import-guidance-ui.md),
[Prüfnachweis](quality/import-guidance-ui-2026-11-08.json).

## Produktnahe lokale Fragenabnahme · 08.11.2026

Fortschritt: **11/11 feste Fragen über den echten lokalen MCP bestanden**, mit
quellengebundenen extraktiven Referenzantworten. **47 native Tests / zehn Suites
neu bestanden (36,523 s)**. Fünf neue Python-Prüfungen einschließlich **20 abgelehnter
falscher Antwortvarianten** bestanden. Reguläres ChatGPT-Gespräch weiterhin offen.

- [x] Acht synthetische Originale / zehn Seiten nativ importieren und OCR/Basisanalyse
  ausführen; keine Sollwerte in OCR oder Analyse eintragen. Ein Dokument gesperrt lassen.
  Einen zusätzlichen Teilscan-Snapshot ausdrücklich als kontrollierte Fixture ausweisen.
- [x] Elf typische Fragen prüfen: Themeninventar, Monats-/Jahresbetrag, Schlussrate
  und Gesamtkosten trennen, Kündigung/Zahlungsfrist, Ausschluss/Bedingung, fehlendes Feld,
  widersprüchliche Raten sowie unvollständige Quelle. Zitat und physische Seite binden.
- [x] Vollständige Pagination, Belegprüfung über unabhängigen Textabruf, Privacy und
  Widerruf für Lesen/Felder/Fristen testen. Bestehende produktive neun Dokumente,
  Freigaben, ChatGPT-Verbindung, Schlüsselbund und Installation unberührt lassen.
- [x] Tatsächliche lokale Aufrufe und Zeiten dokumentieren: **1–3 MCP-Aufrufe / Frage,
  25–91 ms** für diesen kleinen Bestand. Versicherungsunterlagen: ein Aufruf, **82 ms**,
  vier Kandidaten; aktive Verträge nicht behaupten. Zusätzliche Belegprüfaufrufe separat.
  Keine ChatGPT-, Relay- oder Zeit-bis-zur-sichtbaren-Tabelle-Messung daraus ableiten.
- [x] Raster-, Zeilen- und 4-/5-Punkt-Worker-/MCP-Regressionen samt Belegschutz und
  Widerruf neu bestehen. Fester Korpus weiterhin **52/79**, kein Verlust. Separates
  Verbesserungs-Gate bleibt **NO-GO / Exitcode 1**, zwölf extreme Vorlagen ungelöst.
  108 produktive Swift-Dateien und alle vorhandenen 48 Swift-Testdateien bytegleich.
- [x] Produktfragen, native Fixtures, strukturierten Antwortprüfer und Gegenproben in
  den Regressionsrunner aufnehmen. Gesamten Runner in dieser Iteration nicht ausgeführt.
- [ ] **Als Nächstes P1:** reguläre ChatGPT-Abnahme mit ausschließlich synthetischem
  Testanschluss; tatsächliche Formulierung, Quellen, Konflikte/Negationen, Werkzeugrunden
  und sichtbare Zeit messen. Der extraktive Test ist kein Nachweis einer LLM-Antwort.
- [ ] **Danach P1:** pauschale `FIELD_EXTRACTION_INCOMPLETE`-Warnungen für benachbarte
  Kostenrollen präzisieren. Zwei Fälle benötigen derzeit sicheres Quellnachlesen;
  echte Klauselfortsetzungen, Quelllücken und Konflikte dürfen nicht verschwinden.
- [ ] **Danach P1:** unabhängige deutsche Produktvorlagen und schwere OCR-Quellen ergänzen.
  Korrekte kritische Werte oder ausdrücklich unbekannt; keine unbelegten Chat-Aussagen.
  Bestehende Literal-/Belegerhalt-Gates zusätzlich weiterführen.

[Verfahren, Ergebnisse, Dateiliste und Befehle](product-question-acceptance.md),
[alle erhaltenen Referenzantworten](product-question-reference-answers.md),
[Messnachweis](quality/product-question-acceptance-2026-11-08.json).

## PaddleOCR PP-OCRv6 medium auf Deutsch · 08.11.2026

Fortschritt: vollständiger lokaler Vergleich abgeschlossen. **Rohwerte 49/79, 54/79,
53/79 gegenüber Apple Vision 52/79.** Unter dem unveränderten Belegschutz **52/79**;
belegschützendes Austauschgate **NO-GO (Exitcode 1)**. Produktive OCR unverändert.

- [x] Laufzeit 3.7.0 / Paddle 3.3.1 und offizielle medium-Modelle isoliert bereitstellen,
  Revisionen und alle Modelldateien pinnen/verifizieren; deutsche Zuordnung `de` prüfen.
- [x] Apple neu cachefrei messen; alle 35 unveränderten Bilder in drei festen Varianten
  durch PaddleOCR lesen: 105 Seitenaufrufe mit gesperrtem Netzwerk und Benutzerordner.
  Keine Solltexte oder Auswahl der besten Variante je Dokument in der OCR.
- [x] Rohgewinn +2 Literal-Sollfelder netto belegen: drei neue korrekte Felder und ein
  Literal-Verlust. Der Betrag enthält eine reine Kommakorrektur, der Verlust betrifft
  ein Leerzeichen nach `Beginn:`. Das ist kein Nachweis dreier neuer Vertragsfakten.
- [x] Alle bisherigen 52 Sollfelder und Belegzeilen erhalten; tatsächliche Paddle-Ausgaben
  durch den bestehenden Belegschutz prüfen. Seitenrückfälle verhindern die sichere
  Übernahme der Korrekturen; Kontrast erzeugt zusätzlich zehn unerwartete Zeilen.
- [x] **13 Swift-Tests / 4 Suites neu bestanden (15.658 s)**;
  Tesseract-Testadapter rückwärtskompatibel neu geprüft. Vier Python-Tests, Syntax-
  und echter Worker-/MCP-Test mit Privacy, unveränderten Freigaben und Widerruf bestanden.
- [x] Ressourcen messen: M1 Pro / 16 GiB, zwei CPU-Threads, bis
  **4.272 GiB Peak-RSS**, vergrößert etwa zwölf Sekunden/Bild.
  Keine pauschale Vergrößerung oder Paket-/Kundenabnahme daraus ableiten.
- [ ] **Nächster Schritt:** gezielte, quellengebundene zweite OCR-Fassung mit überprüfbaren
  Zeilenkorrekturen und erhaltenen alten Zitaten entwerfen/testen. Zahlen-/Kennungs-
  konflikte markieren; Ganzseitenrückfall nicht einfach lockern. Noch keine produktive
  PaddleOCR-Integration. Erst nach eigenem Gate und unabhängigen deutschen Vorlagen.
- [ ] Zwölf sehr blasse/verrauschte Vorlagen bleiben bei **0/24**. Originalauflösung,
  Lesbarkeit und gezieltes lokales Nachlesen weiter prüfen; diese Teilgruppe nicht
  als durch den Rohgewinn gelöst darstellen. Neun reale Dokumente/Freigaben unberührt.

[Vergleich, konkrete Beispiele, Dateien und Befehle](ocr-paddle-v6.md),
[vollständiger Mess- und Prüfnachweis](quality/ocr-paddle-v6-2026-11-08.json).

## Alternative lokale OCR auf Deutsch · 08.11.2026

Fortschritt: Vergleich abgeschlossen. **Apple Vision 52/79, deutsche Tesseract-OCR
höchstens 39/79; nach bestehendem Belegschutz 52/79. Kein abgesicherter Gewinn, NO-GO.**
Der produktive OCR-Pfad und die lokale Installation bleiben unverändert.

- [x] Tesseract 5.5.4 mit offiziellem `tessdata_best`-Modell **`deu`** isoliert
  bereitstellen; Commit/Git-Blob/SHA-256 pinnen. Kein englischer Vergleich als deutscher
  Nachweis, keine globale Modellinstallation oder automatische Anbieterumschaltung.
- [x] Apple Vision neu cachefrei am unveränderten 35-Bilder-/79-Felder-Korpus messen.
  Acht feste Tesseract-Varianten über sämtliche Bilder, 280 seriell ausgeführte
  OCR-Prozesse mit gesperrtem Netzwerk. Skalierung und Kontrast nur an Testkopien.
- [x] Rohqualität und Schutz bestehender Belege getrennt messen: beste Rohvarianten
  39/79 mit 13 bzw. 14 verlorenen bisherigen Feldern. Der einzelne neue korrekte
  Treffer ist kein sicherer Gesamtgewinn. Keine Auswahl anhand der Sollwahrheit.
- [x] Tatsächliche Tesseract-Ausgaben durch `EvidencePreservingLocalOCR` prüfen:
  alle 52 alten Sollfelder und Belegzeilen erhalten. Geschütztes Ergebnis weiterhin
  52/79; eine Variante erzeugt zudem einen unerwarteten Zusatz. Gate: Exitcode 1.
- [x] 13 native Swift-Tests / vier Suites neu bestanden (15,825 s), einschließlich
  echtem Alternativtext, Belegschutz, festem Korpus und Retry-/Cachegrenzen.
  Drei Konvertierungstests, Syntaxprüfung und echter Worker-/MCP-Zeilentest mit
  Belegerhalt, Privacy und drei Widerrufen bestanden. Keine alte Gesamttestzahl
  als neue Abnahme verwenden; Paket-/UI-/Relay-Gesamtabnahme nicht ausgeführt.
- [x] PaddleOCR PP-OCRv6 medium mit Deutsch (`de`) inzwischen tatsächlich am gleichen
  Korpus geprüft; Ergebnis und neue offene Punkte stehen in der Folgeiteration oben.
  Die produktive Tesseract-Integration bleibt durch ihren Vergleich nicht begründet.
- [ ] Nach einem nachgewiesenen Gewinn unabhängige deutsche Umlaut-/Scan-Holdouts
  und anschließend separat beauftragte reale Nachprüfung. Neun Dokumente, bestehende
  Freigaben, ChatGPT-Verbindung und alle produktiven Swift-Quellen hier unverändert.

[Deutscher Vergleich, Dateien und exakte Befehle](ocr-local-alternative.md),
[Messwerte, Schutzprüfungen und NO-GO](quality/ocr-local-alternative-2026-11-08.json).

## Sehr blasse Rasterzeilen: feste Qualitätsprüfung · 08.11.2026

Fortschritt: Untersuchung und reproduzierbarer Testaufbau abgeschlossen; das gewünschte
OCR-Qualitätsziel ist **nicht erreicht / NO-GO**. Erneut **52/79** vollständige Sollfelder,
kein Gewinn; die zwölf sehr blassen Fälle bleiben bei **0/24**. Kein neuer Filter aktiviert.

- [x] Bestehenden Korpus vor den Versuchen einfrieren: 35 Bilder / 79 wörtliche Sollfelder,
  SHA-256 je PNG; identische Bildbytes bei jeder Regeneration erzwingen.
- [x] Pixelbasierte blasse Zeilenbänder und mehrere lokale Aufbereitungen prüfen.
  Kandidat findet 18 unbedeckte Bänder in zehn der zwölf schwierigen Bilder; keine
  neue Zeile besteht die unveränderten Annahmegates. Mehr Detektion ist kein Textgewinn.
- [x] Fehlkorrekturen prüfen: selbst ein falsches „Schatz“ statt „Schutz“ erreichte in
  einer synthetischen Ausschnittsprobe in beiden Lesungen Konfidenz 1,0. Keine erwarteten
  Wörter einsetzen, keine Konfidenzgrenzen lockern, keine Anbieter umschalten.
- [x] Erfolglosen Prototyp aus dem Produktpfad entfernen. Filter und Versuchsadapter
  ausschließlich im Testziel; produktive native OCR und v14-Cachekennung bytegenau
  auf den Stand vor dieser Iteration zurückgesetzt. Originale, Belege und Freigaben erhalten.
- [x] **111 Swift-Tests / 20 Suites bestanden (49,713 s)**; fünf Tests der strikten
  Gatepolitik bestanden. Vier echte synthetische Worker-/MCP-Prüfungen bestanden:
  Zeilen, dichte Seite, markierte Regionen und Raster; frischer Retry, Belegerhalt,
  Privacy und Widerruf. Keine Paket-/UI-/Relay-Gesamtabnahme behaupten.
- [x] Separates Qualitätsgate wirklich ausführen: **Exitcode 1 / NO-GO**, weiterhin
  mindestens 53/79 nötig; null verlorene Sollfelder, alle bisherigen Belegzeilen
  erhalten, keine unerwarteten Zusätze. Grüne Regression ist keine OCR-Qualitätsfreigabe.
- [ ] **Nächster OCR-Punkt:** tatsächlichen Gewinn auf exakt diesem Korpus erreichen,
  bevor ein neuer Pfad produktiv aktiviert oder die Cacheversion geändert wird.
  Ggf. separaten Vergleich eines weiteren lokalen OCR-Verfahrens bewusst entscheiden;
  keine automatische Modellinstallation, Anbieterumschaltung oder Cloud-Verarbeitung.
- [ ] Danach neue unabhängige Holdouts mit anderen Inhalten und anschließend gesondert
  beauftragte reale Nachprüfung. Die neun produktiven Dokumente und die ChatGPT-Verbindung
  wurden in dieser Iteration nicht verarbeitet oder verändert.

[Versuch, Grenzen, Dateiliste und exakte Befehle](ocr-faint-raster.md),
[echter Prüfnachweis einschließlich gescheitertem Qualitätsgate](quality/ocr-faint-raster-2026-11-08.json).

## Unsichere Einzelzeilen und Prüfgründe · 08.11.2026

Fortschritt: Statuslogik, gezielte Zeilenansteuerung und lokale Diagnose umgesetzt;
108 Swift-Tests und vier echte synthetische Worker-/MCP-Prüfungen bestanden.
**Im zusätzlichen nativen Korpus noch kein Gewinn vollständiger Sollfelder:**
35 Bilder, 52/79 vorher und nachher. Keine reale Nachbearbeitung oder Installation.

- [x] Ursache wechselnder Markierungen im Code klären: unbestätigte schwache Zeilen
  wurden je nach `.keep`, fehlendem Treffer, Retryfehler oder fehlender Bestätigung
  unterschiedlich bewertet; Zeilen außerhalb des Budgets waren teils unberücksichtigt.
  Historische Einzelfälle ohne damalige Pfadprotokolle nicht rückwirkend behaupten.
- [x] Einheitliche Entscheidung für alle anfänglich unsicheren Zeilen implementieren;
  offene Zeilen und mehrdeutige Kennungen bleiben markiert. Zwei passende starke
  Lesungen können unveränderten Text bestätigen. Unsichere Wortzeilen vor klaren
  kleinen Kennungen priorisieren, unbrauchbare Ausschnitte überspringen.
- [x] Räumlich passende Fragmente derselben Zeile konservativ verbinden und begrenzte
  Graustufen-/Kontrastbehandlung für Zeilenausschnitte testen. Zahlen-/Kennungsgates,
  vier Versuche / höchstens acht native Lesungen und Belegerhalt bewahren.
  Vollständige native Sollfelder bleiben im Korpus unverändert; kein allgemeiner
  Transkriptionsgewinn aus den Codeänderungen ableiten.
- [x] Inhaltsfreie Gründe lokal speichern/anzeigen: unbestätigte Zeile, mehrdeutige
  Kennung, Widerspruch, Budget, geringe mittlere Konfidenz und kurzer Text. Cache
  bewahrt gespeicherte Diagnose; v14 schließt v13-Checkpoints aus. Alte Daten lesbar.
- [x] 108 Tests / 19 Suites neu bestanden (39,017 s). Neuer Zeilen-Wiretest mit
  Belegerhalt, stabiler frischer Wiederholung, unveränderten Originalen/Freigaben,
  geschützter Kennung und drei Widerrufen. Bestehende dichte, Regions- und Raster-
  Wiretests ebenfalls bestanden. Teststarter-/Fixture-/Privacy-Erwartungsfehler
  korrigiert und tatsächliche Wiederholungen dokumentiert; komplette Releaseabnahme offen.
- [ ] **Nächster OCR-Qualitätspunkt:** tatsächlichen Textgewinn am festen schwierigen
  Rasterkorpus erreichen; zwölf sehr blasse/kleine verrauschte Vorlagen stehen
  weiterhin bei 0/24 vollständigen Feldern. Erstdetektion/fehlende Zeilen getrennt
  vom Retry prüfen und Fehlkorrekturen sowie alte Raster-Sollwerte absichern.
- [ ] Hohe Konfidenz trotz falscher Sollfelder weiter untersuchen. Der kleine rechts
  geneigte Testfall verfehlt zwei komplette Sollfelder ohne Prüfmarkierung. Ein
  fehlender Hinweis darf nicht als Fehlerfreiheit oder Vollständigkeit gelten.
- [ ] Separate Paket-/Kundenabnahme und gegebenenfalls ausdrücklich beauftragte reale
  Nachprüfung. Produktiv weiterhin v13 mit den zuvor gemessenen fünf offenen Fällen;
  diese Iteration verarbeitet ausschließlich synthetische Vorlagen.

[Implementierung, Grenzen, Korpus und Befehle](ocr-consistent-lines.md),
[Nachweis](quality/ocr-consistent-lines-2026-11-08.json).

## Reale OCR-Nachprüfung mit v13 · 08.11.2026

Fortschritt: beauftragte Nachprüfung aller fünf Fälle abgeschlossen; ihre fachliche
OCR-Abnahme bleibt offen. Keine Codeänderung oder erneute Installation dieser Wartung.

- [x] Aktuellen Bestand privat sichern, installierten v13-Build prüfen und genau
  D1/D2/D3/D8/D9 zuerst als Kandidat, danach aktiv cachefrei lesen: je 22 Seiten.
  Kandidaten- und aktive OCR-Texte identisch, alle 22 aktiven Seiten mit v13,
  kein Cachetreffer und kein Rückfall auf alte Seiten durch den Belegschutz.
- [x] Ergebnis messen: D9 **+68 Zeichen / neun Zeilen**, andere vier Fälle ohne
  Zusatztext. D9 S.5/6 jetzt 165/135 Regionen ohne Vergleichslimit; weiter Lücken.
  Zusatztext sind Datums-/Zahlenzeilen, keine neuen belegten Analysefelder oder
  gespeicherten Fristen. Keine unabhängige fachliche Genauigkeitsabnahme behaupten.
- [x] Alte Belegzeilen in Reihenfolge, fünf gespeicherte Analysebelege, neun
  Originale/IDs/Referenzen und Freigaben erhalten; vier andere Datensätze vollständig
  unverändert. Neuer lokaler Starttest und tatsächlicher ChatGPT-Anschluss 9/9
  erreichbar. Keine Neukopplung, Keychain-/Clientänderung oder Datenmigration.
- [x] Offene Befunde ehrlich aktualisieren: fünf Dokumente bleiben `partial`,
  markierte Seiten **13 → 14**. D1 S.4/8 neu markiert, S.6 nicht mehr, ohne
  Textänderung. Sieben Seiten mit Geometrielücken, elf mit niedriger Zeilenkonfidenz;
  Gruppen überlappen. Alle neun Basisanalysen bleiben prüfbedürftig.
- [x] Kontext-/Bestätigungsprüfung und wechselnde Prüfmarkierungen im Branch
  überarbeitet und synthetisch geprüft, siehe Folgeiteration oben. Gemessener
  Transkriptionsgewinn bleibt offen; native lange Zeichenregionen und weitere
  dichte Raster-/Tabellenvorlagen bleiben zusätzliche Qualitätsaufgaben.
- [ ] Rollen der neuen Zahlen-/Datumszeilen anhand des lokalen Quellkontexts prüfen,
  bevor daraus Vertragsbeginn, Fälligkeit oder Kündigungsfrist abgeleitet werden.
  Alle fünf realen Fälle bleiben fachlich offen; kein allgemeiner OCR-Qualitätsgewinn.

[Tabelle, Chatwirkung, Belegerhalt und Befehle](ocr-v13-real-review.md),
[Nachweis](quality/ocr-v13-real-review-2026-11-08.json).

## v13-Paket und lokale Aktualisierung · 08.11.2026

- [x] Neues `Vauldy.zip` aus dem aktuellen MCP-Arbeitsbaum gebaut, Version 0.13.0,
  OCR-Konfiguration v13, Mehrfach-OCR und geführter Assistent enthalten. Finales ZIP
  nach Entpacken tief/strikt signaturgeprüft; ad hoc, nicht notarisiert.
- [x] 97 Swift-Tests / 18 Suites erneut bestanden (26,600 s). Paketierte native
  OCR über geschützten stdio, Widerruf, Belegerhalt, Update/Rollback mit Fehlern,
  SIGKILL und Konkurrenz sowie beobachtenden UI-Start ohne Worker geprüft.
- [x] Neun Dokumente/Originale, Profile und vorige App privat lokal gesichert.
  `/Applications/Vauldy.app` und lokale Programmgeneration aktualisiert; neuer
  lokaler Starttest bestätigt Build und neun Freigaben. Alle neun vollständigen
  Dokumentdatensätze und Originale unverändert, 26 Dateien und Clientkonfiguration
  bytegleich. Reguläre Audit-Ergänzung mit erhaltenem Präfix und gültiger Kette.
- [x] Nach macOS-Schlüsselbundbestätigung frischen Hintergrundzugriff erfolgreich
  prüfen und neuen Relay mit bestehender Kopplung starten. Erster Freigabevorgang
  abgelaufen, einmal erneuert und ausdrücklich bestätigt. Tatsächlicher ChatGPT-
  Anschluss über den neuen Agenten erreichbar: 9/9 freigegeben und durchsuchbar.
  Kopplung/Profile erhalten, keine Trennung oder Neukopplung durchgeführt.
- [ ] Developer-ID Application, Notarisierung, sauberer Releasecommit und frischer
  physischer Offline-Kundenmac bleiben separate Kundengates. Persistenter Gesamtstapel
  weiterhin offen; die reale OCR-Nachprüfung folgte separat, siehe oben.

[Paketpfad, Prüfbefehle und Datenerhalt](v13-package-update.md),
[Nachweis](quality/v13-package-update-2026-11-08.json).

## Dichte OCR-Seiten, Mehrfach-OCR und Dokumentenfenster · 08.11.2026

Fortschritt dieser Iteration: vier Umsetzungspakete abgeschlossen; weitergehende
Abnahmen unten bleiben offen. Im MCP-Branch umgesetzt; anschließend als v13-Paket
lokal installiert, siehe Paketiteration oben.

- [x] Dichte visuelle Abdeckung begrenzt segmentieren, Lücken priorisieren und
  exakte Summen bei weiterhin maximal 128 gespeicherten Regionen validieren.
  Native 140-Zeilen-Vorlage: fünf exakte Zusatzfelder **0/5 → 5/5**, 147 Regionen,
  drei Nachlesefenster innerhalb des ursprünglichen Vierer-/Pixelbudgets.
- [x] Unsichere Zeilen geometrisch im Kontext auswählen und vor Ersetzung durch
  einen zweiten Kontext bestätigen; Konflikt-/Kennungsgrenzen erhalten. Spalten
  in der Kleinschriftplanung trennen. Jeder frische Worker-Nachlauf erhält alte
  Belege; Protokoll 3 verhindert Einreichung bei alten laufenden Workern.
- [x] Mehrere Dokumente separat für OCR auswählen, Treffer gesammelt übernehmen,
  mit einem Klick nacheinander frisch verarbeiten, Gesamt-/Seitenfortschritt und
  Abbruch anbieten. Freigaben separat einklappen; klare Dateinamen und getrennte
  OCR-/Basisanalysefilter. Native UI: 6/6 erfolgreich, Abbruch nach drei und
  Fortsetzung der verbleibenden drei; final nochmals 6/6 nach Freigabewechsel.
  Alle sechs Originale/Texte und die unveränderte Zweierfreigabe verifiziert.
- [x] 97 Swift-Tests / 18 Suites neu bestanden (27,110 s), zwei echte stdio-/CLI-
  Prüfungen bestanden; finalen nativen UI-Build und Darstellung geprüft. Neuer
  Wiretest in Regression eingebunden. Produktiv nur Datenerhalt lesend geprüft:
  neun Originale/Texte, Profile und Clientkonfiguration erhalten. Keine Installation,
  echte Dokumentnachbearbeitung oder neue ChatGPT-Kopplung dieser Iteration.
- [ ] **Nächster OCR-Qualitätspunkt:** unabhängige dichte Raster-/Tabellenseiten,
  native Zeichenregionen über 256 Zeichen und verrauschte Einzelzeilen gegen
  exakte Solltexte/Felder sowie Fehlalarme prüfen. Synthetische Grenz-/Abbruchtests
  sind vorhanden, ersetzen diese native Qualitätsabnahme aber nicht.
- [ ] **OCR-Stapel nach Neustart:** bisher liegen noch nicht eingereichte Rest-IDs
  im offenen Einrichtungsfenster. Gesamten Stapel dauerhaft speichern; Beenden,
  Prozessabbruch und Wiederanlauf samt Original-/Beleg-/Freigabeerhalt prüfen.
- [x] Neues Paket und gesonderte reale Nachprüfung der fünf offenen Dokumente /
  bisher 13 markierten Seiten am 08.11. ausgeführt: +68 Zeichen, nun 14 markierte
  Seiten. Die fachliche Abnahme der fünf Fälle bleibt offen, siehe Nachprüfung oben.
- [ ] Große native Dokumentenliste gesondert prüfen. Vollständige Releasegates,
  Developer-ID/Notarisierung und physischer Offline-Kundenmac bleiben offen.

[Änderungen, Codebelege, Befehle und Grenzen](ocr-dense-batch-ux.md),
[Prüfnachweis](quality/ocr-dense-batch-ux-2026-11-08.json).

## v12-Paket, lokale Aktualisierung und reale OCR-Nachprüfung · 07.11.2026

- [x] Neues `Vauldy.zip` aus dem MCP-Branch gebaut, signatur- und paketgeprüft;
  lokales Update mit authentifiziertem Rückweg ausgeführt. Native Einstellungen
  bestätigen passenden Build und verfügbare Vorversion. Vorige App privat gesichert.
- [x] Frische paketierte 4-/5-Punkt-Importe mit sechs exakten Sollfeldern über den
  geschützten MCP geprüft. Update/Rollback samt Abbruch- und Kompatibilitätsfällen
  erneut bestanden. Vorherige 88 Swift-Tests separat referenziert, nicht als neu gezählt.
- [x] Fünf reale Prüffälle erst privat als Kandidat, danach aktiv mit OCR v12 erneut
  gelesen: 22 Seiten, kein Zusatztext, markierte Seiten weiterhin 13. Belegzeilen,
  neun Originale/IDs, Freigaben und Clientkonfiguration erhalten; vier andere
  Datensätze insgesamt unverändert. Alle neun Basisanalysen bleiben prüfbedürftig.
- [x] Bestehende ChatGPT-Kopplung nach bewusster macOS-Schlüsselbundbestätigung mit
  neuen Programmen neu gestartet. Frischer Hintergrundzugriff und tatsächlicher
  Anschlussstatus erfolgreich: 9/9 freigegeben und durchsuchbar, vier Quellen
  vollständig verarbeitet, fünf weiterhin mit Prüfhinweisen. Keine Neukopplung.
- [ ] **Restabnahme dichte Seiten:** Segmentierung und koordinatengebundene
  Fortsetzung am 08.11. umgesetzt; native 147-Regionen-/Fünf-Lücken-Vorlage bestanden.
  Native lange Zeichenregionen und unabhängige Rasterfälle weiter offen, siehe oben.
  D9 S.3/4 erreicht bisher vier Versuche, S.5/6 enthält begrenzte Abdeckungsvergleiche.
- [ ] Unsichere Einzelzeilen: Kontextauswahl und doppelte Bestätigung am 08.11.
  umgesetzt und gezielt getestet. Unabhängige verrauschte native Vorlagen und reale
  Wirkung bleiben offen: zehn der 13 markierten Seiten haben niedrige Zeilenkonfidenzen,
  sieben geometrische Lücken; Gruppen überlappen. Hohe mittlere Konfidenz nicht
  mit gemessener Genauigkeit gleichsetzen.
- [ ] Reale OCR-Fälle bleiben offen: dieser erneute Lauf hat keine zusätzliche
  inhaltliche Antwortgrundlage geschaffen. Developer-ID-/Notarisierungs- und
  Offline-Kundengates bleiben separat offen.

[ZIP, tatsächliche Ergebnisse, Datenerhalt und Befehle](v12-package-ocr-review.md),
[Prüfnachweis](quality/v12-package-ocr-review-2026-11-07.json).

## Kleinstschrift und Chatwirkung · 07.11.2026

- [x] Nicht markierte kleine Druckbereiche mit begrenzter lokaler Detaildetektion prüfen.
  Für winzige Vektorschrift unrotierte PDF-Ausschnitte aus dem Original neu rastern.
  Bestehende doppelte Bestätigung, Zahlenkonflikte, Seitenbindung und Budgets erhalten;
  v11-Checkpoints durch eigene v12-Konfiguration ausschließen.
- [x] Strikte 4-/5-Punkt-Sollfelder: 0/3 → 3/3 und 2/3 → 3/3; 6-Punkt-Kontrolle
  weiterhin 3/3. Normale synthetische Importe bis zum geschützten MCP-Lesen, zur Suche
  nach Hausrat und zum Widerruf prüfen. Keine produktiven Daten oder Freigaben ändern.
- [x] Chatwirkung im regulären Safari-Chat als ausdrücklich benannten Replay der
  tatsächlichen synthetischen MCP-Ergebnisse beobachten: neue Fälle liefern Hausrat,
  49,99 € und 27.01.2026; fehlende alte Angaben bleiben offen; kein aktiver Vertrag
  behauptet. Ein Live-Relay-Aufruf aus diesem Chat war nicht Teil dieses Nachweises.
- [x] Abschluss: 88 Swift-Tests in 15 Suites / 26,835 s bestanden, einschließlich
  verschobenem PDF-Crop, winzigem Zahlenkonflikt, alten Checkpoints und den bestehenden
  Raster-/Privacy-/Indexregressionen. Zwei stdio-Prüfungen bestanden: vier Vorher-/Nachher-
  Bestände mit acht Widerrufsprüfungen sowie bestehende Regionserkennung mit Cache,
  Frischerkennung und Belegerhalt. In die vollständige Regression aufgenommen;
  vollständige Release-/Installerregression in dieser Iteration nicht ausgeführt.
- [ ] Reales Nachlesen der fünf offenen Dokumente / 13 markierten Seiten nach eigener
  Paket-/Quellenprüfung. Synthetische 3/3-Felder schließen diesen Punkt nicht ab.
- [ ] Niedrig aufgelöste Raster-Kleinstschrift und dichte/berührende Tabellen unabhängig
  prüfen. Allgemeine OCR-Genauigkeit und vollständige visuelle Abdeckung bleiben offen.
- [ ] Strukturierte Feldrollen kontextgebunden ergänzen: `Beginn` und `Versicherungsart`
  sind im Text erreichbar, aber noch keine sicheren Regeln für `startDate`/`contractType`.
  Generischen Beginn nicht automatisch als Vertragsbeginn ausgeben. Verarbeitete Seiten
  auch in Chat-Anweisungen eindeutig von vollständig erkanntem Text unterscheiden.
- [ ] Separater Live-Zielchat-Test mit synthetischem Anschluss und neuem Build;
  produktiven Anschluss und Neun-Dokumente-Freigabe dafür unverändert lassen.

[Implementierung, Chatbeobachtung, Grenzen und Befehle](ocr-small-text.md),
[maschineller Nachweis](quality/ocr-small-text-2026-11-07.json).

## Installationspaket und lokaler Neustart vom 07.11.2026

- [x] Aktuelles `Vauldy.zip` aus dem MCP-Arbeitsbaum bauen. Automatischer erster
  Installationsdialog und direkter Übergang zur optionalen Chatbot-Einrichtung umgesetzt.
  Abbruch öffnet den Dialog beim Statuspolling nicht erneut. Native Installation mit
  frischem isolierten Bestand bis zum sichtbaren erfolgreichen Starttest geprüft.
- [x] 80 Swift-Tests in 13 Suites neu bestanden, einschließlich nativer synthetischer OCR.
  Finales ZIP auf Signatur, reale stdio-Aufrufe, Diagnose, Update/Rollback und beobachtenden
  UI-Start geprüft. Zwei fehlgeschlagene Fixture-Starts samt Ursache und neuem tatsächlichen
  Prüfergebnis dokumentiert. [Nachweis und Kommandos](guided-installation-package.md),
  [Messprotokoll](quality/guided-package-2026-11-07.json).
- [x] Auf ausdrücklichen Nutzerwunsch laufende lokale Vauldy-Installation stoppen und
  aktive Konfigurationen zurücksetzen. Alte Programme und Dokumentbestand lokal gesichert,
  zwei Vauldy-Client-Einträge entfernt, fremde Einstellungen erhalten. Safari-Web-App und
  Relay-Schlüsselbundzugang nach zusätzlicher Bestätigung entfernt. Abschließend keine
  aktiven Vauldy-Prozesse oder Apps an den bisherigen Installationspfaden.
- [ ] Kundenpaket mit Developer ID und Notarisierung bauen. Aktuell keine gültige
  Signieridentität vorhanden; bereitgestelltes ZIP bleibt ein ad-hoc-signiertes Testpaket
  für Apple Silicon und macOS ab 14. Kundenprüfung auf frischem physischem Offline-Mac offen.

- [x] **Installation auf dem tatsächlichen Nutzer-Mac am 07.11.2026.** `Vauldy.app`
  unter `/Applications` aus dem geprüften ZIP neu installiert. Bei Beginn waren inzwischen
  wieder ein Profil und neun ausgewählte Dokumente vorhanden. Deshalb nur Programme neu
  installiert und diese Daten/Freigaben erhalten. Die vorhandene App scheiterte an
  Finder-Metadaten in der Signaturprüfung; die unveränderte App aus dem ZIP ist gültig.
  Nativen Assistenten am regulären Installationsort bis zur sichtbaren Meldung
  „Der lokale Server hat den Starttest bestanden“ durchgeführt. Alle 46 zuvor erfassten
  Bestands-/Freigabedateien unverändert. Installierte Binärdateien entsprechen dem Paket,
  App und installierte Bundles bestehen die Signaturprüfung.
  [Aktueller Installationsnachweis](quality/local-install-2026-11-07.json).

- [x] **Regulären ChatGPT-Anschluss am 07.11.2026 verbinden.** Bestehenden privaten
  Dienstzugang erneut über verborgenes stdin lokal bereitgestellt, ohne einen neuen Token
  zu erzeugen oder das Cloud-Deployment zu ändern. Native Auswahl der genau neun bereits
  freigegebenen Dokumente nach ausdrücklicher Bestätigung mit dem angemeldeten Konto gekoppelt.
  Im regulären Safari-Chat zeigt eine vollständige Tabelle 9/9 erreichbare Dokumente und
  `hasMore=false`. Audit: genau zwei Aufrufe (`status`, `list`), jeweils neun Ergebnisse,
  keine vollständigen Textlesungen. Tabelle bei der Beobachtung nach 25,516 s sichtbar;
  bei 14,682 s noch nicht sichtbar. 44 Bestands-/Freigabedateien weiterhin unverändert.
  Separater aktueller Plugin-Status bestätigt neun durchsuchbare und keine fehlenden
  Dokumente. Drei Quellen vollständig verarbeitet, sechs mit Verarbeitungslücken;
  Basisanalyse bei allen neun prüfbedürftig.
  [Regulärer Testchat](https://chatgpt.com/c/6aef1354-9d1c-83ed-bac6-3885a5044c52),
  [Prüfnachweis](quality/chatgpt-nine-documents-2026-11-07.json).

- [x] **Die sechs OCR-Fälle lokal prüfen und gezielt verfeinern, alle neun Basisanalysen
  erneut ausführen (07.11.2026).** Begrenzte Vergrößerung markierter kleiner Bereiche und
  Belegzeilenerhalt implementiert. Zuerst private Kandidatenkopie, danach ausdrückliche
  Wartung des bestehenden Bestands. Sieben zusätzliche Zeilen / 38 Zeichen in drei
  Dokumenten; markierte Seiten 15 → 13; quellseitig vollständig verarbeitete Dokumente
  3 → 4. Neun Originaldateien und sämtliche Freigaben unverändert. Sieben neue Zeilen
  über den installierten MCP lokal auffindbar; bestehender ChatGPT-Anschluss bestätigt
  weiterhin neun durchsuchbare Dokumente. Alle neun Basisanalysen neu berechnet und fünf
  gespeicherte Zitatfelder gegen ihre OCR-Seiten geprüft. Alle neun bleiben fachlich
  prüfbedürftig; fehlende Werte nicht erfunden. 78 Swift-Tests und finale synthetische
  Import-/MCP-/Verfeinerungsprüfung bestanden. Die getrennten extremen 4-/5-Punkt-Proben
  haben ihr vollständiges Sollfeldziel weiterhin nicht erreicht.
  [Umsetzung, Grenzen und Kommandos](ocr-nine-document-review.md),
  [Prüfnachweis](quality/ocr-nine-document-review-2026-11-07.json).
- [ ] **Verbleibende fünf Dokumente / 13 Seiten.** Nicht markierte Kleinstschrift und
  überlappende Tabellen gezielt erschließen; alte belegte Zeilen und Zahlen erhalten.
  Abnahme an unabhängigen synthetischen Sollwerten und anschließend ausdrücklicher lokaler
  Quellenprüfung; keine bloße Entfernung von Review-Hinweisen.
- [ ] **Basisanalyse weiterentwickeln.** Neun Betrefflücken, acht fehlende Übersichten,
  sechs unklare Typen und eine mehrdeutige Struktur behandeln. Belegbare Rollen/Seiten
  mit Positiv-, Konflikt- und Negativfällen prüfen; fehlende Angaben bleiben offen.
- [x] **v11-Paket erstellen und lokale Installation mit Datenerhalt aktualisieren
  (07.11.2026).** Neues `Vauldy.zip` aus dem bytegeprüften MCP-Arbeitsbaum gebaut,
  neue synthetische Update-/Rollbackprüfung bestanden und App/Programmsatz installiert.
  44 Bestands-/Freigabedateien und eine Clientkonfiguration unverändert. Neun Dokumente
  und bestehende ChatGPT-Kopplung erhalten. Nach bewusster macOS-Schlüsselbundfreigabe
  läuft der neue Agent; vorübergehend verwendeter Alttransport wieder beendet. Bestehender
  ChatGPT-Anschluss bestätigt abschließend neun durchsuchbare Dokumente. Native Oberfläche
  bestätigt aktuellen Programmsatz und verfügbaren Rollback. Paket bleibt ad hoc signiert,
  nicht notarisiert. Die vorherigen 78 Swift-Tests gehören zum identischen OCR-Quellstand
  und wurden in dieser Paketiteration nicht als neuer Testlauf ausgegeben.
  [Paket, Prüfbefehle und Rückweg](v11-package-update.md),
  [Prüfnachweis](quality/v11-package-update-2026-11-07.json).

Erreichbarkeit und Inventar sind bestätigt. Die Textverfeinerung ist begrenzt nachgewiesen;
vollständige OCR und fachlich richtige Vertragsauslegung sind keine bestandene Abnahme.
Die zurückgestellte synthetische R6-Abnahme bleibt unverändert offen.

## Review vom 06.11.2026 · nächste Umsetzungsschritte

Auf Nutzerwunsch wurde die Weiterentwicklung für eine Prüfung von Architektur, Performance,
UX/UI und Qualität des durchsuchbaren Textes unterbrochen. [Vollständiger Review](architecture-performance-ux-review-2026-11-06.md),
[neue Messungen](quality/architecture-review-2026-11-06.json). Die folgende Reihenfolge hat
Vorrang vor weiteren Fachwerkzeugen. Iteration 11 bleibt unverändert offen.

- [x] Aktuelle Quellen und isolierte Tests prüfen. Neun OCR-Tests in zwei Suites erneut
  bestanden (2,880 s); Fristen- und Feld-Wiretests erneut bestanden. Fristen: fünf ausgewählte
  Dokumente in einem lokalen Aufruf, 177,4 ms. Kein neuer Build und keine neue Zielchat-/UI-Abnahme.
- [x] **R1 · Suchtext normalisieren.** Soft Hyphens und konservative Zeilentrennung in einer
  separaten, quellengebundenen Suchprojektion behandeln. Abnahme: alle drei Varianten des
  neuen Versicherungs-Probes finden; echte Bindestriche, Kennungen und Zahlen unverändert;
  gleiche Trefferregeln für Liste, Suche, FTS und Passagen; Seitenbelege, Privacy, Widerruf
  und JSON-Lesbarkeit erhalten. Umgesetzt und am 06.11.2026 neu geprüft: sieben Schreibvarianten
  werden in Standard-, Speicher-FTS- und Datei-FTS-Betrieb gefunden; Belege bleiben wörtlich.
  52 Swift-Tests in sechs Suites und die synthetischen Wireprüfungen bestanden.
  [Prüfnachweis](quality/search-normalization-2026-11-06.json)
- [x] **R2 · Schwieriges Raster-PDF verbessern.** Geometrisch begründetes Neurendern aus dem
  Original umgesetzt. Problemfall jetzt 4/4 statt 0/4 Sollfelder; erweiterter Korpus 35/36 statt
  27/36. Acht bisherige Rasterfälle weiterhin strikt bestanden. Zeichen-/Wortfehler, Review,
  drei sequenzielle A/B-Läufe und Speicherwerte erfasst. 28 Swift-Tests und der neue echte
  Worker-/MCP-Test bestanden. Keine erfundenen Werte und kein Anbieterwechsel.
  [Prüfnachweis](quality/ocr-raster-r2-2026-11-06.json)
- [x] **R3 · Speichergrenzen, selektiver Lesepfad und Storage-Pilot.** 20.001 Datensätze
  bei einer Freigabe sind lesbar; Größenfehler und Importgrenzen werden getrennt gemeldet.
  Freigabebezogener Cache, dokumentweiser Leser für Teilfreigaben und schneller Gesamtlader
  für bereits geprüfte Vollfreigaben. Getrennter SQLite-Pilot mit Einzelupdates, Alt-JSON-
  Import/Export, Backup/Restore und getestetem SIGKILL-Rollback; **keine produktive Umstellung**.
  64/96/128-MiB-Grenzen, lange synthetische Texte, Neustart, Widerruf und echter Import
  während MCP-Abfragen gemessen. 79 reguläre Swift-Tests plus ein separat ausgeführter
  Storage-Benchmark bestanden; MCP-Vertrag und drei Suchindexmodi per Wire geprüft.
  [Umsetzung und exakte Kommandos](storage-r3.md),
  [Prüfnachweis](quality/storage-r3-2026-11-06.json).
- [x] **R4 · Build, Fähigkeiten und Verbindungsdiagnose.** Geladener Mach-O-Build statt
  alleiniger Produktversion; tatsächliche Werkzeugliste einschließlich Discovery-Pagination;
  eigener Status für fehlende Fähigkeiten, pausierten Zugriff und lokale Protokollfehler.
  Altprozesse gleicher Version erkennen; externe Chatverbindung nicht aus einem lokalen Test
  ableiten. Neue Paketmanifeste binden Build und Werkzeugliste an die Startprüfung.
  23 Swift-Tests sowie Legacy-/Paket-/Verwaltungs-/MCP-/HTTP-Prüfungen bestanden.
  [Umsetzung und Prüfkommandos](build-diagnosis-r4.md),
  [Prüfnachweis](quality/build-diagnosis-r4-2026-11-06.json).
- [x] **R3b · SQLite-Anbindung für ausdrücklich neue Bestände.** Worker, lokale Verwaltung
  und MCP verwenden den gemeinsamen JSON-/SQLite-Einstieg. Einzelne OCR-Datensätze werden
  gezielt gelesen/geschrieben; Commitgeneration bindet Antworten, Handles, Cursor und Suchindex.
  Neue Bestände nur über `create-sqlite`; bestehende JSON-Bestände bleiben unverändert.
  **97 ausgeführte Swift-Testfunktionen bestanden**, ein optionaler Storage-Benchmark übersprungen.
  Echter nativer Worker-/stdio-Test mit SIGKILL während OCR, automatischem Wiederanlauf,
  paralleler Suche, Widerruf und bytegleichen unveränderten Zeilen bestanden. MCP-Vertrag
  und Werkzeug-Parität geprüft. Kein Rollout/Installer, keine Migration oder 20k-Abnahme.
  [Umsetzung, Änderungen und exakte Kommandos](storage-r3b.md),
  [Prüfnachweis](quality/storage-r3b-2026-11-06.json).
- [x] **R3c · Additive CLI-Migration, geprüftes Backup und Rückweg.** Vorschau mit
  Fingerabdruck und Kapazitätsprüfung; JSON→SQLite, geprüfter Restore und aktueller
  SQLite→JSON-Rückweg jeweils an neue Ziele. Vollständiger Vergleich von IDs, Texten,
  Analyse, Status, Originalkopien und Bookmarkbytes; unbekannte Felder werden abgewiesen.
  Bestehende Profile/Installationspfade werden nicht automatisch umgehängt. Der Dateidialog
  kann SQLite für eine ausdrückliche neue Freigabe lesen; Importziele bleiben ausdrücklich.
  **83 ausgeführte Swift-Testfunktionen bestanden**, ein optionaler Benchmark ausgelassen.
  Echter Import/CLI/MCP/Restore/Rückweg, SIGKILL vor Veröffentlichung sowie tatsächliche
  Ablehnung durch einen älteren JSON-only Writer bestanden. Quelle und Freigaben bytegleich.
  [Umsetzung, Grenzen, Änderungen und Kommandos](storage-r3c.md),
  [Prüfnachweis](quality/storage-r3c-2026-11-06.json).
- [x] **R3d-Prüflauf · Matrix ausgeführt und ausgewertet.** 1k/2k/5k/10k/20k lange
  synthetische SQLite-Dokumente, jeweils 100 Freigaben und Vollfreigabe. In allen Größen:
  SQL-/OCR-Prozessabbruch, automatischer Worker-Neustart, unveränderte Freigaben, alte
  Handles/Cursor und Widerruf nach Neustart geprüft. Indexaufbau mit Widerruf und SIGKILL
  am 20k-Bestand mit 100 Freigaben bestanden. Vollständige Pagination in allen zehn Varianten.
  Die Lastgates sind **nicht** bestanden; keine neue Swift-/Zielchat-/Installerabnahme.
  [Prüfnachweis](quality/storage-r3d-2026-11-06.json).
- [x] **R3d · Ursprüngliches NO-GO für große Vollfreigaben aufgearbeitet.** Im ersten
  Lauf überschritten bereits 5k Vollfreigaben Status-/Listen-P95 und Filterbudget.
  R3d.1 bis R3d.4 behandeln diese Befunde. Der unten dokumentierte synthetische GO gilt
  für die geprüfte Matrix. Der allgemeine SQLite-Standardrollout ist ein eigenes Gate.
  [Ursprüngliche Messmethodik und Ergebnisse](storage-r3d.md).
- [x] **R3d.1 · Kleine SQLite-Projektionen für Status und Listen.** SQLite-Writer
  speichert Projektion und Datensatz atomar. Bestehende SQLite-Bestände sind weiterhin
  lesbar und können Projektionen ausdrücklich per CLI aufbauen. Status und ungefilterte
  kompakte Listen laden nur freigegebene Projektionen. Lesen eines Handles lädt genau
  den zugehörigen Datensatz. Alle zehn Lastvarianten bestanden die R3d.1-Grenzwerte.
  20k Vollfreigaben: erster Status 318 ms, Status-P95 101 ms, Listen-P95 155 ms,
  61,4 MiB Peak-RSS. Alle 200 Seiten vollständig in 45,7 s (R3d: 33,7 s).
  Widerruf, veraltete Handles/Cursor und Wiederanlauf geprüft.
  [Umsetzung, Testbefehle und Messwerte](storage-r3d1.md).
- [x] **R3d.2 · Inkrementeller SQLite-Suchindex.** Ganze Wörter, Teilwortfilter und
  gerankte Suche nutzen dieselbe gespeicherte Kandidatengrundlage mit getrennten
  Trefferregeln. Themen laden Belege seitenweise, Fristen die ausgewählten Handles.
  Bei 20k Vollfreigaben liefert der Versicherungsfilter 5.000 Treffer in 417 ms,
  der Teilwortfilter in 181 ms und der seltene gerankte Marker in 558 ms. Die erste
  Themenseite mit Belegen dauert 7,9 s. Alle zehn Abfragevarianten bestanden.
  Die Journalprüfung der großen Matrix brach ab. Der korrigierte Indexabbruch- und
  Wiederanlauftest mit 2.000 Dokumenten bestand separat. 59 Swift-Testfunktionen und
  vier Wire-/Discovery-Prüfungen bestanden. [Bericht](storage-r3d2.md).
- [x] **R3d.3 · Gemeinsame Lastprüfung ausgeführt.** 1k/2k/5k/10k/20k lange
  synthetische Bestände mit echtem 24-Seiten-Import und anschließender OCR bei
  Vollfreigabe. Alle Größen bestanden die Basisprüfungen, den kompakten Filter
  und die seltene Rangsuche. Bei 20k während OCR lagen deren P95 bei 386 und 510 ms.
  Der Indexabbruch mit SIGKILL, Rollback, Integritätsprüfung, Neuaufbau und
  Vollfreigabe-Abfragen bei 20k ist bestanden.
  [Messbericht und Prüfbefehle](storage-r3d3.md).
- [x] **R3d.3 · Synthetische SQLite-Gesamtlastprüfung — GO nach R3d.4.**
  Die wiederholte Matrix besteht bei 1k/2k/5k/10k/20k Vollfreigaben einschließlich
  der breiten Einwort-Rangsuche während OCR. Der Indexabbruch und Wiederanlauf
  mit 20k Rangprojektionen ist erneut bestanden. Die Aussage gilt für die
  dokumentierte synthetische Last und die geprüften Abfragetypen.
- [x] **R3d.4 · Breite Einwort-Rangsuche beschleunigt.** SQLite speichert gewichtete
  Rangmerkmale transaktional. Volltexte liefern die Belege der besten Treffer.
  Bei 20k beträgt der P95 der breiten Rangsuche 879 ms im ruhenden Bestand und
  1,13 s während OCR. 60 Swift-Testfunktionen, stdio und Relay-Discovery bestanden.
  Mehrwortphrasen behalten die bisherige Bewertung. Der 20k-Testbestand belegt
  mit Rangprojektionen rund 872 MiB. [Bericht](storage-r3d4.md).
- [x] **R5 · Seitenprüfung aus dem Importbericht.** Erster betroffener Seitenhinweis,
  geprüfte Originalvorschau, gespeicherter Text und Vorher-/Nachher-Vergleich nach
  frischer OCR. 34 Swift-Tests bestanden. Nativer Import, langer Dateiname, schmaler
  Dialog, Tastaturwechsel und erneute OCR in einer isolierten Instanz geprüft.
  Die synthetische Freigabe blieb bytegleich. [Prüfbericht](setup-quality-r5.md).
- **R5 · VoiceOver-Abnahme entfällt auf Nutzerwunsch vom 7. November.** Die native
  Tastaturbedienung und Accessibility-Beschriftungen sind geprüft. VoiceOver wurde nach
  ausdrücklicher Erlaubnis vorübergehend aktiviert und anschließend wieder ausgeschaltet.
  Die separate VoiceOver-Abnahme wurde übersprungen. R5 ist im vereinbarten Umfang
  abgeschlossen. [Prüfstand](r5-r6-ocr-package.md).
- [ ] **R6 · Gesamtablauf messen · vorerst zurückgestellt auf Nutzerwunsch vom 7. November.**
  Bei Wiederaufnahme die vorhandene Zielchat-Abnahme fortsetzen. Werkzeugaufrufe inklusive
  Fehlern und Wiederholungen sowie die Zeit bis zur
  sichtbaren Tabelle erfassen und lokale Verarbeitung, Relay und Chat getrennt ausweisen.
  Der Server aus `Vauldy.zip` lieferte im lokalen Fristenpilot drei belegte Zeilen mit zwei
  Aufrufen in zusammen 73,4 ms. Auch nach dem Entsperren ist in Safari nur das bestehende
  Vauldy-Plugin verfügbar. Die isolierte Bereitschaftsdatei und das Chat-Audit fehlen.
  [Prüfstand](r5-r6-ocr-package.md).
- [x] **OCR · Defekte eingebettete PDF-Zeichenzuordnung erkennen.** Bei Zeichen aus dem
  privaten Unicode-Bereich oder unerwarteten Steuerzeichen liest Vision die sichtbare Seite.
  A/B-Test mit künstlich defekter Schriftzuordnung und 35 gezielte Swift-Tests bestanden.
  [Prüfstand](r5-r6-ocr-package.md).
- [x] **OCR · Übersehenen Text aus Type-3-Schriften erfassen.** Ausgewählte Type-3-Schriften
  lösen die sichtbare Seitenerkennung aus, auch in PDF-Formularen. Unbenutzte Fontressourcen
  behalten den eingebetteten Schnellpfad. Zwei synthetische Dokumentarten liefern 6/6 statt
  0/6 Körperfelder. 42 Swift-Tests in sechs Suites und der echte Worker-/MCP-Test einschließlich
  Cache, Frischerkennung, Quellenbelegen und Widerruf bestanden. Cachekonfiguration v7
  verwirft alte Kopfzeilen-Checkpoints. [Umsetzung und Befehle](ocr-vector-text.md),
  [Prüfnachweis](quality/ocr-vector-text-2026-11-07.json).
- [x] **OCR · Quellengebundene Zeilenkoordinaten.** Optionale lokale Metadaten binden
  UTF-16-Textbereiche und Rechtecke an Original-Prüfsumme, Seite, OCR-Konfiguration und
  Seitentext-Prüfsumme. Randbeschnitt, Bildkacheln, PDF-Regionen, Drehung und Hybridtext
  werden zurückgerechnet. Alte Datensätze bleiben lesbar. 60 Swift-Tests in neun Suites
  und der echte Worker-/MCP-Test bestanden. Die Geometrie bleibt lokal, Cache und
  Frischerkennung erhalten die Bindung. [Umsetzung und Befehle](ocr-line-layout.md),
  [Prüfnachweis](quality/ocr-line-layout-2026-11-07.json).
- [x] **OCR · Textblöcke und visueller Abdeckungsvergleich.** Benachbarte Zeilen werden
  geometrisch gruppiert. Eine zusätzliche lokale Vision-Textbereichserkennung prüft
  Zeichenrechtecke gegen die gespeicherten Zeilen. Zwei synthetische PDFs mit freien
  Vektortexten erhalten jeweils drei gezielte Prüfhinweise. Die Grafikvorlage löst
  keinen zusätzlichen Hinweis aus. 68 Swift-Tests in zehn Suites und zwei echte
  Worker-/MCP-Prüfungen bestanden. Metadaten bleiben lokal, v9 schließt alte
  Zeilen-Checkpoints aus. [Umsetzung und Befehle](ocr-block-coverage.md),
  [Prüfnachweis](quality/ocr-block-coverage-2026-11-07.json).
- [x] **OCR · Auffällige Regionen gezielt nachlesen.** Vier Bereiche pro physischer Seite,
  je zwei übereinstimmende Vision-Durchläufe, räumliche Bindung und erneute Abdeckungsprüfung.
  Bestehender Text und Zeilenrechtecke bleiben erhalten. Zwei synthetische Vorlagen liefern
  6/6 zusätzliche Felder. Der echte Worker-/MCP-Test bestätigt drei erhaltene Werte und
  den abgewiesenen widersprüchlichen Betrag. 73 Swift-Tests in elf Suites sowie beide
  Worker-/MCP-Prüfungen bestanden. Cachekonfiguration v10, Cacheabruf, Frischerkennung,
  Quellenbelege und Widerruf sind geprüft. [Umsetzung und Befehle](ocr-marked-region-recovery.md),
  [Prüfnachweis](quality/ocr-marked-region-recovery-2026-11-07.json).
- [ ] **Weitere OCR-Qualität.** Sehr helle, bisher leer klassifizierte Seiten und
  plausibel falsche Zuordnungen innerhalb bereits abgedeckter Textrechtecke gesondert
  prüfen. Mehrdeutige Kennungen und eine breitere Qualitätsmessung an unterschiedlichen
  Vorlagen bleiben eigene Prüfpunkte.

## Abgeschlossen

- [x] Beide Repository-Stände und die Quellabweichungen erfassen. Deutscher Masterprompt und Bestandsaufnahme liegen im App-Repo.
- [x] MCP-Paketierung auf gemeinsame Version, Plattformprüfung und Paketnachweis umstellen.
- [x] Vollständigen Softwarewechsel, Startprüfung und Rollback mit synthetischem Bestand prüfen.
- [x] Reale lokale stdio-Verträge für Privacy, Pagination und Widerruf absichern.
- [x] Installationsassistent in einer isolierten Instanz bis zum lokalen Starttest durchspielen.
- [x] Rekursiven Ordnerimport und gemeinsamen Dokumentzähler implementieren. Der Import von zwölf synthetischen PDFs wurde verifiziert.
- [x] Importoberfläche verbessern. Fortschritt nennt Datei, Schritt und Seitenzahl. Der Bericht trennt neue, bereits vorhandene, fehlgeschlagene und übersprungene Dateien mit Details. Importfilter, sichtbare Auswahl und Gesamtauswahl unterscheiden. Dateiimport, einmaligen Ordnerimport und Überwachung klar benennen. [Ablauf](mcp-installation.md#bestehenden-bestand-und-chatfreigabe-aktualisieren)
- [x] Seitenmarkierungsvertrag in `VauldyDocumentCore` extrahieren und optionalen FTS5-Speicherpilot anbinden.
- [x] Agensi-Anweisungspaket bauen. Die Zielclient-Abnahme steht separat aus.
- [x] Entwicklungsskills an den eigenständigen MCP und den aktuellen Werkzeug-/OCR-Stand anpassen. Drei aktive Skills plus Verweis für den früheren iOS-Skillnamen installiert. Versionierbare Kopien unter `skills/development`, Kunden-Anweisungspaket separat auf 1.1.1 aktualisiert.
- [x] Lokales Installationspaket vom 05.11.2026 mit allen sechs Programmen frisch bauen und an synthetischen Beständen prüfen. Version 0.13.0, arm64, Mindestziel macOS 14.0. ZIP-Signatur, sechs Werkzeuge, Import-Worker, Einrichtungsstart und Update/Rollback lokal bestanden. Ad-hoc-Testpaket; Kundenabnahme bleibt offen.

## Architektur zuerst

- [x] Privat abgelegten, aus JSON wiederaufbaubaren SQLite-Index für ausdrücklich freigegebene Datensätze implementieren. Inkrementelle Änderungen, Profilbindung und Korruptionsrückweg absichern.
- [x] Kompakte Listenmetadaten mit gültigem JSON-Stand und Profil verbinden. Gleichheit der Antworten, Cursor und Quellen prüfen.
- [x] Cachegröße, kompakte Projektion und FTS5 getrennt an 20.000 synthetischen Dokumenten messen. Die Größen 1.000, 2.000, 5.000, 10.000 und 20.000 prüfen. Latenz einschließlich P95, Peak-RSS, Vollständigkeit und Wiederverwendung über Prozessneustarts erfassen.
- [x] Index bei gleichzeitigem Freigabewiderruf, Entfernen einer Verbindung und Prozessabbruch absichern. Stagingreste, SQLite-Journal und liegen gebliebenen getrennten Cache beim Wiederanlauf prüfen.
- [x] Kompakte Pagination im lokalen stdio-Server als Standard für `includeExcerpts=false` aktivieren. Der Dateiindex bleibt optional. JSON bleibt führend. Eine spätere Formatänderung braucht eine eigene Backup- und Restore-Abnahme.
- [x] Verträge des eigenständigen MCP für Dokument-IDs, Seitenbelege, Suchvollständigkeit, Datenschutz und Widerruf festlegen. Interne Swift-Modelle und versionierte Werkzeugantworten abgrenzen. Kompatibilität mit bestehenden Clients und lokalen Daten anhand synthetischer Testfälle prüfen.
- [x] Einen direkten Chatablauf als reproduzierbare Folge der vorhandenen MCP-Werkzeuge messen. Erwartete Treffer, Feldwerte und Fundstellen am synthetischen Versicherungsbestand festhalten.
- [x] Einen lokalen Recherche-Agenten für diesen Auftrag erproben. Listen- und Fundstellenseiten vollständig abrufen. Felder mit Seitenbelegen ausgeben und fehlende, pseudonymisierte oder widersprüchliche Angaben kennzeichnen.
- [x] Agenten und direkten Referenzablauf am selben Bestand vergleichen. Abbruch, Zeitlimit, Quelländerung und Freigabewiderruf prüfen. Den vorhandenen lokalen Modellplaner bei gesperrtem Prozessnetz ausführen.
- [x] Den Pilot als separates Werkzeug im lokalen Codex-Host bereitstellen. Werkzeugerkennung, echte Aufrufe im isolierten Testthread, Tabelle und Widerruf prüfen. Die direkte MCP-Prüfung deckt auch Abbruch und Zeitlimit ab.
- [x] Die automatische Werkzeugwahl aus Freitext mit dem lokalen Apple-Modell und dem isolierten Codex-Host prüfen. Tabelle, Seitenbelege, Widerrufsfehler und ausbleibende Dokumentaufrufe bei engeren oder sachfremden Fragen belegen.
- [x] Themenübersicht als lesendes MCP-Werkzeug bereitstellen. „Zeige alle Versicherungen“ mit synthetischem Bestand in einem Aufruf messen. Policenüberschriften, Erwähnungen und Beleglücken trennen. Datenschutz, Folgeseiten, Quellenänderung und Widerruf prüfen.
- [ ] Themenübersicht im regulären ChatGPT-Gespräch mit einem synthetischen Profil abnehmen. Vorprüfung am 04.11.2026: Die ChatGPT-Pluginseite verlangte eine Anmeldung. Ein separater privater MCP-Testanschluss war in dieser Sitzung nicht verfügbar. Die lokale Vorprüfung mit 150 synthetischen Dokumenten lieferte 19 Kandidaten in einem `tools/call` (448,2 ms). Aufrufzahl und Zeit bis zur sichtbaren Tabelle im regulären Chat bleiben offen. Vor einer Relay-Aktualisierung die Unterstützung auf den Test-Macs prüfen.
- [ ] Die Werkzeugwahl und Darstellung in einem regulären ChatGPT-Webgespräch mit synthetischem Profil abnehmen. Vorprüfung am 04.11.2026. Die erreichbare Weboberfläche zeigte die Anmeldung. Der separate Recherche-Adapter war lokal funktionsfähig. Für den Chat-Aufruf fehlt ein privater Testanschluss, der diesen Adapter im Test-Workspace anbietet. [Abnahmestand und Kriterien](local-first-release.md#abnahme-im-regulären-chatgpt-gespräch)
- [x] Gezielte Feldauslese als sechstes lesendes Werkzeug implementieren. Bis zu zehn ausgewählte Dokumente und acht feste Felder bündeln. Wörtliche, ausdrücklich beschriftete Werte mit physischen Seiten ausgeben. Fehlende, maskierte, widersprüchliche Angaben und unterschiedliche Kostenrollen unterscheiden. Lokale stdio-, HTTP-/OAuth- und Relay-Prüfungen bestanden. [Vertrag und Grenzen](mcp-mvp.md#vertrag-der-feldauslese-v1)
- [x] Fassungsvergleich lokal umsetzen und prüfen. Zwei ausdrücklich ausgewählte Fassungen bei passender belegter Zuordnung vergleichen. Unterschiedliche und nur einseitig belegte Feldtexte mit Seitenbelegen ausgeben. Unklare Paare offenlassen. Originale und gespeicherte Analysen bleiben unverändert. [Werkzeugvertrag](mcp-mvp.md#vertrag-des-fassungsvergleichs-v1)
- [x] Fristenübersicht für bis zu fünf ausgewählte Dokumente pro Aufruf implementieren und synthetisch prüfen. Feste Termine, wörtliche Fristregeln und rechnerische Stichtage mit Seitenbelegen unterscheiden. Fehlende oder widersprüchliche Angaben offenlassen. [Werkzeugvertrag](mcp-mvp.md#vertrag-der-fristenübersicht-v1)
- [ ] Fristenübersicht im regulären ChatGPT-Gespräch mit dem separaten synthetischen Anschluss abnehmen. Werkzeugaufrufe, Fehler und Wiederholungen zählen. Zeit bis zur ersten sichtbaren Tabellenzeile und vollständige Tabelle prüfen. [Vorprüfung vom 06.11.2026](#iteration-11--zielchat-abnahme-der-fristenübersicht-vom-06112026)
- [ ] Den langen Vertragsabruf auf weniger Werkzeugrunden reduzieren. Diagnose vom 05.11.2026 am letzten erhaltenen Aufrufblock vom 04.11.2026, etwa 21.25–21.29 Uhr: 21 Anfragen in 234 Sekunden, davon sieben Leseanfragen mit `invalidArguments`. Erfolgs- und Fehlerantworten benötigten zusammen 24,8 Sekunden lokale Verarbeitung, einschließlich 20,8 Sekunden für die erste Suchantwort. Der Bezug zu einem konkreten Vertrag wurde anhand dieser inhaltsfreien Metadaten nicht festgestellt. Den tatsächlichen Chatablauf mit gebündelter Feldauslese und korrekten Werkzeugargumenten erneut messen.
- [x] OCR-Optimierung am synthetischen Bestand erneut prüfen (04.11.2026). Alle 22 gezielten Tests inklusive acht Raster-PDF-Fällen bestanden mit Zugriff auf native macOS-Texterkennung. Der Worker-/MCP-Test bestätigte unter anderem einen frischen OCR-Durchlauf und die Seitencache-Wiederholung. Sequenzieller Vergleich: 438 ms für die gemischte PDF nach dem System-Warmlauf, 381 ms für eine neue PNG und 208 ms für die PDF-Wiederholung aus dem Cache. Der erste Referenzimport dauerte 58,026 s, der erneute Referenzimport im neuen Prozess nach System-Warmlauf 332 ms. Aus der Differenz lässt sich der Effekt der OCR-Optimierung nicht isolieren. [Prüfbefehle](mcp-mvp.md#bauen-paket-und-prüfung)
- [x] Gezielten lokalen OCR-Zweitlauf umsetzen und gegen denselben Vision-Erstlauf messen. Sieben synthetische Scans, je 23 von 28 exakten Sollfeldern, zwei zusätzliche Prüfmarkierungen. Der saubere Kontrollscan löste keinen Zweitlauf aus. [Vergleich](mcp-mvp.md#vergleich-des-ocr-zweitlaufs)
- [ ] Erkennungsgewinn für blasse Raster-PDFs und schwer lesbare Kennungen an einem größeren synthetischen Korpus belegen. Exakte Feldwerte, Fehlalarme und Wiedererkennung vollständig verfehlter Zeilen separat messen.
- [ ] Lokalen Import und OCR-Worker unter kontrollierter Last messen. Vor einer Kundenfreigabe Referenz-Mac, Dokumentmix, P95, Durchsatz, Speichergrenzen und Suchqualität festlegen.
- [ ] Lokale Worker-Parallelität begrenzen, Abbruch und Wiederaufnahme nach Absturz belegen und einen Diagnosebericht mit technischen Zählern prüfen.
- [ ] Festlegen, wie ein bewusst gestarteter lokaler Import und sein Gesamtfortschritt im Chat sichtbar werden. Technische Einrichtung und Freigaben separat betrachten.

## Nach der Architektur

- [ ] Zwei kompatible Developer-ID-Pakete bauen, notarisieren und die Tickets im finalen ZIP prüfen.
- [ ] Auf einem frischen Offline-Test-Mac Erststart, Update und Rollback mit synthetischen Daten und stabilen Clientpfaden belegen.
- [ ] Agensi-Skill im Zielclient mit dem bestehenden lokalen MCP prüfen. Inventar, Quellenlesen und Widerruf abnehmen.
- [ ] Freigabeentscheidung für Kundenauslieferung und 20.000 reale Dokumente dokumentieren.
- [ ] Optionale Remote- und Lizenzfunktionen bei Bedarf in einem separaten Architekturvorschlag entscheiden. Lokalen stdio-Betrieb offline weiterhin prüfen.

## Iterationen

| Iteration | Stand | Nachweis und nächster Schritt |
| --- | --- | --- |
| 0 · Lokale Produktschnittstelle | Abgeschlossen | Release-Gates, Update/Rollback, Assistent und rekursiver Import. Interne und Kundenabnahme werden getrennt geführt. |
| 1 · Architekturpilot | Abgeschlossen | Seitenvertrag und zuschaltbarer FTS5-Speicherindex. Synthetisches Inventar mit 20.000 Dokumenten vollständig. |
| 2 · Persistenz und Projektion | Abgeschlossen | 21 gezielte Swift-Tests bestanden. Geprüft sind unter anderem Neustart, inkrementelle Änderungen, Korruptionsreparatur, Cursor und Widerruf. |
| 3 · Variantenmessung | Abgeschlossen | Fünf Varianten bei fünf Bestandsgrößen. Bei 20.000 Dokumenten lieferte der Dateimodus alle 200 Seiten in 30,62 s und verwendete den Index nach Neustart bytegleich wieder. [Messwerte](local-first-release.md#variantenmessung) |
| 4 · Widerruf, Wiederanlauf und Standardbetrieb | Abgeschlossen | Der gestoppte Indexschreiber liefert nach Widerruf keine Treffer. Nach zwei realen `SIGKILL`-Abbrüchen sind Bestand und Berechtigungen intakt. Kompakte Pagination ist lokaler Standard. Im 20.000er-Vergleich sank der Median der ersten zehn Folgeseiten von 703 auf 126 ms. [Prüfbefehle](local-first-release.md#prüfbefehle) |
| 5 · MCP-Verträge für den Chatbetrieb | Abgeschlossen | Werkzeugvertrag v1, Seitenbelege, veraltete Handles und Freigabeprüfung vor der Ausgabe abgesichert. 54 gezielte Swift-Tests, separater nativer OCR-Test und MCP-Protokollprüfungen bestanden. [Werkzeugvertrag und Referenzauftrag](mcp-mvp.md#vauldy-werkzeugvertrag-v1) |
| 6 · Recherche-Agent | Lokale Prüfungen bestanden | Der reguläre ChatGPT-Test steht aus. Die Vorprüfung ergab zwei Voraussetzungen, einen angemeldeten Test-Workspace und einen privaten Anschluss für den separaten Recherche-Adapter. [Abnahmestand](local-first-release.md#abnahme-im-regulären-chatgpt-gespräch) |
| 7 · Themenübersicht | Lokal geprüft, Zielchat offen | Ein MCP-Aufruf über 150 synthetische Dokumente mit 149 Freigaben und 19 Kandidaten. Kalt 404,9 ms Median und 450,0 ms P95 (20 Läufe). Warm 373,2 ms Median und 425,2 ms P95 (30 Läufe). Für den Zielchat fehlen die Anmeldung im Test-Workspace und ein separater Testanschluss. [Vertrag und Messbefehl](mcp-mvp.md#vertrag-der-themenübersicht-v1) |
| 8 · Gezielte Feldauslese | Lokal geprüft, Zielchat offen | Ein Inhaltsaufruf statt sechs Leseaufrufen am selben 18-seitigen synthetischen Vertrag. Vier beschriftete Felder mit Seitenbelegen. 43 gezielte Swift-Tests einschließlich nativer OCR und zehn Relay-Tests bestanden. stdio, HTTP/OAuth, Discovery-Parität und unveränderter v1-Basisvertrag geprüft. Die tatsächliche ChatGPT-Laufzeit bleibt offen. [Vertrag, Messwerte und Prüfbefehle](mcp-mvp.md#vertrag-der-feldauslese-v1) |
| 9 · Fassungsvergleich | Lokal geprüft, Zielchat offen | Siebtes Werkzeug. Ein Vergleichsaufruf für zwei ausgewählte 18-seitige synthetische Fassungen. Änderungen der Feldtexte mit Seitenbelegen, unklare Paare ohne Vergleichszeilen. 44 Swift-Tests, stdio, HTTP/OAuth, Relay-Parität und zehn Relay-Tests bestanden. |
| 10 · Fristenübersicht | Lokal geprüft, Zielchat offen | Achtes Werkzeug. Fünf ausgewählte Dokumente in einem Offline-Aufruf (104,7 ms). 22 synthetische Datensätze, 45 Swift-Tests, HTTP/OAuth, Relay-Parität und 10 Relay-Worker-Tests bestanden. [Prüfnachweis](quality/deadline-overview-2026-11-06.json) |
| 11 · Zielchat-Abnahme der Fristenübersicht | Plugin-Einrichtung blockiert | ChatGPT meldete nach Freigabe und einem Wiederholungsversuch ein Anfragelimit. Am isolierten Profil kam keine Anfrage an. Aufrufzahl und Tabellenzeit im Chat sind offen. |
| R1 · Suchtext-Normalisierung | Umgesetzt und lokal geprüft | Sieben Schreibvarianten in drei Indexmodi, wörtliche Fundstellen auf Seite 2, alte Indexversion, Quelländerung und Widerruf geprüft. 52 Swift-Tests in sechs Suites bestanden; Basis-Wirevertrag, Themenübersicht, Feldauslese und Relay-Discovery bestanden. |
| R2 · Raster-PDF-Qualität | Umgesetzt und lokal geprüft | Problemfall 4/4 statt 0/4; neun Scans 35/36 statt 27/36 Felder. 28 Swift-Tests inklusive acht strikter Raster-Originalfälle bestanden. Worker speichert 12/12 Felder aus drei schwierigen PDFs; geschützte MCP-Ausgabe, Cache/Frischerkennung und Widerruf geprüft. |
| R3d · SQLite-Lastprüfung | Gemessen; Lastfreigabe NO-GO | Fünf Größen bis 20k, je 100 Freigaben und Vollfreigabe. 100er-Auswahlen bestehen die lokalen Gates. 20k Vollfreigabe: Status kalt 9,21 s, Liste P95 11,82 s bei nur 17/25 Aufrufen, 1.197 MiB Server-RSS, Filter > 30 s. Pagination, Widerruf und Wiederanlauf bestanden. Als Nächstes R3d.1. |
| OCR · Gezielter Zweitlauf | Lokal geprüft | 33 gezielte Swift-Tests bestanden. Der A/B-Test zeigte zwei zusätzliche Prüfmarkierungen und dieselbe Zahl exakt erkannter Felder. |
| Import · Bedienung | Nativ geprüft | 22 Swift-Tests bestanden. Der gemischte Ordnerimport meldete je eine neue, vorhandene, fehlgeschlagene und übersprungene Datei. Im Assistenten wurden gefilterte Auswahl, Gesamtauswahl und der Abbruch eines laufenden Imports geprüft. |
| Skills · Aktueller MCP-Stand | Aktualisiert und geprüft | Architektur, Import/OCR und Suche/Evidenz auf MCP-only umgestellt. Vier installierte Skillstrukturen, zehn Referenzen und elf bytegleiche Repository-Kopien geprüft. Zwei reale synthetische MCP-Wireprüfungen bestanden. Keine neue Swift-/Installerabnahme aus der Skillpflege abgeleitet. |
| Paket · Aktueller MCP-Branch | Frisch gebaut, lokal geprüft | Sechs Programme aus einer bytegeprüften Kopie von 91 Paket-/Quelldateien gebaut. 50 Swift-Tests in acht Suites sowie zwölf Paketprüfungen bestanden. Nach Anleitungsergänzung Signatur, Verwaltung, Update/Rollback und Einrichtungsstart am finalen ZIP erneut bestanden. Notarisierung, frischer Offline-Mac und Zielchat bleiben offen. |

### Iteration R5 · Qualitätsprüfung in der MCP-Einrichtung

Fortschritt **umgesetzt und nativ geprüft**. Der Importbericht öffnet die betroffene
Originalseite. Tastatur, langer Name, schmaler Dialog und Vergleich nach erneutem
Lesen sind am synthetischen Bestand nachgewiesen. Die separate VoiceOver-Abnahme
entfällt auf Nutzerwunsch vom 7. November. R5 ist damit im vereinbarten Umfang
abgeschlossen. [Ablauf und Prüfungen](setup-quality-r5.md).

### Iteration R3d.4 · Rangsuche

Fortschritt **Rangprojektionen umgesetzt und synthetische Gesamtlastprüfung bestanden**.
Das frühere Timeout der breiten Suche nach „Versicherung“ ist in der wiederholten
Matrix beseitigt. Rangfolge, Quellenbelege, Freigaben und der Wiederanlauf nach
Indexabbruch sind geprüft. Als Nächstes folgt **R5**, die Qualitätsprüfung in der
MCP-Einrichtung. [Messbericht](storage-r3d4.md).

### Iteration R3d.3 · Gemeinsame Lastprüfung

Fortschritt **Prüflauf abgeschlossen, Lastfreigabe NO-GO**. Der echte Import erweiterte
keine Freigabe. Nach ausdrücklicher Vollfreigabe liefen die kompakten Filter und seltenen
Rangabfragen während nativer OCR in allen Größenstufen innerhalb der Grenzen. Bei 20k
wurden alle Einträge vollständig paginiert. Der Indexabbruch und Wiederanlauf bei
20k sind bestanden. Als Nächstes folgt **R3d.4** für häufige Begriffe in der Rangsuche.
[Messbericht](storage-r3d3.md).

### Iteration R3d.2 · Inkrementeller SQLite-Suchindex

Fortschritt: **Index angebunden, Abfragegrenzen bis 20.000 synthetische Vollfreigaben
bestanden.** Treffer, Originalseiten, Pagination und Freigaben wurden geprüft. Der
Wiederanlauf des abgebrochenen Indexaufbaus ist separat bei 2.000 Dokumenten bestätigt.
Als Nächstes folgt **R3d.3**, die gemeinsame Lastabnahme mit parallelem Import und
wiederholten Suchen. [R3d.2-Bericht](storage-r3d2.md).

### Iteration R3d.1 · SQLite-Projektionen

Fortschritt: **Status und ungefilterte kompakte Listen sind bis 20.000 synthetische
Vollfreigaben innerhalb der gesetzten Grenzen gemessen.** Vollständige Pagination und
Lesen per Handle sind geprüft. Der Gesamtabruf aller Seiten war langsamer als in R3d.
Als Nächstes folgt **R3d.2** für Textfilter, gerankte Suche und Übersichten.
[R3d.1-Bericht](storage-r3d1.md).

### Iteration R3d · Lastprüfung vom 06.11.2026

Fortschritt: **Der Prüflauf ist umgesetzt und vollständig über alle fünf Bestandsgrößen
ausgeführt. Die Lastfreigabe bleibt NO-GO. Als Nächstes folgt R3d.1: kleine SQLite-Projektionen
für Status und kompakte Listen.** Bei 20k Dokumenten und 100 Freigaben beträgt die Listen-P95
91,4 ms; bei 20k Vollfreigabe 11,82 s aus einem nach Zeitlimit unvollständigen Messblock.
Die SQLite-Datei belegt rund 720 MiB, der Server bis zum Abbruch rund 1,17 GiB RAM.
SQL-Rollback, OCR-Worker-Neustart, vollständige Pagination, Widerruf und unveränderte Quelle
nach den Leseprüfungen bestanden. Der zusätzliche Indexabbruch-/Widerrufstest verwendet
ausdrücklich 100 Freigaben aus dem 20k-Bestand. Keine Kundenmigration oder Standardumstellung.
Details und exakte Befehle: [R3d-Bericht](storage-r3d.md).

### Iteration R3c · Migration und Rückweg vom 06.11.2026

Fortschritt: **R1 bis R4 sowie R3b und das additive CLI-Inkrement R3c sind umgesetzt.
Als Nächstes folgt R3d: Lastabnahme des angebundenen SQLite-Pfads.** Die Migration erzeugt
geprüfte neue Ziele; vorhandene Kundenbestände, Freigaben und Installationspfade wurden nicht
umgestellt. Ein komfortabler Umschaltassistent bleibt zusätzliche UI-Arbeit, keine durch
R3c behauptete Kundenumstellung. SQLite wird vor R3d nicht zum allgemeinen Standard.
Details: [R3c-Bericht](storage-r3c.md), [vorherige SQLite-Anbindung](storage-r3b.md).

### Iteration R2 · Raster-PDF-Qualität vom 06.11.2026

Ursache: Die bisherige PDF-Zeichentransformation zentrierte den kleinen Scan bei 1× im größeren
Bitmap. Eine bloße Erhöhung der Bitmapauflösung vergrößerte die Schrift nicht. Die neue
Geometrieprüfung nutzt die vorhandenen Vision-Zeilenboxen: Mindestens zwei und mindestens die
Hälfte der Zeilen müssen kleiner als 16 Pixel sein. Nur für eine bekannte einzelne vollseitige
Rastergrafik wird dann einmal explizit in Pixelkoordinaten neu gerendert, begrenzt durch native
Pixeldichte und 3072 Pixel lange Kante. Die Entscheidung verwendet keine Textwerte oder Sollangaben.
Der bestehende konservative Zeilen-Zweitlauf und seine Konfliktregeln bleiben bestehen.

Ein unbedingter neuer Renderpfad verursachte Regressionen im bestehenden Korpus und wurde
verworfen. Die endgültige gezielte Variante lässt alle acht vorhandenen strikten Rasterfälle
auf ihrem bisherigen Pfad bestehen. Reine Kontraständerungen und größere Bitmaps ohne korrekte
Transformation zeigten ebenfalls keinen zuverlässigen Gewinn und wurden nicht übernommen.

Neu gemessene Ergebnisse gegen den bisherigen Standard **einschließlich Zeilen-Zweitlauf**:

| Maß | Vorher | Nachher |
|---|---:|---:|
| Vier Sollfelder des schwierigen Raster-PDFs | 0/4 | 4/4 |
| Exakte Sollfelder in neun synthetischen Scans | 27/36 | 35/36 |
| Zeichenfehler im normalisierten Korpus (984 Zeichen) | 21 | 6 |
| Wortfehler im normalisierten Korpus (92 Wörter) | 10 | 3 |
| Problemfall: Median gesamte Seitenerkennung, drei warme A/B-Läufe | 293 ms | 292 ms |

Die nahezu gleiche Medianzeit ist keine belastbare Beschleunigungszusage. Das Neurendern
verarbeitet im Problemfall zusätzlich 554.400 Pixel (etwa 2,12 MiB pro RGBA-Bitmap); die Summe
der gerenderten Pixel steigt von 1.247.400 auf 1.801.800. Die drei `swift test`-Messaufrufe
meldeten 170.065.920 / 170.393.600 / 171.212.800 Bytes maximale Residentgröße. Das sind Werte
des Testaufrufs, keine isolierte Vorher-/Nachher-Speicherdifferenz je OCR-Dokument.

Die bekannte mehrdeutige Kennung bleibt bei 3/4 korrekten Feldern und erhält Review. Der sehr
blasse Rasterkontrollfall hat vier korrekte Felder, aber weitere Transkriptfehler und bleibt
ebenfalls prüfbedürftig. Somit wird weder vollständige OCR-Qualität noch eine allgemeine
Erkennungsquote für echte Archive behauptet. Die sauberen Kontrollfälle bekommen keinen neuen
Raster-Zweitlauf. Kennungen und Beträge werden nicht aus erwarteten Testwerten ersetzt.

**Prüfungen:** 28 Swift-Tests in vier Suites in 15,990 s bestanden, einschließlich der acht
strikten Raster-Originale, Crop-/Rotationsmarken bei 0/90/180/270°, Pixelgrenze, Cacheversion,
nativer PDF-/PNG-Erkennung, Speicherung, Wiederanlauf und Abbruch. Drei weitere sequenzielle
A/B-Testläufe bestanden. Der neu gebaute Release-Worker speicherte 12/12 Sollfelder aus drei
schwierigen PDFs. Explizite Freigabe, unveränderte Originale, Privacy, physische Seite 1,
Cachetreffer, cachefreier Retry und Widerruf bestanden über reale CLI-/MCP-Aufrufe.
Bestehender Import-/Worker-Wiretest, R1-Suchnormalisierung in drei Modi und Basis-MCP-Wiretest
bestanden ebenfalls. Die vollständige Installerregression und ein regulärer ChatGPT-Test
wurden in dieser Iteration nicht ausgeführt.

Cachekonfiguration v5 schließt alte OCR-Checkpoints aus. Abgeschlossene produktive Importe
werden nicht automatisch geändert. Für vorhandene Dokumente ist weiterhin „Text erneut lesen“
erforderlich. `pdfScaleRetries` ist ein neues optionales lokales Metrikfeld; alte Metriken bleiben
lesbar. Die neue Prüfung ist im Regressionsskript eingetragen; native OCR-Tests laufen dort
nun ausdrücklich sequenziell.

Dateien dieser Iteration:

- `Sources/VauldyCore/NativeLocalDocumentOCR.swift`, `PDFContentInspection.swift`, `LocalOCRMetrics.swift`, `LocalOCRPageCache.swift`.
- `Tests/VauldyMCPRuntimeTests/OCRTargetedRetryTests.swift`, `BaseAnalysisMCPTests.swift`.
- `scripts/mcp/raster_ocr_quality_smoke_test.py` (neu), `regression_test.py`.
- `docs/base-analysis.md`, diese To-do-Liste, `docs/quality/ocr-raster-r2-2026-11-06.json` (neu).

Exakte Build-/Testkommandos, Binärhashes, Fallwerte, Messwiederholungen und die verworfenen
Versuche stehen im [maschinenlesbaren Nachweis](quality/ocr-raster-r2-2026-11-06.json).
Kernkommandos des tatsächlich verwendeten isolierten Builds:

```sh
VAULDY_OCR_AB_FIXTURES=/private/tmp/vauldy-r2-wire-fixtures swift test --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter 'OCRTargetedRetryTests|OCRWhiteMarginsTests|BaseAnalysisMCPTests|LocalImportTests'
python3 scripts/mcp/raster_ocr_quality_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-local /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp /private/tmp/vauldy-r2-wire-fixtures
python3 scripts/mcp/import_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-local /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
```

Kein neues Installationspaket, keine Produktivinstallation, keine Freigabeerweiterung und kein
Relay-Rollout. Bestehende anderweitige Änderungen im MCP-Branch wurden erhalten.

### Iteration R1 · Suchtext-Normalisierung vom 06.11.2026

Fortschritt: **R1 abgeschlossen; R2 OCR-Qualität ist der nächste Umsetzungsschritt.**
Die neue Suchprojektion ergänzt Schreibvarianten für einzelne Zeilenumbrüche nach Bindestrich,
Soft Hyphen, Zero Width Space, Word Joiner und internes U+FEFF. Sie bewahrt die ursprünglichen
Teilwort-Tokens und schließt Zahlen, erkannte Kennungsbeschriftungen, Großbuchstaben-Codes,
normale Bindestriche sowie Absatz-/Seitengrenzen von der Zusammenziehung aus. Die Regel ist
konservativ für deutsche/englische Wortfragmente; sie ist keine allgemeine OCR-Korrektur.

Listenfilter, Rangsuche und FTS nutzen dieselbe Projektion. Fundstellen und Themenübersicht
bilden Treffer nach vollständiger Privacy-Verarbeitung auf wörtliche Quellbereiche zurück ab.
Der optionale SQLite-Index erhält `user_version=3`; ein alter abgeleiteter Index wird bei Verwendung
neu aufgebaut. Originale, gespeicherter OCR-Text, JSON-Format und Freigaben werden nicht migriert.

Neu ausgeführt: Release-Build und **52 Swift-Tests in sechs Suites, 5,181 s**, darunter fünf
neue Normalisierungstests. Der neue Wiretest findet **7/7 Varianten** in Standard-, Speicher-FTS-
und Datei-FTS-Betrieb. Fünf negative Kontrollfälle und ein nicht freigegebenes Dokument bleiben
korrekt behandelt. Literale Belege auf Seite 2, vollständige Pagination, unveränderte Bestands-
und Profilbytes vor den ausdrücklich simulierten Änderungen, Indexversion/Neustart,
Quelländerung und Widerruf sind geprüft. Der gesamte paginierte Listenabruf benötigte lokal
72,1 / 72,2 / 96,1 ms in den drei Modi; dies ist keine Einzelaufruf- oder ChatGPT-Zeitmessung.

Zusätzlich bestanden: bestehender Basis-Wiretest, Themenübersicht (150 synthetische Dokumente),
Feldauslese (sieben Dokumente, 17 Prüfgruppen) und unveränderte Relay-Discovery. Kein Relay-Rollout.
Frühe Test-Fixtures hatten fehlende Pflichtparameter, einen für SQLite-NOFOLLOW ungeeigneten
temporären Pfad und änderten zunächst nicht die ausgewählte Testquelle. Diese Testaufbaufehler
wurden behoben; nur die abschließenden erfolgreichen Läufe zählen zum Ergebnis.

Die Quellen einschließlich Package-Dateien und Tests wurden mit der isolierten Buildkopie
byteweise abgeglichen. Exakte Kommandos, Ergebnisse und Binärhash stehen im
[maschinenlesbaren Nachweis](quality/search-normalization-2026-11-06.json).

```sh
swift build -c release --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --product vauldy-mcp
swift test --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter 'SearchTextNormalizationTests|MCPPassageTests|MCPScalabilityTests|MCPPrivacyBoundaryTests|MCPRetrievalCompletenessTests|VaultRuntimeTests'
python3 scripts/mcp/search_normalization_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
python3 scripts/mcp/topic_overview_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
python3 scripts/mcp/field_extraction_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --check
git --no-optional-locks -c core.fsmonitor=false diff --check
```

Dateien dieser Iteration:

- Core: `VaultSearchText.swift` (neu), `VaultDocumentFilter.swift`, `VaultRuntime.swift`, `SQLiteVaultTokenIndex.swift`.
- Runtime: `MCPSourceExcerpt.swift`, `ReadOnlyMCPRuntime.swift` (Themenfundstellen).
- Tests: `SearchTextNormalizationTests.swift` (neu), `search_normalization_smoke_test.py` (neu), Integration in `regression_test.py`.
- Dokumentation: `docs/mcp-mvp.md`, diese To-do-Liste und `docs/quality/search-normalization-2026-11-06.json` (neu).

Die vorhandenen anderweitigen Branchänderungen wurden erhalten. Kein neues Installationspaket,
keine Produktivinstallation und keine neue reguläre ChatGPT-Abnahme in dieser Iteration.

### Iteration 11 · Zielchat-Abnahme der Fristenübersicht vom 06.11.2026

In Safari ist der reguläre Chat angemeldet. Der in Safari angelegte private Tunnel
`Vauldy Fristenpilot` ist sichtbar und dem erwarteten ChatGPT-Workspace zugeordnet.
Der Tunnelstart wurde gemeldet. ChatGPT bot den Testtunnel namentlich an.
Nach bestätigtem Sicherheitshinweis meldete ChatGPT bei beiden Speicherversuchen,
dass das Anfragelimit für die Einrichtung erreicht sei und der Tunnel-Client
geprüft werden solle. Das Plugin blieb im Einrichtungsdialog. Lokal waren kein
laufender Tunnel-Client, kein aktives Test-Tunnelprofil und kein Eintrag im Audit
des isolierten Chat-Profils nachweisbar. Die Ursache der ChatGPT-Meldung ist damit
nicht eindeutig. MCP-Aufrufzahl und Zeit bis zur sichtbaren Tabelle bleiben offen.

Der isolierte Testbestand enthält vier synthetische Dokumente, davon drei freigegeben.
Der lokale Offline-Probelauf entdeckte acht Werkzeuge. `list_documents` fand die drei
freigegebenen Dokumente in 79,7 ms. Ein anschließender Aufruf von `get_deadline_overview` lieferte die
drei Fristenzeilen in 48,6 ms. Das Probe-Audit bestätigte zwei gestartete Aufrufe und zwei
vorbereitete Antworten ohne Werkzeugfehler. Der separate Chat-Profilordner blieb ohne Audit.
[Lokaler Probenachweis](../dist/mcp/hosted-deadlines-2026-11-06.PWvBW4pY/local-rehearsal.json)

Beim Start den Runtime-Schlüssel verdeckt im Terminal eingeben und den Tunnel-Client
während der Chat-Prüfung verbunden halten. Der [vorbereitete Tunnelstarter](../dist/mcp/hosted-deadlines-2026-11-06.PWvBW4pY/start-private-tunnel.command)
erwartet die ID dieses Testtunnels. Er bindet den startenden MCP an die per Prüfsumme
verifizierte Binärdatei und das synthetische Profil. Der Tunnel-Client und die lokale
Profilgenerierung wurden geprüft. Der Starter schreibt bei laufendem Client
eine lokale Statusdatei für die Bereitschaftsprüfung. Den Plugin-Dialog erneut
speichern, sobald der laufende Testtunnel lokal erreichbar ist.
[OpenAI Docs zum privaten Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)

Im frischen regulären Chat ausschließlich den synthetischen Anschluss auswählen und fragen:
„Zeige mir die Fristen der Dokumente mit dem Stichwort Fristenpilot als Tabelle. Trenne feste Termine, rechnerische Stichtage und offene Fälle und nenne die Seitenbelege.“
Erwartet werden das Fixdatum 10.03.2027 und die Zahlungsfrist 21.02.2027,
der rechnerische Stichtag 15.03.2027 sowie ein offener Fall wegen zweier
Vertragsenddaten. Jeder belegte Wert verweist auf Seite 1. Das unfreigegebene
Testdokument darf in der Tabelle nicht erscheinen.

Zeit ab Absenden bis zur ersten sichtbaren Tabellenzeile mit Dokumentdaten erfassen.
Zeitpunkt und Inhalt der vollständigen Tabelle separat prüfen. Im Chat-Audit die
`requestStarted`-Ereignisse für dieses Zeitfenster zählen, einschließlich Wiederholungen
und Fehlern. Toolnamen aus der sichtbaren Chat-Aktivität abgleichen, da das Audit nur
Operationsgruppen speichert. Discovery separat zählen. Ziel sind eine Dokumentauswahl
und ein gebündelter Fristenaufruf.

### Iteration 10 · Fristenübersicht vom 06.11.2026

`get_deadline_overview` liefert Vertragsende, Kündigungsfrist, Kündigungsstichtag,
Zahlungsfrist und Termin mit Seitenbelegen. Ein fest genannter Kündigungsstichtag
hat Vorrang. Die Kalenderrechnung benötigt ein eindeutiges Vertragsende und eine
unterstützte, auf derselben physischen Seite belegte Kündigungsfrist. Fehlt beim
Monatsabzug der entsprechende Kalendertag oder ist die Regel bedingt, bleibt das
Ergebnis offen.

Der Offline-stdio-Test verwendete 22 synthetische Datensätze, darunter einen
unfreigegebenen. Fünf bereits ausgewählte Dokumente wurden in einem `tools/call` in
104,7 ms ausgewertet. Geprüft sind unter anderem Schaltjahr, Monats- und Jahresgrenze,
widersprüchliche Daten, Zahlungsfrist einer Rechnung, OCR-Lücken, mehrteilige Quellen,
Maskierung, Quellenänderung und Widerruf. Die Einzelmessung betrifft den lokalen
Werkzeugaufruf nach der Auswahl.

Bestanden sind der Release-Build, 45 gezielte Swift-Tests einschließlich nativer OCR
und Widerruf während der Antworterstellung, die bestehenden stdio-Verträge, HTTP/OAuth,
exakte Relay-Parität und 10 lokale Relay-Worker-Tests. Die sieben bisherigen
Discovery-Definitionen stimmen mit dem vorherigen Teststand überein.
[Prüfbefehle und Ergebnisse](quality/deadline-overview-2026-11-06.json)

Als Nächstes folgt die isolierte Zielchat-Abnahme mit einem Testbuild, der alle acht
Werkzeuge enthält. Sie soll auch den langen Vertragsabruf mit gebündelter Feldauslese
und die Zeit bis zur sichtbaren Tabelle messen.

### Iteration 9 · Fassungsvergleich vom 05.11.2026

Im MCP-Branch `codex/local-first-product-readiness` ergänzt `compare_contract_versions` die
sechs bestehenden Werkzeuge. Deren Discovery-Definitionen stimmen exakt mit dem vorherigen
Testpaket überein. Das neue Werkzeug akzeptiert zwei verschiedene freigegebene Handles und
vergleicht nur explizite Feldtexte. Nummer, Nummernart und Aussteller müssen lokal auf beiden
Seiten eindeutig zusammenpassen. Unvollständige oder mehrseitig nicht eindeutig zugeordnete
Quellen werden abgelehnt. Beide Quellen und die Freigabe werden vor Ausgabe erneut geprüft.
Die Vertragskennung bleibt lokal. Das Werkzeug schreibt weder Originale noch Analyseergebnisse.

Der finale synthetische Wiretest nutzte 14 Datensätze. Bei den zwei Fassungen mit je 18 Seiten
lag die Änderung der Monatsrate auf Seite 18 und wurde mit beiden Zitaten geliefert. Einseitige
Gesamtkosten und Schlussrate blieben getrennt. Konflikte, maskierte Werte, fehlende Seiten,
fehlgeschlagene Basisanalyse, Sammelquellen, geänderte Quelle und Widerruf wurden geprüft.
Der Einzelaufruf nach Dokumentauswahl benötigte 231,3 ms unter Prozess-Netzwerksperre.
Das ist eine lokale Einzelmessung ohne Modellausgabe, Relay und sichtbare ChatGPT-Tabelle.

Bestanden: Release-Build, 44 gezielte Swift-Tests in sechs Suites einschließlich nativer OCR,
stdio- und Regressionstests für Themenübersicht und Feldauslese, HTTP/OAuth, exakte Relay-Parität
und zehn lokale Relay-Worker-Tests. [Exakte Kommandos und Ergebnisse](quality/contract-comparison-2026-11-05.json)
sowie [lokale Testlogs](../dist/mcp/comparison-2026-11-05-0lyob_01/verification.json).

Dateiänderungen: `MCPContractComparison.swift`, `ReadOnlyMCPRuntime.swift`,
`MCPFieldExtraction.swift`, `MCPAuditLog.swift`, `ServerFactory.swift`, `OutputSchemas.swift`,
`RelayClient.swift`, Relay-Discovery und Worker-Tests; neue
`scripts/mcp/contract_comparison_smoke_test.py` und aktualisierte Wire-/Discovery-Gates;
Swift-Tests für Widerruf und Relay-Weiterleitung; Werkzeugdokumentation, To-do-Liste,
Entwicklungsreferenzen und Kunden-Skill 1.2.0 als Quelltext. Keine produktive Installation,
kein neues Installations-ZIP, kein Cloud-Rollout, keine produktiven Dokumente verwendet.

Erneute Zielchat-Vorprüfung: Der In-App-Browser zeigte die Anmeldung. Kein synthetischer
Testanschluss konnte dort ausgewählt werden. Die reguläre ChatGPT-Messung bleibt offen.
Die Fristenübersicht wurde anschließend in Iteration 10 umgesetzt und lokal geprüft.

### Paketiteration vom 05.11.2026

[Lokales Installations-ZIP](../dist/mcp/contracts-2026-11-05-373egj4t/Vauldy-MCP-macOS.zip),
[Kunden-Anweisungspaket 1.1.1](../dist/mcp/contracts-2026-11-05-373egj4t/Vauldy-Lokale-Dokumente-Skill.zip),
[Prüfsummen](../dist/mcp/contracts-2026-11-05-373egj4t/SHA256SUMS).
Der [zusammengefasste Prüfnachweis](quality/package-2026-11-05.json) gehört zu diesem Arbeitsstand.

Alle sechs Programme wurden mit dem regulären Xcode-Buildsystem in einem neuen temporären
Quell-/Buildverzeichnis gebaut. Die 91 Paket-/Quelldateien wurden vor und nach dem Build gegen
den MCP-Arbeitsbranch geprüft. Kein zweiter Git-Branch angelegt. Die Paketierung verwendete
`--skip-build` erst nach diesen sechs frischen Builds; `buildMode=reused` im Manifest bedeutet
hier die Übernahme genau dieser geprüften Binärdateien. Der Arbeitsstand enthält lokale Änderungen,
deshalb behauptet das Paket keinen sauberen Release-Commit. Produktversion 0.13.0 und
Kompatibilitätsepoche stammen aus dem aktuellen Code.

Gefundener Paketierungsfehler: Der File-Provider ergänzt an einem losen kopierten App-Bundle
`com.apple.FinderInfo`, wodurch die strikte Signaturprüfung scheitert. Der Paketierer entfernt
aus eigenen generierten Bundles gezielt FinderInfo/ResourceFork und bietet `--archive-only` für
solche Ausgabeordner. Quarantäne und andere Attribute werden erhalten. Das tatsächlich ausgegebene
ZIP wird nach erneutem lokalem Entpacken strikt geprüft. Ein neuer synthetischer Codesign-Test
belegt Fehlerreproduktion, unveränderte signierte Bytes, Attributerhalt, Idempotenz und Symlinkabwehr.
Der Test ist in der vollständigen Regression eingetragen.

Aktuelle Ergebnisse:

- 50 Swift-Tests in acht Suites bestanden, einschließlich nativer PDF-/PNG-OCR, Privacy, Freigaben,
  Feldauslese, Installation und Grenzen der Schlüsselbundinteraktion. Build und Tests zusammen 58,43 s.
- Zwölf Prüfungen am entpackten Paket bestanden: Signatur, stdio, Themenübersicht, Feldauslese,
  Verwaltung, synthetische Clientregistrierung, Update/Rollback, HTTP/OAuth, Relay-Parität,
  zehn Relay-Worker-Tests, echter Import-Worker und isolierter nativer Einrichtungsstart.
- stdio, Themen, Felder, Verwaltung, Clientregistrierung und Update/Rollback liefen unter einer
  zusätzlichen Prozess-Netzwerksperre. Das ist keine bestätigte Netztrennung des ganzen Macs.
- Der Worker-Test erhielt Originale/Freigaben und prüfte Prozesswiederverwendung, parallele
  Queue-Anfragen, Wiederanbindung, Cache und frische Erkennung. Der erste synthetische gemischte
  PDF-Import dauerte 54,30 s. Das ist ein beobachteter Kaltlauf, kein allgemeines Leistungsversprechen.
- Nach der aktualisierten Paket-Anleitung ZIP neu erzeugt. Fünf Hilfsprogramme bleiben bytegleich;
  der Setup-Code ist nach Signaturentfernung an Testkopien identisch. Die Anleitung ändert die
  Bundle-Signatur des Setup-Programms. Deshalb Signatur, Verwaltung, Update/Rollback einschließlich
  Prozessabbrüchen und Einrichtungsstart am finalen ZIP nochmals ausgeführt und bestanden.
- Kunden-Anweisungspaket enthält genau eine `SKILL.md`, keine Entwicklerreferenzen oder Quellarchive.

Exakte ausgeführte Build- und Paketkommandos stehen im lokalen
[Buildnachweis](../dist/mcp/contracts-2026-11-05-373egj4t/build-proof.json).
Testkommandos, Rückgabecodes und Laufzeiten stehen in
[Swift-Ergebnis](../dist/mcp/contracts-2026-11-05-373egj4t/swift-result.json),
[Paketprüfungen](../dist/mcp/contracts-2026-11-05-373egj4t/wire-verification.json) und
[Abschlussprüfung](../dist/mcp/contracts-2026-11-05-373egj4t/final-artifact-verification.json).
Zusätzlich ausgeführt: `python3 scripts/mcp/package_metadata_smoke_test.py`,
`python3 -m py_compile scripts/mcp/package.py scripts/mcp/package_metadata_smoke_test.py scripts/mcp/regression_test.py`
und `git --no-optional-locks -c core.fsmonitor=false diff --check`.

Dateiänderungen dieser Iteration: `scripts/mcp/package.py`, neuer
`scripts/mcp/package_metadata_smoke_test.py`, `scripts/mcp/regression_test.py`,
`docs/mcp-installation.md`, diese Liste, `docs/quality/package-2026-11-05.json` sowie
`skills/development/vauldy-mcp-development/references/verification.md` und deren installierte Kopie.
Kein produktiver Bestand, Profil, OAuth-Gerät, Schlüsselbund oder Host-Eintrag geändert.
Keine produktive Installation und kein Relay-Rollout.

Freigabe: **GO für isolierte lokale Entwicklertests**. **NO-GO für Kundenauslieferung** bis
Developer-ID-/Notarisierung und Erststart/Update/Rollback auf einem frischen Offline-Test-Mac
bestanden sind. **Agensi-Zielclient und 20.000 reale Dokumente bleiben ohne Freigabe**;
diese Pakettests ersetzen deren eigene Abnahmen nicht. Die reguläre ChatGPT-Messung ist offen.
Nächster Abnahmeschritt ist deren separater synthetischer Testanschluss. Der anschließend
unabhängig umgesetzte Fassungsvergleich ist in Iteration 9 dokumentiert.

### Skillpflege vom 05.11.2026

Der aktive Entwicklungsleitfaden ist `vauldy-mcp-development`. `vauldy-ios-clean-code` bleibt als
kurzer Verweis auf diesen Leitfaden erhalten. `vauldy-import-ocr-sync` behandelt nun den lokalen
macOS-Import, rekursive Batches mit Gesamtfortschritt, Originalzugriff und den begrenzten OCR-Zweitlauf.
`vauldy-ai-search-assistant` beschreibt die sechs lesenden Werkzeuge und ihre Evidenz-/Privacy-Grenzen.
Die aktuellen Einstiege laden keine frühere App-/VLM-/Cloud-Anbieterpipeline als Entwicklungsstandard.

Elf Dateien unter `skills/development` sind als geprüfte Kopien nach `~/.codex/skills` übernommen.
Die bisherigen verwalteten Dateien wurden vorher lokal gesichert; zusätzliche vorhandene Referenzen
blieben erhalten. UI-Metadaten und bestehende Aufrufregeln wurden berücksichtigt. Das separate
Kunden-Anweisungspaket `skills/vauldy-lokale-dokumente/SKILL.md` ist Version 1.1.1. Es enthält nur
Anweisungen für vorhandene MCP-Werkzeuge, keine Entwicklungsreferenzen oder App-Quelltexte.

Ausgeführt:

```sh
python3.11 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py ~/.codex/skills/vauldy-mcp-development
python3.11 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py ~/.codex/skills/vauldy-ai-search-assistant
python3.11 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py ~/.codex/skills/vauldy-import-ocr-sync
python3.11 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py ~/.codex/skills/vauldy-ios-clean-code
python3 scripts/mcp/field_extraction_smoke_test.py .build/arm64-apple-macosx/release/vauldy-mcp
python3 scripts/mcp/topic_overview_smoke_test.py .build/arm64-apple-macosx/release/vauldy-mcp
git --no-optional-locks -c core.fsmonitor=false diff --check
```

Alle vier Skillvalidierungen sowie beide Wireprüfungen bestanden. Zusätzlich Metadaten,
lokale Verweisziele, das einzelne Kundenpaket und die bytegleichen installierten Kopien geprüft.
Die Wireprüfungen bestätigen den beschriebenen Werkzeugvertrag am vorhandenen Release-Programm,
keine automatische Werkzeugwahl eines Chatmodells. Es wurde kein neuer Swift-Build und kein neues
Installationspaket erstellt. Frühere Testzahlen und Latenzwerte wurden nicht als neue Messungen ausgegeben.

Die erneute Zielchat-Vorprüfung am 05.11.2026 zeigte im erreichbaren In-App-Browser die
ChatGPT-Anmeldung. Ein separater privater synthetischer Testanschluss wurde dort nicht verifiziert.
Die Messung im regulären Chat bleibt offen. Das Paket mit sechs Werkzeugen ist in der
Paketiteration oben bereitgestellt und lokal geprüft. Der Fassungsvergleich ist danach im
MCP-Branch ergänzt worden. Die Fristenübersicht folgte in Iteration 10. Die isolierte Zielchat-Abnahme bleibt offen.

### Iteration 8 · Prüfnachweis vom 05.11.2026

Fortschritt: Implementierung und lokale Prüfung abgeschlossen. Die Abnahme im regulären Zielchat
bleibt offen. Keine Dokumentmigration und keine produktive Installation oder Relay-Bereitstellung
durchgeführt. JSON, Freigabeprofile und Originaldateien sind keine Schreibziele des neuen Werkzeugs.
Der bestehende Auditpfad zählt die Auslese als Lesezugriff.

Ausgeführte Prüfungen, jeweils mit ausschließlich synthetischen Beständen:

```sh
export GIT_OPTIONAL_LOCKS=0
export CLANG_MODULE_CACHE_PATH=/tmp/vauldy-topic-clang
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/vauldy-topic-swift
swift build --build-system native -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --product vauldy-mcp
swift test --build-system native --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none -Xswiftc -parse-as-library --no-parallel --filter 'MCPFieldExtractionTests|MCPRetrievalCompletenessTests|MCPPrivacyBoundaryTests|MCPPassageTests|RelayConnectionTests|LocalImportTests/scannedPDFAndPNGUseRealVisionWithoutApp'
python3 scripts/mcp/field_extraction_smoke_test.py .build/arm64-apple-macosx/release/vauldy-mcp --benchmark
python3 scripts/mcp/smoke_test.py .build/arm64-apple-macosx/release/vauldy-mcp
python3 scripts/mcp/topic_overview_smoke_test.py .build/arm64-apple-macosx/release/vauldy-mcp
python3 scripts/mcp/oauth_smoke_test.py .build/arm64-apple-macosx/debug/vauldy-local .build/arm64-apple-macosx/debug/vauldy-mcp-http
python3 scripts/mcp/export_relay_tools.py .build/arm64-apple-macosx/release/vauldy-mcp --check
node --test cloud/chatgpt-relay/tests/relay.mjs
git --no-optional-locks -c core.fsmonitor=false diff --check
```

Ergebnisse: 43 Swift-Tests in sechs Suites bestanden, einschließlich des nativen PDF-/PNG-OCR-Tests.
Zehn Node-Tests bestanden. stdio-, Themen-, HTTP-/OAuth- und Paritätsprüfungen bestanden. Der
Feldtest prüfte sieben synthetische Datensätze und 17 Prüfgruppen einschließlich vollständig
übertragener Konfliktbelege, Quellenänderung, Widerruf und unveränderter Bestand-/Profilbytes.
Die vier Basiswerkzeuge behalten ihren bisherigen Schemafingerabdruck. Eine vollständige
Installer-/UI-Regression wurde in dieser Iteration nicht ausgeführt.

Die lokale Buildumgebung benötigte wieder lokal verfügbare, unverändert versionierte
Abhängigkeitsdateien. Vorherige Versuche brachen durch Materialisierung ausgelagerter Dateien
während der Kompilierung ab. Das neue Xcode-Buildsystem blieb beim Öffnen seiner Builddatenbank
stehen. Der erfolgreiche Lauf nutzte deshalb das bisherige SwiftPM-Buildsystem und für die
bestehenden `@main`-Einstiege die explizite Parsingoption. Diese Umgebungsfehler werden nicht
als bestandene Tests gezählt.

Geänderte Dateien dieser Iteration, zusätzlich zu zuvor vorhandenen Branchänderungen:

- Runtime: `Sources/VauldyMCPRuntime/MCPFieldExtraction.swift` (neu), `ReadOnlyMCPRuntime.swift`, `MCPAuditLog.swift`.
- Protokoll: `Sources/VauldyMCPProtocol/ServerFactory.swift`, `OutputSchemas.swift`.
- Relay: `Sources/VauldyRelay/RelayClient.swift`, `cloud/chatgpt-relay/worker/index.js`, `cloud/chatgpt-relay/tests/relay.mjs`.
- Swift-Prüfungen: `Tests/VauldyMCPRuntimeTests/MCPFieldExtractionTests.swift` (neu), `MCPRetrievalCompletenessTests.swift`, `RelayConnectionTests.swift`.
- Wire-/Regressionsskripte: `scripts/mcp/field_extraction_smoke_test.py` (neu), `smoke_test.py`, `management_smoke_test.py`, `oauth_smoke_test.py`, `customer_release_smoke_test.py`, `regression_test.py`.
- Anleitung: `README.md`, `skills/vauldy-lokale-dokumente/SKILL.md`, `docs/mcp-mvp.md`, diese To-do-Liste und `docs/quality/field-extraction-benchmark.json` (neu).

Nächster Schritt: Den langen Vertragsabruf im isolierten regulären Chat erneut messen. Nach
gezielter Auswahl des synthetischen VW-Vertrags Vertragsart, Kosten, Laufzeit und Kündigungsfrist
abfragen. Erwartung: ein Feldaufruf für den bereits ausgewählten Vertrag, korrekte Seitenbelege
und keine unnötige vollständige Textlesung. Bei notwendiger vorheriger Suche diese zusätzlich
zählen. Zeit bis zur sichtbaren Tabelle, alle Fehlversuche und Wiederholungen erfassen. Der
lokale Messwert ist kein Beleg für die berichtete vierminütige reale Anfrage. Der Fassungsvergleich
und die Fristenübersicht sind inzwischen lokal geprüft.

### Messung im ChatGPT-Zielchat

In einem frischen regulären Chat ausschließlich den privaten MCP-Testanschluss mit dem
synthetischen Profil auswählen. „Zeige alle Versicherungen“ unverändert absenden. Die Zeit
vom Absenden bis zur ersten sichtbaren Tabellenzeile mit Dokumentdaten messen und den
vollständigen Tabellenstand danach separat prüfen. Im Zeitfenster des Chats die begonnenen
Werkzeugaufrufe im lokalen Audit zählen, einschließlich Fehlversuchen und Wiederholungen.
Initialisierung und Werkzeugliste separat erfassen. Die ChatGPT-Werkzeugaktivität mit dem
Audit abgleichen. Erwartet sind ein Aufruf von `get_topic_overview` und eine Trennung von
Policenüberschriften, Erwähnungen und OCR-Lücken. Die lokale Vorprüfung nutzte ein separates
Profil, damit ihr Aufruf nicht in die spätere Chat-Messung eingeht.
