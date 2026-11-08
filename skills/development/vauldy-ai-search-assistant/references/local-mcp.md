# Aktueller lokaler MCP-Vertrag

Maßgeblich sind `Sources/VauldyMCPProtocol/ServerFactory.swift`, `OutputSchemas.swift`,
`Sources/VauldyMCPRuntime/ReadOnlyMCPRuntime.swift` und `docs/mcp-mvp.md` im ermittelten Checkout.
Die folgenden acht Werkzeuge entsprechen dem Code bei der Skillpflege. Zur Laufzeit Discovery
prüfen. Die Paketversion aus `MCPBuild.swift`, MCP-Protokollversion und Werkzeugverträge sind
getrennte Versionslinien. Die ersten vier Werkzeuge behalten ihren v1-Schemafingerabdruck.

| Werkzeug | Einsatz und Fortsetzung |
| --- | --- |
| `get_vault_status` | Zugriff, freigegebene Anzahlen und getrennte Verarbeitungsabdeckung. |
| `search_documents` | `query`, optional `limit` (Standard 5, maximal 10). Begrenzte Rangliste mit `totalCount`/`truncated`, kein vollständiges Themeninventar. |
| `list_documents` | Optionale Textfilter, `matchMode`, `includeExcerpts`, `pageSize`, `cursor`. Standard `all-tokens`; alternative Wortstämme über `any-term-substring`. Ohne Auszüge bis 100, mit Auszügen bis 25 Einträge. Alle `nextCursor`-Seiten abrufen. |
| `read_document` | Eine flüchtige Dokumentkennung, optional `view=content|metadata|passages`, `cursor`; für Fundstellen konkrete `query`. Metadaten lesen bestehende Analyse, starten keine neue. |
| `get_topic_overview` | Genau `topic=insurance` oder konkrete Wortstämme als `query`. Bis 25 Kandidaten je Seite, vollständige Cursorfortsetzung. Policenüberschriften, Erwähnungen und Beleglücken trennen. |
| `extract_document_fields` | 1–10 eindeutige Dokumentkennungen, optional 1–8 eindeutige Felder. Bei Fortsetzung genügt `cursor`. Bis acht Ergebnisabschnitte je Antwort. |
| `compare_contract_versions` | Zwei ausgewählte Dokumentkennungen als `before` und `after`. Gegenüberstellung der beschrifteten Feldtexte mit Belegen je Fassung, wenn die Zuordnung passt. |
| `get_deadline_overview` | 1–5 ausgewählte Dokumentkennungen. Feste Daten und wörtliche Fristtexte mit Seitenbelegen. Belegte Kalenderrechnung gesondert ausweisen und offene Fälle offenlassen. |

## Feldauslese

Standardfelder sind `contractType`, `cost`, `term`, `noticePeriod`. Optional sind
`contractNumber`, `issuer`, `startDate`, `endDate` verfügbar. Es werden bekannte ausdrücklich
beschriftete deutsche Angaben und alleinstehende Vertragsüberschriften aus vorhandenem
geschütztem OCR-Text gelesen. Keine neue OCR, Modellinferenz oder Ergebnispersistenz.

Jeder Wert enthält Beschriftung, Wert, physische Seite, wörtliches Zitat und Quellenreferenz.
Statuswerte: `evidenced`, `redacted`, `not-evidenced`, `source-unavailable`, `multiple-values`,
`conflicting`. Verschiedene Kostenrollen sind keine widersprüchlichen Monatsraten. Konflikte
werden auf allen verfügbaren physischen Seiten geprüft, bevor die erste Seite ausgegeben wird.
Ein gleicher Wert derselben Rolle behält den ersten Beleg und wird nicht als weiterer Vertrag gezählt.

Pro Feldabschnitt werden höchstens zwei verschiedene Belege übertragen. `evidenceCount`,
`evidenceOffset`, `evidenceComplete` und `nextCursor` beachten. `retrievalComplete` bestätigt
die vollständige Übertragung der gefundenen beschrifteten Werte, keine vollständige Vertragsanalyse.
`FIELD_EXTRACTION_INCOMPLETE` kann überlange Belege oder fortgesetzte Klauseln anzeigen.
`not-evidenced` bedeutet nicht, dass die Originalquelle das Feld sicher nicht enthält.
In beiden Fällen bei Bedarf gezielte Fundstellen lesen. PDF-interne Vertragsgrenzen werden nicht
automatisch ermittelt. Rollen und Aussagen anhand der jeweiligen Seiten prüfen.

## Freigabe, Quellen und Caches

Beim Fassungsvergleich bleiben Vertragskennung und Ausstellerabgleich lokal. Unklare
Paarzuordnung, unvollständige OCR oder mehrseitige Quellen ohne aktuelle eindeutige
Basisanalyse ergeben keine Vergleichszeilen. `before-only`/`after-only` kennzeichnen
einseitige Belege. Änderungen des Feldtextes bestätigen weder Rechtswirkung noch Reihenfolge.
Details und Abnahmekriterien stehen im aktuellen `docs/mcp-mvp.md`.

Profile gewähren exakte lokale Dokument-IDs pro Verbindung. Toolparameter, Clientnamen und
Anmeldung erweitern diese Auswahl nicht. Neue Importe bleiben unfreigegeben. Handles und Cursor
sind flüchtig, prozess-, profil- und quellengebunden. Änderungen oder Widerruf müssen alte Zugriffe
ausdrücklich sperren. Keine Freigabe-TTL und kein Rohpfad-Transport als Umgehung.

Vollständigen Kontext inklusive relevanter Metadaten lokal schützen, danach zitieren/paginieren.
Privacy-Platzhalter nicht aufteilen oder als Suchwort wegen gemeinsamer Tokenpräfixe verwechseln.
Keine reversiblen Zuordnungen persistieren. Schutzprüfung oder Auditfehler blockieren Ausgabe.
Ergebnisse sind auf getrennte Identitäts-, Text- und Sitzungscaches begrenzt. Aktuelle Limits aus
dem Code lesen, nicht durch unbeschränkte Caches oder Archivvollabruf ersetzen.

`sourceCoverage`, `processingComplete`, `coverage` und `analysisStatus` getrennt beachten.
Listen können auch freigegebene nicht suchbare Einträge zeigen. Wartende, fehlgeschlagene oder
unlokalisierte Quellen sind keine bewiesene Trefferfreiheit. Geänderte Originale machen alten
Text historisch; fehlende Originale löschen den gespeicherten Text nicht.

## Transportschichten

stdio bleibt lokal offline nutzbar. HTTP/OAuth und optionales Relay verwenden denselben
`VauldyMCPProtocol`-Dispatcher. Bei neuen Werkzeugen lokale Discovery, Relay-Allowlist in
`Sources/VauldyRelay/RelayClient.swift`, die generierte Discovery in
`cloud/chatgpt-relay/worker/index.js` und Wiretests zusammen prüfen. `export_relay_tools.py`
gleicht die Kopie mit dem tatsächlich gebauten Server ab. Ein Branch-Diff ist kein Cloud-Rollout.

Audit verwendet begrenzte technische Operationen. Die Feldauslese zählt kompatibel als `read`.
Neue Audit-Enumwerte brauchen eine Kompatibilitätsprüfung alter Leser. stdout bleibt JSON-RPC,
rohe SDK-Logs und rohe Fehler dürfen keine Inhalte oder Secrets ausgeben.

Paketaktualisierung, lokale Startprüfung und Verbindung im Chat getrennt nachweisen. Laufende
Hostprozesse können noch alte Binärdateien nutzen. Discovery allein beweist keine Antwort im
regulären ChatGPT-Gespräch. Keine produktive Verbindung für synthetische Abnahmen umhängen.
