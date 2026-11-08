# R3b · SQLite im lokalen Import- und MCP-Pfad

Arbeitsbranch: `codex/local-first-product-readiness`. Basiscommit:
`87ab76c3d7f79b53a2723235c036bf224c7573d6`, zuzüglich der vorhandenen lokalen Änderungen.
Keine Produktivinstallation, keine Änderung bestehender Freigaben und keine Datenmigration.

## Verwendung für einen neuen Bestand

```sh
/absolut/vauldy-local create-sqlite --store /absolut/neuer-bestand
/absolut/vauldy-local import --store /absolut/neuer-bestand /absolut/synthetisch.pdf
/absolut/vauldy-local status --store /absolut/neuer-bestand
```

`create-sqlite` verweigert jedes vorhandene Zielverzeichnis. Das Elternverzeichnis muss
existieren. Die Ausgabe enthält den neuen `vaultPath` (`sqlite/records.sqlite`). Eine neue,
explizite Freigabe verweist auf genau diesen Pfad; der Import legt keine Freigabe an.
Die Einrichtung kann den eigenen SQLite-Bestand lesen, importieren und verwalten, wenn er
vorab unter `<setup-root>/vault` ausdrücklich angelegt wurde. Es gibt noch keinen
SQLite-Umschalter und keine automatische Migration im Assistenten.

Bestehende JSON-Bestände bleiben bei JSON einschließlich ihrer Backuprotation. Auch neu
implizit durch Import angelegte Bestände verwenden weiterhin JSON. Die Versionskennung
`--build-info` nennt JSON als Standard und beide unterstützten Speicherformate separat.

## Umsetzung und Sicherheitsgrenzen

- `LocalDocumentStore` ist der gemeinsame Einstieg für Import, Worker und Verwaltung.
  Formatmarker 3 bezeichnet neue SQLite-Bestände; alte Writer akzeptieren ihn nicht.
- Der SQLite-Adapter verwendet einzelne Datensätze mit SHA-256-Prüfung und sekundären
  Indizes für Inhaltsduplikate, Originalpfad/-identität und OCR-Zustand. OCR-Start, Abschluss,
  Fehler und Analyse aktualisieren nur die betroffenen Zeilen. Wiederanlauf liest gezielt
  die unterbrochenen Erkennungen. Verwaltungsinventare dürfen weiterhin vollständig lesen.
- Die bestehende prozessübergreifende Writer-/OCR-Sperre bleibt erhalten. Änderungen und
  zufällige Generationstoken werden durch SQL-Trigger gemeinsam atomar committet.
  `synchronous=FULL`, privates Verzeichnis 0700 und Datenbank 0600; kein Netzwerkdienst.
  Symlinks/Hardlinks bzw. fremde oder öffentliche Datenbank-/Journaldateien werden abgewiesen.
- Standard ist das SQLite-Rollbackjournal. MCP prüft zusätzlich zur Dateidentität die
  Transaktionsgeneration, sodass auch WAL-Commits ohne geänderte Hauptdatei erkannt werden.
  Ein nur umgestelltes WAL ohne initialisierte Journaldateien kann vom streng lesenden
  MCP zunächst als nicht verfügbar abgewiesen werden; die Initialisierung gehört zum Writer.
  Ein konkurrierender Commit kann die laufende Antwort sicher abbrechen; der Client muss
  dann erneut abfragen. Es werden keine veralteten Ergebnisse als aktuell ausgegeben.
- `LocalVaultSnapshotSource` liest ausschließlich freigegebene SQLite-Datensätze für MCP.
  Datenbankstruktur und jeder gelesene Datensatz werden geprüft. Anders als beim sequenziellen
  JSON-Leser werden nicht freigegebene OCR-Payloads weder decodiert noch gecacht.
- Generation und Profilrevision binden Antwortprüfung, Handles, Pagination und den
  abgeleiteten Suchindex. Eine Änderung auch außerhalb der Freigabe invalidiert SQLite-Handles
  und Cursor. Privacy, wörtliche Quellenbindung und explizite Auswahl bleiben vorgeschaltet.
- Lokale Bestandsberichte verwenden Datenbankidentität plus Generation. Originalkopien und
  Security-Scoped Bookmarks behalten ihre bisherigen Regeln. Der bisherige JSON-spezifische
  Dienst zum Entfernen verwalteter Alt-Kopien ist für SQLite ausdrücklich gesperrt.

## Noch keine Standardfreigabe

R3b ersetzt keine Kundenabnahme. Der SQLite-Pfad hat vorläufig eine Grenze von 1 GiB und
20.000 importierten Datensätzen; diese Grenzen sind keine Leistungszusage. Große Freigaben,
Inventaransichten und Privacy-Vorbereitung halten weiterhin mehrere Datensätze im Speicher.
Die 1k/2k/5k/10k/20k-Lastmessungen mit langen Texten folgen in R3d.

R3c muss JSON→SQLite-Vorschau, Speicherprüfung, Backup/Restore am neuen Ziel, vollständigen
Vergleich und den expliziten Rückweg liefern. Ein SQLite-Rollbackjournal ersetzt kein
Benutzerbackup. Ein alter Softwarestand kann neue Format-3-Bestände nicht bearbeiten.
Die isolierten R3-Pilotdatenbanken mit Schema 1 werden nicht automatisch auf Schema 2 migriert.

## Geänderte Dateien dieser Iteration

| Dateien | Änderung |
| --- | --- |
| `Sources/VauldyCore/SQLiteDocumentStorePilot.swift` | Pilot zum gemeinsamen `SQLiteDocumentStore` mit Schema 2, Generationstriggern, Zeilenzugriffen und sekundären Indizes ausgebaut; alter Typname als interne Testkompatibilität erhalten. |
| `Sources/VauldyCore/LocalVaultSnapshotSource.swift` | Gemeinsamer lesender JSON-/SQLite-Adapter. |
| `Sources/VauldyCore/LocalDocumentStore.swift`, `LocalImportWorker.swift` | Explizite Neuanlage, gezielte OCR-Schreib-/Lesewege, Queue-Validierung und Wiederanlauf. |
| `Sources/VauldyCore/LocalInventoryReconciliation.swift`, `LocalOriginalMigration.swift` | Inventarbindung an Generation; JSON-spezifische Kopienlöschung für SQLite sperren. |
| `Sources/VauldyMCPRuntime/MCPFileVersion.swift`, `ReadOnlyMCPRuntime.swift` | Quelle, Antwort, Handle, Cursor und Suchindex an Commitgeneration binden. |
| `Sources/VauldyMCPRuntime/MCPBuildIdentity.swift` | Unterstützte Speicherformate getrennt vom JSON-Standard ausweisen. |
| `Sources/VauldyLocalCLI/main.swift` | `create-sqlite --store` für ein neues Ziel. |
| `Sources/VauldyMCPSetup/SetupModel.swift`, `SetupDetailViews.swift` | SQLite lesen und den eigenen Speicher korrekt anzeigen. |
| `Tests/VauldyMCPRuntimeTests/SQLiteIntegrationTests.swift` | Native OCR, Privacy, Generation, Indexmodi, Widerruf, Wiederanlauf, selektive Korruptionsprüfung und WAL. |
| `scripts/mcp/sqlite_integration_smoke_test.py`, `regression_test.py` | Echter Worker-/stdio-/SIGKILL-Test und Aufnahme in die Gesamtregression. |
| `docs/storage-r3b.md`, `local-first-todo.md`, `mcp-mvp.md`, `quality/storage-r3b-2026-11-06.json` | Umsetzung, Nachweise und nächste Schritte. |

## Tatsächlich ausgeführte Prüfkommandos

Die Quell-/Testkopie unter `/private/tmp/vauldy-deadlines.kTXJpJXZ/source` wurde bytegleich
geprüft. Der erste Befehl baut nativ; der abschließende gemeinsame Lauf verwendet zusätzlich
`--skip-build` mit dem unveränderten, zuletzt gebauten Testprogramm.

```sh
swift test -c release --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter 'SQLiteIntegrationTests|SQLiteDocumentStorePilotTests|LocalImportTests|LocalWorkerTests|LocalOriginalReferenceTests|InventoryWorkflowTests|MCPScalabilityTests|MCPPrivacyBoundaryTests|MCPRetrievalCompletenessTests|StorageBoundaryTests'
swift test -c release --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter SQLiteIntegrationTests
swift test -c release --skip-build --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter 'SQLiteIntegrationTests|SQLiteDocumentStorePilotTests|LocalImportTests|LocalWorkerTests|LocalOriginalReferenceTests|InventoryWorkflowTests|MCPScalabilityTests|MCPPrivacyBoundaryTests|MCPRetrievalCompletenessTests|StorageBoundaryTests'
python3 scripts/mcp/sqlite_integration_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-local /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --output /private/tmp/vauldy-r3b-wire.json
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --check
```

Der gezielte finale SQLite-Lauf bestand fünf Tests (darunter eine Parametrisierung mit drei
Indexmodi). Der echte Prozesslauf importierte von 41 auf 42 Dokumente, bei unverändert zwei
Freigaben. Er beendete den Worker tatsächlich während `recognizing` per SIGKILL. Der Client
startete ihn automatisch neu; Import, Queueabschluss und SQLite-Integritätsprüfung bestanden.
Originalbytes, Freigabe und unveränderte Payloadzeilen blieben bytegleich; alte Handles und
Cursor wurden abgewiesen. Verkleinern und Deaktivieren der Freigabe sowie MCP-Neustart bestanden.

Zehn parallele Listenaufrufe: sieben erfolgreich, drei sicher abgebrochen bei gleichzeitigem
Commit. Median aller Versuche **52,393 ms**, P95 **76,473 ms**, Import einschließlich Abbruch
und Wiederanlauf **754,791 ms**. Kleine synthetische Stichprobe mit zwei Freigaben, keine
20.000er- oder Zielchat-Performanceaussage. Die Laufzeiten enthalten auch die Fehlerantworten.

MCP-v1-Vertrag mit JSON-Quellen, beiden Antwortkanälen, Privacy und Widerruf sowie lokale
Relay-Werkzeug-Parität bestanden. Der Gesamtregressions-Runner wurde erweitert, aber nicht
komplett ausgeführt. Kein neues Installerpaket, keine Signierung/Notarisierung, keine visuelle
UI-Abnahme und kein realer ChatGPT- oder netzgetrennter Kunden-Mac-Test in dieser Iteration.

Vorläufe hatten korrigierte Testannahmen: aktivierte leere Freigabe, noch nicht initialisiertes
WAL und die Stop-Marke des eigenen Testworkers. Diese fehlgeschlagenen Vorläufe sind keine
bestandenen Abnahmen. Das strikt lesende bzw. gesperrte Verhalten wurde dafür nicht gelockert.


Der abschließende gemeinsame Lauf meldete `98 tests in 10 suites passed after 82.062 seconds`.
Die Aufschlüsselung enthält **97 tatsächlich gestartete und bestandene Testfunktionen** und
**einen übersprungenen optionalen Benchmark** (`largeSyntheticStorageComparison`). Der Benchmark
ist keine neue Leistungsmessung dieser Iteration. [Maschinenlesbarer Nachweis](quality/storage-r3b-2026-11-06.json).

Freigabeentscheidung: **GO für neue isolierte SQLite-Bestände und weitere Entwicklung.**
**NO-GO für automatische Kundenmigration, SQLite als allgemeinen Standard und eine
20.000-Dokumente-Leistungszusage.** R3c und R3d haben dafür eigene Abnahmekriterien in der
To-do-Liste. Es wurde kein Commit, Push oder PR und kein Installationspaket erstellt.
