# Dokumentidentität und Importzeitpunkt · 08.11.2026

Umgesetzt im MCP-Arbeitsbranch `codex/local-first-product-readiness`. Der lokale
Dokumentbestand besitzt bereits eine UUID und ein Importdatum. Diese beiden
Eigenschaften sind im Core jetzt `let`: OCR, Analyse und Freigabewechsel können
sie nicht nachträglich zuweisen. Das bestehende Datenschema bleibt lesbar.

## Vertrag für den Chat

Das neue neunte Werkzeug `get_document_inventory` liefert ausschließlich die
aktuell freigegebenen Dokumente. Die vier festgeschriebenen v1-Basisverträge
bleiben unverändert; das Inventar hat einen eigenen Vertrag in Version 1.

| Feld | Bedeutung |
| --- | --- |
| `documentID` | Dauerhafte Referenz des gespeicherten Datensatzes, unabhängig vom Freigabehandle und von Verbindungsrevisionen. |
| `document` | Aktuelles, widerrufbares Lesehandle. Nur dieses Handle darf für `read_document` verwendet werden. |
| `importedAt` | Ursprünglicher Importzeitpunkt als ISO-8601-Zeit in UTC; bei unbekanntem Altbestand ausgelassen. |
| `contentHash` | SHA-256 der zuletzt importierten Originalbytes; fehlt bei Altbeständen ohne belegten Originalhash. |
| `originalState` | Zuletzt gespeicherter Zustand des Originals: `available`, `changed`, `unavailable` oder `unknown`. Kein aktueller Dateisystemcheck. |
| `processingStatus`, `sourceCoverage` | Gespeicherter Verarbeitungs- und Quellenzustand; keine Behauptung vollständiger OCR. |

`documentID` ist `doc_` plus SHA-256 über die UTF-8-Bytes von
`vauldy.document-reference.v1\0` und der kleingeschriebenen lokalen UUID;
`\0` steht hier für ein Nullbyte. Die rohe Archiv-UUID bleibt lokal. Gleiche
Datensätze sind damit bewusst über Freigabewechsel hinweg wiedererkennbar.
Das ist eine korrelierbare Referenz, kein Geheimnis, kein Anonymitätsversprechen
und keine Zugriffsberechtigung. Widerruf gilt auch für bereits bekannte IDs.

Für „Welche Dokumente wurden zuletzt importiert?“ genügt zunächst:

```json
{"name":"get_document_inventory","arguments":{"order":"imported-desc","pageSize":5}}
```

Alle freigegebenen Datensätze werden **vor** der Seitenauswahl nach Importzeit
sortiert. Unbekannte Zeitpunkte stehen in beiden Sortierrichtungen zuletzt;
gleiche Zeitpunkte werden deterministisch nach stabiler Referenz sortiert.
Standard: 20 Einträge, Maximum: 100. `nextCursor` bindet Fortsetzungen an Bestand,
Freigabe, Reihenfolge und Seitengröße. Vollständige Inventare müssen bis
`retrievalComplete=true` gelesen werden. Geänderte Freigaben verwerfen alte Cursor.
Antworten enthalten keine Originalpfade, Dateinamen, rohen Archiv-IDs oder OCR-Texte.
Für eine inhaltliche Bezeichnung oder einen Beleg ist zusätzlich ein erlaubter
Dokument-/Metadatenabruf nötig; die Geschwindigkeitsmessung unten betrifft das Inventar.

Die Dokumentenliste des Einrichtungsassistenten zeigt `Importiert: TT.MM.JJJJ,
HH:mm:ss` in der lokalen Zeitzone. Das Importdatum ist weder Ausstellungsdatum
noch Datum des letzten OCR-Laufs. Neue lokale Importe verwenden ganze Sekunden,
damit der zuerst zurückgegebene Zeitpunkt exakt zum bestehenden ISO-8601-
Speicherformat passt. Ein erneuter Import gleicher Bytes behält ID und Zeitpunkt.
Unbekannte Altzeitpunkte erscheinen als „Importzeitpunkt nicht bekannt“.

## Grenzen und Bestandsschutz

- Der Hash bezeichnet die zuletzt importierte Originaldatei, nicht den OCR-Text
  und nicht einen frisch gelesenen Dateistand. Eine erneute OCR verändert ihn nicht.
  Bei `changed`/`unavailable` bleibt er ein historischer Importhash. Das Inventar
  öffnet weder Originale noch startet es OCR oder eine Synchronisation.
- Geänderte Originalbytes erzeugen im vorhandenen Importmodell einen **neuen
  Datensatz mit neuer ID**. Der vorherige Datensatz und seine Belege bleiben erhalten.
  Eine über mehrere Inhaltsversionen gleichbleibende logische Dokumentfamilie
  ist damit noch nicht implementiert.
- Eine fehlende Zeile beweist keine Dateilöschung: Widerruf, geänderte Freigabe
  und entfernte Datensätze sind aus diesem freigabebezogenen Inventar nicht
  unterscheidbar. Ein belastbares Änderungsjournal mit Löschmarkierungen ist offen.
- SQLite verwendet kleine abgeleitete Projektionen mit zusätzlichem optionalem
  Inventarmetadatenstand. Alte Projektionen werden bei Bedarf datensatzweise nur
  im Arbeitsspeicher ergänzt. Kein Schemawechsel und keine Schreibmigration durch
  MCP-Lesezugriffe. JSON bleibt lesbar; fehlende Metadaten werden nicht erfunden.
- Produktive Dokumente, Freigaben, Profile, Originale, Keychain und Installation
  wurden in dieser Iteration nicht verändert. Sämtliche neuen Datenprüfungen
  verwenden isolierte synthetische Bestände.

## Neu ausgeführte Prüfung

Dateiänderungen dieser Iteration:

- Core: `VaultModels.swift`, `LocalDocumentStore.swift`,
  `SQLiteVaultTokenIndex.swift`, `VaultSourceState.swift`.
- MCP: neues `MCPDocumentInventory.swift`, `ReadOnlyMCPRuntime.swift`,
  `MCPAuditLog.swift`, `MCPBuildIdentity.swift`, `ServerFactory.swift`,
  `OutputSchemas.swift` und `RelayClient.swift`.
- Setup: `SetupText.swift`, `SetupDetailViews.swift`.
- Tests: neue `MCPDocumentInventoryTests.swift`, `SetupDocumentTimestampTests.swift`,
  aktualisierte `MCPBuildDiagnosisTests.swift`, neuer
  `scripts/mcp/document_inventory_smoke_test.py`; Fähigkeitsgates in `package.py`,
  `smoke_test.py`, `management_smoke_test.py`, `customer_release_smoke_test.py`,
  `build_diagnosis_smoke_test.py` und Integration in `regression_test.py`.
- Lokale Relay-Quellen: `cloud/chatgpt-relay/worker/index.js`,
  `cloud/chatgpt-relay/tests/relay.mjs`; keine externe Veröffentlichung.
- Anweisungen/Dokumentation: `skills/vauldy-lokale-dokumente/SKILL.md`, diese Datei,
  `docs/mcp-mvp.md`, `docs/local-first-todo.md` und der folgende Qualitätsnachweis.

Die maschinenlesbaren Ergebnisse und endgültigen Messwerte stehen in
[quality/document-inventory-2026-11-08.json](quality/document-inventory-2026-11-08.json).

Endgültiger Lauf: **56 Tests / zehn Suites in 18,778 s bestanden**. Die erste
Inventarseite mit fünf von 20.000 Einträgen benötigte **einen MCP-Aufruf und
737,350 ms**. Fünf weitere Abrufe: Median **286,988 ms**, beobachtetes P95
**327,614 ms**. JSON/SQLite/alte SQLite-Projektion mit jeweils fünf freigegebenen
Dokumenten: erste Seite **13,803 / 14,563 / 36,317 ms**. Insgesamt 225 Quell-,
Test-, Manifest- und Skriptdateien wurden mit der Buildkopie byteverglichen.

- 56 native Tests in zehn Suites: Inventar für JSON/SQLite, 20.000 kleine
  SQLite-Projektionen ohne Snapshotdekodierung und ohne Privacy-Textaufbau,
  stabile Identität über Neustart/Freigabewechsel, Widerruf, Datum/Zeitzonen,
  Duplikate und veränderte Originalbytes, Migration/Restore und bestehende
  gezielte OCR-/Belegerhalt-Regressionen.
- Echter lokaler stdio-MCP: JSON, SQLite, alte SQLite-Projektion und 20.000
  synthetische Vollfreigaben; vollständige Pagination mit 200 Seiten im großen
  Bestand, Quellen-/Profilbytes unverändert, unbekannte Daten zuletzt,
  Handlewechsel bei Neustart und Sperre nach Widerruf.
- Die letzte native Prüfung fand einen echten Präzisionsfehler: der frisch
  zurückgegebene Importzeitpunkt hatte Nachkommastellen, der erneut geladene
  ISO-8601-Wert nur Sekunden. Neue Importe werden jetzt vor dem Speichern auf
  Sekunden normiert. Vorhandene Importdaten werden nicht umgeschrieben.
- Bestehender stdio-Smoke-Test, vier gepinnte v1-Schemas, exakte Parität zwischen
  lokaler Discovery und Relay-Quelldefinition sowie zehn lokale Relay-Tests.
  Das ist kein Deployment und keine reguläre ChatGPT-Abnahme.
- Der vollständige Regressionsrunner und das feste 79-Sollfelder-OCR-Gate wurden
  in dieser Iteration nicht ausgeführt. Historische OCR-Ergebnisse sind kein
  neuer Nachweis dieser Funktion.

Reproduzierbare Befehle (Buildkopie und Berichte lagen ausschließlich unter `/private/tmp`):

```sh
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --no-parallel --filter 'MCPDocumentInventoryTests|SetupDocumentTimestampTests|SetupDocumentGuidanceTests|SQLiteIntegrationTests|StorageMigrationTests|MCPBuildDiagnosisTests|LocalImportTests|OCRTargetedRetryTests|OCRSmallRegionTests|EvidencePreservingOCRTests'
python3 scripts/mcp/document_inventory_smoke_test.py /private/tmp/vauldy-ocr-vector-wtr5pb1z/.build/out/Products/Release/vauldy-mcp /private/tmp/vauldy-document-inventory-rhznnt5_/fixtures --report /private/tmp/vauldy-document-inventory-rhznnt5_/wire-immutable.json
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-ocr-vector-wtr5pb1z/.build/out/Products/Release/vauldy-mcp
python3 scripts/mcp/export_relay_tools.py /private/tmp/vauldy-ocr-vector-wtr5pb1z/.build/out/Products/Release/vauldy-mcp --check
node --test cloud/chatgpt-relay/tests/relay.mjs
```

Für frische Wire-Fixtures beim nativen Test `VAULDY_DOCUMENT_INVENTORY_FIXTURES`
auf ein neues isoliertes Verzeichnis setzen. Die Fixtures enthalten ausdrücklich
kontrollierte Import-/Hashmetadaten, keine Ergebnisse einer neuen OCR-Messung.
Zeitmessungen sind lokale Werkzeuglaufzeiten; fünf Warmmessungen erlauben keine
allgemeine P95-Zusage und messen keine Zeit bis zur sichtbaren ChatGPT-Tabelle.

## Nächste Aufgaben mit Abnahmekriterien

1. **P1 – Paket und private Discovery aktualisieren:** neues Paket bauen und
   bestehenden lokalen Bestand ohne Neuimport aktualisieren; Relay-Discovery
   separat freigeben/ausrollen und Client-Metadaten aktualisieren. Abnahme: alle
   neun Werkzeuge sichtbar, bestehende neun Dokumente/Freigaben unverändert.
2. **P1 – Reguläre synthetische Chat-Abnahme:** Frage nach den fünf letzten
   Importen über separaten Testanschluss. Abnahme: echte Zeitpunkte korrekt,
   unbekannte Daten benannt, tatsächliche Werkzeugrunden und sichtbare Antwortzeit
   gemessen; keine Produktionsdokumente als Testdaten übertragen.
3. **P2 – Versionsfamilien und Änderungsjournal:** explizite logische ID zusätzlich
   zur unveränderlichen Datensatz-ID, Vorgängerverweise sowie freigabesichere
   Lösch-/Widerrufssemantik planen. Abnahme: neue/geänderte/entfernte Datensätze
   nach Neustart eindeutig unterscheidbar, ohne frühere Belege zu überschreiben
   oder entzogene Dokumente offenzulegen. Keine automatische Bestandsmigration.

Aktuell installierter Build und laufende private Discovery enthalten dieses neue
Werkzeug noch nicht. Code-/Vertragstest: **GO**. Verfügbarkeit im regulären Chat:
**offen bis Paket-/Discovery-Rollout und tatsächlicher Chat-Abnahme**.
