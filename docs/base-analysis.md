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

Titel entstehen aus belegtem Aussteller, Gegenstand, Dokumenttyp und geeignetem Jahr.
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
