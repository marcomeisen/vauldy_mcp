# Vauldy MCP prüfen

Kommandos im ermittelten MCP-Checkout ausführen. Binärpfade aus dem tatsächlich benutzten Build
nehmen. Ein gleiches `--version` allein beweist keinen gleichen Quellstand. Vor einem Vergleich
Discovery und Paketmanifest prüfen. Installerartefakte in einem neuen aufgabeneigenen Ausgabeordner
erstellen. Bestehende Installation und fremde Hostprozesse nicht als Testumgebung verwenden.

## Passende Prüfflächen

| Änderung | Bestehende Prüfungen |
| --- | --- |
| Feldauslese, Evidenz, Pagination | `MCPFieldExtractionTests`, `MCPRetrievalCompletenessTests`, `MCPPassageTests`; `field_extraction_smoke_test.py`, `smoke_test.py` |
| Fristenübersicht | `deadline_overview_smoke_test.py`. Explizite Daten, Belege, Kalendergrenzen, Konflikte, Privacy und Widerruf prüfen. |
| Fassungsvergleich | `contract_comparison_smoke_test.py`; unklare Paarzuordnung, Seitenbelege, Widerruf und Ausgabe ohne Vertragskennungen prüfen |
| Themenübersicht | `topic_overview_smoke_test.py`; Zielchat-Messung separat |
| Privacy/Freigabe | `MCPPrivacyBoundaryTests`, einschlägige Widerrufstests, reale stdio-Antworten in beiden Ausgabeformaten |
| Persistenz/Index | `MCPScalabilityTests`, `index_recovery_smoke_test.py`, `scalability_benchmark.py`; Profil-/Quellenänderung und Prozessabbruch berücksichtigen |
| OCR/Originale | `LocalImportTests`, `OCRWhiteMarginsTests`, `OCRTargetedRetryTests`, `LocalOriginalReferenceTests`; `import_smoke_test.py`, `original_reference_smoke_test.py` |
| Bestandsabgleich | `InventoryWorkflowTests`; bestehende synthetische Verwaltungs-/Abgleichprüfungen anhand des aktuellen Skriptbestands wählen |
| OAuth/Relay | `OAuthConnectionTests`, `RelayConnectionTests`, `RelayKeychainInteractionTests`; `oauth_smoke_test.py`, `export_relay_tools.py --check`, Worker-Tests |
| Update/Installation | `software_update_smoke_test.py`, `client_install_smoke_test.py`, `management_smoke_test.py`; Kundenreleaseprüfung zusätzlich auf frischem Offline-Mac |

Die Skripte liegen unter `scripts/mcp`, Swift-Tests unter `Tests/VauldyMCPRuntimeTests`.
Parameter vor einer abweichenden Verwendung mit `--help` oder im aktuellen Skript prüfen.

## Build und lokale Schnittstelle

```sh
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --product vauldy-mcp
swift test --disable-sandbox --disable-automatic-resolution --jobs 4 --no-parallel --filter MCPFieldExtractionTests
python3 scripts/mcp/smoke_test.py /absolut/zum/gebauten/vauldy-mcp
python3 scripts/mcp/field_extraction_smoke_test.py /absolut/zum/gebauten/vauldy-mcp --benchmark
python3 scripts/mcp/export_relay_tools.py /absolut/zum/gebauten/vauldy-mcp --check
node --test cloud/chatgpt-relay/tests/relay.mjs
```

Native Vision und Loopback-Tests brauchen die entsprechenden macOS-Laufzeitrechte. Ein
Sandbox- oder Teststarterfehler ist kein bestandener Test und noch kein OCR-Produktfehler.
OCR-Benchmarks sequenziell ohne konkurrierende OCR ausführen. Performance getrennt nach erstem
Zugriff, Wiederholung, Cache und beteiligten Schichten messen. Build/Komponententest, stdio,
HTTP, Relay und sichtbare Zielchat-Antwort sind verschiedene Nachweise.

Synchronisierte Buildverzeichnisse können beim Öffnen einer Builddatenbank oder ausgelagerter
Dateien hängen. Eine bytegeprüfte frische Quell-/Buildkopie in einem lokalen temporären Verzeichnis
erlaubte den regulären Xcode-Paketbuild. Erst die aktuelle Ursache prüfen und Abhängigkeiten an
den festgeschriebenen Commits halten. Ein früherer Ausweichlauf verwendete `--build-system native`,
separate Modulcaches unter `/tmp` und beim Testen `-debug-info-format none -Xswiftc -parse-as-library`;
das ist kein vorgeschriebener Standardmodus. Materialisierung ausgelagerter Dateien kann außerdem
einen Compilerabbruch wegen geänderter Eingaben auslösen. Weder Quellfehler noch fehlgeschlagene
Versuche als Pass zählen.

Die gesamte synthetische Regression ist `python3 scripts/mcp/regression_test.py`. Sie baut und
paketiert ebenfalls und ist für passende Releasearbeit gedacht, nicht nach jeder Textänderung.
Keine historischen Summen als Ergebnis eines neuen Laufs angeben.

## Paket und Kundenabnahme

`scripts/mcp/package.py` erzeugt ein vollständiges macOS-Bundle mit Setup, lokalem MCP, CLI,
HTTP-Server, Relay-Agent und Status-App. Der separate Recherchepilot ist daraus nicht automatisch
ein mitgeliefertes Standardwerkzeug. `--skip-build` nur bei eindeutig verifizierten aktuellen
Binärdateien für lokale Entwicklung einsetzen. Der Signierungsmodus entscheidet über die Aussage:

- Ad-hoc: lokales Testpaket, keine Developer-ID-/Notarisierungsabnahme.
- Developer ID: tatsächliche Identität und frischer sauberer Quellstand erforderlich.
- Notarisiert: gültiges vorhandenes Notary-Profil, finale Ticketprüfung und ZIP-Nachweis erforderlich.

Für File-Provider-Ausgabeordner `--archive-only` verwenden, wenn ein loses kopiertes App-Bundle
erneut verbotene Finder-Metadaten erhält. Der Paketierer prüft das veröffentlichte ZIP nach erneutem
Entpacken in lokalem Staging. Aus eigenen generierten Bundles nur FinderInfo/ResourceFork entfernen,
Quarantäne und andere Attribute erhalten. `scripts/mcp/package_metadata_smoke_test.py` prüft dies
mit realer Codesignatur, unveränderten signierten Bytes, Idempotenz und Symlinkabwehr.

Credentialanforderungen benennen, keine Secrets erfinden und Gatekeeper nicht abschalten.
Update und Rollback auf einem frischen, tatsächlich netzgetrennten Test-Mac mit synthetischen
Profilen und stabilen Clientpfaden abnehmen. Ein Prozess mit gesperrtem Netzwerk beweist nicht,
dass der ganze Mac offline ist. Fehlende Voraussetzungen offen dokumentieren.

`MCPLocalProbe` prüft Version/Discovery/Status, keine ChatGPT-Anmeldung. Im regulären Zielchat
einen separaten privaten synthetischen Testanschluss verwenden. Aktuelle Anmeldung und
Werkzeugverfügbarkeit beobachten. Aufrufe einschließlich Fehlern/Wiederholungen im lokalen
inhaltsfreien Audit zählen. Zeit bis zur sichtbaren Tabelle messen. Kein Produktivprofil umhängen
und keinen Live-Relay-Rollout für den Test vornehmen. Bei fehlendem Zugang unabhängige Arbeit
fortsetzen und diesen Abnahmepunkt offenlassen.
