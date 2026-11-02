# Clientunabhängiger lokaler MCP-Dienst

Version 0.8 importiert PDFs und Bilder und erkennt ihren Text unabhängig von der bestehenden
Vauldy-App. Der lokale Kern besitzt dafür einen eigenen Bestand. Die MCP-Schnittstelle bleibt
lesend und freigabegesteuert; die bestehende App und ihre Daten bleiben erhalten. Das Paket wird eigenständig in `marcomeisen/vauldy_mcp` entwickelt.

## Grenzen und Module

- `Sources/VauldyCore`: UI-/MCP-unabhängige Modelle, eigener Importbestand, native OCR, Snapshot-Leser
  und lexikalische Suche.
  Die Core-Ergebnisse sind **nicht** für externe Ausgabe bereinigt.
- `Sources/VauldyDocumentIntelligence`: lokale, regelbasierte Extraktion und gemeinsame Annahmeprüfung.
- `Sources/VauldyPrivacy`: eigenständig versionierte `IdentifierPrivacySession` und deterministischer
  Kennungsdetektor. Keine Quellpfadabhängigkeit zur App.
- `Sources/VauldyMCPRuntime`: lokale Verbindungsfreigabe, Datenschutzgrenze, begrenzte DTOs,
  flüchtige Dokumentkennungen, seitenbezogenes Lesen und lokale Installationsverwaltung.
- `Sources/VauldyMCPServer`: standardkonformer stdio-Adapter mit vier lesenden Tools.
- `Sources/VauldyMCPSetup`: eigenständiger macOS-Assistent für Import und MCP-Freigaben.
- `Sources/VauldyLocalCLI`: Import, Status, Wiederholung und Desktop-Registrierung ohne grafische Oberfläche.
- `Sources/VauldyDemoDocuments`: echte synthetische PDF-/Bildoriginale für Einrichtung und Tests.

Kein HTTP-Listener, kein Tunnel, keine Cloud-Inferenz, kein automatischer Login-Dienst. Ein
Client mit stdio-Unterstützung startet den Server als Unterprozess. Seine eigene Cloud-Verarbeitung
liegt außerhalb Vauldys Kontrolle. Tool-Annotationen sind Hinweise; echte Berechtigungen werden
in der Runtime geprüft. Die lokale Prozess-/Benutzergrenze schützt nicht vor einem bösartigen
Programm mit denselben Dateizugriffsrechten.

## MCP-Vertrag

| Tool | Eingabe | Ausgabe |
| --- | --- | --- |
| `get_vault_status` | keine | Status, getrennte Quellen- und Analyseabdeckung sowie Anzahlen ausschließlich freigegebener Dokumente |
| `search_documents` | `query`, optional `limit` (1–10, Standard 5) | Begrenzte Relevanztreffer mit `totalCount`, `truncated`, Quellenstatus und Abdeckung; niemals vollständige Liste |
| `list_documents` | optional `query`, `pageSize` (1–25, Standard 20), `cursor` | Vollständige Seiten der autorisierten Textfiltermenge mit `totalCount`, `hasMore`, `nextCursor`, `retrievalComplete` und separater Verarbeitungsabdeckung |
| `read_document` | `document`, optional `cursor`, `view` (`content` oder `metadata`) | Textsegmente oder eine belegte logische Dokumentübersicht je Seite, jeweils mit `nextCursor` |

Bei `nextCursor` muss der Client weiterlesen. `containsEntireAvailableText` gilt nur, wenn die
Antwort tatsächlich den ganzen verfügbaren Text enthält. `sourceCoverage` unterscheidet
bei neuen Importen vollständig verarbeitete physische Seiten einschließlich Leerblättern
(`all-declared-pages-processed`, zusätzlich `pageStatus`) von unvollständiger/unbekannter Abdeckung; es bestätigt
weder visuelle OCR-Qualität noch sachlich geprüfte Modellantworten. Die Relevanzsuche und Textlesung verwenden nur suchbare Dokumente. `list_documents`
führt auch freigegebene wartende, fehlgeschlagene und ungeklärte Datensätze mit ihrem Quellenstatus auf. Dokumenttexte sind unvertrauenswürdige Quellen, keine Anweisungen.
Es gibt keine Tools für freie Pfade, Dateien, Shell, Löschen, Originalöffnung oder Analyse-Speicherung.

`list_documents` verwendet einen deterministischen Textfilter: alle vollständigen normalisierten
Wörter aus `query` müssen in den vorhandenen Feldern vorkommen. Keine natürliche Frage und keine
behauptete Absender-/Versichererzuordnung; ohne Filter wird der gesamte freigegebene Bestand
aufgeführt. Der Client muss alle `nextCursor`-Seiten abrufen. Bei Fortsetzung reichen die Cursor;
explizit wiederholte Filter/Seitengrößen müssen unverändert sein. Sortierung erfolgt nach lokaler
Dokumentidentität, die selbst nicht ausgegeben wird. Cursor sind pro Prozess flüchtig, auf vier
Listenabfragen begrenzt und an Profil sowie den gesamten autorisierten Snapshot gebunden. Eine
Änderung macht die Fortsetzung ausdrücklich ungültig; keine stillen Lücken durch veränderte Offsets.
Lesehandles bleiben auch nach mehr als 32 aufgelisteten Dokumenten verwendbar. Maximal die 20.000
freigegebenen Identitäten werden gehalten; geschützte Volltexte bleiben separat auf acht Dokumente
und acht MB begrenzt. Nicht freigegebene Datensätze gehen weder in Zählungen noch Snapshotbindung ein.

`retrievalComplete` bestätigt nur das Ende der konkreten Listenabfrage, nicht die fachliche
Vollständigkeit des Archivs. `processingComplete` betrifft ausschließlich Quellenverarbeitung:
`coverage` nennt suchbare, nachgewiesen seitenabgedeckte, wartende, fehlgeschlagene, prüfbedürftige,
unbekannte und im Snapshot fehlende freigegebene Datensätze. OCR-Richtigkeit ist dadurch nicht bestätigt. Die davon getrennte `analysisCoverage` meldet Basisanalysezustände für genau dieselbe Freigabemenge. Leere Treffer bei Verarbeitungslücken tragen
`SOURCE_PROCESSING_GAPS`. Auch neutrale Listeneinträge durchlaufen die Privacy-/Freigabegrenze.

Auszüge werden nach vollständiger Kontextbereinigung um die Fundstelle gewählt, statt den
Seitenanfang zu liefern. Dateinamentreffer ohne OCR-Fundseite verwenden vorhandenen lesbaren OCR-Text
vor einer Zusammenfassung. Physische Seite und unzerteilte Platzhalter bleiben erhalten. Alle vier
Tools deklarieren `outputSchema`; beide Antwortkanäle enthalten denselben bereinigten Vertrag.

`answer_privately` aus 0.1 wird nicht mehr extern angeboten: lokal erzeugte Antworten sind nicht
automatisch vertraulich, sobald sie ein Cloud-Chatbot erhält. `search_vault` wird durch den
freigabegeprüften `search_documents`-Vertrag ersetzt. Es gibt keinen ungeschützten Kompatibilitätsweg.

## Freigabe und Datenschutz

Der Server startet ausschließlich mit `--profile /absoluter/pfad/profile.json`. Es gibt keinen
Standardpfad zum Archiv und keinen `--vault-path`-Bypass. Die Einrichtung legt pro Verbindung eine
lokale Freigabe an: genau ausgewählte Dokument-IDs, Pfad zum Bestand, Aktivierungszustand und
bestätigter Hinweis zur möglichen Cloud-Verarbeitung. Neue Dokumente bleiben gesperrt.

Vor jeder Anfrage und vor Rückgabe der Ergebnisse wird die Freigabe neu geladen. Pausieren,
Entfernen oder Beschädigung einer Freigabe blockiert weitere Inhalte. Die Konfiguration ist eine
vertrauenswürdige lokale Verwaltungsdatei und niemals ein vom Modell veränderbarer Tool-Parameter.

Die Kennungserkennung erhält den vollständigen Dokumentkontext vor Kürzung. Danach werden nur
bereinigte Abschnitte segmentiert. Platzhalter werden nicht in Teile zerschnitten. Titel sind
neutral, Abfrage und Importdaten werden nicht zurückgespiegelt. Dauerhafte Archiv-IDs bleiben
lokal; Lesekennungen sind pro Serverlauf flüchtig und werden bei Dokument-/Freigabeänderung ungültig.
Beide MCP-Kanäle (`content` und `structuredContent`) enthalten identische bereinigte Ergebnisse.
Fehlertexte enthalten keine ursprünglichen Decoder-/Dateisystemmeldungen.

Das ist heuristische Pseudonymisierung, keine Anonymisierung oder allgemeine DSGVO-Freigabe.
Auch die ausdrücklich freigegebenen fachlichen Inhalte können personenbezogen bleiben.

Grenzen: Snapshot höchstens 128 MiB/20.000 Dokumente; Datenschutzkontext eines ausgegebenen
Dokuments höchstens 1 MB; höchstens 32 Dokumentkennungen pro Prozess; Segmente höchstens 6.000
Zeichen, Antworten höchstens 180 KB. Überschreitungen führen zu ausdrücklichen Fehlern.
Der Kern liest Such-Snapshots pro Anfrage. Ein begrenzter prozesslokaler Suchindex bereitet nur
geänderte Dokumente neu vor; bereinigte Textfassungen werden versions- und freigabegebunden wiederverwendet.

## Unabhängiger Import und OCR

`LocalDocumentStore` schreibt ausschließlich seinen markierten eigenen Bestand. Ein fremdes oder
beschädigtes Archiv wird ausdrücklich abgelehnt. Ordnerimporte referenzieren Originale über
schreibgeschützte Security-Scoped Bookmarks; temporäre Einzelimporte behalten eine lokale Kopie.
Beide Pfade werden über SHA-256 dedupliziert und vor Wiederholung erneut geprüft. Atomare Snapshots, vorheriger gültiger
Snapshot als Sicherung, private Dateirechte und prozessübergreifende Schreibsperren sichern den Zustand.
Der Speicher ist lokal, aber nicht zusätzlich anwendungsseitig verschlüsselt.

`LocalImportService` persistiert queued/recognizing/completed/partial/failed/interrupted/cancelled.
Eine Prozesssperre lässt nur einen nativen OCR-Lauf pro Bestand zu. Abbruch hält diese Sperre bis zum
wirklichen Ende der System-OCR; ein abgebrochener Lauf darf keinen vollständigen Erfolg speichern.
Nach einem Prozessabbruch wird ein verwaistes recognizing beim Öffnen/Status/Import erkannt. Wiederholen
nutzt das lokale Original. `LocalImportWorker` hält eine private dateibasierte Warteschlange mit genau einem Worker pro Bestand.
CLI und Assistent starten dasselbe Programm bei Bedarf ohne Netzwerkport. Der Prozess überlebt das
anfragende Fenster, beendet sich ohne aktive Ordnerüberwachung nach 120 Sekunden Leerlauf und lässt sich nach dem aktiven Auftrag
stoppen. Wartende Clients starten einen abgestürzten Worker höchstens dreimal neu. Kein Login-Agent
wird registriert; ohne Client wird erst beim nächsten Auftrag wieder aufgenommen.

`PDFContentInspection` verfolgt Grafiktransformationen und Formressourcen. Textbasierte Formen bleiben
im direkten Textpfad, kleine getrennte Rasterbereiche werden einzeln erkannt. Unklare/überlappende oder
große Bildinhalte bleiben auf vollständiger Seiten-OCR. Inline-Bilder fallen konservativ zurück.
`NativeLocalDocumentOCR` verwendet genaue Vision-OCR, angepasste Schriftauflösung und überlappende
Teilbilder für lange Belege. Kein fachlicher Inhalt wird allein wegen geringer Fläche verworfen.
Physische Seiten, Leerblätter, unlesbare Seiten und echte OCR-Konfidenzen bleiben unterscheidbar.
Die Grenzen sind 50 MiB Original, 200 Seiten, 900 KB Text und 3072 Pixel längste OCR-Bildkante. Lange Bildoriginale werden bis höchstens 12288 Pixel
dekodiert und vor OCR in Teilbilder zerlegt; breite/rotierte Sonderfälle bleiben konservativ prüfpflichtig.
Native Aufrufe laufen seriell außerhalb des UI-Threads; es gibt keinen Timeout, der noch aktive
native Arbeit als beendet behandelt. Ein kalter System-OCR-Start kann deutlich länger dauern. Inhaltsfreie Messungen trennen Prüfung,
Rendering, native Erkennung, Speicherung und Cache. `LocalOCRPageCache` hält höchstens 32 Original-/
Konfigurationsfassungen. Er speichert nur vollständige Seiten ohne Review-Signal, bleibt lokal,
übersteht Worker-Neustarts und wird bei `retry --fresh` umgangen. OCR-Methode und Konfidenz bleiben erhalten.

Import führt nach erfolgreicher Texterfassung eine lokale regelbasierte Basisanalyse aus.
Sie verwendet ausschließlich vorhandene Quellen. Es werden keine Modelle geladen und keine
Cloud-Anbieter aufgerufen. Details und Grenzen: [Basisanalyse](base-analysis.md). Neue Dokumente
sind nicht automatisch freigegeben. Ein MCP-Client bekommt ausschließlich freigegebene, bereinigte
Texte über dieselbe Datenschutzgrenze. CLI-Importpfade werden niemals MCP-Toolparameter.

## Bauen, Paket und Prüfung

```sh
swift test --disable-sandbox
swift build --product vauldy-mcp
python3 scripts/mcp/smoke_test.py /absoluter/pfad/zum/gebauten/vauldy-mcp
python3 scripts/mcp/import_smoke_test.py /absoluter/pfad/vauldy-local /absoluter/pfad/vauldy-mcp
python3 scripts/mcp/benchmark_ocr.py /absoluter/pfad/vauldy-local
python3 scripts/mcp/audit_smoke_test.py /absoluter/pfad/vauldy-local
python3 scripts/mcp/package.py
```

Der Python-Protokolltest startet das echte Binary und verwendet ausschließlich synthetische
Bestände. Er prüft beide Ausgabekanäle, Ablehnung ohne Freigabe, Dokumentgrenzen, Widerruf,
unerlaubte Argumente und unveränderte Archivbytes. Swift-Tests prüfen zusätzlich Kontextbereinigung,
Änderungen zwischen Such-/Leseaufrufen, seitenübergreifende Namen, Pagination und Installation.
Sie benötigen keinen Xcode-App-Testhost und keinen echten Vault.

Die Einrichtung kann für isolierte UI-Prüfungen mit `--setup-root /absoluter/testpfad` gestartet
werden. Das ist ausschließlich ein lokales Startargument, kein MCP-Werkzeug. Beim Test das
künstliche Beispiel verwenden. Auch die Registrierung wird dabei nach `<testpfad>/test-client-home`
umgeleitet; produktive Client-Konfigurationen bleiben unberührt. `MCPClientRegistration` wird vom
Wizard und `vauldy-local connect` geteilt. Es ergänzt ChatGPT-TOML bzw. Claude-JSON, sichert bestehende
Dateien und verweigert Konflikte. Der MCP-Kern bleibt unabhängig von der Client-Registrierung.

Installationsanleitung, Widerruf und Signierungsgrenzen: [mcp-installation.md](mcp-installation.md).

## Weitere Ausbaustufen

1. Gemeinsamer revisionssicherer Dienst vor schreibenden MCP-Funktionen.
2. Optionalen Login-Dienst und einen persistenten Datenbank-Suchindex für große Bestände prüfen.
3. Lokale Originalöffnung mit vertrauenswürdiger Nutzeraktion.
4. Geprüfte Analysevorschläge, Korrektur und Widerruf als getrennte Schreibberechtigungen.
5. Client-Pakete und unterstützte Remote-Adapter separat gegen deren tatsächliche Fähigkeiten prüfen.

## Prüfstand

Die reproduzierbaren Tests verwenden ausschließlich künstliche Originale und isolierte Bestände.
`LocalImportTests` prüft echte Vision-OCR, gemischte und gescannte PDFs, PNG, Leerblätter, fehlende
Seiten, Dubletten, Abbruch bis zum tatsächlichen Worker-Ende, Wiederholung, Originalintegrität,
Dateigrößenlimits, beschädigte/fremde Bestände und konkurrierende Schreibzugriffe.
`import_smoke_test.py` prüft CLI-Import, Worker-Wiederverwendung, MCP-Weitergabe, Widerruf, Cache/frische
Erkennung und eine zwischen Prozessen gehaltene OCR-Sperre samt gemeinsamem Warten auf einen Auftrag.
Die Tests in `LocalImportTests` simulieren einen verwaisten Lauf; das ist kein erzwungener Systemcrash.
`LocalWorkerTests` prüft Leerlaufende, getrennte Warteschlangenaufträge und Abbruch vor/nach nativer
Übernahme. Native Bildtests prüfen Text-/Raster-PDF, Formobjekte, kleine Bildbereiche und lange PNG-Belege.

Den konkret ausgeführten Paket-/UI-Prüfstand hält `dist/mcp/VERIFICATION.txt` neben dem ZIP fest.
Nicht nachgewiesen: Live-Nutzung in ChatGPT/Claude, Intel-/ältere-macOS-Kompatibilität,
Qualität komplexer echter Dokumente, Verschlüsselung des Bestands oder rechtliche Gesamtfreigabe.

## Eigenständige Ordnerüberwachung

`LocalWatchedFolderStore` speichert bis zu 32 lokale Ordner pro markiertem Bestand atomar und mit
Prozesssperre. Assistent und CLI konfigurieren mehrere Ordner, optionale Rekursion sowie Pause/Entfernen.
`LocalWatchedFolderMonitor` prüft im vorhandenen Worker alle fünf Sekunden zwischen OCR-Aufträgen,
wartet zwei unveränderte Beobachtungen ab und übergibt Originale an dieselbe dauerhafte Importqueue.
Der Worker bleibt bei aktivierten Ordnern am Leben; Stop beendet ihn nach dem laufenden Auftrag.
Kein Login-Agent, kein zusätzlicher Netzwerkdienst und keine Änderung der MCP-Dokumentfreigaben.
Nach Prozess-/Mac-Neustart nimmt Öffnen der Einrichtung oder `watch-start` die Überwachung wieder auf.

Versteckte Dateien, Paketinhalte und Symlinks werden übersprungen. Eigener Bestand, darunterliegende
Ordner und ihn enthaltende Ordner sind ausgeschlossen. Scans sind auf 20.000 Einträge je Ordner
begrenzt; insgesamt werden höchstens 20.000 Dateisignaturen und 100 Übergaben pro Scan gehalten. Fehler werden über lokale Statuscodes sichtbar. Unveränderte Dateien werden pro Prozess
übersprungen, nach Neustart prüft der Importer erneut den SHA-256-Hash. Änderungen erzeugen neue
Originale, Entfernung löscht keine Dokumente. Vorhandene Partial-/Fehlerergebnisse bleiben für eine
explizite Wiederholung erhalten. Die MCP-Schnittstelle bleibt unverändert lesend.

`LocalWatchedFolderTests` prüft Mehrfachordner, konkurrierende Konfiguration, Schutz vor beschädigten
Listen/Vault-Überlappung, Rekursion, Symlinks, stabile Dateien, Änderungen, Fehlerwiederholung,
Deduplizierung und Worker-Leerlauf. `scripts/mcp/watch_smoke_test.py` prüft echte Hintergrundprozesse,
PDF-/Bild-OCR, Pause, Neustart und unveränderte Freigaben über MCP mit isolierten künstlichen Dateien.

Native Paketprüfung mit isoliertem `--setup-root`: Zwei Ordner gemeinsam ausgewählt, einen pausiert
und entfernt, künstliches PDF automatisch vollständig erkannt und in der aktualisierten Dokumentliste
weiterhin unausgewählt angezeigt. Reale iCloud-/OneDrive-Ordner sind damit nicht live geprüft.

## Native Verwaltung und Menüleistenstatus (0.7)

Die Setup-App verwendet fünf Bereiche: Übersicht, Verbindungen, Dokumente, Ordner und Einstellungen.
Der vierstufige Assistent trennt Clientauswahl, Dokumentauswahl, Empfänger-/Cloud-Einwilligung und echten lokalen MCP-Test. Ein lokaler Test bestätigt keinen Chatbot- oder Cloud-Zugriff.
`MCPAccessProfile.desktopClient` ist optionale, rückwärtskompatible lokale Metadaten; ein tatsächlicher Client-Eintrag wird separat und nur lesend geprüft. Manuelle/ältere Profile werden nicht still einem Client zugeordnet.

`MCPInstallation.updateSoftware` tauscht Server/CLI, Menühelfer und Verwaltungsbundle unter einer eigenen Sperre aus; bestehende Profile und Client-Einträge bleiben unverändert. `softwareStatus` vergleicht die ausführbaren Programme per SHA256 und berücksichtigt fehlende Komponenten. Laufende ältere Server benötigen einen Neustart im Chatbot. Eine Bestandsinstallation erhält beim Update die Verwaltungs-App für Menü-Einstiege.

`setAccess` und `updateSelection` serialisieren Profiländerungen über eine gemeinsame lokale Sperre. Revisionsprüfung verhindert, dass ein veralteter Entwurf eine zwischenzeitliche Pause überschreibt. Zusätzliche IDs benötigen neue Einwilligung; Speichern erhält den Pausenzustand, eine leere Auswahl sperrt. Pause bleibt auch während des Imports erreichbar.

`MCPProcessPresence` hält je Server eine leere UUID-Marke mit OS-flock. Begrenzte private Metadaten ergänzen Verbindungs-ID, Buildversion, Diagnoseflag und letzten Werkzeuganfragezeitpunkt, ohne Dokumentinhalte, Dokument-IDs, Suchanfragen, Pfade oder PID. Ausschließlich die aktive Sperre beweist Prozesslebendigkeit; normales Ende und SIGKILL geben sie frei. Diagnoseprozesse werden in der UI nicht als Chatbot-Nutzung gezählt. Alte unzuordenbare Marken ergeben einen unklaren Zustand.

`VauldyMCPStatus` liest Serverzustände alle zwei Sekunden, Ordnerzustände alle zehn Sekunden. Das Menü bietet pro Verbindung Freigabe-/Serverzustand, Pause/Fortsetzen mit Bestätigung, Dokumentauswahl und Diagnose. Ordnersteuerung bleibt separat; Beenden stoppt nur den Beobachter. Die feste Menüsperre verhindert mehrere Symbole pro Root. Geöffnete Menüs werden während der Interaktion nicht neu aufgebaut.

Menü-Einstiege schreiben einen begrenzten, typisierten, höchstens fünf Minuten gültigen `MCPSetupRequest` und öffnen das installierte Verwaltungsbundle. Dieser Kanal erlaubt Navigation und lesende Diagnose, keine Freigabeänderungen. Benutzerdefinierte Testwurzeln werden durchgereicht und leiten Clientkonfigurationen in ihr eigenes Test-Home um. Kein Netzwerkdienst und kein Login-Agent.

`MCPLocalProbe` führt einen begrenzten echten stdio-Handshake plus `get_vault_status` mit eigenem Diagnoseprozess aus. Keine Inhalte werden abgerufen; temporäre Dateien und der Kindprozess werden anschließend entfernt. Verfügbar über UI und `vauldy-local check-connection --profile …`.

`MCPManagementTests` prüfen bytegenau erhaltene pausierte Profile, Auswahl-/Revisionsregeln, Legacy-Decodierung, lesende Clientprüfung, Diagnoseausschluss, veraltete Server und einmalige Menü-Navigation. Bestehende Installations-, Datenschutz-, Import-, Ordner- und Sperrentests bleiben erhalten. Paketprüfungen verwenden ausschließlich künstliche Daten und isolierte Clientkonfigurationen.
