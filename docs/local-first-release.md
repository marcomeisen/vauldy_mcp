# Lokaler Release und Kundenabnahme

## Release erzeugen

Für jedes Artefakt eine neue Ausgabeablage verwenden. Aus dem eigenständigen Repository bauen, die Toolchain festhalten und `Package.resolved` einchecken. `MCPBuild.swift` ist die Produktversionsquelle. Der Paketbuild prüft die Versionen und Architektur aller Programme, bevor er das Paket schreibt. Beide App-Bundles erhalten dieselbe Produktversion. Das signierte Bundle enthält `Contents/Resources/release.json` mit Layout, Toolchain, Architektur, Mindest-OS und Lockfile-Hash. Ein verifizierter sauberer Neubau kann den Quellcommit ausweisen. Ein Build mit `--skip-build` hat keine Commit-Zuordnung.

```sh
python3 scripts/mcp/package.py --output ./dist/mcp/internal
```

Das Ad-hoc-Artefakt dient isolierten internen Tests. Für einen Kundenkandidaten benötigt die Release-verantwortliche Person einen sauberen Git-Checkout, die pinned Abhängigkeiten, ein gültiges **Developer ID Application**-Zertifikat mit privatem Schlüssel und ein bereits eingerichtetes `notarytool`-Profil für das richtige Apple-Team. Das ZIP enthält ein App-Bundle. Ein Developer ID Installer-Zertifikat wäre für ein späteres signiertes PKG erforderlich.

```sh
python3 scripts/mcp/package.py --output ./dist/mcp/customer-candidate \
  --identity 'Developer ID Application: TEAM-NAME (TEAM-ID)' \
  --notary-profile 'VORHANDENES-PROFIL'
```

Der Build verwendet für Developer ID eine frische Build-Ablage. Der signierte Pfad nutzt Hardened Runtime und Zeitstempel. Bei angegebenem Notary-Profil reicht das Skript das ZIP bei Apple ein, stapelt und validiert das Ticket, prüft Gatekeeper und packt erneut. Vergleiche `SHA256SUMS` über einen vertrauenswürdigen Bezugskanal. Layout und Eingaben sind nachvollziehbar. Zeitstempel und Notarisierung verhindern einen Anspruch auf byteidentische ZIPs.

Abnahme auf einem frischen Mac jeder unterstützten Architektur mit geplanter Mindestversion. Lade das ZIP über den vorgesehenen Vertriebskanal, prüfe Hash, Team-ID, Signatur, Ticket und Gatekeeper. Installiere mit Testbenutzer und synthetischer Freigabe. Deaktiviere danach Netzwerk und Relay. Belege lokalen Import/OCR, vollständige stdio-Inventarliste, Quellenlesung und Widerruf. Teste den Zielclient separat. [Apple-Vorgaben für macOS-Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Update und Rückweg

Update aus einer vertrauenswürdigen Setup-App öffnen oder per CLI auslösen. Die CLI darf aus der bereits installierten Generation oder aus einem vertrauenswürdigen Paket kommen. Für interne Ad-hoc-Artefakte ist in der CLI zusätzlich `--allow-ad-hoc` erforderlich. Ein Developer-ID-Updater akzeptiert weiterhin ausschließlich Developer ID Application desselben Apple-Teams. Die lokale Prüfung verwendet die von Apple definierte Anforderung für Developer ID Application. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

```sh
"/pfad/zu/vauldy-local" update-software --root "/pfad/zum/Installationsroot" \
  --from-app "/pfad/zu/Vauldy MCP Einrichtung.app"
"/pfad/zu/vauldy-local" rollback-software --root "/pfad/zum/Installationsroot"
```

Der Updater kopiert das vollständige Bundle in eine private Ablage und prüft dort verschachtelte Signaturen, Herausgeber, Produktversion und Kompatibilitäts-Epoche. Vor und nach dem Wechsel startet er den lokalen Server mit einem leeren synthetischen Profil und prüft Protokoll, Version, vier Tools und Status. Ein fehlgeschlagener Start nach dem Wechsel tauscht das vorherige Verzeichnis zurück. Die Verzeichnisse liegen auf demselben Volume. Der atomare Austausch hält `bin/vauldy-mcp` und die übrigen Clientpfade stabil. Ein Wiederholungsaufruf desselben gültigen Pakets behält den Rückweg. Die aktuelle Setup-App des verwalteten Satzes liegt innerhalb von `bin/`. Verwende nach dem Wechsel diesen Pfad oder das neu gestartete Statusmenü. Der bisherige Setup-Pfad gehört zu älteren Installationen. Nach erfolgreichem Wechsel bereits laufende MCP-Verbindungen neu starten.

Der Rückweg verwendet genau eine vorherige geprüfte Generation mit gleicher Epoche. Er prüft Signatur, Komponenten-Integrität und stdio-Start erneut. Ein Altbestand ohne Generationsnachweis bleibt bis zum ersten erfolgreichen Austausch als Wiederherstellungsstand für einen fehlgeschlagenen Start verfügbar. Die manuelle Rückkehr beginnt nach zwei erfolgreichen verwalteten Installationen. Direkte Downgrades werden abgewiesen. Bei unbekannten Einträgen im Softwareordner bricht die Aktivierung ab. Der bekannte optionale Tunnel-Helfer wird bytegleich mitgeführt. Hat er sich zwischen den Generationen geändert, wird die Rückkehr gesperrt.

Die Epoche in `MCPBuild.swift` und im signierten Release-Manifest umfasst Profil-, Store-, Audit- und Anmeldedatenformate sowie Worker- und Relay-IPC. Sie muss sich ändern, sobald die Abwärtskompatibilität eines solchen Vertrags entfällt. Ein Epochenwechsel erfordert eine gesonderte Upgrade- und Migrationsentscheidung. Der Updater hat keinen Zugriffspfad zu Nutzerprofilen, Archiven, Originalen, OAuth-Geräten, Schlüsselbund oder Client-Konfiguration. Der optionale Relay-Agent wird beim Test weder gestartet noch mit Zugangsdaten versorgt.

Die lokale Regression prüft Wiederholung, beschädigte Signatur, fremde Epoche, direkten Downgrade, Startfehler nach Aktivierung, SIGKILL vor und nach Aktivierung, parallele Aufrufe und echte Rückkehr samt stdio-Lesung. Eine absichtliche Prozessunterbrechung ersetzt keine Stromausfallprobe. Die Developer-ID-Kette und der Kunden-Mac bleiben separate Release-Gates.

### Lokaler Nachweis

Die Wire-Regression verwendet zwei getrennt Ad-hoc-signierte Generationen mit derselben Produktversion, verschiedenen Signaturen und verschiedenen Serverbytes. Sie bestätigt auch, dass eine manipulierte Vorversion und ein zwischenzeitlich geänderter Tunnel-Helfer den Rückweg blockieren. Profil, Snapshot, synthetisches Original, Audit, Geräte-Datei und Host-Konfiguration werden byteweise verglichen.

```sh
testdir=$(mktemp -d /tmp/vauldy-update-final.XXXXXX)
export CLANG_MODULE_CACHE_PATH="$testdir" SWIFTPM_MODULECACHE_OVERRIDE="$testdir"
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
python3 scripts/mcp/package.py --skip-build --output dist/mcp/safe-update
app='dist/mcp/safe-update/Vauldy MCP Einrichtung.app'
resources="$app/Contents/Resources"
python3 scripts/mcp/software_update_smoke_test.py "$app"
python3 scripts/mcp/management_smoke_test.py "$resources"
python3 scripts/mcp/smoke_test.py "$resources/vauldy-mcp"
python3 scripts/mcp/export_relay_tools.py "$resources/vauldy-mcp" --check
swift test --disable-sandbox --disable-automatic-resolution --jobs 4 \
  --filter 'MCPManagementTests|MCPInstallationTests|MCPScalabilityTests|MCPPassageTests'
```


## Abnahme von zwei Kundenpaketen

Auf dem autorisierten Build-Mac werden zwei saubere Stände des MCP-Branches mit aufsteigender Produktversion und gleicher Software-Epoche gebaut. Der ältere Stand muss den verwalteten Updater bereits enthalten. Für beide Builds dieselbe gültige Developer-ID-Application-Identität und das bereits eingerichtete Notarisierungsprofil nutzen. Identität und Profilname aus der lokalen Release-Umgebung beziehen. Die eigentlichen Apple-Zugangsdaten bleiben dort.

```sh
# Aus dem Checkout von Version A und separat aus dem Checkout von Version B.
python3 scripts/mcp/package.py --output "$release_output" \
  --identity "$VAULDY_DEVELOPER_ID" --notary-profile "$VAULDY_NOTARY_PROFILE"
```

Verwende je Version eine neue Ausgabeablage. Halte Git-Commit, Apple-Notarisierungsergebnis und finale SHA-256 getrennt fest. Prüfe Apples Notarisierungslog und validiere das Ticket an der aus dem finalen ZIP entpackten App auf dem Build-Mac. Übertrage die beiden finalen ZIPs, ihre unabhängig bestätigten Prüfsummen und die beiden Python-Testdateien `customer_release_smoke_test.py` und `smoke_test.py` auf einen sauberen Test-Mac oder eine frisch zurückgesetzte macOS-VM mit unterstützter Architektur und vorbereitetem Python 3. Trenne dort WLAN, Ethernet und gegebenenfalls den virtuellen Netzwerkadapter, bevor eine der Apps entpackt oder gestartet wird. [Apple-Verfahren für die Offline-Distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

```sh
python3 scripts/mcp/customer_release_smoke_test.py "$zip_a" "$zip_b" \
  --sha-a "$sha_a" --sha-b "$sha_b" --team-id "$apple_team_id" --fresh-test-mac
```

`--fresh-test-mac` bestätigt die frische Umgebung durch den Betreiber. Der Test verweigert die Kundenabnahme bei unklarem oder aktivem Netzwerkstatus und prüft den Status mehrmals. Er verifiziert die ZIP-Integrität, vollständige Signatur, Team-ID und die macOS-Distributionsprüfung beider entpackter Apps. A wird mit seiner CLI installiert. Die installierte CLI aktiviert B und stellt anschließend A wieder her. Jede Generation beantwortet über den stabilen stdio-Pfad Discovery, Status, ein vollständiges Inventar über zwei Seiten und beide Quellenlesungen. Jede Softwareoperation muss die synthetischen Original-, Archiv-, Profil-, Audit-, Geräte- und Clientdateien bytegleich erhalten. Die abschließende JSON-Zeile ist der maschinenlesbare Nachweis. Den tatsächlichen ersten GUI-Start aus dem vorgesehenen Vertriebskanal auf dem Test-Mac separat beobachten.

`--local-ad-hoc` führt denselben Versionswechsel mit intern signierten Test-ZIPs aus und kennzeichnet das Ergebnis als lokale Probe. Dieser Modus ersetzt weder Apples Vertrauensprüfung noch die Abnahme auf einem frischen Offline-Mac.

### Prüflauf vom 4. November 2026

Auf dem Entwicklungs-Mac (arm64, macOS 27.2) wurden 0.13.0 und ein isolierter 0.13.1-Testbuild separat kompiliert und Ad-hoc-signiert. Die lokale Probe 0.13.0 → 0.13.1 → 0.13.0 bestand mit realer stdio-Discovery, vollständiger Pagination, Quellenlesung und unveränderten Fixtures. Falsche Prüfsumme, gleiche Versionen, fehlender verifizierbarer Offline-Status und eine Ad-hoc-Signatur im Developer-ID-Prüfschritt wurden abgewiesen. Der Testbuild 0.13.1 ist eine Fixture. Die Versionsquelle des Branches bleibt bei 0.13.0.

Kundenstatus **offen**. Die Sitzung sah keine gültige Developer-ID-Application-Identität, kein benanntes Notarisierungsprofil und keinen erreichbaren frischen Test-Mac. Die Kundenprüfung wurde am Offline-Gate beendet.

## Lokale Architektur im MCP-Branch

[Entwicklungsaufgaben und Iterationsstand](local-first-todo.md)

`VauldyDocumentCore` ist das erste eigenständige Swift-Modul für den Seitenmarkierungsvertrag. `VauldyCore` exportiert denselben Typ weiterhin über den bisherigen Namen. Die App kann dieses Modul später über einen gepinnten Stand beziehen. Aktuell wird nur der MCP-Branch umgebaut.

### Wiederaufbaubarer SQLite-Index

Aktiviere den persistenten Index nur für eine lokale Verbindung mit eigenem privaten Profilordner:

```sh
vauldy-mcp --profile /absoluter/pfad/profile.json --persistent-sqlite-index
```

Der Cache liegt neben dem Profil in einem privaten, versionsgebundenen Verzeichnis. Die Datei `index-v1.sqlite` ist auf 64 MiB begrenzt. Sie enthält gehashte Suchwörter, interne Dokumentkennungen, Prüffingerabdrücke und kompakte Statusfelder. Gehashte Suchwörter sind weiterhin sensible Ableitungen. Die Datei enthält keine Originale, vollständigen OCR-Texte, Pfade oder reversiblen Pseudonym-Zuordnungen. JSON und dessen Backup bleiben führend.

Das Öffnen bindet den Cache an den vollständigen Fingerabdruck der Freigabe und vergleicht ihn mit dem aktuellen autorisierten JSON-Bestand. Geänderte, neue und entfernte Zeilen werden zusammen mit der Generation transaktional gespeichert. Bei beschädigten Inhalten baut Vauldy den Cache in einer separaten Datei auf und tauscht diese atomar ein. Ein unvollständiger Aufbau und eine vorübergehende Cache-Sperre blockieren die Suche nicht. SQLite-Fehler führen zur bisherigen Filterung. Gespeicherte Profiländerungen stoßen die Bereinigung des Cache an. Bei belegter Sperre ist diese Bereinigung im Pilotbetrieb bestmöglich. Ein konkurrierender Schreiber prüft das Profil erneut. Der Nachweis für verwaiste Dateien nach gleichzeitigem Entfernen oder Prozessabbruch steht aus. Bei direkter Bearbeitung einer Profildatei greift die neue Freigabe beim nächsten Aufruf, und der Cache wird bei der nächsten Nutzung neu gebunden. [SQLite FTS5](https://www.sqlite.org/fts5.html)

Bei kompakten Folgeseiten verwendet der Prozess Statusfelder der zuvor geprüften Generation. Er prüft Profil und Dateistand vor der Ausgabe erneut. Ändert sich der autorisierte Bestand, läuft der Cursor über den bisherigen Prüfpfad und wird bei abweichender Generation abgewiesen. Für Treffer werden weiterhin der bestehende Textfilter und die Privacy-Grenze angewendet. Rangsuche und Teilwortmodus verwenden ihre bisherigen Suchverträge.

Die Entwicklungsoptionen `--large-snapshot-cache`, `--compact-list-projection` und `--memory-sqlite-index` erlauben Einzelvergleiche. Der frühere Schalter `--experimental-sqlite-index` kombiniert größeren Cache und Speicherindex wie bisher. `--persistent-sqlite-index` kombiniert den Dateiindex mit der kompakten Projektion. Er erhöht das JSON-Cache-Limit erst zusammen mit `--large-snapshot-cache`. Alle Optionen gelten für den lokalen stdio-Aufruf. Entferne die Zusatzoptionen, wenn du eine ältere Version ohne diese Schalter startest.

```sh
python3 scripts/mcp/scalability_benchmark.py .build/release/vauldy-mcp \
  dist/mcp/persistent-index-variants.json --documents 1000 2000 5000 10000 20000 --compare-index-variants
```

### Variantenmessung

Ein Release-Lauf mit `vauldy-mcp 0.13.0` verglich dieselben synthetischen Bestände mit 1.000, 2.000, 5.000, 10.000 und 20.000 Einträgen. Das Archiv und die Ausgangsprofildatei waren bytegleich. Die Varianten nutzten getrennte Prozesse und Profilkopien.

| Variante bei 20.000 Dokumenten | Erste Inventarseite | Median erste 10 Folgeseiten | P95 Folgeseiten | Median exakte Suche warm | Peak-RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| JSON-Basis | 1,35 s | 690 ms | 751 ms | 2,42 s | 325 MiB |
| Größerer JSON-Cache | 1,32 s | 495 ms | 537 ms | 2,18 s | 309 MiB |
| Kompakte Projektion | 1,37 s | 133 ms | 151 ms | 2,05 s | 301 MiB |
| FTS5 im Speicher | 1,33 s | 703 ms | 729 ms | 0,82 s | 352 MiB |
| Datei-FTS5 und Projektion | 3,73 s | 136 ms | 157 ms | 0,63 s | 421 MiB |

Die vier Einzelvarianten messen bei 20.000 Einträgen je zehn Folgeseiten. Der Dateimodus misst alle 199 Folgeseiten und liefert in 30,62 s insgesamt 20.000 unterschiedliche Dokumente. In allen Varianten ergeben sich 400 Treffer für die Testanfrage und ein überprüfter Beleg auf Seite 1. Die Indexdatei misst 20,91 MiB und wurde nach Neustart bytegleich wiederverwendet. Die erste exakte Suche nach Neustart dauerte 1,38 s.

Die kompakte Projektion erzielte den größten Gewinn bei der Pagination. Der Dateimodus beschleunigte den exakten Textfilter und beanspruchte in diesem Lauf mehr Arbeitsspeicher. Der Index bleibt optional. Die Messreihe deckt synthetische MCP-Abfragen ab. Importlast, native OCR, Suchqualität auf Kundenarchiven und Backup/Restore werden separat geprüft.

### Prüfbefehle

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/vauldy-mcp-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/vauldy-mcp-module-cache
swift test --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none \
  --filter 'MCPScalabilityTests|MCPRetrievalCompletenessTests|MCPPassageTests'
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
python3 scripts/mcp/smoke_test.py .build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py .build/release/vauldy-mcp --check
```

Die 21 gezielten Swift-Tests, der Release-Build, der stdio-Test und die Übereinstimmung der vier Relay-Werkzeuge sind bestanden.

### Abnahmestand

- **20.000 synthetische Dokumente · GO für weitere Architekturtests.** Der Nachweis für reale Bestände unter paralleler Import- und OCR-Last steht aus.
- **Agensi · NO-GO für Freigabe.** Der Test im Zielclient mit Inventar, Quellenbelegen und Widerruf steht aus.
- **Kunden-Mac · NO-GO für Freigabe.** Die zwei Developer-ID-signierten und notarisierten Pakete und deren Offline-Abnahme stehen aus.

## Priorisierte Abnahmetickets

| Reihenfolge | Ticket | Abnahme |
| --- | --- | --- |
| 1 | P0 · Vertrauenswürdiger Release und CI | Paketzusammenbau, Versions- und Architekturprüfung, Regression und Schema-Parität auf sauberem macOS-Runner. Team-ID, Gatekeeper und Ticket auf frischem Kunden-Mac belegen. Signierung und Notarisierung erst mit autorisierter Release-Umgebung ausführen. |
| 2 | P0 · Kundenabnahme von Update und Rückweg | Zwei kompatible Developer-ID-Releases auf frischem Kunden-Mac prüfen. Rückkehr mit bewusstem Neustart, unabhängige Offline-Probe und kontrollierten Stromausfalltest ausführen. |
| 3 | P0 · Agensi-Pilot | In einem Zielclient das Anweisungspaket und bestehenden lokalen Vauldy MCP getrennt laden. Synthetische Recherche über mehrere Inventar- und Leseseiten, Quellen und Widerruf prüfen. Bei Agensi den vorhandenen lokalen MCP unter „Needs access“ ausweisen. [Agensi-Format und Angebotsgrenzen](https://www.agensi.io/docs/what-you-can-sell) |
| 4 | P1 · Gemeinsamer Core | Je gemeinsamem Pfad Eigentümer und API bestimmen. Ein erstes identisches Modell oder einen kleinen Quellenvertrag extrahieren. App- und MCP-Adapter gegen Altfixtures prüfen, anschließend nur belegte Duplikate entfernen. Veröffentlichung gemeinsamer Quellen separat entscheiden. |
| 5 | P1 · 20.000 Dokumente | Größenreihe auf Referenz-Mac mit Freigaben, realistischen Dokumentlängen, Speicherspitzen, Wiederholungen, Suchbelegen und Worker-/Importlast ausführen. Zielwerte vor Abnahme festlegen. Vergleichbarer read-only Indexversuch nur bei belegtem Engpass. Alte JSON-Daten weiter lesen, Backup/Restore und Abbruch testen. |
| 6 | P1 · Resilienz | Synthetische Crash-/Cancel-Proben mit tatsächlicher nativer OCR, kontrollierten CPU-/Speichergrenzen und Wiederaufnahme. Diagnosen auf technische Zähler begrenzen. |
| 7 | Optional · Remote und Lizenz | Separaten Architekturvorschlag mit Zweck, widerrufbarer Zustimmung, Gerätebindung, Aufbewahrung und Offline-Test liefern. Lokaler stdio-Betrieb bleibt unabhängig. |
