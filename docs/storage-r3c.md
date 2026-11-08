# R3c · Bewusste Speicherübertragung und Rückweg

Implementierung im Branch `codex/local-first-product-readiness`, auf Basis von
`87ab76c3d7f79b53a2723235c036bf224c7573d6` plus vorhandenen lokalen Änderungen.
Die CLI erstellt neue lokale Bestände. Sie verändert keine bestehende Installation,
Freigabe, OAuth-Kopplung, Keychain, Watch-Konfiguration oder externe Originaldatei.

## Ausdrücklicher Ablauf

Diese Beispiele beschreiben spätere lokale Wartungsaktionen; in der Entwicklung wurden nur
eigens angelegte synthetische Verzeichnisse verwendet. Alle Pfade müssen absolut sein.

```sh
vauldy-local worker-stop --store /lokal/bisheriger-bestand
vauldy-local storage-preview --store /lokal/bisheriger-bestand --format sqlite
vauldy-local storage-migrate --store /lokal/bisheriger-bestand --format sqlite --to /lokal/neue-uebertragung --expected FINGERPRINT_AUS_DER_VORSCHAU
```

Der Worker muss tatsächlich beendet sein; offene Importe sind vorher abzuschließen oder
bewusst abzubrechen. Auch ein noch laufender, gerade untätiger Worker sperrt die Migration.
Die Vorschau zählt Dokumente, Originalkopien und Originalverweise, nennt den konservativ
benötigten Speicher und einen an Quelle und Zielformat gebundenen Fingerabdruck. Sie öffnet
vorhandene Sperrdateien ohne Neuanlage und schreibt keine Bestandsdateien.

`--to` muss neu sein, sein Elternverzeichnis muss existieren. Unter dem Ziel entstehen:

- `backup/`: unabhängig geprüfter Bestand im bisherigen Format, mit Originalkopien und
  einer Prüfsummenliste. Ein vorhandener JSON-Backupsnapshot bleibt ebenfalls bytegleich erhalten.
- `vault/`: der vollständig verglichene neue Bestand; bei SQLite unter `sqlite/records.sqlite`.
- `receipt.json`: lokale Bestätigung mit Zielpfaden, Dokumentzahl und `profilesChanged: false`.

Vor der Veröffentlichung liegen diese Dateien in einem privaten `.vauldy-transfer-*`-Ordner.
`INCOMPLETE` sperrt seine Bestände für den aktuellen Worker, die Einrichtung und MCP. Erst nach
Backupprüfung, Konvertierung, vollständigem Vergleich und Synchronisierung wird das Verzeichnis
mit einer atomaren, vorhandene Ziele niemals überschreibenden Umbenennung veröffentlicht.
Die Sperrmarke wird zuletzt entfernt und diese Änderung synchronisiert.

### Bestand ausdrücklich verwenden

In der Einrichtung kann unter „Vauldy-Bestand auswählen“ nun auch `records.sqlite` ausgewählt
werden. Die Ansicht liest den Bestand; eine neue Verbindung benötigt weiterhin die bewusste
Dokumentauswahl und Freigabe. Bestehende Verbindungen bleiben am bisherigen Bestand und ihre
alten Handles bleiben gültig, solange dessen Dokumente und Freigabe unverändert bleiben.
Es findet **kein automatisches Umhängen bestehender Verbindungen** statt.

Der eigene Importpfad der bestehenden Installation wird ebenfalls nicht automatisch verschoben.
Neue Importe in das konvertierte Archiv erfolgen ausdrücklich mit
`vauldy-local import --store /lokal/neue-uebertragung/vault /lokal/neues-dokument.pdf`.
Ein komfortabler Installations-/Profil-Umschaltassistent ist nicht Bestandteil dieses CLI-Inkrements.
Der technische Dateiauswahldialog unterstützt SQLite; eine neue visuelle UI-Abnahme wurde nicht ausgeführt.

## Zwei getrennte Rückwege

**Den gesicherten früheren Zustand wiederherstellen:**

```sh
vauldy-local storage-preview --store /lokal/neue-uebertragung/backup --format same
vauldy-local storage-restore --store /lokal/neue-uebertragung/backup --to /lokal/wiederhergestellt --expected FINGERPRINT_AUS_DER_VORSCHAU
```

Restore prüft die Backup-Prüfsummen erneut, schreibt an ein neues Ziel und überschreibt weder
das Backup noch den bisherigen oder konvertierten Bestand. Es stellt den gesicherten Zeitpunkt
wieder her. Spätere Änderungen gehören nicht zu diesem Backup.

**Den aktuellen SQLite-Bestand einschließlich späterer Änderungen nach JSON zurückführen:**

```sh
vauldy-local worker-stop --store /lokal/neue-uebertragung/vault
vauldy-local storage-preview --store /lokal/neue-uebertragung/vault --format json
vauldy-local storage-migrate --store /lokal/neue-uebertragung/vault --format json --to /lokal/json-rueckweg --expected FINGERPRINT_AUS_DER_VORSCHAU
```

Der Rückweg sichert zuerst den aktuellen SQLite-Zustand mit der SQLite-Backup-API und exportiert
anschließend nach JSON. Der JSON-Stand erhält Formatmarker 2, damit Originalverweise erhalten
bleiben und inkompatible Format-1-Writer ihn ablehnen. SQLite behält Formatmarker 3 und Schema 2;
ein früherer JSON-only Writer darf dort nicht schreiben. Der Rückweg ist kein Software-Rollback
und ändert keine installierten Programme oder Clientkonfigurationen.

## Prüfungen und Grenzen

- Alle IDs und kompletten typisierten Datensätze werden verglichen: OCR-Text, Analyse,
  Status, Seiten, Metadaten und Originalreferenzen einschließlich Bookmarkbytes.
- Unbekannte Felder im JSON oder SQLite-Payload werden vor der Übertragung zurückgewiesen,
  wenn der aktuelle Decoder/Encoder sie verlieren würde. Die Quelle bleibt erhalten.
- Verwaltete Originalkopien müssen vollständig lesbar sein und zu ihrem Inhaltshash passen;
  auch erhaltene historische Kopien werden gesichert. Unbekannte Dateien, Symlinks, Hardlinks,
  fremde Besitzer und offene Dateirechte werden abgewiesen.
- Externe Originalverweise bleiben unverändert. Die Migration kopiert weder deren Dateien
  noch erneuert sie Bookmarks; sie ist keine neue Verfügbarkeits- oder OCR-Qualitätsabnahme.
- Ein lebender Worker, belegte OCR-/Writer-Sperren sowie wartende/laufende Dokumente oder
  Queuejobs verhindern die Übertragung. Vorschau und Ausführung sind separat, die Ausführung
  prüft den Fingerabdruck nochmals unter den Sperren. Keine Wartung über MCP oder HTTP.
- SQLite-Backups verwenden die Online-Backup-API; ein WAL wird nicht als bloße Hauptdatei kopiert.
  Das Backup wird auf ein eigenständig lesbares Rollbackjournalformat gebracht und erneut geöffnet.
- Die Kopie ist ein Dokumentenbackup, kein Backup von Anmeldung, Freigaben, Jobqueue oder
  Watch-Konfiguration. Diese verbleiben unverändert am bisherigen Ort. Es starten keine Watcher.
- Grenze: 20.000 Datensätze; JSON maximal 128 MiB; SQLite-Ziel konservativ maximal 256 MiB
  kodierte Dokumentdaten und 8 MiB je Datensatz. Ein größerer SQLite-Stand kann nicht ungeprüft
  in das kleinere JSON-Format zurückgeführt werden. R3d muss große Freigaben und Speicherbedarf messen.
- Freier Platz wird am tatsächlichen Zielvolume geprüft. Der konservative Bedarf enthält Backup,
  Ziel, Journal-/Indexreserve und 64 MiB Sicherheitsreserve. Ein Fehler lässt die Quelle erhalten.

Nach einem Fehler oder Prozessabbruch werden private Staging-Dateien absichtlich nicht rekursiv
gelöscht. Es wird kein halbfertiger Bestand aktiviert. Die Quelle bleibt nutzbar; nach Prüfung der
Ursache kann eine neue Übertragung gestartet werden. Falls ein endgültiger Zielordner noch
`INCOMPLETE` enthält, bleibt auch er gesperrt. Die Marke nicht manuell entfernen, um eine Prüfung
zu umgehen. Fehlgeschlagene eigene Staging-Ordner erst nach gesonderter Kontrolle entfernen.
Ein getesteter SIGKILL ist kein Nachweis eines physischen Stromausfalls oder einer Hardwarestörung.

## Dateien

- `Sources/VauldyCore/LocalStorageMigration.swift`: Vorschau, Sperren, Kapazität, geprüfte
  Sicherung/Konvertierung/Restore, Datengleichheit und Veröffentlichung.
- `Sources/VauldyCore/SQLiteDocumentStorePilot.swift`: Prüfung unbekannter Payloadfelder und
  eigenständig lesbare SQLite-Backups auch aus WAL.
- `Sources/VauldyCore/LocalDocumentStore.swift`, `LocalVaultSnapshotSource.swift`: vorhandene
  Sperren ohne Dateineuanlage öffnen; unvollständige Übertragungen abweisen.
- `Sources/VauldyLocalCLI/main.swift`: drei explizite Wartungskommandos.
- `Sources/VauldyMCPSetup/SetupModel.swift`: lesende Auswahl von JSON oder SQLite.
- `Tests/VauldyMCPRuntimeTests/StorageMigrationTests.swift`: Roundtrip, Originale/Bookmarks,
  Änderungen nach Migration, Platzmangel, Sperren, Stale-Preview, Beschädigung, unbekannte
  Felder, WAL und unvollständige Verzeichnisse.
- `scripts/mcp/storage_migration_smoke_test.py`: tatsächlicher nativer Import, CLI-Migration,
  MCP-Lesen, Restore/Rückweg und SIGKILL vor Veröffentlichung.
- `scripts/mcp/storage_legacy_writer_smoke_test.py`: tatsächlicher Importversuch eines älteren
  JSON-only Writers gegen einen synthetischen Format-3-Bestand.
- `scripts/mcp/regression_test.py`, To-do-Liste und dieser Bericht: Integration und Nachweis.

## Tatsächlich ausgeführte Prüfung

Die Quell-/Testkopie in `/private/tmp/vauldy-deadlines.kTXJpJXZ/source` wurde bytegleich mit
dem Checkout geprüft. Der native Swift-Lauf baut auch CLI, MCP und Einrichtung.

```sh
swift build -c release --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 --product vauldy-local
swift test -c release --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter 'StorageMigrationTests|SQLiteIntegrationTests|SQLiteDocumentStorePilotTests|LocalOriginalReferenceTests|LocalWorkerTests|InventoryWorkflowTests|MCPScalabilityTests|MCPPrivacyBoundaryTests|LocalImportTests'
python3 scripts/mcp/storage_migration_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-local /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --output /private/tmp/vauldy-r3c-wire.json
python3 scripts/mcp/storage_legacy_writer_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-local dist/mcp/contracts-2026-11-05-373egj4t/Vauldy-MCP-macOS.zip --output /private/tmp/vauldy-r3c-legacy.json
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --check
```

- **83 Testfunktionen tatsächlich ausgeführt und bestanden**, ein optionaler großer
  Storage-Benchmark ausgelassen. Swift meldet einschließlich dieses übersprungenen Tests
  `84 tests in 9 suites passed after 13.172 seconds`.
- Der reale Wire-Test importierte ein synthetisches zweitseitiges PDF über den nativen Worker.
  Die anschließende Migration dauerte **273,634 ms**; diese Einzelmessung ist keine Lastabnahme.
  Suche und Privacy über SQLite, Backup-Restore, Rückweg und anschließende JSON-MCP-Suche bestanden.
- Bei der Abbruchprüfung lagen zusätzlich rund 128 MiB eigens generierte historische
  Originalkopien im Testbestand. Der eigene Migrationsprozess wurde nach dem Anlegen von
  `INCOMPLETE`, vor Veröffentlichung, tatsächlich per SIGKILL beendet. Kein endgültiges Ziel
  entstand; ein Zugriff auf den Zwischenstand wurde abgewiesen. Quelle und Freigabe blieben
  bytegleich, ihr bestehender MCP-Handle blieb nutzbar.
- Das vorhandene ältere Paket meldet ebenfalls `vauldy-local 0.13.0`, sein ZIP-Hash ist
  `874a2573bd212a5bba16c07637cefa969263bacd3733482897d4a0773fc073eb`.
  Dessen tatsächlicher Importversuch gegen einen neuen SQLite-Bestand endete mit Exitcode 1,
  ohne JSON-Fallback, Workerstart oder Änderung von Bestand und Original.
- MCP-v1-Vertrag mit beiden Antwortkanälen, JSON-Kompatibilität, Privacy, Widerruf und lokale
  Relay-Werkzeug-Parität bestanden. Kein Relay wurde bereitgestellt oder verändert.

Ein Vorlauf fand einen echten WAL-Backupfehler: Eine SHM-Datei blieb im neuen Backup nach der
Umstellung auf das Rollbackjournal zurück. Die Korrektur schließt alle Zielverbindungen und
prüft den Header sowie die Abwesenheit von WAL/Journal, bevor sie ausschließlich diesen Rest
im exklusiv neu erzeugten Backup entfernt. Der finale WAL-/Restoretest und die betroffenen
Regressionen bestanden. Der fehlgeschlagene Vorlauf wird nicht als bestanden gezählt.

[Maschinenlesbarer Nachweis und Testausgaben](quality/storage-r3c-2026-11-06.json).
Kein Commit/Push/PR, kein neues Installerpaket, keine Kundenmigration, kein vollständiger
Release-Regressionslauf, keine Notarisierung und keine neue visuelle oder Zielchat-Abnahme.

**GO für kontrollierte additive Übertragungen mit geprüften neuen Zielen.** Kein allgemeiner
SQLite-Standard und keine 20.000-Dokumente-Leistungszusage vor R3d. Die bestehenden
Installations-/Freigabepfade bleiben unverändert, bis der Anwender bewusst anders auswählt.
