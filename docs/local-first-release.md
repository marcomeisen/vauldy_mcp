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

Der Rückweg verwendet genau eine vorherige geprüfte Generation mit gleicher Epoche. Er prüft Signatur, Komponenten-Integrität und stdio-Start erneut. Ein Altbestand ohne Generationsnachweis bleibt bis zum ersten erfolgreichen Austausch als Wiederherstellungsstand für einen fehlgeschlagenen Start verfügbar. Die manuelle Rückkehr beginnt nach zwei erfolgreichen verwalteten Installationen. Direkte Downgrades werden abgewiesen. Bei unbekannten Einträgen im Softwareordner bricht die Aktivierung ab. Der optionale Tunnel-Helfer und datierte Serversicherungen im Format `vauldy-mcp.before-init-compatibility-JJJJMMTT` werden mit unverändertem Inhalt und Dateirechten mitgeführt. Unterscheiden sie sich zwischen den Generationen, wird die Rückkehr gesperrt. Reguläre Finder-Metadaten (`.DS_Store`) sind vom Programmsatz ausgenommen.

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

`VauldyDocumentCore` ist das eigenständige Swift-Modul für den Seitenmarkierungsvertrag im MCP. `VauldyCore` exportiert denselben Typ weiterhin über den bisherigen Namen. Die Entwicklung findet im eigenständigen MCP statt. Der Chatbot ist die Oberfläche für die Dokumentarbeit. Der lokale MCP verantwortet Dokumentzugriff, Freigaben, Quellenbindung und die strukturierte Ausgabe an den Chatclient.

### Wiederaufbaubarer SQLite-Index

Aktiviere den persistenten Index nur für eine lokale Verbindung mit eigenem privaten Profilordner:

```sh
vauldy-mcp --profile /absoluter/pfad/profile.json --persistent-sqlite-index
```

Der Cache liegt neben dem Profil in einem privaten, versionsgebundenen Verzeichnis. Die Datei `index-v1.sqlite` ist auf 64 MiB begrenzt. Sie enthält gehashte Suchwörter, interne Dokumentkennungen, Prüffingerabdrücke und kompakte Statusfelder. Gehashte Suchwörter sind weiterhin sensible Ableitungen. Die Datei enthält keine Originale, vollständigen OCR-Texte, Pfade oder reversiblen Pseudonym-Zuordnungen. JSON und dessen Backup bleiben führend.

Das Öffnen bindet den Cache an den vollständigen Fingerabdruck der Freigabe und vergleicht ihn mit dem aktuellen autorisierten JSON-Bestand. Geänderte, neue und entfernte Zeilen werden zusammen mit der Generation transaktional gespeichert. Bei beschädigten Inhalten baut Vauldy den Cache in einer separaten Datei auf und tauscht diese atomar ein. Ein unvollständiger Aufbau und eine vorübergehende Cache-Sperre blockieren die Suche nicht. SQLite-Fehler führen zur bisherigen Filterung. Bei einer verwalteten Profiländerung wird der Cacheordner atomar aus dem aktiven Pfad verschoben. Das gelingt auch bei belegter SQLite-Schreibsperre. Die leere Sperrdatei liegt außerhalb des Cacheordners und verhindert, dass ein anderer Schreiber den aktiven Pfad vorzeitig neu anlegt. Sie bleibt als gemeinsamer Sperrpunkt erhalten. Der laufende Schreiber prüft das aktuelle Profil vor und nach der Veröffentlichung. Der nächste Indexaufruf räumt eigene Stagingreste und getrennte Cacheordner auf. Ein deaktiviertes Profil löst die Bereinigung beim nächsten Zugriff auch ohne Indexoption aus. Bei direkter Bearbeitung eines weiterhin aktiven Profils bindet der nächste Indexaufruf die Datei an die neue Freigabe. [SQLite FTS5](https://www.sqlite.org/fts5.html)

Der lokale stdio-Server verwendet die kompakte Projektion standardmäßig für Anfragen mit `includeExcerpts=false`. Die Projektion bleibt im Arbeitsspeicher. Bei Folgeseiten verwendet der Prozess Statusfelder der zuvor geprüften Generation. Er prüft Profil und Dateistand vor der Ausgabe erneut. Ändert sich der autorisierte Bestand, läuft der Cursor über den bisherigen Prüfpfad und wird bei abweichender Generation abgewiesen. Für Treffer werden weiterhin der bestehende Textfilter und die Privacy-Grenze angewendet. Rangsuche und Teilwortmodus verwenden ihre bisherigen Suchverträge.

Für Vergleiche stellt `--no-compact-list-projection` die bisherige Pagination wieder her. `--compact-list-projection` bleibt als ausdrückliche Wahl des Standards gültig. `--persistent-sqlite-index` aktiviert den optionalen Dateiindex mit kompakter Projektion. `--large-snapshot-cache` erhöht das JSON-Cache-Limit. `--memory-sqlite-index` aktiviert FTS5 im Arbeitsspeicher. `--experimental-sqlite-index` kombiniert weiterhin größeren Cache und Speicherindex. Alle Optionen gelten für den lokalen stdio-Aufruf.

```sh
python3 scripts/mcp/scalability_benchmark.py .build/release/vauldy-mcp \
  dist/mcp/persistent-index-variants.json --documents 1000 2000 5000 10000 20000 --compare-index-variants
```

### Variantenmessung

In Iteration 3 verglich ein Release-Lauf mit `vauldy-mcp 0.13.0` dieselben synthetischen Bestände mit 1.000, 2.000, 5.000, 10.000 und 20.000 Einträgen. Das Archiv und die Ausgangsprofildatei waren bytegleich. Die Varianten nutzten getrennte Prozesse und Profilkopien.

| Variante bei 20.000 Dokumenten | Erste Inventarseite | Median erste 10 Folgeseiten | P95 Folgeseiten | Median exakte Suche warm | Peak-RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| JSON-Basis | 1,35 s | 690 ms | 751 ms | 2,42 s | 325 MiB |
| Größerer JSON-Cache | 1,32 s | 495 ms | 537 ms | 2,18 s | 309 MiB |
| Kompakte Projektion | 1,37 s | 133 ms | 151 ms | 2,05 s | 301 MiB |
| FTS5 im Speicher | 1,33 s | 703 ms | 729 ms | 0,82 s | 352 MiB |
| Datei-FTS5 und Projektion | 3,73 s | 136 ms | 157 ms | 0,63 s | 421 MiB |

Die vier Einzelvarianten messen bei 20.000 Einträgen je zehn Folgeseiten. Der Dateimodus misst alle 199 Folgeseiten und liefert in 30,62 s insgesamt 20.000 unterschiedliche Dokumente. In allen Varianten ergeben sich 400 Treffer für die Testanfrage und ein überprüfter Beleg auf Seite 1. Die Indexdatei misst 20,91 MiB und wurde nach Neustart bytegleich wiederverwendet. Die erste exakte Suche nach Neustart dauerte 1,38 s.

Die kompakte Projektion erzielte den größten Gewinn bei der Pagination. Der Dateimodus beschleunigte den exakten Textfilter und beanspruchte in diesem Lauf mehr Arbeitsspeicher. Der Index bleibt optional. Die Messreihe deckt synthetische MCP-Abfragen ab. Importlast, native OCR, Suchqualität auf Kundenarchiven und Backup/Restore werden separat geprüft.

Iteration 4 verglich den neuen Standard erneut bei 20.000 synthetischen Dokumenten mit dem ausdrücklichen Rückweg. Der Median der ersten zehn Folgeseiten sank von 703 auf 126 ms. Die erste Inventarseite dauerte 1,35 s mit bisheriger Pagination und 1,38 s mit Projektion. Beide Varianten lieferten 400 Treffer für die Testanfrage und einen Beleg auf Seite 1. Der optionale Dateimodus lieferte alle 200 Seiten in 30,31 s und verwendete den Index nach Neustart bytegleich wieder.

```sh
python3 scripts/mcp/scalability_benchmark.py .build/release/vauldy-mcp \
  dist/mcp/iteration-4-index-variants.json --documents 20000 --compare-index-variants
```

### Prüfbefehle

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/vauldy-mcp-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/vauldy-mcp-module-cache
swift test --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none \
  --filter 'MCPScalabilityTests|MCPRetrievalCompletenessTests|MCPPassageTests|MCPConnectionRemovalTests|MCPPrivacyBoundaryTests'
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
python3 scripts/mcp/index_recovery_smoke_test.py .build/release/vauldy-mcp
python3 scripts/mcp/smoke_test.py .build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py .build/release/vauldy-mcp --check
```

Alle 39 gezielten Swift-Tests, der Release-Build, beide stdio-Tests und der Vergleich der Relay-Werkzeuge waren erfolgreich. Die Swift-Tests prüfen Pausieren und Entfernen während einer echten SQLite-Stagingphase. Der stdio-Test hält einen realen Server während des Aufbaus an und widerruft die Freigabe. Weitere Serverprozesse werden beim Aufbau und während einer inkrementellen Transaktion mit `SIGKILL` beendet. Der Neustart wird gegen die synthetischen JSON-Daten geprüft. Ein bereits getrennter, liegen gebliebener Cacheordner wird als eigener Wiederanlauffall simuliert. Bereinigung bedeutet Entfernen der abgeleiteten Dateien auf Dateisystemebene. Stromausfall und forensische Löschung sind eigene Fragestellungen.

### Abnahmestand

- **20.000 synthetische Dokumente · GO für weitere Architekturtests.** Der Nachweis für reale Bestände unter paralleler Import- und OCR-Last steht aus.
- **Agensi · NO-GO für Freigabe.** Der Test im Zielclient mit Inventar, Quellenbelegen und Widerruf steht aus.
- **Kunden-Mac · NO-GO für Freigabe.** Die zwei Developer-ID-signierten und notarisierten Pakete und deren Offline-Abnahme stehen aus.

## Agenten im Chatbetrieb

Der erste Pilot ist ein Recherche-Agent auf dem Mac des Kunden. Der Chatbot nimmt den Auftrag entgegen. Der Agent koordiniert Suche, Pagination, vorhandene Metadaten und Fundstellen über den lokalen MCP. Der MCP prüft jede Abfrage gegen die aktuelle Freigabe und begrenzt die ausgegebenen Inhalte. Vor der Rückgabe einer zusammengeführten Antwort muss der Agent die Quellenfreigabe erneut über den MCP prüfen. Bei Widerruf oder Abbruch verwirft er die noch ausstehende Antwort.

Der Pilot nutzt die bestehende Werkzeugschnittstelle. Ein synthetischer Versicherungsbestand dient als Vergleich zwischen direktem Chatablauf und Agent. Geprüft werden Trefferabdeckung, korrekte Feldbelege, Laufzeit, Werkzeugaufrufe, Abbruch und Offline-Ausführung. Ein gezieltes Extraktionswerkzeug folgt bei einer belegten Lücke in den verfügbaren Metadaten oder Fundstellen. Der Chat bleibt die Oberfläche für den gesamten Ablauf.

### Recherche-Pilot aus Iteration 6

Der Pilot akzeptiert den festgelegten Auftrag „Finde meine Versicherungsverträge und erstelle eine Tabelle mit Versicherer, Vertragsnummer und Kündigungsfrist.“ Ein neuer MCP-Prozess wird für genau ein vorgegebenes Profil gestartet. Der Pilot prüft Status und Zugriff, sammelt alle kompakten Listenseiten und liest pro Kandidat Metadaten und gezielte Fundstellen. Die Ausgabe ist ein JSON-Bericht mit Zeilen, Feldern, Seitenbelegen und Angaben zur Abdeckung. Für die geplante Chat-Anbindung steht dieser Bericht als Ergebnis des lokalen Auftrags bereit.

Die Felder stammen aus passenden Rollen in gespeicherten Metadaten und aus ausdrücklich beschrifteten Zeilen in den bereitgestellten Quellen. Eine eindeutige Vertragsüberschrift muss belegt sein. Kandidaten mit mehrdeutiger Dokumentstruktur werden separat gezählt. Die Tabelle unterscheidet belegte, pseudonymisierte, fehlende und widersprüchliche Werte. Ein vollständig abgerufenes Textinventar sagt nichts über die Vollständigkeit der OCR oder die fachliche Erkennung aller Verträge aus.

Vor der Ausgabe prüft der Pilot den Status und wiederholt die vollständige Kandidatenliste. Er vergleicht die aktuellen Lesekennungen und Verarbeitungszustände, auch für ausgeschlossene Kandidaten. Widerruf, Quelländerung, Abbruch oder ein überschrittenes Zeit-, Kandidaten- oder Aufruflimit führen zu einem unvollständigen Ergebnis ohne Dokumentzeilen.

Der optionale Planner verwendet Apples vorhandenes [On-Device-Modell](https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute/). Er erhält den Auftrag und ergänzt den festen Suchwortsatz aus einer begrenzten Auswahl. Dokumenttexte und Werkzeugergebnisse gehen ausschließlich durch den lokalen MCP und den regelbasierten Belegpfad. Ein nicht verfügbares Modell beendet den modellgestützten Auftrag mit einem ausdrücklichen Status. Der Pilot kann auch ausdrücklich mit dem festen Auftrag ohne Modell gestartet werden.

Die folgenden Befehle sind für den Entwicklungsnachweis. Der Test legt ein eigenes Profil und ausschließlich synthetische Bestände an. Der direkte Referenzablauf bildet eine Skriptfolge derselben MCP-Werkzeuge ab und liest die Kandidaten vollständig. Die technische Anbindung im lokalen Zielhost wird separat geprüft.

```sh
python3 scripts/mcp/research_agent_smoke_test.py .build/release/vauldy-mcp
CLANG_MODULE_CACHE_PATH=/tmp/vauldy-mcp-clang-cache xcrun swiftc -parse-as-library \
  -target arm64-apple-macos26.0 scripts/mcp/research_planner.swift -o /tmp/vauldy-iteration6-planner
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  python3 scripts/mcp/research_agent_smoke_test.py .build/release/vauldy-mcp \
  --planner /tmp/vauldy-iteration6-planner --require-network-denied
```

Der lokale Pilot kann für ein ausdrücklich ausgewähltes Testprofil auch einzeln aufgerufen werden.

```sh
python3 scripts/mcp/research_agent.py .build/release/vauldy-mcp \
  --profile /absoluter/pfad/zum/testprofil.json --planner /tmp/vauldy-iteration6-planner
```

Im Lauf mit gesperrtem Prozessnetz lieferten beide Varianten die drei erwarteten Verträge. Ein thematischer Flyer blieb Textkandidat und ein Dokument mit fehlgeschlagener OCR wurde separat gezählt. Die Vertragsnummern waren pseudonymisiert. Eine Frist fehlte und eine zweite war widersprüchlich belegt. Der zweite Widerspruchsbeleg lag auf Seite 12 hinter dem ersten Fundstellencursor.

| Ablauf | MCP-Aufrufe gesamt | Leseaufrufe | Abgerufener Text in Segmenten | Gesamtlauf |
| --- | ---: | ---: | ---: | ---: |
| Direkt mit vollständiger Textlesung | 26 | 18 | 41.085 Byte | 1,18 s |
| Agent mit lokalem Modellplaner | 17 | 9 | 5.405 Byte | 2,98 s |

Die Zeiten sind Einzelmessungen auf demselben Mac. Die Agentenzeit umfasst den Modellaufruf. Der separate Lauf mit festem Suchwortsatz dauerte beim Agenten 1,04 s. Die Textmenge umfasst ausschließlich die Textsegmente aus `read_document`. Die Negativtests bestätigten, dass Widerruf, Quelländerung, `SIGINT`, ein angehaltener MCP-Prozess am Zeitlimit und das Aufruflimit jeweils keine Dokumentzeilen ausgeben. Der synthetische Bestand und die ursprüngliche Freigabe blieben bytegleich.

### Anbindung an den lokalen Codex-Host

`vauldy-research-mcp` bietet das optionale Werkzeug `research_insurance_contracts` über stdio an. Das Werkzeug hat eine leere Eingabe. Die lokale Startkonfiguration bestimmt Python, Agentenskript, Vauldy-Binary, Profil und optional den Modellplaner. Das Chatmodell kann diese Pfade im Werkzeugaufruf nicht ändern. Der bisherige MCP bleibt die Instanz für Dokumentzugriff und Datenschutz und bietet weiterhin die vier Werkzeuge aus Vertrag v1 an.

Eine erfolgreiche Antwort enthält eine deutsche Tabelle mit Seitenbelegen und strukturierte Daten. Pseudonymisierung, widersprüchliche oder fehlende Angaben und OCR-Lücken werden sichtbar. Bei Widerruf, paralleler Recherche oder Zeitlimit enthält die Antwort einen Fehlergrund und keine Dokumentzeilen. Bei einer MCP-Abbruchnachricht wird der Agent beendet und die verspätete Antwort verworfen. Die Freigabe und der Quellenstand werden auch am Chat-Adapter vor der Ausgabe erneut geprüft.

Der Adapter ist ein separates Entwicklungsprogramm. Beispiel für die Konfiguration eines lokalen Testhosts mit absoluten Pfaden.

```toml
[mcp_servers.vauldy_research_test]
command = "/absoluter/pfad/vauldy-research-mcp"
args = [
  "--python", "/absoluter/pfad/python3",
  "--agent", "/absoluter/pfad/scripts/mcp/research_agent.py",
  "--server", "/absoluter/pfad/vauldy-mcp",
  "--profile", "/absoluter/pfad/zum/testprofil.json",
  "--planner", "/absoluter/pfad/research-planner",
]
tool_timeout_sec = 65
```

Der optionale Modellplaner wird wie oben gebaut. Der Abnahmetest erzeugt die Konfiguration, den Testthread und die Dokumente selbst. Er verwendet die installierte Codex-CLI über ihre lokale App-Server-Schnittstelle.

```sh
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
python3 scripts/mcp/research_chat_smoke_test.py .build/release/vauldy-research-mcp .build/release/vauldy-mcp
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  python3 scripts/mcp/research_chat_smoke_test.py .build/release/vauldy-research-mcp .build/release/vauldy-mcp \
  --planner /tmp/vauldy-iteration6-planner --codex "$(command -v codex)" --require-network-denied
```

Der installierte lokale Codex-Host erkannte das Werkzeug in einem flüchtigen Testthread und lieferte drei belegte Verträge. Nach Widerruf lieferte derselbe Host einen Fehler ohne Dokumentzeilen. Der Lauf sperrte Netzwerkzugriffe und nutzte das lokale Apple-Modell für die Suchplanung. Ein separater stdio-Test belegt, dass nach Abbruch keine Antwort folgt und der wartende Modellprozess endet. Die automatische Werkzeugwahl aus einem Freitextturn und die Darstellung durch das Chatmodell sind ein eigener Abnahmeschritt.

### Freitexttest mit lokalem Chatmodell

Der Freitexttest verbindet Apples lokales Chatmodell mit dem isolierten Codex-Testthread. Das Modell klassifiziert die natürlich formulierte Anfrage zunächst ohne Dokumentwerkzeuge. Bei einer allgemeinen Übersicht über eigene Versicherungsverträge erhält es das Recherche-Werkzeug zur Auswahl. Der Testclient akzeptiert genau eine Auswahl und ruft das Werkzeug dann im echten lokalen Codex-Host auf.

Beim direkten Angebot des einzelnen Werkzeugs wählte das Modell es im ersten Versuch auch für sachfremde und zu eng gefasste Fragen. Deshalb liegt die Prüfung des Auftragsumfangs vor der Werkzeugwahl. Das Modell erhält für diese Entscheidung nur die Chatfrage. Die sichtbare Antwort übernimmt die geprüfte Markdown-Tabelle samt Werten und Belegen oder den Fehlerhinweis aus der Werkzeugantwort.

```sh
CLANG_MODULE_CACHE_PATH=/tmp/vauldy-mcp-clang-cache xcrun swiftc -parse-as-library \
  -target arm64-apple-macos26.0 scripts/mcp/research_chat_router.swift -o /tmp/vauldy-research-chat-router
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  python3 scripts/mcp/research_chat_smoke_test.py .build/release/vauldy-research-mcp .build/release/vauldy-mcp \
  --planner /tmp/vauldy-iteration6-planner --router /tmp/vauldy-research-chat-router \
  --codex "$(command -v codex)" --require-network-denied
```

Im Lauf mit gesperrtem Prozessnetz führten zwei verschieden formulierte Versicherungsfragen jeweils zu einer Tabelle mit drei belegten Verträgen. Eine auf Hausrat im Jahr 2024 eingeschränkte Frage und eine Rechenfrage führten zu keinem Werkzeugaufruf. Nach Widerruf führte eine weitere Versicherungsfrage zum Freigabefehler ohne Dokumentzeilen. Insgesamt gab es drei tatsächliche Werkzeugaufrufe im isolierten Codex-Host.

Dieser Nachweis betrifft die lokale Modellwahl, den Codex-Werkzeugaufruf und die vom Testclient gezeigte Antwort. Die Darstellung im normalen ChatGPT- oder Codex-Gespräch mit dem dort ausgewählten Modell hat einen eigenen Abnahmepunkt.

### Abnahme im regulären ChatGPT-Gespräch

**Vorprüfung vom 04.11.2026.** Die erreichbare ChatGPT-Weboberfläche zeigte die Anmeldung. Der reguläre ChatGPT-Werkzeugaufruf konnte deshalb in diesem Lauf nicht ausgeführt werden. Ein frisches synthetisches Profil mit eigenem stdio-Startbefehl wurde lokal geprüft. Dieser Einstieg bietet ausschließlich `research_insurance_contracts` an und liefert die erwartete Tabelle mit drei belegten Verträgen.

Der erneute lokale HTTP/OAuth-Test bestätigte vier angebotene Werkzeuge. Der Relay-Abgleich bestätigte dieselbe Standardliste für den Relay-Code. Für diesen Test ist der separate Recherche-Adapter der Zielprozess. Das ChatGPT-Webgespräch benötigt einen separat hinzugefügten MCP-Anschluss. OpenAI unterstützt für einen privaten Testanschluss einen Secure MCP Tunnel, der einen lokalen stdio-Prozess aufruft. [Benutzerdefinierte MCP-Server in ChatGPT](https://developers.openai.com/api/docs/guides/custom-mcp-server) · [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)

1. Einen angemeldeten Test-Workspace mit Zugriff auf einen separaten privaten Tunnel verwenden. Den vorhandenen Tunnel-Client mit dem geprüften stdio-Startbefehl und dem synthetischen Profil starten. Den Runtime-Schlüssel ausschließlich lokal eingeben. In ChatGPT den Testanschluss hinzufügen und die Anzeige von `research_insurance_contracts` prüfen.
2. Im neuen Chat den Testanschluss auswählen und fragen „Welche Versicherungsverträge habe ich? Bitte als Tabelle mit Versicherer, Vertragsnummer und Kündigungsfrist.“ Den tatsächlichen Werkzeugaufruf und die angezeigten drei Tabellenzeilen prüfen. Erwartet sind Seitenbelege, pseudonymisierte Vertragsnummern, eine fehlende Frist und eine widersprüchliche Frist.
3. Das synthetische Profil widerrufen und in einem weiteren neuen Chat erneut fragen. Der Werkzeugaufruf muss den Freigabefehler liefern. Die Antwort darf keine früheren Dokumentzeilen wiedergeben.

```sh
python3 scripts/mcp/research_chat_smoke_test.py .build/release/vauldy-research-mcp .build/release/vauldy-mcp
python3 scripts/mcp/oauth_smoke_test.py .build/release/vauldy-local .build/release/vauldy-mcp-http
python3 scripts/mcp/export_relay_tools.py .build/release/vauldy-mcp --check
```

### Grundlage aus Iteration 5

Der [Werkzeugvertrag v1](mcp-mvp.md#vauldy-werkzeugvertrag-v1) beschreibt Handles, Seitenbelege, Vollständigkeit und Widerruf. Die vier Werkzeugnamen und ihre Schemas sind im stdio-Test festgehalten. Der SQLite-Pilot verwirft die frühere Cache-Schemaversion, damit alte Listenmetadaten neu berechnet werden. Der lokale JSON-Bestand bleibt lesbar.

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/vauldy-mcp-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/vauldy-mcp-module-cache
swift test --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none \
  --filter 'MCPPrivacyBoundaryTests|MCPRetrievalCompletenessTests|MCPPassageTests|MCPScalabilityTests|OAuthConnectionTests|annotatedPDFOriginalsPersistCorrectRolesAcrossDocumentDomains|metadataIsProtectedPaginatedAndRevocableWithoutMutatingTheStore|metadataSharesContentPrivacyMappingAndCannotExposeRecipientOrIdentifiers|warningCodesCannotCarryArbitrarySourceText'
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
python3 scripts/mcp/smoke_test.py .build/release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py .build/release/vauldy-mcp --check
python3 scripts/mcp/index_recovery_smoke_test.py .build/release/vauldy-mcp
python3 scripts/mcp/scalability_benchmark.py .build/release/vauldy-mcp dist/mcp/iteration-5-scaling.json --documents 1000 2000
```

Der separate native OCR-Test lief mit Zugriff auf macOS Vision. Der lokale OAuth-Protokolltest lief über einen temporären Loopback-Port. Beide verwendeten synthetische Bestände.

```sh
swift test --skip-build --disable-sandbox --disable-automatic-resolution \
  --filter rasterOriginalsUseNativeOCRBeforeTheSameAnalysisPipeline
python3 scripts/mcp/oauth_smoke_test.py .build/debug/vauldy-local .build/debug/vauldy-mcp-http
```

54 gezielte Swift-Tests, der separate Rastertest mit acht PDF-Originalen, der Release-Build, die stdio-Prüfungen und der lokale OAuth-Test waren erfolgreich. Der zusätzliche Protokolllauf las die Metadaten von 25 synthetischen PDF-Originalen. Die Skalierungsprobe lieferte die kompakten Inventare mit 1.000 und 2.000 Einträgen vollständig in 10 und 20 Aufrufen. In der Fundstellenprobe lieferte ein Aufruf Belege auf den erwarteten Seiten 42 und 87.

## Priorisierte Abnahmetickets

| Reihenfolge | Ticket | Abnahme |
| --- | --- | --- |
| 1 | P0 · Vertrauenswürdiger Release und CI | Paketzusammenbau, Versions- und Architekturprüfung, Regression und Schema-Parität auf sauberem macOS-Runner. Team-ID, Gatekeeper und Ticket auf frischem Kunden-Mac belegen. Signierung und Notarisierung erst mit autorisierter Release-Umgebung ausführen. |
| 2 | P0 · Kundenabnahme von Update und Rückweg | Zwei kompatible Developer-ID-Releases auf frischem Kunden-Mac prüfen. Rückkehr mit bewusstem Neustart, unabhängige Offline-Probe und kontrollierten Stromausfalltest ausführen. |
| 3 | P0 · Agensi-Pilot | In einem Zielclient das Anweisungspaket und bestehenden lokalen Vauldy MCP getrennt laden. Synthetische Recherche über mehrere Inventar- und Leseseiten, Quellen und Widerruf prüfen. Bei Agensi den vorhandenen lokalen MCP unter „Needs access“ ausweisen. [Agensi-Format und Angebotsgrenzen](https://www.agensi.io/docs/what-you-can-sell) |
| 4 | P1 · MCP-Verträge für den Chatbetrieb | Werkzeugvertrag v1 und Referenzauftrag sind dokumentiert. Kompatibilität, Seitenbelege, Vollständigkeit und Freigaben werden anhand synthetischer Testfälle geprüft. Die vergleichende Ausführung des Rechercheablaufs gehört zu Iteration 6. |
| 5 | P1 · 20.000 Dokumente | Größenreihe auf Referenz-Mac mit Freigaben, realistischen Dokumentlängen, Speicherspitzen, Wiederholungen, Suchbelegen und Worker-/Importlast ausführen. Zielwerte vor Abnahme festlegen. Vergleichbarer read-only Indexversuch nur bei belegtem Engpass. Alte JSON-Daten weiter lesen, Backup/Restore und Abbruch testen. |
| 6 | P1 · Resilienz | Synthetische Crash-/Cancel-Proben mit tatsächlicher nativer OCR, kontrollierten CPU-/Speichergrenzen und Wiederaufnahme. Diagnosen auf technische Zähler begrenzen. |
| 7 | Optional · Remote und Lizenz | Separaten Architekturvorschlag mit Zweck, widerrufbarer Zustimmung, Gerätebindung, Aufbewahrung und Offline-Test liefern. Lokaler stdio-Betrieb bleibt unabhängig. |
