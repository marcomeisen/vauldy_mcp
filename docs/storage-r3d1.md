# R3d.1 · SQLite-Projektionen für Status und Listen

In einem neuen SQLite-Bestand speichert der Writer eine kleine Projektion pro Datensatz.
Sie enthält Suchbarkeit, OCR-Abdeckung, Analysezustand und Dokumentfingerprint. SQLite
veröffentlicht Projektion, Datensatz und Generation gemeinsam. Die Tabelle enthält
keinen OCR-Text, keine Originalpfade und keine Privacy-Zuordnungen.

`get_vault_status` und ungefiltertes `list_documents` mit `includeExcerpts: false`
lesen nur Projektionen der freigegebenen IDs. Sie behalten fehlende Datensätze in der
Abdeckungsstatistik und verwenden dieselbe Reihenfolge und denselben Antwortvertrag.
Ein Handle aus der kompakten Liste lädt beim Lesen nur den zugehörigen SQLite-Datensatz.
Der Runtime- und der Transportpfad prüfen Profil und Quellenstand erneut vor der Ausgabe.
Textfilter, Auszüge, gerankte Suche und Übersichten verwenden weiterhin die bestehenden
Volltextpfade. Die Suchbeschleunigung ist Gegenstand von R3d.2.

SQLite-Schema 2 bleibt lesbar. Fehlt die Projektion eines tatsächlich freigegebenen
Datensatzes, verwendet MCP den bisherigen geprüften Lesepfad. Datenbanktrigger entfernen
die alte Projektion auch bei einer Änderung durch einen älteren SQL-Writer. Bereits
bestehende SQLite-Bestände lassen sich mit dem folgenden ausdrücklichen CLI-Aufruf ergänzen.
Der Aufbau läuft unter der Writer-Sperre und prüft die Datensatzprüfsummen. Ein Abbruch
rollt den Aufbau zurück. Ein Commit bei einem nicht leeren Bestand erneuert die Generation.

```sh
vauldy-local storage-rebuild-projections --store /absoluter/pfad/zum/sqlite-bestand
```

Die Lastmatrix verwendet 1.000, 2.000, 5.000, 10.000 und 20.000 synthetische Dokumente
mit rund 32 KiB Text auf acht Seiten. Je Größe werden 100 Freigaben und eine Vollfreigabe
geprüft. Der Prüfer baut die Projektionen mit dem echten CLI auf, importiert je Größe
zwei native Testdokumente und prüft den Rest als synthetische SQLite-Datensätze.
Er misst den ersten Status in einem neuen MCP-Prozess sowie jeweils 25 Status- und
Listenaufrufe. Der Dateisystemcache wird nicht geleert. RSS ist der Peak des MCP-Servers
einschließlich Pagination und anschließendem Lesen eines Handles. Das sind lokale
stdio-Werte. Der SQL-Abbruch und der OCR-Worker-Wiederanlauf laufen separat bei 100
Freigaben. [Ausgangsmessung und Abgrenzung](storage-r3d.md).

Alle zehn Varianten bestehen die R3d.1-Grenzwerte für ersten Status (≤ 5 s), warme
Status- und Listen-P95 (≤ 1 s) und Server-RSS (≤ 512 MiB).

| Dokumente | Erster Status bei Vollfreigabe | Status-P95 | Listen-P95 | Peak-RSS | Alle Seiten | Listen-P95 bei 100 Freigaben |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1.000 | 41 ms | 50 ms | 102 ms | 31,6 MiB | 0,84 s | 86 ms |
| 2.000 | 73 ms | 55 ms | 115 ms | 33,4 MiB | 1,63 s | 77 ms |
| 5.000 | 103 ms | 73 ms | 102 ms | 37,1 MiB | 4,35 s | 90 ms |
| 10.000 | 165 ms | 84 ms | 113 ms | 44,6 MiB | 11,19 s | 75 ms |
| 20.000 | 318 ms | 101 ms | 155 ms | 61,4 MiB | 45,70 s | 76 ms |

Bei 20.000 Vollfreigaben dauerte der erste Status in R3d 9,21 s. Die alte Liste lag
bei 11,82 s P95 aus 17 von 25 Aufrufen. R3d.1 schließt alle 25 ab. Der alte Spitzen-RSS
von 1.197 MiB umfasste auch den bis zum Timeout laufenden Textfilter, während die neue
Messung auf Status, Listen und einen Dokumentlesevorgang begrenzt ist. Alle 20.000
Handles wurden über 200 Aufrufe ohne Duplikate paginiert. Dieser Gesamtabruf dauerte
45,70 s gegenüber 33,66 s in R3d. Die kürzere Latenz gilt für den Status und den Start
einer neuen Liste. Die Laufzeit für alle Folgeseiten ist ein eigener Messwert.

Der explizite Aufbau für den 20.000er-Testbestand dauerte 8,08 s. Die Datenbank nach
Aufbau und letztem Import belegt 725,72 MiB. Bei allen Größen blieben die reinen
Abrufe bytegleich zur Quelle. Geprüft wurden außerdem SQL-Rollback nach Prozessabbruch,
automatischer OCR-Worker-Neustart, anschließendes Lesen eines kompakten Handles,
Ablehnung veralteter Handles und Cursor sowie Widerruf nach Neustart. Der native
Worker- und SQL-Abbruchtest verwendet eine Auswahl von 100 Dokumenten.

Der Auswertung zufolge ist der Status- und Listenpfad für die synthetische Vollfreigabe
bis 20.000 abgenommen. Die SQLite-Gesamtlastfreigabe bleibt offen. R3d.2 behandelt
Textfilter, gerankte Suche und Übersichten. R3d.3 prüft danach die Pfade gemeinsam.

Der Build lief in einer temporären, mit dem Checkout verglichenen Quellkopie.
Die Lastmatrix lief separat vor den Swift-Regressionstests.

```sh
cd /private/tmp/vauldy-r3d1.XUlyQpRs
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --product vauldy-mcp
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --product vauldy-local
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'SQLiteIntegrationTests|SQLiteDocumentStorePilotTests|StorageMigrationTests|MCPScalabilityTests|MCPPrivacyBoundaryTests|MCPRetrievalCompletenessTests'
cd "/Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp"
python3 scripts/mcp/sqlite_load_acceptance.py /private/tmp/vauldy-r3d1.XUlyQpRs/.build/release/vauldy-local /private/tmp/vauldy-r3d1.XUlyQpRs/.build/release/vauldy-mcp --projection-gates --output /private/tmp/vauldy-r3d1.XUlyQpRs/matrix.json
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-r3d1.XUlyQpRs/.build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py /private/tmp/vauldy-r3d1.XUlyQpRs/.build/release/vauldy-mcp --check
git diff --check
```

Frisch geprüft wurden 52 Swift-Testfunktionen in sechs Suites. Der optionale
`largeSyntheticStorageComparison` war übersprungen. Die separate R3d.1-Lastmatrix,
der echte stdio-Werkzeugtest und die Discovery-Parität zum Relay waren erfolgreich.
Der neue Swift-Test vergleicht die Statusantwort mit dem Volltextpfad, prüft ältere
Schema-2-Bestände, liest ein Listen-Handle und prüft veraltete Handles und Cursor
sowie den Widerruf. [Rohmesswerte und Binärprüfsummen](quality/storage-r3d1-2026-11-06.json).
