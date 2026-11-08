# R3 · Speichergrenzen, selektiver Lesepfad und SQLite-Pilot

Stand: 06.11.2026, Branch `codex/local-first-product-readiness`. Diese Iteration betrifft
nur `vauldy_mcp`. Keine Installation, keine Migration eines Benutzerbestands, kein Relay-Rollout.

## Was sich im normalen Betrieb ändert

- Die Grenze von 20.000 gilt weiterhin für neue lokale Importe und die ausdrücklich
  freigegebene Auswahl. Ein bereits vorhandener JSON-Bestand mit 20.001 Datensätzen
  blockiert eine zulässige Einzelfreigabe nicht mehr.
- Teilfreigaben werden dokumentweise aus 64-KiB-Blöcken gelesen. Alle Datensätze einschließlich
  nicht freigegebener Datensätze werden auf gültiges Format und eindeutige IDs geprüft.
  Im MCP bleiben nur freigegebene Dokumente erhalten. Defekte oder doppelte Einträge
  werden nicht übersprungen und niemals als vollständige leere Trefferliste ausgegeben.
- Das Cachebudget bezieht sich auf die kodierten Quellbytes der freigegebenen Auswahl. 64 MiB im Standard
  und 96 MiB beim bestehenden experimentellen Modus bleiben erhalten. Das ist ein Budget
  für kodierte Nutzdaten, keine harte Grenze für den gesamten Prozessspeicher. Dateidentität,
  Nanosekunden-mtime/ctime, Profil und Auswahl bleiben Teil der Gültigkeitsprüfung.
- Wenn eine bereits geprüfte Dateigeneration vollständig freigegeben ist, nutzt ein weiterer
  Abruf außerhalb des Cachebudgets den schnellen bisherigen Gesamtlader. Das gilt nur bei
  identischer Datei **und** Auswahl. Ein Import oder Profilwechsel erzwingt die neue Prüfung.
  Der Verwaltungs-/Writer-Lesepfad behält ebenfalls den begrenzten Gesamtlader.
- Die 128-MiB-Lese-/Schreibgrenze bleibt erhalten. Übergroße Dateien werden vor dem Laden
  abgewiesen; MCP liefert den vorhandenen Größenfehler statt „Bestand nicht lesbar“.
- Der Import prüft Anzahl und kodierte Snapshotgröße vor dem Kopieren eines neuen Originals
  oder der Änderung des Store-Markers. Die Einrichtung meldet die konkrete Grenze und hält
  den restlichen Batch an. Später anfallender OCR-Text kann weiterhin die Bytegrenze erreichen;
  der Commit wird dann verweigert. Dies ist keine Vorhersage der späteren OCR-Größe.
- Kapazitätsfehler sind keine Diagnose „Original beschädigt“. Im bestehenden gespeicherten
  Jobfehler bleibt der kompatible Code `storageUnavailable`; ein optionales Zusatzfeld
  transportiert die konkrete Kapazitätsmeldung an neue Worker-Clients. Alte Reader ignorieren
  das Zusatzfeld. Snapshot, Sicherung, IDs und Freigaben werden bei Kapazitätsablehnung erhalten.

Der produktive JSON-Writer schreibt und sichert weiterhin den Gesamtsnapshot. Der neue
Lesepfad beseitigt nicht diese Schreibkosten. Eine große vollständig freigegebene Auswahl
kann weiterhin das Cachebudget überschreiten und erneutes Laden erfordern.

## Getrennter SQLite-Speicherpilot

`SQLiteDocumentStorePilot` ist eine package-interne, ausdrücklich aufzurufende Implementierung
hinter `DocumentRecordStorage`. Es gibt keinen automatischen Start, keinen neuen MCP-Endpunkt
und keinen Schalter, der bestehende Kundenbestände ungefragt umstellt.

- Eigener, ausschließlich neu angelegter privater Ordner, Datenbank 0600, Schema-/Application-ID.
- Bestehendes JSON wird lesend, dokumentweise und in einer Transaktion in einen leeren Pilot
  übernommen. Fehler oder doppelte IDs rollen den gesamten Import zurück.
- Einzelzugriff per Dokument-ID, transaktionale Einzelupdates mit Vergleich gegen die erwartete
  vorherige Dokumentfassung. Stale Updates können aktuelle Änderungen nicht überschreiben.
- SQLite `synchronous=FULL`, Rollbackjournal, gebundene Parameter und Integritätsdigest pro
  Datensatz. Der Digest prüft Beschädigung, er ist keine Authentifizierung gegen denselben Benutzer.
- SQLite-Backup-API für einen konsistenten Stand. Restore ausschließlich in ein **neues**
  Verzeichnis; kein Überschreiben einer aktiven Datenbank. Export als kompatibles JSON nur
  unterhalb der bestehenden 128-MiB-Grenze und nur an einen noch nicht bestehenden Dateinamen.
- Pilotgrenzen: 1 GiB Datenbank bei 4096-Byte-Seiten, 8 MiB pro kodiertem Datensatz.
  Der Besitzer serialisiert den Zugriff auf eine Instanz; keine Behauptung eines fertigen
  produktiven Mehrprozess-Storage-Dienstes.

Der Pilot speichert OCR-Rohtext lokal. Er wird **nicht** mit dem bestehenden optionalen FTS5-Index
verwechselt: Dieser bleibt abgeleitete Suchstruktur. Originaldateien, Profile, OAuth-Zugänge
und Keychain gehören nicht in die neue Datenbank.

## Prüfumfang und Ergebnisse

Die Zahlen und Binary-Hashes stehen in [quality/storage-r3-2026-11-06.json](quality/storage-r3-2026-11-06.json).
Der Vorher-Build ist die vor R3 erhaltene lokale Release-Binärdatei; beide Varianten werden
im selben aktuellen Lauf gegen denselben synthetischen Snapshot ausgeführt. Keine alten
Messwerte werden als neu ausgegeben.

Der Grenzbenchmark verwendet 20.000/20.001 kurze Datensätze sowie 500 lange Datensätze bei
64/96/128 MiB ± 1 KiB. Die langen Datensätze umfassen etwa 134–268 kB kodierten Text pro Dokument.
Es ist jeweils **ein** Dokument freigegeben. Pro erfolgreicher Variante werden 25 wiederholte
Status- und 25 Listenabfragen mit Suchtext gemessen. P95 ist das Nearest-Rank-Quantil.
`/usr/bin/time -l` erfasst den nativen maximalen RSS des jeweiligen MCP-Prozesses. Erster Werkzeugaufruf nach MCP-Initialisierung,
Neustart, Widerruf und Quellbytes werden separat geprüft. Das ist weder eine Zielchat-Messung
noch eine Zusage für vollständig freigegebene große Archive.

Die Swift-Regression prüft zusätzlich Chunkgrenzen, Escapes, Unicode, ungültige JSON-Enden,
doppelte nicht freigegebene IDs, Cachebudget und Auswahlwechsel, gleich große Fremdänderungen,
Privacy, vollständiges Retrieval und bestehende native Importe. Der 128-MiB-Importtest prüft
Snapshot/Backup bytegleich und das Ausbleiben einer Originalkopie. SQLite-Tests prüfen
Alt-JSON-Roundtrip, Compare-and-swap, Restart, Backup/Restore, fehlerhaften Import sowie
Rollback nach einem tatsächlichen SIGKILL eines schreibenden Hilfsprozesses.

Der separate Importtest verwendet einen temporären Bestand mit 500 langen synthetischen
OCR-Datensätzen und importiert über die echte CLI/den echten Worker ein zusätzliches
synthetisches Bild. Gleichzeitig laufen MCP-Listenabfragen. Quellenrotation darf eine
Anfrage ausdrücklich scheitern lassen; erfolgreiche Antworten müssen exakt die eine
Freigabe zeigen. Nach Import und Neustart bleiben es eine Freigabe und 501 Datensätze.


### Finaler Messlauf

79 Swift-Tests in neun Suites bestanden (16,485 s); der dort übersprungene große Storage-
Benchmark wurde getrennt ausgeführt und bestand ebenfalls (2,637 s). Zusammen sind es
80 tatsächlich ausgeführte Tests. Release-Binaries für MCP, CLI und Einrichtung wurden
gebaut. Der vorhandene MCP-v1-Wiretest und die sieben Suchtextvarianten einschließlich
Negativfällen, wörtlichen Belegen und Widerruf in drei Indexmodi sind ebenfalls bestanden.
Ein GUI-Durchlauf oder Installationspaket wurde nicht erstellt.

Die folgenden Werte stammen aus demselben finalen Vorher-/Nachher-Lauf, jeweils eine Freigabe:

| Bestand | Status P95 vorher → nachher | Suchliste P95 vorher → nachher | Peak-RSS vorher → nachher | Erster Status vorher → nachher |
| --- | --- | --- | --- | --- |
| 63.999 MiB | 21.0 → 44.4 ms | 82.1 → 53.7 ms | 154.3 → 19.8 MiB | 125.0 → 209.3 ms |
| 64.001 MiB | 115.8 → 38.3 ms | 149.7 → 65.5 ms | 215.8 → 20.3 MiB | 137.8 → 214.8 ms |
| 95.999 MiB | 162.2 → 49.1 ms | 206.0 → 72.3 ms | 290.5 → 21.8 MiB | 187.0 → 295.2 ms |
| 96.001 MiB | 160.0 → 53.3 ms | 199.9 → 71.2 ms | 294.9 → 21.5 MiB | 174.8 → 296.3 ms |
| 127.999 MiB | 222.1 → 53.1 ms | 259.6 → 70.1 ms | 375.8 → 24.9 MiB | 235.7 → 386.0 ms |

20.001 Datensätze: vorher Fehler, jetzt genau eine freigegebene Zeile. 128 MiB + 1 KiB:
weiterhin ausdrücklich abgewiesen, jetzt mit Größenfehler und ohne Vollallokation.

Bei **vollständiger Freigabe** aller 500 Datensätze oberhalb des Cachebudgets verbessert
sich die Abfrage nicht grundsätzlich: bei 70 MiB P95 329,8 → 329,9 ms, bei 98 MiB im
96-MiB-Cachemodus 469,9 → 445,3 ms. Erster Status 338 → 445 beziehungsweise 455 → 600 ms.
Die große Erstprüfung bleibt langsamer; dafür benötigt die typische kleine Teilfreigabe
deutlich weniger Speicher. Auch unterhalb von 64 MiB ist kein allgemeiner Laufzeitgewinn
belegt. Die Tabelle weist diese Einschränkungen ausdrücklich aus.

Der echte Worker-Import neben der Suche dauerte **2.74 s**. Bei 28 parallelen
Abfragen waren 26 erfolgreich; 2 wurden während Quellenrotation ausdrücklich abgewiesen.
P95 einschließlich dieser Fehler: 280.5 ms. Danach 501 statt 500 Datensätze, weiterhin eine
Freigabe, bestehende OCR-Texte und Originalbytes unverändert; Restart und Widerruf bestanden.

Der isolierte SQLite-Schreibvergleich nutzte 500 Dokumente mit 108.9 MiB JSON:
25 Einzelupdates Median **3.02 ms**, P95 7.17 ms;
25 Einzelzugriffe Median 0.71 ms. Drei vollständige JSON-Lese-/Neuschreibläufe
benötigten im Median **431.0 ms** (ohne Backuprotation).
Dieser Mikrovergleich beweist keinen fertig angebundenen Datenbankbetrieb.

## Ausgeführte Kommandos

Arbeitsverzeichnis für Python: `/Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp`.
Die native Buildkopie unter `/private/tmp/vauldy-deadlines.kTXJpJXZ/source` verwendet die
gepinnten vorhandenen Abhängigkeiten. `Sources`, `Tests` und Package-Dateien werden byteweise
mit dem Checkout abgeglichen. Logs liegen ausschließlich unter `/private/tmp/vauldy-r3-*`.

```sh
swift test -c release --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter 'StorageBoundaryTests|SQLiteDocumentStorePilotTests|MCPScalabilityTests|LocalImportTests|LocalOriginalReferenceTests|LocalWorkerTests|SearchTextNormalizationTests|MCPPrivacyBoundaryTests|MCPRetrievalCompletenessTests'

python3 scripts/mcp/storage_boundary_benchmark.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --before /private/tmp/vauldy-r3-before-mcp --output /private/tmp/vauldy-r3-boundaries-final.json

python3 scripts/mcp/storage_boundary_benchmark.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --before /private/tmp/vauldy-r3-before-mcp --full-selection-only --output /private/tmp/vauldy-r3-full-selection.json

VAULDY_R3_STORAGE_REPORT=/private/tmp/vauldy-r3-sqlite.json swift test -c release --skip-build --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter SQLiteDocumentStorePilotTests/largeSyntheticStorageComparison

python3 scripts/mcp/storage_import_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-local /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --output /private/tmp/vauldy-r3-import.json
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
python3 scripts/mcp/search_normalization_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
```

Der große SQL-Schreibvergleich ist in der normalen Suite ausdrücklich deaktiviert und
wird mit der oben angegebenen Reportvariable separat aktiviert. Die reguläre vollständige
Regression führt die beiden neuen Python-Prüfungen künftig ebenfalls aus. Ein neuer
Installer oder eine vollständige Release-/Zielchat-Abnahme gehört nicht zu diesem Nachweis.

## Geänderte Dateien und Codebelege

| Datei | Änderung in R3 |
| --- | --- |
| `Sources/VauldyCore/FileVaultSnapshotSource.swift` | Begrenzter Gesamtlader, dokumentweiser Auswahl-Leser, vollständige Format-/ID-Prüfung. |
| `Sources/VauldyCore/VaultStorageLimits.swift` | Gemeinsame JSON-Import-/Bytegrenzen und verständliche Kapazitätsfehler. |
| `Sources/VauldyCore/LocalDocumentStore.swift` | Preflight vor Originalkopie; Kapazität getrennt von beschädigtem Bestand. |
| `Sources/VauldyCore/LocalImportService.swift`, `LocalImportWorker.swift` | Kapazität durch Service/Job zum Client; bestehende Fehlercodes lesbar halten. |
| `Sources/VauldyCore/SQLiteDocumentStorePilot.swift` | Storagevertrag, transaktionaler Pilot, Compare-and-swap, JSON-Import/Export, Backup/Restore. |
| `Sources/VauldyMCPRuntime/MCPFileVersion.swift` | Cachebudget und Vollfreigabe-Optimierung an Dateigeneration/ID-Auswahl binden. |
| `Sources/VauldyMCPRuntime/ReadOnlyMCPRuntime.swift` | Auswahl an Leser übergeben; globale 20.000er-Abweisung entfernen; Größenfehler erhalten. |
| `Sources/VauldyMCPSetup/SetupModel.swift` | Kapazität verständlich anzeigen und gesättigten Importbatch beenden. |
| `Tests/VauldyMCPRuntimeTests/StorageBoundaryTests.swift`, `SQLiteDocumentStorePilotTests.swift`, `LocalWorkerTests.swift` | Neue Grenz-, Authority-, Storage-/Rollback- und Worker-Kompatibilitätsprüfungen. |
| `scripts/mcp/storage_boundary_benchmark.py`, `storage_import_smoke_test.py`, `regression_test.py` | Reproduzierbare Grenz-/Lastmessungen und Einbindung in die Gesamtregression. |
| `docs/storage-r3.md`, `docs/quality/storage-r3-2026-11-06.json`, `docs/local-first-todo.md`, `docs/mcp-mvp.md` | Messergebnisse, Grenzen, Dateiliste und nächste Aufgaben. |

Die Arbeitskopie enthielt bereits zahlreiche Änderungen aus den vorherigen Iterationen.
Diese Liste beschreibt nur den R3-Anteil; vorhandene Arbeiten wurden nicht zurückgesetzt.
Kein Commit, Push oder PR wurde erzeugt.

## Entscheidung und nächste Schritte

**GO für den getesteten R3-Code und den isolierten Storage-Piloten. Kein GO für eine
produktive SQLite-Umstellung oder 20.000 reale Dokumente.**

1. R4: Build-/Fähigkeitskennung und konkrete Verbindungsdiagnose gemäß To-do-Liste.
2. Vor produktiver SQLite-Anbindung: Profil-/Quellgeneration auch bei Datenbanktransaktionen
   binden, Worker und Verwaltung hinter denselben Storagevertrag bringen, Search-/FTS-
   Aktualisierung und Widerruf während konkurrierender Transaktionen prüfen. Abnahme:
   Neustart, verlorene Writer, gleichzeitiger Import/Suche, keine stale Handles, keine neue Freigabe.
3. Explizite Migration mit Vorschau, freiem Speicher, geprüftem Backup und Restore an neuem
   Ziel. Bestehendes JSON bleibt bis zur geprüften Umschaltung unverändert. Abnahme: alle IDs,
   Texte und Originalreferenzen vergleichbar, Downgrade verweigert inkompatiblen Writer.
4. Danach 1k/2k/5k/10k/20k mit längen-/seitenverteilten Dokumenten und großen Freigabeauswahlen
   im angebundenen Datenbankpfad messen. Erst daraus P95-/RAM-/Kapazitätszusagen ableiten.
   Kundeninstallation, Signierung/Notarisierung, Offline-Test-Mac und regulärer Chat bleiben
   gesonderte offene Abnahmen.
