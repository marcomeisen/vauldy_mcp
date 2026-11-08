# Clientunabhängiger lokaler MCP-Dienst

Version 0.11 importiert PDFs und Bilder und erkennt ihren Text unabhängig von der bestehenden
Vauldy-App. Der lokale Kern besitzt dafür einen eigenen Bestand. Die MCP-Schnittstelle bleibt
lesend und freigabegesteuert; die bestehende App und ihre Daten bleiben erhalten. Das Paket wird eigenständig in `marcomeisen/vauldy_mcp` entwickelt.

## Grenzen und Module

- `Sources/VauldyCore`: UI-/MCP-unabhängige Modelle, eigener Importbestand, native OCR, Snapshot-Leser
  und lexikalische Suche.
  Die Core-Ergebnisse sind **nicht** für externe Ausgabe bereinigt.
- `Sources/VauldyDocumentIntelligence`: lokale, regelbasierte Extraktion und gemeinsame Annahmeprüfung.
- `Sources/VauldyPrivacy`: eigenständig versionierte `IdentifierPrivacySession` und deterministischer
  Kennungsdetektor. Keine Quellpfadabhängigkeit zur App.
- `Sources/VauldyMCPRuntime`: lokale Verbindungsfreigabe, Datenschutzgrenze, begrenzte DTOs,
  flüchtige Dokumentkennungen, seitenbezogenes Lesen und lokale Installationsverwaltung.
- `Sources/VauldyMCPProtocol`: gemeinsamer Dispatcher und Retrieval-Anleitung für die lesenden Werkzeuge.
- `Sources/VauldyMCPServer`: standardkonformer stdio-Adapter.
- `Sources/VauldyMCPHTTP` und `Sources/VauldyOAuth`: optionaler OAuth-Anschluss für Remote-Clients.
- `Sources/VauldyMCPSetup`: eigenständiger macOS-Assistent für Import und MCP-Freigaben.
- `Sources/VauldyLocalCLI`: Import, Status, Wiederholung und Desktop-Registrierung ohne grafische Oberfläche.
- `Sources/VauldyDemoDocuments`: echte synthetische PDF-/Bildoriginale für Einrichtung und Tests.

Keine automatische öffentliche Bereitstellung, keine Cloud-Inferenz, kein automatischer Login-Dienst.
Der optionale HTTP-Dienst bindet Loopback und benötigt Betreiber-HTTPS; siehe [OAuth](mcp-oauth.md). Ein
Client mit stdio-Unterstützung startet den Server als Unterprozess. Seine eigene Cloud-Verarbeitung
liegt außerhalb Vauldys Kontrolle. Tool-Annotationen sind Hinweise; echte Berechtigungen werden
in der Runtime geprüft. Die lokale Prozess-/Benutzergrenze schützt nicht vor einem bösartigen
Programm mit denselben Dateizugriffsrechten.

## MCP-Vertrag

### Vauldy-Werkzeugvertrag v1

Der Werkzeugvertrag hat eine eigene Versionslinie. Der Basisvertrag `v1` bezeichnet die vier bisherigen Werkzeugnamen, Eingabe- und Ausgabeschemas sowie ihre Lese-Annotationen. Themenübersicht, Feldauslese und Fassungsvergleich ergänzen diesen Vertrag jeweils mit einem eigenen Antwortschema v1. Die Werkzeugverträge sind unabhängig von Vauldys Paketversion, der ausgehandelten MCP-Protokollversion und dem Format der lokalen Dateien. Clients entdecken die Werkzeuge bei der Verbindung. Der stdio-Vertragstest prüft die vier Basiswerkzeuge gegen einen festen Fingerabdruck. Die Relay-Kopie wird separat mit dem tatsächlichen Server verglichen. Eine inkompatible Änderung braucht eine neue Vertragsversion und eine Prüfung der betroffenen Clients.

| Ebene | Zuständigkeit | Bedeutung für den Chat |
| --- | --- | --- |
| Lokale Dokumentidentität | `VauldyCore` speichert die UUID im Snapshot. | Der Chat behandelt `document` als flüchtige Lesekennung. Die interne UUID bleibt lokal. |
| Seitenbeleg | `VauldyDocumentCore` liest gespeicherte Seitenmarken. `VauldyMCPRuntime` prüft ihre Verwendbarkeit und schützt den Text. | `[Quelle:<handle>:S.<seite>]` verweist auf eine physische, ab 1 gezählte Seite. Ohne eindeutige Seitenmarke gibt es einen Dokumentbeleg ohne Seitenzahl. |
| Trefferumfang | `VauldyMCPRuntime` bindet Pagination an Filter, Freigabe und Datenstand. | Der Chat unterscheidet Rangsuche, vollständig abgerufene Textkandidaten, Fundstellenauswahl und OCR-/Analyseabdeckung. |
| Ausgabe und Widerruf | `VauldyMCPRuntime` prüft Freigabe und Quellenstand. `VauldyMCPProtocol` serialisiert die vorbereiteten Ergebnisobjekte. | Der Dispatcher prüft Quelle und Freigabe nach Serialisierung und Audit erneut. Ein Fehler liefert `isError=true` ohne strukturierte Dokumentdaten. |

Archiv-UUID, Lesekennung, Quellenbeleg und Cursor sind verschiedene Werte. Ein Handle kann für denselben Datensatz im gleichen Serverprozess wiederverwendet werden, solange Dokumentinhalt und Freigabe passen. Handles und Cursor sind für den Client undurchsichtige Kennungen. Nach Neustart, Widerruf oder einem veralteten Handle muss der Client die Dokumente erneut ermitteln. Wurde ein Handle oder Listencursor wegen abweichender Daten zurückgewiesen, wird er im Prozess verworfen. Die interne UUID bleibt im lokalen Bestand erhalten.

OCR-Text bleibt bei ungültigen, doppelten oder außerhalb der deklarierten Seitenzahl liegenden Marken lesbar. Die betroffenen Abschnitte erscheinen ohne Seitenzahl. Die Quellenabdeckung bleibt in diesen Fällen ausdrücklich unvollständig oder unbekannt. Ein Fundstellenbeleg bezieht sich auf bereinigten OCR-Text. Historischer Text und unlesbare Seiten müssen im Chat als solche behandelt werden.

### Suchtext-Normalisierung

Die lokale Suche verwendet eine abgeleitete Suchprojektion (`VaultSearchText`). Sie ergänzt
bei wortähnlichen deutschen/englischen Fragmenten Suchvarianten für einen einzelnen
Zeilenumbruch nach Bindestrich sowie Soft Hyphen (U+00AD), Zero Width Space (U+200B),
Word Joiner (U+2060) und internes U+FEFF. CRLF und eingerückte Fortsetzungen werden unterstützt.
So finden „Versicherung“ und „Versiche\u00adrung“ auch einen Beleg mit „Versiche-\nrung“.

Die ursprünglichen Teilwort-Tokens bleiben suchbar. Normale Bindestriche innerhalb einer
Zeile, Zahlen, Großbuchstaben-Codes, erkannte Kennungsbeschriftungen, Absatz- und Seitengrenzen
werden nicht zusammengezogen. Die konservative Regel erfasst nicht beliebige Sprachen oder
alle denkbaren Trennungen. Eine zusätzliche Schreibvariante ist ein Suchkandidat, keine
bestätigte OCR-Korrektur oder Vertragsangabe. Mehrdeutige alphabetische Worttrennungen können
ohne Layoutwissen nicht abschließend von echten zusammengesetzten Wörtern unterschieden werden.

Listenfilter, Rangsuche und optionaler FTS-Index nutzen dieselbe Normalisierung; ihre jeweiligen
AND-/Substring-/Ranking-Verträge bleiben erhalten. Fundstellen und Themenbelege suchen nach
der vollständigen Privacy-Verarbeitung und bilden Trefferpositionen auf den unveränderten
Quelltext zurück ab. Ausgegebene Zitate enthalten deshalb weiterhin die ursprünglichen
Trennzeichen und physischen Seiten. Feldwerte und gespeicherter OCR-Text werden nicht geändert.

Die abgeleitete SQLite-Indexsemantik steigt von `user_version=2` auf `3`. Ein alter Index wird
beim nächsten ausdrücklich verwendeten Indexpfad aus dem autorisierten JSON-Stand neu aufgebaut;
das führende JSON-Format und seine Sicherung bleiben unverändert. Bestehende Profil- und
Quellenprüfungen gelten weiterhin vor der Antwort. Regression: `SearchTextNormalizationTests`
und `scripts/mcp/search_normalization_smoke_test.py` (Standard, Speicher-FTS, Datei-FTS,
Neustart/Indexversion, Quelländerung und Widerruf; ausschließlich synthetische Dokumente).

### Referenzauftrag für den Recherchepilot

Ein synthetischer Versicherungsbestand soll einen belegten Vertrag, einen reinen Textkandidaten und einen Vertrag mit fehlender Frist enthalten. Der Referenzablauf ruft alle Folgeseiten von `list_documents` ab, liest vorhandene Felder über `read_document(view="metadata")` und prüft relevante Stellen mit `read_document(view="passages")`. Der Chat trennt Kandidaten von belegten Verträgen und lässt fehlende Werte offen. Für die spätere Messung werden erwartete Treffer, Felder und Fundstellen vorab festgehalten. Vor der Ausgabe eines mehrstufigen Ergebnisses muss der Ablauf die verwendeten Quellen nochmals über den MCP prüfen.

### Werkzeugübersicht

| Tool | Eingabe | Ausgabe |
| --- | --- | --- |
| `get_vault_status` | keine | Status, getrennte Quellen- und Analyseabdeckung sowie Anzahlen ausschließlich freigegebener Dokumente |
| `search_documents` | `query`, optional `limit` (1–10, Standard 5) | Begrenzte Relevanztreffer mit `totalCount`, `truncated`, Quellenstatus und Abdeckung; niemals vollständige Liste |
| `list_documents` | optional `query`, `matchMode`, `includeExcerpts`, `pageSize` (mit Auszügen 1–25, ohne 1–100; Standard 20), `cursor` | Vollständige Seiten der autorisierten Textfiltermenge mit `totalCount`, `hasMore`, `nextCursor`, `retrievalComplete` und separater Verarbeitungsabdeckung |
| `read_document` | `document`, optional `cursor`, `view` (`content`, `metadata` oder `passages`), bei Fundstellen `query` | Textsegmente oder eine belegte logische Dokumentübersicht je Seite, jeweils mit `nextCursor` |
| `get_topic_overview` | `topic="insurance"` oder `query` mit konkreten Wortstämmen, optional `cursor` | Kompakte Übersicht mit einer Zeile je Kandidat, Seitenbeleg und, sofern vorhanden, belegtem Aussteller und Betreff. Höchstens 25 Kandidaten je Seite. |
| `extract_document_fields` | `documents` (1–10 flüchtige Kennungen), optional `fields`, bei Fortsetzung `cursor` | Ausdrücklich beschriftete Vertragsfelder mit physischer Seite und wörtlichem Beleg. Fehlende Felder, Konflikte und unterschiedliche Kostenarten getrennt. Höchstens acht Ergebnisabschnitte je Antwort. |
| `compare_contract_versions` | `before`, `after`: zwei verschiedene flüchtige Kennungen in der gewählten Reihenfolge | Gegenüberstellung ausdrücklich beschrifteter Angaben mit Belegen aus beiden Fassungen. Unklare Paarzuordnung ergibt keine Vergleichszeilen. |
| `get_deadline_overview` | `documents` (1–5 verschiedene flüchtige Kennungen) | Vertragsende, Kündigungsfrist, Kündigungsstichtag, Zahlungsfrist und Termin mit Seitenbelegen. Feste Daten, wörtlicher Fristtext, Rechnung und offene Angaben sind getrennt. |

Der separate Recherchepilot `research_insurance_contracts` ist ein Entwicklungsadapter für den
lokalen Testhost. Er führt einen festen Auftrag mit Vertragsnummern und Kündigungsfristen aus und
ist separat konfiguriert. Seine Abnahme im regulären ChatGPT-Gespräch steht aus.

#### Vertrag der Fristenübersicht v1

`get_deadline_overview` erhält die flüchtigen Kennungen von bis zu fünf ausgewählten Dokumenten
aus Suche, Liste oder Themenübersicht und liefert eine Zeile je Dokument in Aufrufreihenfolge.
Für weitere ausgewählte Dokumente einen neuen Aufruf senden. Das Werkzeug arbeitet mit
vorhandenem lokalem OCR-Text und führt das Audit unter `read`.

Pro Dokument erscheinen fünf Rollen. `endDate` umfasst Vertragsende und Laufzeitende.
`noticePeriod` enthält wörtlich beschriftete Kündigungsangaben. `cancellationDue` erfasst
„Kündigung bis“, „Kündigungsstichtag“ oder „Kündigung spätestens am“. `paymentDue` erfasst
„Zahlbar bis“, „Zahlungsfrist“ oder „Zahlung fällig am“. `appointment` erfasst „Termin“
oder „Termin am“. `explicit-date` normalisiert einen eindeutigen vollständigen Kalendertag
aus `TT.MM.JJJJ` oder ISO-Datum nach `JJJJ-MM-TT`. Bei `stated-rule` bleibt der Fristtext
wörtlich. `not-evidenced` und `unresolved` unterscheiden fehlende Belege von Konflikten,
Maskierungen, mehrdeutigen Formaten oder unvollständiger Quelle. Bis zu zwei begrenzte
Belege je Rolle enthalten den physischen Seitenverweis. `evidenceCount` und Warnungen
zeigen weitere oder zurückgehaltene Belege an.

Ein eindeutig genannter Kündigungsstichtag hat Vorrang (`calculationStatus=stated-date`).
Für `calculated` benötigt das Werkzeug eine vollständige Quelle, einen eindeutigen
Vertragskontext und auf derselben physischen Seite eine erkannte Vertragsüberschrift,
ein eindeutiges Vertragsende und eine beschriftete Kündigungsfrist nach dem Muster
„1 Monat vor Vertragsende“. Unterstützt werden positive ganze Kalendertage, Wochen und
Monate. Monatsabzug verwendet denselben Kalendertag. Fehlt er im Zielmonat, bleibt das
Ergebnis offen. Bei erkannten Bedingungen, Verlängerung oder Zugangserfordernis bleibt
die Rechnung ebenfalls offen. Das Ergebnis enthält Rechenmethode und beide Quellen.
Rechtswirkung und aktueller Vertragsstatus bleiben ungeprüft.

Der synthetische Offline-Test ist `scripts/mcp/deadline_overview_smoke_test.py`.

#### Vertrag des Fassungsvergleichs v1

`compare_contract_versions` erhält `before` und `after` für zwei ausdrücklich ausgewählte
freigegebene Dokumente. Die Reihenfolge stammt vom Aufrufer. Das Werkzeug bestimmt weder die
zeitliche Reihenfolge noch gültige Fassungen. Es startet keine Analyse oder OCR und speichert
keinen Vergleich.

Beide Quellen müssen vollständig verarbeitet sein. Bei mehrseitigen Dokumenten wird eine aktuelle,
nicht fehlgeschlagene Basisanalyse mit genau einem logischen Dokument für alle Seiten benötigt.
Eine vorhandene Basisanalyse einer Einzelseite darf ebenfalls keinen unklaren Dokumentumfang
haben. Auf Seite 1 werden eine erkannte Vertragsüberschrift sowie ausdrücklich beschriftete
Vertragskennung und Aussteller benötigt. Kennung, Kennungsart und Aussteller werden nur lokal und
ohne unscharfe Ähnlichkeit verglichen. Abweichende, mehrdeutige oder nicht belegte Zuordnung ergibt
`unresolved-pair` ohne Vergleichszeilen. Vertragskennungen werden nicht ausgegeben. Die Zuordnung
ist ein Belegabgleich, keine Garantie dafür, dass OCR alle Teile einer Sammel-PDF erkannt hat.

Verglichen werden Vertragsart, Kosten nach Rolle, Laufzeit, Kündigungsangaben, Beginn und Ende.
`different-text` und `same-text` betreffen nur den gelesenen Feldtext. `before-only` und
`after-only` bedeuten, dass eine beschriftete Angabe nur in einer Auslese belegt ist; damit
ist keine rechtliche Änderung, Ergänzung oder Streichung nachgewiesen. `not-evidenced` lässt ein
beidseitig unbelegtes Feld offen. Konflikte, Maskierungen, unvollständige oder zurückgehaltene
Belege führen zu `unresolved`. Fundstellen können anschließend gezielt gelesen werden.

Die Antwort hat höchstens 14 Rollenabschnitte und pro Abschnitt höchstens einen wörtlichen,
begrenzten Beleg je Fassung. Konfliktanzahlen zeigen an, wenn weitere Einzelbelege existieren;
für diese ist `extract_document_fields` mit seiner Pagination vorgesehen. Privacy, Freigabe und
Quellenstand werden wie bei anderen Lesewerkzeugen geprüft. Das Audit führt den Aufruf als `read`.
Der synthetische Test ist `scripts/mcp/contract_comparison_smoke_test.py`.

#### Vertrag der Feldauslese v1

`extract_document_fields` arbeitet lokal auf bereits gespeichertem OCR-Text. Es startet weder
OCR noch Modellauswertung und speichert keine fachlichen Ergebnisse. Vor jeder Ausgabe gelten
dieselben Freigabe-, Quellen- und vollständigen Privacy-Prüfungen wie beim Lesen.
Zuerst mit `search_documents`, `list_documents` oder `get_topic_overview` die passenden Kennungen
ermitteln. Anschließend zum Beispiel:

```json
{"documents":["<Kennung>"],"fields":["contractType","cost","term","noticePeriod"]}
```

Diese vier Felder sind Standard. Optional sind außerdem `contractNumber`, `issuer`, `startDate`
und `endDate` verfügbar. Die Auslese erkennt bekannte ausdrückliche deutsche Feldbeschriftungen
und alleinstehende Vertragsüberschriften. Eine Erwähnung, ein Dateiname oder der mehrdeutige
„Vertragspartner“ reicht nicht als Rollenbeleg. Geldbeträge werden weder summiert noch umgerechnet.
Jeder Beleg trägt Beschriftung, Wert, physische Seite, wörtliches Zitat und Quellenreferenz.
Mehrere logisch verschiedene Verträge innerhalb einer PDF werden nicht automatisch zugeordnet.
Die Seitenbelege erhalten, bevor Angaben demselben Vertrag zugeschrieben werden.

Statuswerte: `evidenced`, `redacted`, `not-evidenced`, `source-unavailable`, `multiple-values`
und `conflicting`. Monatsrate und Gesamtkosten ergeben unterschiedliche Kostenrollen, zwei
verschiedene Monatsraten einen Konflikt. Gleiche Werte derselben Rolle werden zusammengefasst,
der erste Seitenbeleg bleibt erhalten. Konflikte berücksichtigen auch späte Seiten, bevor die
erste Antwort ausgegeben wird. `not-evidenced` bedeutet nur, dass dieser begrenzte Auslesepfad
keinen belegbaren beschrifteten Wert gefunden hat. Bei `FIELD_EXTRACTION_INCOMPLETE` kann der
Beleg zu lang sein oder eine Klausel auf unbeschrifteten Folgezeilen weitergehen. Zur Detailprüfung
gezielt `read_document` mit `view=passages` und konkreten Wortstämmen verwenden. Verfügbarkeit
und Vollständigkeit der OCR bleiben über `sourceCoverage` gesondert sichtbar.

Je Feldabschnitt höchstens zwei verschiedene Belege, je Antwort acht Abschnitte. `evidenceCount`,
`evidenceOffset` und `evidenceComplete` beschreiben die Belegfortsetzung. Bei `nextCursor` mit
`{"cursor":"<nextCursor>"}` weiterlesen, bis `retrievalComplete=true` ist. Dieses Kennzeichen
bestätigt die vollständige Übertragung der gefundenen beschrifteten Angaben, keine vollständige
fachliche Vertragsanalyse. Wiederholte Kennungen/Feldlisten müssen identisch bleiben. Cursor
sind an Prozess, Profil und Quellenstand gebunden, maximal vier Auslesen bleiben fortsetzbar.
Überlange Eingaben oder mehr als 512 verschiedene Feldbelege pro Dokument schlagen ausdrücklich
fehl. Es gibt keine stille Abschneidung. Geänderte Quellen und widerrufene Freigaben sperren
alte Kennungen und Fortsetzungen. Das bestehende Audit zählt diesen Zugriff kompatibel als `read`.

Prüfung mit ausschließlich synthetischen Dokumenten:

```sh
python3 scripts/mcp/field_extraction_smoke_test.py .build/release/vauldy-mcp --benchmark
```

Die Messung vergleicht vollständiges seitenweises Lesen mit der Feldauslese am selben
18-seitigen Leasingvertrag. Initialisierung, Auswahl des Dokuments und Werkzeugerkennung sind
vor der Zeitmessung abgeschlossen. Kalt bedeutet hier den ersten Inhaltszugriff nach der Auswahl,
warm wiederholte Inhaltszugriffe im selben Prozess. Laufzeit, Aufrufzahl und strukturierte
Antwortgröße werden getrennt ausgewiesen. Chatmodell, Relay und Zeit bis zur sichtbaren Tabelle
sind nicht enthalten. Die neue Relay-Werkzeugkopie ist Quellcode im Branch, keine Bereitstellung.

Messung vom 05.11.2026, je zehn erste Inhaltszugriffe und zwanzig Wiederholungen:

| Zugriff auf denselben Vertrag | MCP-Aufrufe | Median erster Zugriff / P95 | Median Wiederholung / P95 | Strukturierte Antwortbytes |
| --- | --- | --- | --- | --- |
| Vollständiger Text, 18 Seiten | 6 | 392,0 / 416,9 ms | 153,0 / 240,3 ms | 30.729 |
| Vier beschriftete Vertragsfelder | 1 | 321,2 / 348,4 ms | 15,3 / 16,1 ms | 2.294 |

[Maschinenlesbarer Prüfnachweis](quality/field-extraction-benchmark.json). Der Vergleich zeigt
weniger Werkzeugrunden und weniger übertragene Inhalte. Er misst keine fertige Chatantwort
und garantiert keinen bestimmten Zeitgewinn beim realen VW-Vertrag. Die synthetischen Fristen
im Messvertrag sind numerisch beschriftet. Bei der Vorprüfung wurde ein ausgeschriebenes Zahlwort
von der bestehenden Privacy-Erkennung zusätzlich maskiert. Maskierte Werte bleiben ausdrücklich
`redacted`; die Feldauslese stellt sie nicht wieder her und lockert den Datenschutz nicht.

#### Vertrag der Themenübersicht v1

`get_topic_overview({"topic":"insurance"})` ist der Einstieg für „Zeige alle Versicherungen“.
Der Filter sucht nach `versicher polic`. Eine erkennbare, alleinstehende Policenüberschrift wird
als `policy-heading` ausgegeben. Ein belegter Texttreffer ohne diese Überschrift ist
`topic-mention`. Kandidaten ohne belastbaren physischen Beleg oder mit fehlender lesbarer Quelle
bleiben separat sichtbar. Die Zeilen zählen Quelldokumente. Mehrere Fassungen können denselben
Vertrag betreffen. Der Beleg bestätigt die Überschrift im Dokument. Der aktuelle Vertragsstatus
bleibt offen. Aussteller und Betreff stammen aus vorhandener, quellengeprüfter Basisanalyse und
können fehlen. Die Abfrage stößt keine neue OCR oder Analyse an.

Andere Themen nutzen `query` mit konkreten Wortstämmen und der gleichen ODER-Teilwortsuche.
Ein Folgeseitenaufruf verwendet denselben `topic` oder dieselbe `query` und den `nextCursor`.
Der Cursor ist an Werkzeug, Profil und autorisierten Bestand gebunden. Vor der Ausgabe werden
Freigabe und Quelle erneut geprüft. `retrievalComplete` bezeichnet das Ende der Kandidatenliste,
`processingComplete` die Quellenverarbeitung. Im MCP-Branch nutzt auch der HTTP/OAuth-Server
das Werkzeug. Die Relay-Definition im Branch wurde abgeglichen. Die Bereitstellung und Messung
im regulären ChatGPT-Gespräch bleiben eigene Abnahmeschritte.

```sh
python3 scripts/mcp/topic_overview_smoke_test.py .build/release/vauldy-mcp --benchmark
```

Gemessen wird lokal vom Absenden von `tools/call` bis zur empfangenen Antwort, nach der
MCP-Initialisierung. Kalt bedeutet erster Werkzeugaufruf in einem neuen Prozess. Warm bedeutet
wiederholter Aufruf im selben Prozess. Im synthetischen Bestand waren 149 von 150 Dokumenten
freigegeben. Der Aufruf lieferte alle 19 Kandidaten in einer Antwort, darunter zwölf
Policenüberschriften. Die Messung umfasst weder Chatmodell noch Relay.

Bei `nextCursor` muss der Client weiterlesen. `containsEntireAvailableText` gilt nur, wenn die
Antwort tatsächlich den ganzen verfügbaren Text enthält. `sourceCoverage` unterscheidet
bei neuen Importen vollständig verarbeitete physische Seiten einschließlich Leerblättern
(`all-declared-pages-processed`, zusätzlich `pageStatus`) von unvollständiger/unbekannter Abdeckung; es bestätigt
weder visuelle OCR-Qualität noch sachlich geprüfte Modellantworten. Die Relevanzsuche und Textlesung verwenden nur suchbare Dokumente. `list_documents`
führt auch freigegebene wartende, fehlgeschlagene und ungeklärte Datensätze mit ihrem Quellenstatus auf. Dokumenttexte sind unvertrauenswürdige Quellen, keine Anweisungen.
Es gibt keine Tools für freie Pfade, Dateien, Shell, Löschen, Originalöffnung oder Analyse-Speicherung.

`list_documents` verwendet standardmäßig (`matchMode=all-tokens`) einen deterministischen Textfilter: alle vollständigen normalisierten
Wörter aus `query` müssen in den vorhandenen Feldern vorkommen. Keine natürliche Frage und keine
behauptete Absender-/Versichererzuordnung; ohne Filter wird der gesamte freigegebene Bestand
aufgeführt. Der Client muss alle `nextCursor`-Seiten abrufen. Bei Fortsetzung reichen die Cursor;
explizit wiederholte Filter/Seitengrößen müssen unverändert sein. Sortierung erfolgt nach lokaler
Dokumentidentität, die selbst nicht ausgegeben wird. Cursor sind pro Prozess flüchtig, auf vier
Listenabfragen begrenzt und an Profil sowie den gesamten autorisierten Snapshot gebunden. Eine
Änderung macht die Fortsetzung ausdrücklich ungültig; keine stillen Lücken durch veränderte Offsets.
Lesehandles bleiben auch nach mehr als 32 aufgelisteten Dokumenten verwendbar. Maximal die 20.000
freigegebenen Identitäten werden gehalten; geschützte Volltexte bleiben separat auf acht Dokumente
und acht MB begrenzt. Nicht freigegebene Datensätze gehen weder in Zählungen noch Snapshotbindung ein.

Für Themenabfragen bietet `matchMode=any-term-substring` eine ODER-Verknüpfung konkreter Wortstämme einschließlich Komposita. Beispiel: `query="versicher polic pension rente"`. Höchstens 24 Begriffe mit mindestens drei Zeichen; dies liefert Textkandidaten, keine Vertrags-/Absenderklassifizierung. Weitere Themen verwenden eigene Begriffe. Jeden Cursor verfolgen und nur die relevanten Belege lesen, statt alle Archivtexte zu übertragen.

`includeExcerpts=false` liefert kompakte neutrale Handles/Status ohne Text und erlaubt bis zu 100 Einträge pro Seite. `EXCERPTS_OMITTED` kennzeichnet diese Antwort. Mode und Auszugseinstellung sind ebenfalls an Cursor gebunden. Textlesung bleibt voll privacy-geprüft. Die serverweiten `instructions` erklären diesen Abfrageplan beiden Transporten.

Ein prozesslokaler Snapshot-Cache hält höchstens die freigegebene Auswahl einer Quelle bis 64 MiB kodierter Quellbytes. R3 liest Teilfreigaben dokumentweise und prüft dabei auch nicht freigegebene Datensätze auf Format/ID-Eindeutigkeit. Vollständig freigegebene, unveränderte Dateigenerationen nutzen außerhalb des Cachebudgets wieder den schnellen Gesamtlader. Inode, Größe, Nanosekunden-mtime und ctime sowie Rechte invalidieren Änderungen; vor Ausgabe wird Quelle und Profil erneut geprüft. Größere gültige Quellen werden ohne Rohsnapshot-Cache weiter gelesen, nicht abgeschnitten. Der Audit-Schreibpfad verwendet nur bei unveränderten Dateien einen zuvor verifizierten Zustand; Rotation/fremde Schreiber/Manipulation verlangen erneute Prüfung. Kein zusätzlicher persistenter Rohindex.

`read_document(view="passages", query="hausrat pflege")` durchsucht nur das gewählte Dokument nach konkreten Wortstämmen. Die dokumentweite Privacy-Prüfung erfolgt vor der Auswahl. Zurückgegeben werden wörtliche zusammenhängende Fundstellenfenster mit physischen Seiten; nur überlappende Quellbereiche werden zusammengeführt. Höchstens acht Abschnitte à 1.000 Zeichen pro Antwort. Alle Fundstellencursor verfolgen; bis zu 16 Anfragen bleiben gebunden an Dokument, Inhalt, Profil und ursprünglichen Filter. `matchingPassageCount` zählt die ausgewählten Abschnitte, `retrievalComplete` deren vollständigen Abruf; `containsEntireAvailableText` bleibt ausdrücklich false. Dieser Modus ist keine Zusammenfassung und keine vollständige Dokumentlesung. Bei zu vielen Treffern explizit eingrenzen statt still abzuschneiden.

`retrievalComplete` bestätigt nur das Ende der konkreten Listenabfrage, nicht die fachliche
Vollständigkeit des Archivs. `processingComplete` betrifft ausschließlich Quellenverarbeitung:
`coverage` nennt suchbare, nachgewiesen seitenabgedeckte, wartende, fehlgeschlagene, prüfbedürftige,
unbekannte und im Snapshot fehlende freigegebene Datensätze. OCR-Richtigkeit ist dadurch nicht bestätigt. Die davon getrennte `analysisCoverage` meldet Basisanalysezustände für genau dieselbe Freigabemenge. Leere Treffer bei Verarbeitungslücken tragen
`SOURCE_PROCESSING_GAPS`. Auch neutrale Listeneinträge durchlaufen die Privacy-/Freigabegrenze.

Auszüge werden nach vollständiger Kontextbereinigung um die Fundstelle gewählt, statt den
Seitenanfang zu liefern. Dateinamentreffer ohne OCR-Fundseite verwenden vorhandenen lesbaren OCR-Text
vor einer Zusammenfassung. Physische Seite und unzerteilte Platzhalter bleiben erhalten. Alle
Tools deklarieren `outputSchema`; beide Antwortkanäle enthalten denselben bereinigten Vertrag.

`answer_privately` aus 0.1 wird nicht mehr extern angeboten: lokal erzeugte Antworten sind nicht
automatisch vertraulich, sobald sie ein Cloud-Chatbot erhält. `search_vault` wird durch den
freigabegeprüften `search_documents`-Vertrag ersetzt. Es gibt keinen ungeschützten Kompatibilitätsweg.

## Freigabe und Datenschutz

Der Server startet ausschließlich mit `--profile /absoluter/pfad/profile.json`. Es gibt keinen
Standardpfad zum Archiv und keinen `--vault-path`-Bypass. Die Einrichtung legt pro Verbindung eine
lokale Freigabe an: genau ausgewählte Dokument-IDs, Pfad zum Bestand, Aktivierungszustand und
bestätigter Hinweis zur möglichen Cloud-Verarbeitung. Neue Dokumente bleiben gesperrt.

Vor jeder Anfrage und vor Rückgabe der Ergebnisse wird die Freigabe neu geladen. Pausieren,
Entfernen oder Beschädigung einer Freigabe blockiert weitere Inhalte. Die Konfiguration ist eine
vertrauenswürdige lokale Verwaltungsdatei und niemals ein vom Modell veränderbarer Tool-Parameter.

Die Kennungserkennung erhält den vollständigen Dokumentkontext vor Kürzung. Danach werden nur
bereinigte Abschnitte segmentiert. Platzhalter werden nicht in Teile zerschnitten. Titel sind
neutral, Abfrage und Importdaten werden nicht zurückgespiegelt. Dauerhafte Archiv-IDs bleiben
lokal; Lesekennungen sind pro Serverlauf flüchtig und werden bei Dokument-/Freigabeänderung ungültig.
Beide MCP-Kanäle (`content` und `structuredContent`) enthalten identische bereinigte Ergebnisse.
Fehlertexte enthalten keine ursprünglichen Decoder-/Dateisystemmeldungen.

Das ist heuristische Pseudonymisierung, keine Anonymisierung oder allgemeine DSGVO-Freigabe.
Auch die ausdrücklich freigegebenen fachlichen Inhalte können personenbezogen bleiben.

Der JSON-Snapshot ist auf 128 MiB begrenzt. Neue lokale Importe und eine Freigabeauswahl sind auf 20.000 Dokumente begrenzt; eine zulässige Teilfreigabe bleibt auch aus einem größeren bestehenden Datensatzbestand lesbar. Für ausdrücklich neu angelegte Bestände bindet R3b einen lokalen SQLite-Record-Store an Worker, Verwaltung und MCP an (Formatmarker 3, Schema 2). Bestehende Bestände bleiben JSON. R3c bietet ausdrücklich angeforderte additive CLI-Migration, geprüftes Backup/Restore und Rückweg nach JSON; bestehende Profile und Importpfade werden dabei nicht umgestellt. R3d hat den angebundenen SQLite-Pfad mit 1k/2k/5k/10k/20k langen synthetischen Dokumenten gemessen. Kleine Freigaben von 100 Dokumenten bestehen die lokalen Gates; große Vollfreigaben sind NO-GO (20k: erster Status 9,21 s, unvollständige Listen-P95-Stichprobe 11,82 s, Server-RSS rund 1,17 GiB und Filter-Timeout nach 30 s). Vollständige Pagination, Widerruf und Wiederanlauf sind geprüft. R3d.1 liest Status und ungefilterte kompakte Listen aus kleinen transaktionalen SQLite-Projektionen. Bei 20k Vollfreigaben misst der lokale Test 318 ms für den ersten Status und 155 ms Listen-P95. Ältere SQLite-Bestände nutzen den bisherigen Lesepfad bis zum ausdrücklichen Aufbau per CLI. R3d.2 ergänzt den transaktionalen SQLite-Suchindex für Wort- und Teilwortfilter, gerankte Kandidaten und Themenübersichten. Die Belege werden weiterhin aus dem Originaltext gelesen und vor der Ausgabe geschützt. Der Versicherungsfilter liefert bei 20k synthetischen Vollfreigaben 5.000 Treffer in 417 ms. R3d.3 bestätigt schnelle kompakte Filter und seltene Rangtreffer während nativer OCR bei 20k Vollfreigaben. In R3d.3 überschritt die breite Rangsuche das 15-Sekunden-Limit. R3d.4 wertet Einwortabfragen anhand transaktionaler Rangprojektionen aus. Bei 20k Vollfreigaben liegt der P95 für „Versicherung“ bei 879 ms im ruhenden Bestand und 1,13 s während OCR. Die erneute synthetische Lastprüfung und der Wiederanlauf nach Indexabbruch bei 20k bestanden. Mehrwortphrasen behalten die bisherige Bewertung. [Rangprojektionen und Wiederholungsprüfung](storage-r3d4.md). [Gemeinsame Lastprüfung](storage-r3d3.md). [Suchindex und Prüfwerte](storage-r3d2.md). [R3d.1 und CLI-Aufbau](storage-r3d1.md), [R3d-Ausgangsmessung](storage-r3d.md). MCP liest nur freigegebene Zeilen und bindet Antworten, Handles, Cursor und Index zusätzlich an die Transaktionsgeneration. [R3-Grenzen](storage-r3.md), [R3b-Anbindung und Prüfungen](storage-r3b.md), [R3c-Migration und Rückweg](storage-r3c.md). Der Datenschutzkontext eines Dokuments
ist auf 1 MB begrenzt. Textsegmente sind höchstens 6.000 Zeichen lang, Antworten höchstens 180 KB.
Überschreitungen führen zu ausdrücklichen Fehlern.
Der Kern liest Such-Snapshots pro Anfrage. Ein begrenzter prozesslokaler Suchindex bereitet nur
geänderte Dokumente neu vor; bereinigte Textfassungen werden versions- und freigabegebunden wiederverwendet.

## Unabhängiger Import und OCR

`LocalDocumentStore` schreibt ausschließlich seinen markierten eigenen Bestand. Ein fremdes oder
beschädigtes Archiv wird ausdrücklich abgelehnt. Ordnerimporte referenzieren Originale über
schreibgeschützte Security-Scoped Bookmarks; temporäre Einzelimporte behalten eine lokale Kopie.
Beide Pfade werden über SHA-256 dedupliziert und vor Wiederholung erneut geprüft. Atomare Snapshots, vorheriger gültiger
Snapshot als Sicherung, private Dateirechte und prozessübergreifende Schreibsperren sichern den Zustand.
Der Speicher ist lokal, aber nicht zusätzlich anwendungsseitig verschlüsselt.

`LocalImportService` persistiert queued/recognizing/completed/partial/failed/interrupted/cancelled.
Eine Prozesssperre lässt nur einen nativen OCR-Lauf pro Bestand zu. Abbruch hält diese Sperre bis zum
wirklichen Ende der System-OCR; ein abgebrochener Lauf darf keinen vollständigen Erfolg speichern.
Nach einem Prozessabbruch wird ein verwaistes recognizing beim Öffnen/Status/Import erkannt. Wiederholen
nutzt das lokale Original. `LocalImportWorker` hält eine private dateibasierte Warteschlange mit genau einem Worker pro Bestand.
CLI und Assistent starten dasselbe Programm bei Bedarf ohne Netzwerkport. Der Prozess überlebt das
anfragende Fenster, beendet sich ohne aktive Ordnerüberwachung nach 120 Sekunden Leerlauf und lässt sich nach dem aktiven Auftrag
stoppen. Wartende Clients starten einen abgestürzten Worker höchstens dreimal neu. Kein Login-Agent
wird registriert; ohne Client wird erst beim nächsten Auftrag wieder aufgenommen.

`PDFContentInspection` verfolgt Grafiktransformationen und Formressourcen. Textbasierte Formen bleiben
im direkten Textpfad, kleine getrennte Rasterbereiche werden einzeln erkannt. Unklare/überlappende oder
große Bildinhalte bleiben auf vollständiger Seiten-OCR. Inline-Bilder fallen konservativ zurück.
`NativeLocalDocumentOCR` verwendet genaue Vision-OCR, angepasste Schriftauflösung und überlappende
Teilbilder für lange Belege. Kein fachlicher Inhalt wird allein wegen geringer Fläche verworfen.
Physische Seiten, Leerblätter, unlesbare Seiten und echte OCR-Konfidenzen bleiben unterscheidbar.
Die Grenzen sind 50 MiB Original, 200 Seiten, 900 KB Text und 3072 Pixel längste OCR-Bildkante. Lange Bildoriginale werden bis höchstens 12288 Pixel
dekodiert und vor OCR in Teilbilder zerlegt; breite/rotierte Sonderfälle bleiben konservativ prüfpflichtig.
Native Aufrufe laufen seriell außerhalb des UI-Threads; es gibt keinen Timeout, der noch aktive
native Arbeit als beendet behandelt. Ein kalter System-OCR-Start kann deutlich länger dauern. Inhaltsfreie Messungen trennen Prüfung,
Rendering, native Erkennung, Speicherung und Cache. `LocalOCRPageCache` hält höchstens 32 Original-/
Konfigurationsfassungen. Er speichert nur vollständige Seiten ohne Review-Signal, bleibt lokal,
übersteht Worker-Neustarts und wird bei `retry --fresh` umgangen. OCR-Methode und Konfidenz bleiben erhalten.

Der OCR-Zweitlauf arbeitet auf bereits erkannten, räumlich zugeordneten Zeilen. Geringe
Zeilenkonfidenz, Kleindruck unter 16 Pixeln und bestimmte Verwechslungsmuster in beschrifteten
Kennungen lösen eine gezielte Prüfung aus. Pro physischer Seite sind höchstens vier weitere
Vision-Anfragen erlaubt, auch bei mehreren Bildregionen. Der Zweitlauf vergrößert den Ausschnitt
und liest Kennungen ohne Sprachkorrektur. Bei widersprüchlichen Zahlen oder Kennungen bleibt der
erste Text erhalten und die Seite wird zur Prüfung markiert. Auffällige Kennungen können auch bei
zwei übereinstimmenden Lesarten prüfpflichtig bleiben. Eine Textergänzung braucht räumliche und
textliche Übereinstimmung und darf erkannte Zahlen nicht ändern. Vollständig unerkannt gebliebene
Zeilen lassen sich mit diesem Verfahren nicht nachprüfen. Die lokale Cache-Konfiguration v4 hält
alte OCR-Zwischenstände von diesem Pfad getrennt. Vorhandene Dokumente werden beim Update nicht
automatisch neu gelesen.

Import führt nach erfolgreicher Texterfassung eine lokale regelbasierte Basisanalyse aus.
Sie verwendet ausschließlich vorhandene Quellen. Es werden keine Modelle geladen und keine
Cloud-Anbieter aufgerufen. Details und Grenzen: [Basisanalyse](base-analysis.md). Neue Dokumente
sind nicht automatisch freigegeben. Ein MCP-Client bekommt ausschließlich freigegebene, bereinigte
Texte über dieselbe Datenschutzgrenze. CLI-Importpfade werden niemals MCP-Toolparameter.

### Vergleich des OCR-Zweitlaufs

Nach dem Aufwärmen der nativen Erkennung wurden identische synthetische Dateien abwechselnd
zuerst mit dem bisherigen Pfad und zuerst mit Zweitlauf gelesen. Die Messwerte pro Fall umfassen
die native Erkennungsphase ohne Rendering oder Speicherung. Jeder Fall ist eine Einzelmessung.

| Synthetischer Fall | Exakte Felder vorher → nachher | Zusätzliche Vision-Aufrufe | Prüfmarkierung vorher → nachher | OCR-Zeit vorher → nachher |
| --- | ---: | ---: | --- | ---: |
| Saubere Kontrolle | 4 → 4 | 0 | nein → nein | 104 → 104 ms |
| Kleindruck | 4 → 4 | 0 | nein → nein | 103 → 101 ms |
| Blasse Kopie | 4 → 4 | 0 | nein → nein | 135 → 114 ms |
| Schräger Scan | 4 → 4 | 0 | nein → nein | 104 → 110 ms |
| Blasses Raster-PDF | 0 → 0 | 4 | nein → ja | 182 → 354 ms |
| Ähnliche Zeichen in Policennummer | 3 → 3 | 1 | nein → ja | 109 → 190 ms |
| Eng gesetzte Beträge | 4 → 4 | 0 | nein → nein | 102 → 108 ms |

Beide Pfade lieferten 23 von 28 Feldern exakt. Die fünf zusätzlichen OCR-Anfragen ergaben
keine akzeptierte Textersetzung. Die beiden Prüfmarkierungen decken die im Test bekannten
Probleme ab. Die fehlerhafte Policennummer blieb bei der Erstlesart und wurde zur Prüfung markiert.

```sh
swift test --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none \
  --no-parallel --filter OCRTargetedRetryTests
```

## Bauen, Paket und Prüfung

```sh
swift test --disable-sandbox
swift build --product vauldy-mcp
python3 scripts/mcp/smoke_test.py /absoluter/pfad/zum/gebauten/vauldy-mcp
python3 scripts/mcp/import_smoke_test.py /absoluter/pfad/vauldy-local /absoluter/pfad/vauldy-mcp
python3 scripts/mcp/benchmark_ocr.py /absoluter/pfad/vauldy-local
python3 scripts/mcp/audit_smoke_test.py /absoluter/pfad/vauldy-local
python3 scripts/mcp/package.py
```

Der Python-Protokolltest startet das echte Binary und verwendet ausschließlich synthetische
Bestände. Er prüft beide Ausgabekanäle, Ablehnung ohne Freigabe, Dokumentgrenzen, Widerruf,
unerlaubte Argumente und unveränderte Archivbytes. Swift-Tests prüfen zusätzlich Kontextbereinigung,
Änderungen zwischen Such-/Leseaufrufen, seitenübergreifende Namen, Pagination und Installation.
Sie benötigen keinen Xcode-App-Testhost und keinen echten Vault.

Die Einrichtung kann für isolierte UI-Prüfungen mit `--setup-root /absoluter/testpfad` gestartet
werden. Das ist ausschließlich ein lokales Startargument, kein MCP-Werkzeug. Beim Test das
künstliche Beispiel verwenden. Auch die Registrierung wird dabei nach `<testpfad>/test-client-home`
umgeleitet; produktive Client-Konfigurationen bleiben unberührt. `MCPClientRegistration` wird vom
Wizard und `vauldy-local connect` geteilt. Es ergänzt ChatGPT-TOML bzw. Claude-JSON, sichert bestehende
Dateien und verweigert Konflikte. Der MCP-Kern bleibt unabhängig von der Client-Registrierung.

Installationsanleitung, Widerruf und Signierungsgrenzen: [mcp-installation.md](mcp-installation.md).

## Weitere Ausbaustufen

1. Gemeinsamer revisionssicherer Dienst vor schreibenden MCP-Funktionen.
2. Optionalen Login-Dienst und einen persistenten Datenbank-Suchindex für große Bestände prüfen.
3. Lokale Originalöffnung mit vertrauenswürdiger Nutzeraktion.
4. Geprüfte Analysevorschläge, Korrektur und Widerruf als getrennte Schreibberechtigungen.
5. Client-Pakete und unterstützte Remote-Adapter separat gegen deren tatsächliche Fähigkeiten prüfen.

## Prüfstand

Die reproduzierbaren Tests verwenden ausschließlich künstliche Originale und isolierte Bestände.
`LocalImportTests` prüft echte Vision-OCR, gemischte und gescannte PDFs, PNG, Leerblätter, fehlende
Seiten, Dubletten, Abbruch bis zum tatsächlichen Worker-Ende, Wiederholung, Originalintegrität,
Dateigrößenlimits, beschädigte/fremde Bestände und konkurrierende Schreibzugriffe.
`import_smoke_test.py` prüft CLI-Import, Worker-Wiederverwendung, MCP-Weitergabe, Widerruf, Cache/frische
Erkennung und eine zwischen Prozessen gehaltene OCR-Sperre samt gemeinsamem Warten auf einen Auftrag.
Die Tests in `LocalImportTests` simulieren einen verwaisten Lauf; das ist kein erzwungener Systemcrash.
`LocalWorkerTests` prüft Leerlaufende, getrennte Warteschlangenaufträge und Abbruch vor/nach nativer
Übernahme. Native Bildtests prüfen Text-/Raster-PDF, Formobjekte, kleine Bildbereiche und lange PNG-Belege.

Den konkret ausgeführten Paket-/UI-Prüfstand hält `dist/mcp/VERIFICATION.txt` neben dem ZIP fest.
Nicht nachgewiesen: Live-Nutzung in ChatGPT/Claude, Intel-/ältere-macOS-Kompatibilität,
Qualität komplexer echter Dokumente, Verschlüsselung des Bestands oder rechtliche Gesamtfreigabe.

## Eigenständige Ordnerüberwachung

`LocalWatchedFolderStore` speichert bis zu 32 lokale Ordner pro markiertem Bestand atomar und mit
Prozesssperre. Assistent und CLI konfigurieren mehrere Ordner, optionale Rekursion sowie Pause/Entfernen.
`LocalWatchedFolderMonitor` prüft im vorhandenen Worker alle fünf Sekunden zwischen OCR-Aufträgen,
wartet zwei unveränderte Beobachtungen ab und übergibt Originale an dieselbe dauerhafte Importqueue.
Der Worker bleibt bei aktivierten Ordnern am Leben; Stop beendet ihn nach dem laufenden Auftrag.
Kein Login-Agent, kein zusätzlicher Netzwerkdienst und keine Änderung der MCP-Dokumentfreigaben.
Nach Prozess-/Mac-Neustart nimmt Öffnen der Einrichtung oder `watch-start` die Überwachung wieder auf.

Versteckte Dateien, Paketinhalte und Symlinks werden übersprungen. Eigener Bestand, darunterliegende
Ordner und ihn enthaltende Ordner sind ausgeschlossen. Scans sind auf 20.000 Einträge je Ordner
begrenzt; insgesamt werden höchstens 20.000 Dateisignaturen und 100 Übergaben pro Scan gehalten. Fehler werden über lokale Statuscodes sichtbar. Unveränderte Dateien werden pro Prozess
übersprungen, nach Neustart prüft der Importer erneut den SHA-256-Hash. Änderungen erzeugen neue
Originale, Entfernung löscht keine Dokumente. Vorhandene Partial-/Fehlerergebnisse bleiben für eine
explizite Wiederholung erhalten. Die MCP-Schnittstelle bleibt unverändert lesend.

`LocalWatchedFolderTests` prüft Mehrfachordner, konkurrierende Konfiguration, Schutz vor beschädigten
Listen/Vault-Überlappung, Rekursion, Symlinks, stabile Dateien, Änderungen, Fehlerwiederholung,
Deduplizierung und Worker-Leerlauf. `scripts/mcp/watch_smoke_test.py` prüft echte Hintergrundprozesse,
PDF-/Bild-OCR, Pause, Neustart und unveränderte Freigaben über MCP mit isolierten künstlichen Dateien.

Native Paketprüfung mit isoliertem `--setup-root`: Zwei Ordner gemeinsam ausgewählt, einen pausiert
und entfernt, künstliches PDF automatisch vollständig erkannt und in der aktualisierten Dokumentliste
weiterhin unausgewählt angezeigt. Reale iCloud-/OneDrive-Ordner sind damit nicht live geprüft.

## Native Verwaltung und Menüleistenstatus (0.7)

Die Setup-App verwendet fünf Bereiche: Übersicht, Verbindungen, Dokumente, Ordner und Einstellungen.
Der vierstufige Assistent trennt Clientauswahl, Dokumentauswahl, Empfänger-/Cloud-Einwilligung und echten lokalen MCP-Test. Ein lokaler Test bestätigt keinen Chatbot- oder Cloud-Zugriff.
`MCPAccessProfile.desktopClient` ist optionale, rückwärtskompatible lokale Metadaten; ein tatsächlicher Client-Eintrag wird separat und nur lesend geprüft. Manuelle/ältere Profile werden nicht still einem Client zugeordnet.

`MCPInstallation.updateSoftware` tauscht Server/CLI, Menühelfer und Verwaltungsbundle unter einer eigenen Sperre aus; bestehende Profile und Client-Einträge bleiben unverändert. `softwareStatus` vergleicht die ausführbaren Programme per SHA256 und berücksichtigt fehlende Komponenten. Laufende ältere Server benötigen einen Neustart im Chatbot. Eine Bestandsinstallation erhält beim Update die Verwaltungs-App für Menü-Einstiege.

`setAccess` und `updateSelection` serialisieren Profiländerungen über eine gemeinsame lokale Sperre. Revisionsprüfung verhindert, dass ein veralteter Entwurf eine zwischenzeitliche Pause überschreibt. Zusätzliche IDs benötigen neue Einwilligung; Speichern erhält den Pausenzustand, eine leere Auswahl sperrt. Pause bleibt auch während des Imports erreichbar.

`MCPProcessPresence` hält je Server eine leere UUID-Marke mit OS-flock. Begrenzte private Metadaten ergänzen Verbindungs-ID, Buildversion, Diagnoseflag und letzten Werkzeuganfragezeitpunkt, ohne Dokumentinhalte, Dokument-IDs, Suchanfragen, Pfade oder PID. Ausschließlich die aktive Sperre beweist Prozesslebendigkeit; normales Ende und SIGKILL geben sie frei. Diagnoseprozesse werden in der UI nicht als Chatbot-Nutzung gezählt. Alte unzuordenbare Marken ergeben einen unklaren Zustand.

`VauldyMCPStatus` liest Serverzustände alle zwei Sekunden, Ordnerzustände alle zehn Sekunden. Das Menü bietet pro Verbindung Freigabe-/Serverzustand, Pause/Fortsetzen mit Bestätigung, Dokumentauswahl und Diagnose. Ordnersteuerung bleibt separat; Beenden stoppt nur den Beobachter. Die feste Menüsperre verhindert mehrere Symbole pro Root. Geöffnete Menüs werden während der Interaktion nicht neu aufgebaut.

Menü-Einstiege schreiben einen begrenzten, typisierten, höchstens fünf Minuten gültigen `MCPSetupRequest` und öffnen das installierte Verwaltungsbundle. Dieser Kanal erlaubt Navigation und lesende Diagnose, keine Freigabeänderungen. Benutzerdefinierte Testwurzeln werden durchgereicht und leiten Clientkonfigurationen in ihr eigenes Test-Home um. Kein Netzwerkdienst und kein Login-Agent.

`MCPLocalProbe` führt einen begrenzten echten stdio-Handshake plus `get_vault_status` mit eigenem Diagnoseprozess aus. Keine Inhalte werden abgerufen; temporäre Dateien und der Kindprozess werden anschließend entfernt. Verfügbar über UI und `vauldy-local check-connection --profile …`.

`MCPManagementTests` prüfen bytegenau erhaltene pausierte Profile, Auswahl-/Revisionsregeln, Legacy-Decodierung, lesende Clientprüfung, Diagnoseausschluss, veraltete Server und einmalige Menü-Navigation. Bestehende Installations-, Datenschutz-, Import-, Ordner- und Sperrentests bleiben erhalten. Paketprüfungen verwenden ausschließlich künstliche Daten und isolierte Clientkonfigurationen.


## Build- und Fähigkeitsdiagnose (R4)

Die Produktversion in CLI, Paket und Dokument-DTOs bleibt `MCPBuild.version`. Die
MCP-Initialisierung ergänzt in `serverInfo.version` SemVer-Buildmetadaten:
`0.13.0+macho.<32 Hexzeichen>`. Die Kennung ist die LC_UUID des **geladenen** Hauptprogramms;
sie bleibt für einen alten Prozess auch nach Austausch seiner Datei erhalten. Sie ist weder
Git-Commit noch Signatur oder Vertrauensnachweis. Unterschiedliche Programme desselben Pakets
haben eigene Kennungen. Produktversion und Build getrennt vergleichen.

`vauldy-mcp --build-info` meldet Version, eigenen Build, Kompatibilitätsepoche, aktuellen
Dokumentspeicher (`json-snapshot`) und die tatsächlichen acht Werkzeugnamen. `tools/list`
bleibt die Laufzeitautorität. `vauldy-local check-connection --profile …` prüft die vollständige,
begrenzt paginierte Discovery, lokalen Status und die Übereinstimmung mit dem gestarteten
Programm. Fehlende Werkzeuge ergeben einen diagnostizierten inkompatiblen Stand; ein
pausierter Zugriff ist von einem Startfehler getrennt. Die vier Basiswerkzeuge bleiben
für die Protokollprüfung und ältere, kompatible Rollbackpakete erforderlich.

Neue signierte Paketmanifeste deklarieren Server-Build und Werkzeugliste. Der Updater prüft
Datei-ID und tatsächliche Startantwort gegen diese Angaben. Alte Manifeste bleiben lesbar;
sie erhalten dadurch keine nachträgliche Bestätigung neuer Fähigkeiten. Ein lokaler Probe
oder ein beobachteter MCP-Aufruf beweist keine sichtbare Antwort im externen Chat.
Details und synthetische Prüfungen: [R4-Bericht](build-diagnosis-r4.md).

## Ergänzung: Dokumentinventar · 08.11.2026

Der MCP-Arbeitsbranch bietet zusätzlich `get_document_inventory` (eigener Vertrag
Version 1): stabile `documentID`, ursprüngliches `importedAt`, belegter SHA-256
der zuletzt importierten Originalbytes sowie Zustand/Verarbeitungsabdeckung.
Aktuell autorisierte Datensätze werden vor der Pagination nach Importdatum
sortiert; unbekannte Daten stehen zuletzt. `documentID` ersetzt kein Lesehandle.
Fehlende Inventarzeilen beweisen keine Löschung. Die vier gepinnten v1-
Basisverträge bleiben unverändert. Discovery/Relay-Quellen berücksichtigen damit
neun Werkzeuge; ein laufender Anschluss benötigt einen separaten Rollout.
[Vertrag, Grenzen, Nachweis und nächste Aufgaben](document-inventory.md).
