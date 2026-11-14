# Lokale Basisanalyse (0.8)

Der eigenständige MCP erzeugt nach Texterfassung eine prüfbare Basisübersicht je erkanntem
logischem Dokument. Der Motor `local-rules-extractive-v1` arbeitet ausschließlich mit
vorhandenem OCR-/PDF-Text. Er ist eine bewusst begrenzte regelbasierte Baseline. Kein Modell
wird installiert, kein Anbieter umgeschaltet, kein Cloud-Aufruf ausgelöst.

## Datenvertrag

Ein Vorschlag enthält Dokumenttyp, optionalen Aussteller, Empfänger, Dokumentdatum,
Gegenstand, Bezugsjahr und einen wörtlich übernommenen, nur in den Leerzeichen normalisierten
Textabschnitt als Übersicht. Jedes gefüllte Feld enthält Rolle, physische Seite und wörtlichen
Quellbeleg. Die zentrale Annahmeprüfung wird nach Analyse, beim Speichern und nach Neuladen
verwendet. Unbelegte Vorschläge werden verworfen und als prüfbedürftig markiert.

Aussteller und Empfänger müssen explizit beschriftet sein. Eine im Text erwähnte Organisation,
Bankverbindung oder Dateiname begründet keine Ausstellerzuordnung. Dokumentdaten werden nur
mit passenden Rollen und gültigem Kalenderdatum akzeptiert. Geburtsdatum, Fälligkeit und
Termin bleiben davon getrennt. Ein ausdrücklich angegebenes Bezugsjahr hat Vorrang vor dem
Ausstellungsjahr; bei Konto-/Nebenkostenabrechnungen, Steuer- und Beschäftigungsunterlagen wird
kein fehlendes Bezugsjahr aus dem Ausstellungsdatum ersetzt.

Titel bevorzugen plausible Dokumentüberschriften und ergänzen belegten Aussteller,
kurzen Gegenstand und geeignetes Jahr. Bei Unsicherheit bleibt der Titel neutral.
Manuell geänderte Titel und eigene Notizen bleiben bei erneuter Analyse erhalten. Änderungen
am OCR-Text, Seitenumfang oder Review-Signal machen gespeicherte Analyse veraltet (`stale`).
Eine explizite Neuanalyse speichert nur gegen den unveränderten Ausgangsdatensatz.

Mehrere neue Überschriften mit abweichender expliziter Aussteller-/Referenz-/Datumskennung
können mehrere logische Übersichten erzeugen. Ihre physischen Seiten müssen den Bestand
lückenlos und genau einmal abdecken. Mehrere logische Dokumente bleiben prüfbedürftig.
Originaldatei und physischer Importdatensatz werden nicht aufgeteilt oder verändert.

## Zustände und MCP-Ausgabe

- `completed`: die begrenzten Regeln haben keine offenen Prüfhinweise gefunden.
- `needsReview`: etwa unbekannter Typ, fehlender Gegenstand/Übersicht, Rollenwiderspruch,
  problematische Quelle, mehrere logische Dokumente oder anweisungsförmiger Quelltext.
- `unavailable`: keine lesbare Quelle für eine Übersicht.
- `failed`: Analysefehler, überschrittene Grenzen oder ungültige Seitenzuordnung.
- `not-analyzed` und `stale`: vorhandener Bestand ohne aktuelle passende Analyse.

`completed` bestätigt keine vollständige OCR, keine unabhängige Sachprüfung und keine
Sprachmodellqualität. Optionale Rollenfelder dürfen auch dann fehlen. Quellenverarbeitung,
Listenende und Analyseabdeckung bleiben getrennte Aussagen. Ein Analysefehler verwirft
keinen erfolgreich erkannten OCR-Text.

`read_document` mit `view: "metadata"` liefert eine logische Übersicht pro Antwort. Alle
Titel, Feldwerte, Belege und Übersichtstexte durchlaufen dieselbe Privacy-Sitzung wie der
Volltext. Seitenbelege nutzen das flüchtige MCP-Handle. Fortsetzung erfolgt mit `nextCursor`;
Freigabe- oder Quellenänderungen machen Handles und Cursor ungültig. Diese Sicht schreibt
nichts. Es gibt kein MCP-Werkzeug für eine Analyse oder Freigabeänderung.

Für vorhandene eigene Importe ist die erneute Auswertung ausdrücklich lokal möglich:

```sh
vauldy-local analyze --store /absoluter/bestand --document UUID
```

Ergebnis: Kennung, Analysezustand und Anzahl logischer Dokumente; keine Rohangaben im
CLI-Ergebnis. Nicht abgeschlossene Analyse liefert Exitcode 2. Der Importexitcode betrifft
weiterhin die OCR; `analysisStatus` meldet die getrennte Analyse.

## Layoutbasierte Titel und Bestandsvorschau (0.14.4)

Der Titel des Importdatensatzes nutzt das bereits gespeicherte Seitenlayout, wenn
Quellhash, physische Seite, exakter Seitenwortlaut und Zeilenbereiche zusammenpassen.
Kandidaten auf der ersten Seite erhalten Gewicht durch Dokumenttyp, relative Zeilenhöhe,
Abstand und Position. Nahe, ausgerichtete Überschriftszeilen dürfen zusammengehören.
Tabellenzellen, wiederkehrende Randzeilen, Weiterleitungszeilen, Feldbezeichner und
Satzfragmente werden aussortiert. Ein belegter Typ auf den ersten Folgeseiten kann als
kürzerer Titel dienen. Bei schwachem Layout kann ein bisheriger Typ erhalten bleiben,
wenn ihn die erneute Textauswertung unabhängig bestätigt. Ein explizit belegter Aussteller hat Vorrang vor einer
eindeutigen Organisation im Briefkopf. Bei widersprüchlichen Überschriften oder unklaren
Zusätzen bleibt die Ausgabe beim belegbaren Typ oder einem neutralen Titel. Ältere Bestände
ohne passendes Layout und Layouts gedrehter Seiten bleiben über Textregeln auswertbar.

Der Titel der Datei und die fachlichen Basisangaben haben getrennte Rollen. Die neuen
Layoutregeln schreiben vorhandene Basisanalysen, OCR-Text, Belegzeilen und Freigaben
nicht um. Titelpflege verwendet dieselbe Auswahl wie der Import. Der Originaldateiname
und manuelle Überschreibungen bleiben erhalten.

```sh
vauldy-local title-preview --store /absoluter/bestand
vauldy-local retitle --store /absoluter/bestand --document UUID
```

Die erste Anweisung gibt lokal eine schreibgeschützte Vorschau aller Titel aus. Sie enthält
Dateinamen, bisherige und vorgeschlagene Titel, die Methode und gegebenenfalls die Quellseite.
Bei eigenen Titeln enthält sie zusätzlich den automatischen Vorschlag. Laufende Importe oder
geänderte Originale werden übersprungen. Nur die zweite Anweisung übernimmt einen Vorschlag
für das ausdrücklich angegebene Dokument. Keine der beiden Anweisungen startet Texterkennung.

## Qualitätskorpus

`Tests/VauldyMCPRuntimeTests/Fixtures/overview-corpus.json` enthält 26 künstliche Fälle aus
14 Domänen, darunter Finanzen, Versicherungen, Gesundheit, Behörden, Wohnen, Fahrzeuge,
Beschäftigung, Schule und allgemeiner Schriftverkehr. Erwartete Rollen sind separat
annotiert. Entwicklungs- und zurückgehaltene Fälle sind gekennzeichnet; da sie im offenen
Repository liegen, sind sie kein dauerhaft ungesehener Benchmark.

Neben positiven Dokumenttypen werden generische Scannamen, späte Metadaten, Umbrüche,
Geburts-/Bezugs-/Dokumentdatum, Negationen, Bedingungen, Beträge, mehrdeutige Daten,
unbekannte/leere Quellen, niedrige Quellenqualität, Dokumentpakete und eingeschleuste
Anweisungen geprüft. Das Anweisungssignal ist eine Heuristik, kein allgemeiner Nachweis
gegen Prompt Injection. Der Motor führt grundsätzlich keine Dokumentanweisungen aus.

Drei Ebenen werden getrennt geprüft:

1. Annotierte Transkripte gegen dieselbe Annahmepipeline wie Produktion.
2. Import, Speicherung, Neuladen und explizite Neuanalyse mit identischem Ergebnis.
3. Echte synthetische PDF-Originale (25 Fälle) und acht reine Raster-PDFs über native Vision-OCR,
   anschließend lokale Speicherung und MCP-Freigabe-/Privacy-Prüfung.

Die Berichte unter `docs/quality/` weisen Konfusionsmatrix, Macro-F1, ausgefüllte Rollen,
unerwartete Rollen, kritische Übersichtsinhalte und einzelne Fallfehler aus. Die Rastermessung
bewahrt auch Fehler der strikten Sollwerte. Alle acht Rasterfälle sind seit 0.8.1 strikte Regressionen: fehlende Sollfelder oder
kritische Inhalte lassen den Test fehlschlagen. Der dokumentierte Ausgangsstand liegt
separat unter `native-raster-before-ocr-fix.json`. Acht passende künstliche Vorlagen
sind kein allgemeiner 100-Prozent-OCR-Qualitätsnachweis. Reale Archive und Produktionsdokumente sind nicht Teil
dieser Messung. Einfache saubere synthetische Scans können bereits OCR-Auslassungen zeigen.

Reproduktion:

```sh
VAULDY_BASE_ANALYSIS_REPORT="$PWD/docs/quality/transcript-baseline.json" \
VAULDY_BASE_ANALYSIS_NATIVE_REPORT="$PWD/docs/quality/native-raster-baseline.json" \
swift test --disable-sandbox
```

## Grenzen und nächste Schritte

Unbeschriftete Briefköpfe, komplexe Tabellen, lange Absätze, nicht unterstützte Sprachen,
Layout-/OCR-Fehler und beliebige Dokumentpakete sind nicht zuverlässig abgedeckt. Eine
fehlende Übersicht wird nicht durch Metadaten oder erfundene Prosa ersetzt. Organisations-
und Vertragsauflösung, Fristen, Bezahlstatus und inhaltliche Versionsvergleiche bleiben offen.

Als nächster Qualitätsschritt benötigt der MCP einen repräsentativen freigegebenen,
annotierten Originalkorpus sowie einen ausdrücklich konfigurierten lokalen Modelladapter
mit getrennten Qualitätsgates. Er muss denselben Rollen-, Beleg-, Seiten- und Privacy-Vertrag
erfüllen. Eine Änderung der OCR-Auflösung braucht einen eigenen systematischen Benchmark;
eine Auflösung, die einen Scan verbessert, kann bei einem anderen Text verlieren.

Die Qualität gespeicherter Analyse und die externe Nutzbarkeit werden getrennt betrachtet.
Der übernommene konservative Privacy-Detektor kann auch Organisationsnamen und Sachbegriffe
ersetzen. Im Wire-Bericht sind zwölf Titel mit Ersetzungen erfasst; daraus folgt keine
annotierte Falschpositivrate. Eine gesonderte Bewertung der ausgehenden Antwortqualität
bleibt erforderlich. Die Datenschutzgrenze wird für bessere Lesbarkeit nicht umgangen.

## Gezielte Rasterauflösung (R2, 06.11.2026)

Bei kleinen Raster-PDFs kann `CGPDFPage.getDrawingTransform` eine Seite im größeren
Zielbitmap bei 1× zentrieren. Mehr Bitmap-Pixel ergeben dann keine größeren Schriftzeichen.
Der lokale OCR-Pfad bietet deshalb für eine eindeutig erkannte einzelne, vollseitige
Rastergrafik einen zusätzlichen Renderdurchlauf an. Er wird nur ausgelöst, wenn mindestens
zwei und mindestens die Hälfte der erkannten Zeilen unter der bestehenden Kleinschriftgrenze
von 16 Pixeln liegen. Die Auswahl verwendet die gemessene Geometrie, keine Solltexte oder
erwarteten Vertragswerte. Seiten ohne erkannte Zeilen werden durch diesen Schritt noch nicht
automatisch erschlossen.

Der zusätzliche Renderdurchlauf wendet die begrenzte PDF-Punkt-zu-Pixel-Skalierung explizit
an und berücksichtigt die native Pixeldichte des eingebetteten Bildes. Beschnitt und Rotation
bleiben in der PDF-Transformation. Die lange Bildkante bleibt auf 3072 Pixel begrenzt; pro Seite
ist höchstens eine zusätzliche Vollseiten-Erkennung erlaubt. Mehrteilige Rasterseiten,
unklare Bildtransformationen, eingebetteter Text und gekachelte Langseiten behalten hier ihren
bisherigen Pfad. Der bestehende, ebenfalls begrenzte Zeilen-Zweitlauf bleibt erhalten.

`LocalOCRMetrics.pdfScaleRetries` zählt die zusätzliche Rastererkennung getrennt von
`targetedRetries` und `recoveredLines`. Ein neuer Renderdurchlauf ist keine reparierte Zeile.
Bildpunkte und Zeiten enthalten die zusätzliche Arbeit. Cachekonfiguration v5 verhindert,
dass bereits falsch erkannte v4-Seiten als neue Ergebnisse wiederverwendet werden. Bestehende
abgeschlossene Importe werden nicht automatisch geändert; „Text erneut lesen“ startet weiterhin
die explizite cachefreie Erkennung. Seiten mit Review werden nicht im Seitencache wiederverwendet.

Eine unbedingte Skalierung aller Seiten und reine Kontraständerungen wurden verworfen:
Sie verbesserten den gesamten Kontrollkorpus nicht zuverlässig. Die acht vorhandenen
Raster-Originalfälle behalten ihre strikten Sollwerte. Der erweiterte A/B-Test umfasst neun
künstliche Scans, darunter drei schwierige Raster-PDFs mit unterschiedlichen Werten bzw.
Helligkeiten. Der Problemfall muss jetzt alle vier Sollfelder korrekt liefern. Zeichen- und
Wortfehler werden zusätzlich auf einem normalisierten Volltranskript gemessen; reine
Feldtreffer bedeuten keine fehlerfreie Gesamtseite. Der Worker-Wiretest prüft gespeicherten Text,
Freigabe, geschützte MCP-Ausgabe, Cache, Frischerkennung und Widerruf.

Noch offen sind die Erkennung vollständig übersehener Bereiche, die Verifikation fragwürdiger
eingebetteter PDF-Textschichten sowie eine additive Speicherung von Zeilen-/Blockkoordinaten
für Layout und Quellenvergleich. Dafür sind getrennte Qualitätsfälle erforderlich; R2 ist
kein allgemeiner Nachweis für beliebige Scans oder Kundenarchive.

Für den vollständigen Original-/CLI-/MCP-Test zuerst die synthetischen Originale erzeugen:

```sh
VAULDY_BASE_ANALYSIS_DIAGNOSTICS=/absoluter/synthetischer/testordner \
swift test --disable-sandbox --filter BaseAnalysisMCPTests
python3 scripts/mcp/base_analysis_wire_test.py \
  "$PWD/.build/debug/vauldy-local" "$PWD/.build/debug/vauldy-mcp" \
  /absoluter/synthetischer/testordner
```

Der Diagnoseordner enthält ausschließlich die künstlichen Testvorlagen. Anschließend kann
er gelöscht werden. Der Test verwendet einen eigenen temporären Importbestand und stoppt
seinen Worker. Er verändert keine installierte Verbindung.

## OCR-Korrektur und vorhandene Oberfläche (0.8.1)

Die Vorverarbeitung entfernt nur weiße Außenränder um den gesamten erkannten Bildinhalt,
mit Sicherheitsabstand. Sie behält auch einzelne, sehr helle farbige Randmarkierungen und
Fußzeilen. Unklare oder übergroße Eingaben bleiben unverändert. Texterkennung, Sprachkorrektur,
Auflösungsgrenzen und echte Konfidenzen bleiben erhalten. Alte OCR-Checkpoints haben eine
andere Konfigurationskennung. Produktivbestände werden nicht automatisch neu gelesen.

Die bisherige MCP-Oberfläche zeigt „Übersicht und Basisangaben“ aus dem aktuellen gespeicherten
Datensatz mit Rollen und Quellseiten. „Text erneut lesen“ liest auf ausdrückliche Nutzeraktion
das Original cachefrei und aktualisiert anschließend die Basisanalyse. Auch ein zuvor als
OCR-abgeschlossen markierter Import kann so erneut geprüft werden. Auswahl und Freigaben
werden dadurch nicht erweitert. Manueller Titel und eigene Notizen bleiben erhalten.

Start mit allen Helferprogrammen: `python3 scripts/mcp/run_ui.py`.
Gesamte Regression: `python3 scripts/mcp/regression_test.py`.
Mit `--update-reports` werden die gemessenen Qualitätsberichte unter `docs/quality/` aktualisiert.


## Konkrete Qualitätsanzeige und lokale Fundstellen (08.11.2026)

Die technische Dokumentliste, der Bestands-Qualitätsbericht und die lokale Prüfansicht
verwenden dieselbe abgeleitete `LocalDocumentQuality`. Sie trennt Originalzugriff,
Seitenverarbeitung, unsicheren Text, Dokumentart, Basisangaben und Analysezustand.
„N von N vorhandenen Seiten verarbeitet“ bestätigt weder vollständige Originalunterlagen
noch richtige OCR. Unlesbare Erkennung, nicht zugeordneter Seitentext und tatsächlich
fehlende Originalseiten werden nicht gleichgesetzt. Ein leeres Original bleibt eine
als leer erkannte, verarbeitete Seite.

Konkrete Gründe werden aus gespeicherten Nachlese-, Konflikt-, Kennungs-, Abdeckungs-
und Analysehinweisen abgeleitet. Fehlende optionale Basisangaben heißen „nicht belegt“;
ohne fachliches Pflichtfeldschema wird keine Pflichtverletzung behauptet. Ein unbekannter
Dokumenttyp erfordert nicht automatisch einen neuen Textlauf. Tabellen und abschließende
manuelle Prüfung bleiben ausdrücklich separat und nicht dokumentiert, soweit dafür kein
Nachweis vorliegt. Es gibt keine Qualitätsprozentzahl und keinen Status „modellvalidiert“.
Der MCP-Analysescope beschreibt die regelbasierte Extraktion ohne unabhängige Inhaltsprüfung.

Jeder lokalisierbare Grund öffnet seine physische Seite. Aktuelle, an Originalhash,
Seitentext, OCR-Konfiguration und Geometrie gebundene Bildregionen werden hervorgehoben
und als Ausschnitt dargestellt. Basisangaben öffnen ihren wörtlichen Quellbeleg.
Aggregierte alte Zeilenhinweise ohne Koordinaten öffnen die ganze Seite mit entsprechender
Erklärung. Veraltete Geometrie wird nicht als aktuelle Fundstelle verwendet. Die Vorschau
verifiziert weiter die Originalbytes und hält ihren bestehenden Access-Lease.

Dies ist eine lokale Präsentationsänderung. Erkennungsverfahren, OCR-Caches, Originale,
Speicherformat und Freigaben werden nicht automatisch verändert; GLM, Docling und Jev
werden durch diese Anzeige nicht installiert oder gestartet.

## Dokumenttitel und gezielte Titelpflege (13. November 2026)

`DocumentTitlePolicy` prüft Überschriften und Titelbestandteile separat auf Eignung:
Satzzeichen, Anrede, typische finite Verben/Vertragsklauseln, Satzenden, Länge und
Anweisungsfragmente schließen Fließtext aus. Eine wörtlich belegte Textstelle allein
reicht nicht als Titel. Akzeptierte konkrete Überschriften wie „Versicherungsschein“
haben Vorrang vor der breiten Kategorie. Ein kurzer belegter Gegenstand und ein
explizit als Aussteller beschrifteter Name können den Titel ergänzen. Mehrdeutige
Dokumenttypen bleiben neutral; ohne belastbare Angaben lautet der Titel
„Dokument – Aussteller unbekannt“. Dateinamen und Empfänger sind keine Ausstellerbelege.
Die Erkennung bleibt eine konservative deutschsprachige Textheuristik ohne Layoutmodell;
unbekannte, kleingeschriebene, mehrzeilige oder komplexe Überschriften können zurückfallen.

`VaultDocument.sourceName` erhält den Originaldateinamen. `generatedTitle` und
`manualTitle` sind getrennte optionale Felder; `title` bleibt der effektive Anzeigetitel
für bestehende Leser. Manuelle Änderungen haben Vorrang, auch wenn die eigene Bezeichnung
zufällig dem automatischen Titel entspricht. Direktes Setzen von `title` gilt als
manuelle Änderung. Reine Lesezugriffe migrieren keine gespeicherten Daten.

Altbestände ohne diese Zusatzfelder werden erst beim ausdrücklichen Titel-/Analyseschritt
zugeordnet: Ein exakt dem Dateistamm oder dem früher gespeicherten Analysetitel entsprechender
Wert gilt als automatisch. Andere Bezeichnungen bleiben als manuelle Überschreibung erhalten.
Eine historische manuelle Änderung, die exakt dem damaligen automatischen Titel entspricht,
ist mangels alter Herkunftsangabe nicht unterscheidbar. Alte Writer sollten nach Einführung
der Zusatzfelder nicht parallel weiterverwendet werden: Sie erhalten deren Trennung nicht.

Die lokale Dokumentliste bietet „Titel neu bestimmen“ und zeigt Originaldateiname,
automatischen Titel und gegebenenfalls eigene Bezeichnung getrennt unter „Titelangaben“.
Die CLI erlaubt dieselbe gezielte Neubestimmung sowie manuelle Korrektur und Rücknahme:

```sh
vauldy-local retitle --store /absoluter/bestand --document UUID
vauldy-local set-title --store /absoluter/bestand --document UUID --title "Eigene Bezeichnung"
vauldy-local reset-title --store /absoluter/bestand --document UUID
```

`retitle` liest vorhandenen OCR-/PDF-Text und speichert ausschließlich Titelmetadaten.
Es startet keinen Import, keine OCR und keinen Worker. Gespeicherte Basisanalyse samt
Belegzeilen, Seiten, Text, Zusammenfassung, Kategorie, Originalverweise und IDs bleiben
unverändert. Laufende Importe und als verändert bekannte Originale sperren die Neubestimmung;
unbrauchbarer oder unmarkierter Text führt zum neutralen Titel. Ein Analysefehler schreibt
nichts. Ein Vergleich des vollständigen Ausgangsdatensatzes unter der Writer-Sperre
verhindert, dass konkurrierende Text-/Titeländerungen überschrieben werden. Gleiche
Titelresultate schreiben keinen neuen Snapshot. `reset-title` entfernt nur die manuelle
Überschreibung; es führt keine neue Analyse aus.

Freigabeprofile, Geräte, Revisionen und ausgewählte IDs werden von diesen Diensten nicht
geöffnet oder geändert. Bestehende flüchtige MCP-Handles können wie bei anderen Metadaten-
änderungen ungültig werden; eine frische Liste liefert neue Handles ohne neue Freigabe.
Es gibt weiterhin keine schreibenden Titelwerkzeuge über MCP. Die separate vollständige
Neuanalyse (`analyze`) darf weiterhin Analysefelder erneuern; für reine Titelkorrekturen
ist `retitle` der passende Weg.

Regressionen: `DocumentTitleTests` enthält den wörtlichen Fehler aus dem bereitgestellten
Screenshot, positive Überschriften mehrerer Domänen, Rollenverwechslungen, neutrale
Fallbacks, Altdaten, manuelle Überschreibungen, konkurrierende Änderungen und unveränderte
Belege/Originale/aktive und pausierte Freigaben. `scripts/mcp/title_smoke_test.py` prüft die
echten lokalen Befehle und die lesende MCP-Ausgabe mit einem isolierten synthetischen Archiv.
Der Screenshot liefert den angezeigten Fehler, nicht den vollständigen OCR-Text oder die
Originaldateien der beiden betroffenen Dokumente; deren End-to-End-Abnahme bleibt offen.

## Darstellung optionaler Basisangaben ab 0.14.3

Die Oberfläche trennt Hinweise zu Text/Original von optionalen Basisangaben.
Fehlender Gegenstand, unbekannter Aussteller, unklare Dokumentart oder eine
fehlgeschlagene Basisanalyse erhöhen nicht die angezeigte Anzahl der Textprüfhinweise.
Diese Angaben stehen in einem eigenen neutralen Abschnitt. Echte OCR-, Quellen-
und Verarbeitungshinweise bleiben sichtbar. Die Anzeige ist keine prozentuale
Qualitätsbewertung oder Zusage, dass der Text vollständig und fehlerfrei ist.

Die zugrunde liegenden Befunde und die Regeln zur ausdrücklichen Freigabe bleiben
erhalten. Bei einer neuen Freigabe benennt die Bestätigung deshalb Hinweise zu
Text, Original oder optionalen Basisangaben ausdrücklich. Bestehende Freigaben
werden durch diese Darstellungsänderung nicht geschrieben oder erweitert.
