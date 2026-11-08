# R4 · Buildkennung, Fähigkeiten und Verbindungsdiagnose

Stand 06.11.2026 im Branch `codex/local-first-product-readiness`.
Keine produktive Installation, kein Relay-Rollout und keine Änderungen an Kundenarchiven,
Freigaben, OAuth-Geräten oder Keychain. Die bereits vorhandenen Änderungen im Branch bleiben erhalten.

## Umsetzung

- LC_UUID des geladenen Mach-O-Hauptprogramms als Buildkennung; dünne 64-Bit-Dateien und
  passende Architektur universeller Dateien werden unterstützt. Ein alter Prozess behält
  seine Kennung nach einem Austausch der Datei. Kein Ableiten aus der Produktversion,
  kein Git-Zugriff zur Laufzeit, keine Behauptung eines Quellcommits oder Signaturnachweises.
- Produktversion weiterhin `0.13.0`. MCP-Initialisierung mit Standard-Buildmetadaten
  `0.13.0+macho.<Kennung>`. CLI `--version` und bestehende Dokument-DTOs bleiben unverändert.
  `--build-info` benötigt weder Profil noch Dokumentzugriff; der MCP meldet seine tatsächlichen
  Werkzeugnamen und `json-snapshot` als aktuell produktiven Speicher.
- Lokaler Probe liest alle Discovery-Seiten, begrenzt auf 16 Seiten/128 eindeutige Namen
  und 256 kB Protokollausgabe. Fehlende Werkzeuge, Cursorzyklen, Duplikate, Startabbruch,
  Timeout, falsches Protokoll und nicht prüfbarer Bestand sind unterscheidbar.
- Ein als kompatibel gemeldeter Probe verlangt passende Produktversion, acht Werkzeuge und
  eine Buildkennung, die zum ausgeführten Programm passt. Alte Server bleiben diagnostizierbar.
  Ein Prozess ohne Buildangabe wird nicht als eindeutig aktueller Build bestätigt.
- Einrichtung zeigt App-, mitgelieferten und installierten Server-Build, geprüfte Werkzeuge,
  laufende Altprozesse und konkrete nächste Schritte. Der Diagnosedialog ist scrollbar.
  Probe-Ergebnisse werden bei Freigabe-/Buildwechsel verworfen; ein verspätetes Ergebnis
  einer anderen Freigabefassung wird nicht als aktueller Erfolg übernommen.
- Pausierter Dokumentzugriff, lokaler Protokolltest und externe Chatverbindung bleiben
  getrennte Aussagen. Ein lokaler Werkzeugaufruf beweist keine sichtbare Chatantwort.
  Diagnostische Prozesse werden nicht als echte Clientaktivität gezählt.
- Neue Paketmanifeste enthalten Server-Build, Speicherart und tatsächliche Werkzeugliste.
  Packager prüft auch die Kompatibilitätsepoche. Vor und nach Aktivierung vergleicht der
  Updater die Startantwort mit Version/Build/Werkzeugen des geprüften Pakets.
  Bestehende Manifeste ohne neue Felder bleiben für kompatible Rückwege lesbar; Signatur-,
  Epochengrenzen und bestehende Prüfungen werden nicht durch die UUID ersetzt.

## SQLite: nächster Umsetzungsschritt

**Direkt nach R4 folgt R3b, vor R5 und weiteren Fachwerkzeugen.** Der bisherige Record-Store
ist ein getesteter Pilot und noch kein produktiver Speicher für MCP und Import.

1. **R3b – Anbindung:** gemeinsamer Storageadapter, transaktionale Worker-Schreibvorgänge,
   gezielte Reads, Quellgeneration für Freigabe/Handles/Cursor und Suchindex; zuerst neue,
   ausdrücklich angelegte isolierte Bestände. Lokales stdio bleibt ohne Cloud lauffähig.
2. **R3c – Migration/Rückweg:** Vorschau, Platzprüfung, geprüftes Backup und Restore an neuem
   Ziel; sämtliche IDs, Texte und Originalverweise vergleichen. Keine Freigabeerweiterung
   und kein automatisches Umschreiben bestehender Benutzerbestände.
3. **R3d – Abnahme:** 1k/2k/5k/10k/20k lange synthetische Dokumente mit großen Auswahlen,
   gleichzeitigen Importen und Suche, P95/RSS, Crash-Recovery und Widerruf.

Das ist die verbindliche Arbeitsreihenfolge, keine erfundene Termin- oder Leistungszusage.
Die bisherige JSON-Produktivnutzung und ihre Grenzen bleiben bis zur bewussten Umschaltung bestehen.

## Prüfnachweise

**Bestanden:** 23 native Swift-Tests in vier Suites (5,562 s); echter Sechs-/Acht-Werkzeug-
Vergleich gleicher Produktversion, gleichzeitig laufende Alt-/Neuprozesse, pausierter Zugriff
und Widerruf; Paket-Update/Rollback mit falschen Build-/Werkzeugangaben, fehlgeschlagenem Start,
SIGKILL und konkurrierendem Update; lokale Verwaltung, v1-MCP-Vertrag, lokaler HTTP-/OAuth-
Durchlauf mit 53 Dokumenten sowie lokale Relay-Werkzeug-Parität. Keine Tests übersprungen.
Die native UI wurde gebaut, aber nicht visuell im geöffneten Fenster abgenommen.


Maschinenlesbare Ergebnisse, Hashes und tatsächliche Kommandos:
[quality/build-diagnosis-r4-2026-11-06.json](quality/build-diagnosis-r4-2026-11-06.json).

Native Tests verwenden die bytegeprüfte isolierte Buildkopie
`/private/tmp/vauldy-deadlines.kTXJpJXZ/source` mit festgeschriebenen vorhandenen Abhängigkeiten.
Der Legacy-Vergleich verwendet das tatsächlich vorhandene Paket
`dist/mcp/contracts-2026-11-05-373egj4t/Vauldy-MCP-macOS.zip`; nur dessen Server wird in einen
neuen temporären Testordner extrahiert. Keine bestehende Installation wird geöffnet oder geändert.

```sh
swift test -c release --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --jobs 4 -debug-info-format none --no-parallel --filter 'MCPBuildDiagnosisTests|MCPManagementTests|MCPProcessPresenceTests|MCPInstallationTests'

python3 scripts/mcp/build_diagnosis_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-local --legacy-zip dist/mcp/contracts-2026-11-05-373egj4t/Vauldy-MCP-macOS.zip --output /private/tmp/vauldy-r4-wire.json
```

Die Namen-/Pagination-/Fehlerfälle verwenden synthetische Protokollprogramme. Ein Programm
kann eine UUID behaupten; erst der echte native Wiretest bestätigt deren Übereinstimmung mit
der gestarteten Datei. Der Test der Prozessregistrierung beobachtet gleichzeitig den echten
alten und neuen Server und prüft Widerruf für beide.

Das Paket unter `/private/tmp/vauldy-r4-package` ist ausschließlich Ad-hoc-signiert und nicht
notarisiert. Es dient der isolierten Paket-, Update- und Rollbackprüfung. Kein neues
Kundenrelease und keine reguläre ChatGPT-/Safari-/UI-Abnahme werden daraus abgeleitet.

## R4-Dateiänderungen

| Dateien | R4-Anteil |
| --- | --- |
| `MCPBuildIdentity.swift` (neu), `MCPBuild.swift` | Geladene/filebasierte Build-ID, Metadaten und erforderliche Fähigkeiten. |
| `ServerFactory.swift`, `VauldyMCPServer/main.swift`, `VauldyLocalCLI/main.swift` | Tatsächliche Toolnamen, Initialisierungs-Build und `--build-info`. |
| `MCPLocalProbe.swift` | Paginierte Discovery, Fähigkeiten, verifizierte Buildkennung, getrennte Fehler/Handlungshinweise. |
| `MCPProcessPresence.swift`, `MCPConnectionState.swift`, `MCPManagement.swift` | Laufender/gelieferter/installierter Build und Altprozessvergleich. |
| `SetupModel+Management.swift`, `SetupDetailViews.swift`, `SetupWizardView.swift` | Sichtbare Diagnose und Verwerfen überholter Ergebnisse. |
| `MCPSoftwareUpdate.swift`, `scripts/mcp/package.py` | Manifest, Startgates und lesbare Paketinkompatibilität. |
| `MCPBuildDiagnosisTests.swift` (neu), `build_diagnosis_smoke_test.py` (neu) | Native Diagnoseprüfungen und echter Sechs-/Acht-Werkzeug-Vergleich. |
| `software_update_smoke_test.py`, `management_smoke_test.py`, `customer_release_smoke_test.py`, `oauth_smoke_test.py` | Manifest-Abwehrtests und Produktversion getrennt von Buildmetadaten. |
| `local-first-todo.md`, `mcp-mvp.md`, dieser Bericht und JSON-Nachweis | Fortschritt, Grenzen und SQLite-Reihenfolge. |

GO für den getesteten lokalen R4-Stand. Kundeninstallation mit Developer ID/Notarisierung,
Zielchat-Abnahme und produktive SQLite-Umschaltung bleiben eigene offene Gates.


## Paket- und Wirekommandos

Der Packager läuft aus der isolierten Kopie; die übrigen Skripte aus dem Checkout.
`--skip-build` bezieht sich ausschließlich auf die soeben gebauten und bytegeprüften Quellen.

```sh
python3 /private/tmp/vauldy-deadlines.kTXJpJXZ/source/scripts/mcp/package.py --skip-build --output /private/tmp/vauldy-r4-package
python3 scripts/mcp/software_update_smoke_test.py '/private/tmp/vauldy-r4-package/Vauldy MCP Einrichtung.app'
python3 scripts/mcp/management_smoke_test.py '/private/tmp/vauldy-r4-package/Vauldy MCP Einrichtung.app/Contents/Resources'
python3 scripts/mcp/build_diagnosis_smoke_test.py '/private/tmp/vauldy-r4-package/Vauldy MCP Einrichtung.app/Contents/Resources/vauldy-mcp' '/private/tmp/vauldy-r4-package/Vauldy MCP Einrichtung.app/Contents/Resources/vauldy-local' --legacy-zip dist/mcp/contracts-2026-11-05-373egj4t/Vauldy-MCP-macOS.zip --output /private/tmp/vauldy-r4-wire.json
python3 scripts/mcp/smoke_test.py '/private/tmp/vauldy-r4-package/Vauldy MCP Einrichtung.app/Contents/Resources/vauldy-mcp'
python3 scripts/mcp/oauth_smoke_test.py '/private/tmp/vauldy-r4-package/Vauldy MCP Einrichtung.app/Contents/Resources/vauldy-local' '/private/tmp/vauldy-r4-package/Vauldy MCP Einrichtung.app/Contents/Resources/vauldy-mcp-http'
python3 scripts/mcp/export_relay_tools.py '/private/tmp/vauldy-r4-package/Vauldy MCP Einrichtung.app/Contents/Resources/vauldy-mcp' --check
```

Der Verwaltungsprobe startet seinen normalen Host für die Metadatenprüfung bewusst außerhalb
von `bin`, damit kein unabhängiges Statusmenü den temporären Testordner nach Testende erneut
anlegt. Diagnoseprozesse, Buildkennungen, Inhaltefreiheit, Profil-/Vault-Erhaltung und echte
Clientmetadaten werden weiterhin geprüft. Die frühere Bereinigungsrace wurde nicht als Pass
gewertet. Die komplette Release-/Kundenabnahme wurde nicht ausgeführt.
