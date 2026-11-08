# R3d.2 · Inkrementeller SQLite-Suchindex

Neue SQLite-Bestände speichern neben den kleinen Statusprojektionen einen lokalen,
versionierten Suchindex. Ein Datensatz und seine Suchmerkmale werden zusammen geändert.
SQLite-Trigger entfernen beim Schreiben und Löschen die bisherigen Suchmerkmale.
Das gilt auch für ältere Writer. Eine freigegebene Zeile ohne Indexabdeckung bleibt
durch den geprüften bisherigen Suchpfad auffindbar.

- **Ganze Wörter:** Der Index speichert dieselben normalisierten Tokens und Aliasformen
  wie der bisherige Textfilter. Mehrere Suchwörter werden über die Schnittmenge geprüft.
- **Teilwörter und Themen:** Der Index speichert deduplizierte Textstücke der gefalteten
  Originalschreibweise und der normalisierten Form. Suchwörter werden mit derselben
  Swift-Teilwortprüfung auf diesen Stücken gesucht. Kompakte Listen liefern alle
  Kandidaten per Cursor. Eine Themenübersicht lädt für ihre Belege nur die Dokumente
  der angeforderten Seite.
- **Gerankte Suche:** Der Index liefert eine Obermenge der Kandidaten aus Suchwörtern
  und einem Anker der Suchphrase. Vauldy bewertet diese mit der bisherigen
  Rangformel am Dokumenttext. Die Ausgabe hält nur die besten Treffer und zählt
  alle bewerteten Treffer. Wörtliche Fundstellen kommen aus der gespeicherten Quelle.
- **Fristenübersicht:** Die vom Client ausgewählten Handles werden gezielt geladen.
  Dieser Abruf braucht keinen Textfilter.

Die Suchmerkmale liegen im privaten SQLite-Bestand. Sie können normalisierte
Dokumentwörter enthalten und gehören zum selben lokalen Schutzbereich wie der OCR-Text.
Ergebnisse werden mit den freigegebenen IDs geschnitten. Das Profil und die
Quellgeneration werden vor der Ausgabe erneut geprüft. Auszüge bleiben an den
Privacy-Pfad und die Originalseite gebunden.

Der Index überspringt sehr große OCR-Texte, übergroße Vokabulare und Bestände nahe
der SQLite-Größengrenze. Bei solchen Zeilen bleibt die Volltextprüfung aktiv.
Eine Suche mit häufigen Begriffen kann viele Kandidaten bewerten. Die Laufzeit hängt
deshalb auch nach R3d.2 vom Suchwort und von der Größe der Treffergruppe ab.

Bereits bestehende SQLite-Bestände können mit dem vorhandenen expliziten CLI-Aufruf
beide abgeleiteten Strukturen in einer Transaktion aufbauen. Der Befehl verwendet
die Writer-Sperre und prüft die Datensatzprüfsummen.

```sh
vauldy-local storage-rebuild-projections --store /absoluter/pfad/zum/sqlite-bestand
```

Die Lastmatrix lief mit dem aktuellen Release-Build auf derselben synthetischen
32-KiB-Dokumentverteilung wie R3d. Alle zehn Varianten bestanden die jeweiligen
Latenz-, Speicher- und Vollständigkeitsgrenzen. Filter und Markersuche sind
Einzelmessungen. Status und kompakte Liste verwenden jeweils 25 warme Aufrufe.

| Vollfreigabe | Versicherung | Teilwort versicher | Nichttreffer | Gerankter Marker | Indexaufbau | Peak-RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1.000 | 101 ms | 82 ms | 37 ms | 397 ms | 10,84 s | 32,5 MiB |
| 2.000 | 120 ms | 80 ms | 35 ms | 399 ms | 21,51 s | 34,9 MiB |
| 5.000 | 170 ms | 109 ms | 53 ms | 418 ms | 53,94 s | 41,7 MiB |
| 10.000 | 248 ms | 128 ms | 86 ms | 488 ms | 108,46 s | 50,0 MiB |
| 20.000 | 417 ms | 181 ms | 124 ms | 558 ms | 214,49 s | 79,9 MiB |

Bei 20.000 Vollfreigaben bestätigte der Versicherungsfilter die Sollzahl 5.000.
Die Themenübersicht lieferte 25 Zeilen der ersten Seite in 7,94 s.
Sie erzeugt dabei Quellenbelege und wendet Privacy an. Das ist eine eigene Messung
gegenüber der kompakten Kandidatenliste. ChatGPT- und Relay-Laufzeit sind offen.

Vollständige Pagination, Widerruf, OCR-Worker-Wiederanlauf und bytegleicher Bestand
nach den Leseprüfungen sind für alle Größen bestätigt. Die ursprüngliche Matrix
meldete insgesamt `go: false`, weil der zusätzliche Journaltest mit einer
Assertion abbrach. Die zehn Abfragevarianten waren vollständig bestanden.

Der getrennte Wiederholungstest verwendete 2.000 Dokumente. Der native CLI-Prozess
wurde beim Indexaufbau nach beobachtetem, gefülltem Rollback-Journal mit SIGKILL
beendet. Die letzte Generation und die Indexzählungen blieben erhalten.
Nach dem neuen CLI-Aufbau war das Journal entfernt. Der MCP las bei 100
Freigaben wieder die erwarteten 25 Treffer. Der Wiederanlauf ist damit für
diesen kleineren synthetischen Bestand bestätigt.

59 Swift-Testfunktionen in 7 Suites und vier Wire-/Discovery-Prüfungen bestanden.
Übersprungen wurde `largeSyntheticStorageComparison()`.
Die Regressionen prüfen die Parität zu den bisherigen Treffern und Quellseiten,
Unicode und OCR-Worttrennungen, fehlende Indexabdeckung, inkrementelle Updates
und unveränderte Sichtbarkeitsregeln.

Geänderte Komponenten sind der SQLite-Store, die Suchnormalisierung und Rangfolge
in VauldyCore, die MCP-Abrufpfade, die SQLite-Integrationstests und der Lastprüfer.

Die Builds und Swift-Tests liefen in der geprüften temporären Quellkopie.
Der abschließende Regressionstest enthält eine zusätzliche Einschränkung des
neuen Themen-Cursorpfads auf SQLite. Die Lastmessung nutzt SQLite und misst
nur die erste Themenseite. Die gemessenen Binärdateien sind separat gehasht.
Der zweite Abbruchtest nutzt diese Binärdateien und den korrigierten Prüfer.

```sh
cd /private/tmp/vauldy-r3d2.rFwXXTwt
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --product vauldy-mcp
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --product vauldy-local
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'SQLiteIntegrationTests|SQLiteDocumentStorePilotTests|StorageMigrationTests|SearchTextNormalizationTests|MCPScalabilityTests|MCPPrivacyBoundaryTests|MCPRetrievalCompletenessTests'
cd "/Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp"
python3 scripts/mcp/sqlite_load_acceptance.py /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-local /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-mcp --search-gates --output /private/tmp/vauldy-r3d2.rFwXXTwt/matrix.json
python3 scripts/mcp/sqlite_load_acceptance.py /private/tmp/vauldy-r3d2.rFwXXTwt/bench-bins/vauldy-local /private/tmp/vauldy-r3d2.rFwXXTwt/bench-bins/vauldy-mcp --search-gates --counts 2000 --samples 5 --recovery-at 2000 --output /private/tmp/vauldy-r3d2.rFwXXTwt/recovery.json
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-mcp
python3 scripts/mcp/topic_overview_smoke_test.py /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-mcp
python3 scripts/mcp/deadline_overview_smoke_test.py /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-mcp --check
git diff --check
```

R3d.3 bleibt die gemeinsame Lastabnahme mit parallelem Import bei Vollfreigabe
und wiederholten Suchmessungen.
[Rohmesswerte und Binärprüfsummen](quality/storage-r3d2-2026-11-06.json).
