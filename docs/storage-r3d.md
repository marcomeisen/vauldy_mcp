# R3d · SQLite-Lastprüfung

Prüfbranch: `codex/local-first-product-readiness`, Basiscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6` plus vorhandene lokale Änderungen.
Getestet wird der angebundene R3c-Stand mit bytegeprüften vorhandenen Release-Binaries.
Diese Iteration ergänzt den reproduzierbaren Prüflauf, keine Änderung am produktiven
Speicherformat, keine Installation und keine Kundenmigration.

## Vorgehen und vorab festgelegte Grenzen

- Größen: 1.000 / 2.000 / 5.000 / 10.000 / 20.000 Dokumente, jeweils ein eigener privater
  temporärer Bestand. Die Größen werden nicht verkleinert, wenn eine Abfrage zu langsam wird.
- Je generiertem Dokument etwa 32 KiB Text auf acht synthetischen Seiten. Vier deterministische
  Dokumentfamilien (Versicherung, Rechnung, Steuerbescheid, Befund), eindeutiger Prüfmarker am
  Textende und eine garantiert nicht vorhandene Suchphrase. Kein echtes Kundendokument.
- Zwei Dokumente pro Bestand werden tatsächlich über den nativen OCR-Worker importiert.
  Die übrigen langen OCR-Datensätze sind direkte synthetische SQLite-Fixtures einschließlich
  gültiger Payload-Digests und Generationstrigger. Ihre Originaldateien werden nicht vorgetäuscht
  als tatsächlich importierte PDFs. Dies ist keine 20.000-Dateien-OCR-Durchsatzabnahme.
- Pro Größe: 100 explizite Freigaben und separat Vollfreigabe. Die Parallelprüfung von Import
  und Abfragen verwendet 100 Freigaben; die Vollfreigabeprüfung erfolgt anschließend.
- Je 25 Status- und kompakte Listenaufrufe, Median und P95 (Nearest Rank). Der erste Statusaufruf
  wird separat gemessen. „Kalt“ bedeutet neuer Serverprozess; der macOS-Dateisystemcache wurde
  nicht geleert. Die erste kompakte Liste kann noch den Projektionsaufbau enthalten.
- Textfilter und gerankte Markersuche sind separate Einzelmessungen, keine Such-P95-Aussage.
  Trefferzahlen werden gegen unabhängige Sollzahlen geprüft. Vollständige kompakte Pagination
  muss alle Freigaben genau einmal liefern. Eine Zeitüberschreitung ist keine korrekte leere Liste.
- Prüfschwellen: erster Status höchstens 5 s, warme Status-/kompakte Listen-P95 höchstens 1 s,
  Textfilter höchstens 5 s, nativer Peak-RSS des MCP-Servers höchstens 512 MiB.
- 30 s pro Werkzeugaufruf, maximal 120 s je warmem Messblock. Ein abgebrochener Messblock
  gilt nicht als bestandene P95-Abnahme. Der Prüfer beendet ausschließlich seinen eigenen
  Server bei beobachteten 1,5 GiB RSS, um den Entwicklungs-Mac nicht unbeschränkt zu belasten.

Gemessen auf Apple M1 Pro (8 CPU-Kerne), 16 GiB RAM, macOS 27.2, arm64. Der native Peak-RSS
kommt aus `/usr/bin/time -l` für den Server-Unterprozess. Die zusätzliche RSS-Stichprobe alle
200 ms dient nur der Notabschaltung. Server-RSS ist nicht der gesamte Speicherbedarf von
Worker, CLI, Chatbot oder macOS. Andere Nutzerprogramme und der OS-Dateicache wurden nicht
verändert. Die Messungen sind lokale stdio-Werte, keine ChatGPT-/Relay-Latenz.
Bei Zeitüberschreitungen gilt der RSS nur bis zum Abbruch, nicht als maximaler Bedarf einer
vollständig ausgeführten Suche. Der Prüflauf speichert auch gescheiterte Abnahmekriterien im
JSON (`go: false`); ein normal beendeter Prüferprozess bedeutet deshalb nicht automatisch GO.

## Resilienz und Freigaben

Jede Größenstufe prüft einen echten SIGKILL einer offenen SQL-Transaktion. Anschließend
müssen Generation und Inhalt unverändert sein und `PRAGMA integrity_check` erfolgreich bleiben.
Danach läuft der native Import des letzten Dokuments parallel zu MCP-Listenabfragen. Der
beobachtete OCR-Worker wird während `recognizing` beendet; der anfragende Client muss ihn
neu starten und den Import bis zur vorgesehenen Gesamtzahl abschließen.

Neue Importe dürfen die 100 Freigaben nicht erweitern. Alte Handles und Cursor müssen nach
Datenänderung abgewiesen werden. Nach einem MCP-Neustart wird erneut abgefragt und der Zugriff
widerrufen. Zusätzlich prüft jede vollständig erreichte Abfragevariante das Verkleinern der
Freigabe sowie den Widerruf für Lesen, Listen und Suche.

Am 20.000er-Bestand wird außerdem der optionale persistente Index mit 100 Freigaben geprüft:
Widerruf erst nach tatsächlich beobachteter `.build-*`-Datei, keine Dokumentausgabe nach Widerruf,
anschließend SIGKILL während eines neuen Indexaufbaus, Neustart, Bereinigung der Zwischenstände
und erneute vollständige Kandidatenzählung. Dies ersetzt keine Vollfreigabe-Lastabnahme dieses
optionalen Indexes.

## Ergebnisse der Wiederanlaufprüfung

| Dokumente | Import inkl. OCR-Abbruch/Neustart | Parallele Listen | Davon erwartete Quellwechsel-Fehler | Status nach Serverneustart |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 809.6 ms | 13 | 0 | 70.4 ms |
| 2,000 | 582.9 ms | 10 | 4 | 73.2 ms |
| 5,000 | 738.5 ms | 11 | 3 | 74.9 ms |
| 10,000 | 669.2 ms | 10 | 3 | 78.7 ms |
| 20,000 | 759.7 ms | 12 | 4 | 82.3 ms |

Alle fünf Prüfungen bestanden: SQL-Rollback und Datenbankintegrität nach SIGKILL, automatischer
Worker-Neustart, abgeschlossener letzter Import, keine unerwartete Erweiterung der 100 Freigaben,
Ablehnung alter Handles/Cursor, bytegleiches Testoriginal und wirksamer Widerruf nach Neustart.
Bei Quellwechseln waren ausschließlich die vorgesehenen Fehler für geänderte/nicht lesbare
Quellen zulässig; diese sind in der Tabelle ausdrücklich gezählt. Erfolgreiche Antworten mussten
weiterhin genau die 100 Freigaben melden. Die Importzeit bezieht sich auf **ein** kleines natives
Testbild im jeweiligen langen Textbestand, nicht auf den OCR-Durchsatz aller Dokumente.

## Im Code erkennbare Ursachen der bisherigen Engpässe

Diese Einordnung stützt sich auf Code und Messung; es wurde kein Sampling-Profilerlauf ausgeführt.

- `LocalVaultSnapshotSource.loadSelection` lädt die freigegebenen vollständigen Payloads und
  kodiert sie erneut, um die Cachegröße zu bestimmen. SQLite liefert gezielte Zeilen, aber
  Status und erste kompakte Listen lesen dadurch weiterhin vollständigen OCR-Text.
- `MCPVaultSnapshotCache` hält standardmäßig höchstens 64 MiB kodierte Quellbytes. Oberhalb
  dieser Grenze verzichtet auch `authorizedDocuments` auf seinen Dokumentcache. Ein neuer
  Werkzeugaufruf liest und decodiert dieselbe große Auswahl erneut.
- `VaultDocumentFilter.matches` erzeugt für die genaue Wortsuche die Tokens der gesamten
  durchsuchbaren Felder erneut. Der normale Pfad verwendet dafür keinen persistenten Index.
- Die gerankte Suche in `LocalVault.search` (`VaultRuntime.swift`) behält höchstens etwa 16 MB abgeleitete Felder.
  Weitere Dokumente werden beim Scoring ohne diesen Cache verarbeitet. `search_documents`
  nutzt diesen Pfad auch unabhängig vom optionalen Kandidatenindex der Listenwerkzeuge.
- Die schnelle Cursorfortsetzung kann bereits eine kompakte Projektion verwenden. Ein kurzer
  Seitenabruf beweist deshalb nicht, dass auch neue Textabfragen über den gesamten Bestand
  schnell sind.

## Wiederholung

```sh
python3 scripts/mcp/sqlite_load_acceptance.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-local /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --output /private/tmp/vauldy-r3d-matrix.json > /private/tmp/vauldy-r3d-matrix.log 2>&1
```

Vorher wurde der Prüfer mit `--counts 1000 --output /private/tmp/vauldy-r3d-pilot.json`
erprobt. Der finale Bericht trennt Pilot und vollständigen Lauf. Der aufwendige Lasttest ist
bewusst eigenständig ausführbar und wird nicht ungefragt bei jedem normalen Regressionstest gestartet.

## Messergebnisse und Entscheidung

**R3d-Prüflauf abgeschlossen, Lastfreigabe NO-GO.** Alle fünf 100er-Freigaben bestehen die
festgelegten lokalen Gates. Keine Vollfreigabe besteht alle Gates. SQLite wird deshalb nicht
zum allgemeinen Standard umgestellt; eine schnelle kleine Auswahl aus einem großen Bestand
ist keine Zusage für schnelle Suchen über alle 20.000 Dokumente.

| Bestand | SQLite-Datei | Liste P95 bei 100 Freigaben | Server-RSS bei 100 | Erster Status bei Vollfreigabe | Liste P95 bei Vollfreigabe | Server-RSS bei Vollfreigabe |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 35.95 MiB | 78.0 ms | 49.5 MiB | 0.470 s | 0.091 s (25/25) | 147.5 MiB |
| 2,000 | 71.93 MiB | 89.0 ms | 49.0 MiB | 1.088 s | 0.892 s (25/25) | 205.5 MiB |
| 5,000 | 179.86 MiB | 84.4 ms | 49.0 MiB | 2.289 s | 2.503 s (25/25) | 440.8 MiB |
| 10,000 | 359.81 MiB | 78.9 ms | 49.2 MiB | 4.531 s | 3.467 s (25/25) | 634.0 MiB |
| 20,000 | 719.56 MiB | 91.4 ms | 49.3 MiB | 9.208 s | 11.823 s (17/25) | 1197.4 MiB |

Die Anzahl in Klammern ist die tatsächlich abgeschlossene Stichprobe. Weniger als 25 Aufrufe
bedeutet Messblock abgebrochen, keine bestandene P95-Abnahme. SQLite-Dateigröße ohne Originale,
Worker-/CLI-Dateien und abgeleitete Indizes. Vollfreigabe-RSS schließt gegebenenfalls den
anschließend abgebrochenen Filter-/Suchaufruf bis zur Beendigung ein.

| Vollfreigabe | Status P95 (Aufrufe) | Versicherungsfilter | Gerankter seltener Marker | Vollständige Pagination |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.147 s (25/25) | 5.978 s | 10.627 s | 10 Aufrufe / 0.668 s |
| 2,000 | 0.920 s (25/25) | 11.499 s | 21.819 s | 20 Aufrufe / 2.088 s |
| 5,000 | 2.409 s (25/25) | 28.865 s | > 30 s, abgebrochen | 50 Aufrufe / 7.643 s |
| 10,000 | 4.336 s (25/25) | > 30 s, abgebrochen | nicht erreicht | 100 Aufrufe / 13.927 s |
| 20,000 | 8.822 s (14/25) | > 30 s, abgebrochen | nicht erreicht | 200 Aufrufe / 33.662 s |

Abgeschlossene Filterprüfungen stimmen mit den unabhängigen Sollzahlen überein. Bei 5.000
Vollfreigaben sind alle drei Filter korrekt, die gerankte Markersuche läuft ins Zeitlimit.
Bei 10.000 und 20.000 scheitert bereits der erste Filter am Zeitlimit; die danach liegenden
Suchprüfungen sind nicht als bestanden zu interpretieren. Bei allen zehn Freigabevarianten
sind komplette Pagination ohne doppelte Handles, Verkleinerung der Freigabe und Widerruf
für Lesen/Listen/Suche bestanden. Die Datenbank bleibt nach den reinen Abrufen bytegleich.

Der zusätzliche Indexversuch am 20.000er-Bestand mit **100 Freigaben** bestand: Widerruf bei
beobachteter Staging-Datei liefert keine Dokumentdaten; SIGKILL beim nächsten Aufbau und
anschließender Neustart bereinigen die Zwischenstände. Wiederaufbau plus erste Query: 783.8 ms;
abgeleitete Indexdateien: 0.172 MiB. Dies ist keine 20k-Index-Lastfreigabe.

## Nächste Umsetzung und geänderte Dateien

1. **R3d.1:** Status und kompakte Listen aus kleinen, generationstreuen SQLite-Projektionen
   bedienen. Volltexte nur bei Bedarf lesen; Cachegrenzen, Pagination und Widerruf erhalten.
2. **R3d.2:** Inkrementellen normalisierten Kandidatenindex durchgängig für Filter, gerankte
   Suche und Übersichten verwenden. Treffersemantik, Quellbelege und Freigaben absichern.
3. **R3d.3:** Dieselbe Matrix wiederholen, um parallelen Import mit Vollfreigabe und wiederholte
   Suchmessungen ergänzen. Erst nach bestandenen Gates über den SQLite-Standard entscheiden.

Geändert werden ausschließlich `scripts/mcp/sqlite_load_acceptance.py`, dieser Bericht,
`docs/quality/storage-r3d-2026-11-06.json`, `docs/local-first-todo.md` und `docs/mcp-mvp.md`.
Die vorhandenen anderen lokalen Änderungen stammen aus früheren Iterationen. Kein neuer
Swift-Build und kein neuer Swift-Unit-Testlauf in R3d: Die vorhandenen R3c-Release-Binaries
wurden tatsächlich ausgeführt; 133 Paket-, Quell- und Testdateien sind bytegleich mit ihrer
Buildkopie. Binary-SHA256, Quelldatei-Hashes, Rohmessungen, Hardware und Kommandos stehen im
[maschinenlesbaren Prüfnachweis](quality/storage-r3d-2026-11-06.json).


Zusätzlich ausgeführt: `python3 scripts/mcp/sqlite_load_acceptance.py --help` und
`git diff --check` jeweils Exit 0; Python-Syntax, Bericht-/Skripthash und die zehn
Pagination-/Widerrufsergebnisse separat geprüft. Nach Abschluss: keine verbleibenden
R3d-Testprozesse und keine temporären Fixture-Verzeichnisse. Der Lastprüfer beendet sich
mit Exit 0, seine Abnahmeentscheidung lautet ausdrücklich `go: false`.
