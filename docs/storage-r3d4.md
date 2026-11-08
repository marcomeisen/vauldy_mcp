# R3d.4 · Breite Rangsuche mit SQLite-Projektionen

Die bisherige Rangsuche liest und bewertet für einen häufigen Begriff jeden Kandidaten.
Bei 20.000 Vollfreigaben überschritt sie in R3d.3 das Anfragebudget. Die neue Rangprojektion
speichert für jedes durchsuchte Feld die bisherigen Gewichte, auf fünf begrenzte
Tokenhäufigkeiten und die normalisierten Textstücke für den Phrasenbonus. SQLite liest
die Projektionen einzeln. Im Speicher bleiben die Bewertungen und IDs. Vauldy lädt
danach nur die besten Dokumente für die wörtlichen Quellenbelege und deren Privacy-Prüfung.

Der schnelle Pfad gilt, wenn die normalisierte Suchphrase genau einem der bisherigen
Suchwörter entspricht. Die Bewertungsformel, Trefferzahl, Sortierung nach Importdatum
bei Gleichstand und Quellenbelege bleiben dabei kompatibel. Mehrwortphrasen verwenden
die vollständige Textbewertung. Fehlende oder zu große Projektionen werden aus den
vollständigen Datensätzen bewertet und mit den projizierten Ergebnissen zusammen sortiert.
Das Limit einer einzelnen gespeicherten Projektion beträgt 16 KiB.

Die abgeleiteten Suchmerkmale liegen im geschützten lokalen SQLite-Bestand. Der Writer
speichert sie transaktional. Ein Record-Update oder eine Löschung invalidiert die
Projektion über SQLite-Trigger. Alte SQLite-Bestände können den bestehenden expliziten
Befehl zum Aufbau der Such- und Rangprojektionen verwenden. Die Freigabe wird vor der
Antwort zusammen mit der aktuellen Transaktionsgeneration überprüft.

```sh
vauldy-local storage-rebuild-projections --store /absoluter/pfad/zum/sqlite-bestand
```

Die kombinierte Lastprüfung verwendet das Verfahren aus R3d.3. Für die breite
Rangsuche während OCR sind diesmal mindestens zwei erfolgreiche überlappende Aufrufe
erforderlich. Der erneute Indexabbruch prüft zusätzlich die Zahl der Rangprojektionen
und die breite Rangsuche vor und nach dem Neuaufbau.

Die gerankten Messaufrufe geben wie in R3d.3 höchstens einen Treffer aus
(`limit: 1`). Die Rangsuche berechnet dabei weiterhin die vollständige Trefferzahl.

Der 20.000er-Testbestand belegte nach dem Aufbau 871,7 MiB. In R3d.3 waren es
782,3 MiB. Der Umfang der Rangprojektionen hängt vom Vokabular ab. Nahe der
vorhandenen SQLite-Grenze für den Indexaufbau oder bei übergroßen Projektionen
können einzelne Datensätze wieder auf die vollständige Bewertung fallen. Das
betrifft die Übertragbarkeit der Messwerte auf Bestände mit anderem Vokabular.

**Erneute gemeinsame Lastprüfung GO für die gemessenen synthetischen Abfragen.**

| Vollfreigabe | Breite Rangsuche P95 | Während OCR P95 | Erfolgreiche Überlappungen |
| ---: | ---: | ---: | ---: |
| 1.000 | 415 ms | 132 ms | 45 |
| 2.000 | 426 ms | 126 ms | 38 |
| 5.000 | 501 ms | 199 ms | 22 |
| 10.000 | 624 ms | 762 ms | 11 |
| 20.000 | 879 ms | 1135 ms | 5 |

Nach SIGKILL wurden alle 20,000 Rangprojektionen
aus der letzten Generation wiedergefunden. Die Integritätsprüfung war erfolgreich.
Kompakter Filter, seltener Marker und breite Rangsuche lieferten nach Rollback
und erneutem Aufbau die Solltreffer. Das Rollback-Journal wurde bereinigt.

60 Swift-Testfunktionen in 7 Suites bestanden. Der optionale
`largeSyntheticStorageComparison` war übersprungen. Der echte stdio-Test und
die Discovery-Parität zum Relay bestanden. Die Messmatrix lief mit frischen
Release-Binaries aus der bytegeprüften temporären Quellkopie.

Die Aussage gilt für diese lokalen synthetischen Einwortabfragen und die
geprüften OCR- und Wiederanlaufszenarien. Mehrwortphrasen behalten die bisherige
Bewertung. Der Test liefert keine ChatGPT-Zeiten oder Lastwerte für reale Archive.

```sh
cd /private/tmp/vauldy-r3d4.SvRRweNM
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --product vauldy-mcp
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --product vauldy-local
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'SQLiteIntegrationTests|SQLiteDocumentStorePilotTests|StorageMigrationTests|SearchTextNormalizationTests|MCPScalabilityTests|MCPPrivacyBoundaryTests|MCPRetrievalCompletenessTests'
cd "/Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp"
python3 scripts/mcp/sqlite_combined_acceptance.py /private/tmp/vauldy-r3d4.SvRRweNM/.build/release/vauldy-local /private/tmp/vauldy-r3d4.SvRRweNM/.build/release/vauldy-mcp --counts 20000,1000,2000,5000,10000 --broad-ocr-min 2 --output /private/tmp/vauldy-r3d4.SvRRweNM/matrix.json
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-r3d4.SvRRweNM/.build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py /private/tmp/vauldy-r3d4.SvRRweNM/.build/release/vauldy-mcp --check
git diff --check
```

[Rohmesswerte und Hashes](quality/storage-r3d4-2026-11-06.json).
