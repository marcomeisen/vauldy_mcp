# Review: Architektur, Security, UX/UI

Stand: 16.11.2026, `main` @ `24476d1`, Produktversion 0.14.6. Nur Quelltext gelesen.
Nichts gebaut, keine Tests/OCR/Installer gestartet, keine Profile, Schlüsselbund-Einträge
oder Originale berührt. Die Befunde stammen aus drei getrennten Teilreviews. Die als
„✔ geprüft“ markierten wurden zusätzlich direkt im Code nachvollzogen. Laufzeitwirkungen
(Latenz, Kontrast, VoiceOver) sind abgeleitet, nicht gemessen.

## Gesamturteil

Die Abhängigkeiten zwischen den Modulen laufen sauber in eine Richtung. Der lokale
stdio-Server ist tatsächlich die einzige Privacy-Grenze, und Revalidierung,
Handle-/Cursor-Bindung sowie die im Zweifel sperrende Ausgabeprüfung sind ernsthaft
umgesetzt. Einen kritischen Security-Befund gibt es nicht. Die größten Schwächen liegen an
den Rändern:

- Der Cloud-Relay hat sich vom lokalen Vertrag entfernt und verhält sich bei Fehlern schlecht.
- Der OAuth-Weg verlässt sich bei der Zustimmung auf den visuellen Vergleich eines Codes.
- Die Setup-App ist für Laien zu technisch und sichert destruktive Aktionen uneinheitlich ab.

Von den P1-Befunden der Review vom 06.11. sind drei behoben und zwei teilweise.

---

## 1. Architektur

### Stand der P1-Befunde vom 06.11.
| Befund | Status |
|---|---|
| Globale Grenze von 20.000 Dokumenten vor dem Freigabefilter | **behoben**: Streaming plus Filter (`FileVaultSnapshotSource.swift:63-73`), Test mit 20.001 Dokumenten |
| Cachegrenze, wiederholtes JSON-Dekodieren | **teilweise**: Budget nach freigegebenen Bytes; über 64/96 MiB wird der JSON-Pfad weiterhin bei jedem Aufruf neu gestreamt |
| Suche über Worttrennungen | **behoben** (`VaultSearchText`) |
| OCR-Zweitlauf | **teilweise**: Detail-Renderer und Abdeckungsprüfung; Wirkung an realen Archiven nicht belegt |
| Version und Fähigkeiten | **lokal behoben**; im Relay offen (siehe A1) |

### P1
**A1: Der Relay weicht vom lokalen MCP-Vertrag ab** ✔ geprüft
- Beleg: `cloud/chatgpt-relay/worker/index.js:51`. `INSTRUCTIONS` hat rund 490 Zeichen und wird von Hand gepflegt. `ServerFactory.swift:155-162` liefert rund 3.000 Zeichen.
- Weiterer Beleg: `index.js:85` trägt fest `serverInfo.version:'0.12.1'` ein. `export_relay_tools.py --check` prüft nur `TOOLS`.
- Folge: ChatGPT, der wichtigste Client, bekommt andere Retrieval-Regeln, z. B. keine Hinweise zu any-term-substring, Fristen und Inventar. Die Diagnose zeigt eine falsche Version.
- Nächster Schritt: Instruktionen und Version aus derselben Quelle generieren und in die Paritätsprüfung aufnehmen.

**A2: Ein Fehler im Relay wird für den Nutzer zu 60 s Hänger; Aufrufe laufen nur seriell** ✔ geprüft
- Beleg: `VauldyRelayAgent/main.swift:86-91`. Scheitert `local.call`, wird kein Ergebnis zurückgesendet („Its caller gets a timeout“). Die TTL beträgt 60 s.
- Weiterer Beleg: `RelayLocalMCP.call` lässt nur einen Aufruf gleichzeitig zu, die Abfrage läuft alle ≥ 750 ms, und der Worker fragt D1 alle 250 ms ab.
- Nächster Schritt: Ein verschlüsseltes Fehlerergebnis sofort zurücksenden, gebunden an Job und Richtung. Dadurch wird der Job nicht erneut ausgeführt, die Invariante „kein Replay“ bleibt also gewahrt. Danach begrenzte Parallelität bzw. Long-Poll messen.

**A3: `ReadOnlyMCPRuntime` trägt eine Matrix aus Backend und Flags**
- Beleg: rund 30 veränderliche Zustände und 5 Sitzungsarten (`ReadOnlyMCPRuntime.swift:18-104`). JSON und SQLite sind in jeder Methode getrennt verzweigt.
- Weiterer Beleg: Die Flags `memoryTokenIndex`, `persistentTokenIndex`, `largerSnapshotCache` und `compactProjection` setzt keine Clientregistrierung. Produktiv läuft also nur der Default.
- Weiterer Beleg: Die Freigabeprüfung ist doppelt implementiert (`:912-918`, `:1003-1008`).
- Nächster Schritt: Ein Protokoll `GrantedDocumentSource` für beide Backends einführen und die Sitzungsverwaltung als eigenen Typ auslagern. Ungenutzte Flags entfernen oder auf einen Testbuild beschränken.

### P2
- **A4: Fehlerursachen gehen verloren** ✔ geprüft. Bei `ReadOnlyMCPRuntime.swift:1032` wird jeder Fehler zu `.unavailable`, auch `.stale` und `CancellationError`. Bei gleichzeitigem Schreiben meldet der Chat „Bestand nicht lesbar“ statt „erneut suchen“.
- **A5: Speichergrenzen und Benennung.**
  - Die „JSON compatibility limits“ (20.000 Dokumente) gelten auch für SQLite.
  - `max_page_count` ist mit dem Kommentar „1 GiB until R3d load acceptance“ fest gesetzt.
  - Die führende Datenbank liegt in `SQLiteDocumentStorePilot.swift`.
- **A6: Exklusive `flock` auch beim Lesen.** Grundlage ist die serielle `io`-Queue in `LocalDocumentStore.swift:52`, die Sperre wartet ohne Timeout (`:466`). `isSQLite` liest `store.json` bei jedem Zugriff neu. Die UI wartet dadurch hinter Worker oder Migration.
- **A7: Wildwuchs an OCR-Heuristiken.**
  - 23 Hilfsdateien mit rund 2.000 Zeilen.
  - 7 boolesche Modus-Flags in langen Parameterlisten; die Konfigurationskennung entsteht per String-Verkettung (`NativeLocalDocumentOCR.swift:10-47`).
  - Domänenspezifische Reparaturen wie `OCRPolicyIdentifierRepair`.
  - Vorschlag: eine `OCRPass`-Pipeline mit deklarativer Konfiguration und je Regel ein Negativ-Korpus über mehrere Dokumenttypen (vgl. AGENTS.md „dokumenttypübergreifend“).
- **A8: Lücken in der Regression.** Folgende Tests fehlen in `regression_test.py`:
  - `sqlite_primary_smoke_test`, obwohl `docs/storage-sqlite-primary.md:56` ihn als Nachweis nennt
  - `storage_legacy_writer_smoke_test`
  - die OCR-Gates `ocr_policy_repair`, `ocr_field_recovery`, `ocr_numeric_recovery` und `ocr_source_punctuation_quality_gate`
- **A9: Runtime-Modul enthält Verwaltungslogik.** `MCPSoftwareUpdate`, `MCPClientRegistration`, `MCPInstallation`, `MCPProcessPresence` und `MCPLocalProbe` liegen im Modul der Privacy-Grenze. Vorschlag: `VauldyMCPManagement` herauslösen.
- **A10: Argumentprüfung getrennt vom JSON-Schema.** Ein großer `switch` in `ServerFactory.swift:31-127`. Vorschlag: pro Werkzeug ein `Decodable`-Typ, der Schema und Prüfung vereint.

### P3
- **Versionsachsen ohne Übersicht:** Store-Marker 3…4 vs. 4, SQLite `user_version`, Token-Index v3, OCR v19, `VauldyRelay-v1`. Eine Kompatibilitätstabelle mit Test fehlt.
- **Toter oder Pilot-Code:**
  - `VaultRuntime.answerPrivately` (nur in Tests benutzt)
  - `VauldyResearchMCP` mit fester Versicherungstabelle
  - `PersistentMCPIndex` und `SQLiteVaultTokenIndex`, die nur an ungenutzten Flags hängen
- **Code-Dichte:** Zeilen bis 1.639 Zeichen (`VauldyLocalCLI/main.swift`, `ServerFactory.swift`) erschweren Diffs und Reviews.
- **Ein einziges Testtarget:** Es hängt auch vom Executable `VauldyMCPSetup` ab. Testtargets pro Modul würden die Grenzen schärfen.
- **Wenige Sitzungen:** Nur 4 List- bzw. 4 Feldsitzungen; parallele Paginierung kann Cursor verdrängen.

---

## 2. Security und Privacy

### Hoch
**S1: OAuth – eingeschleuste Freigabeanfrage und verwechselte Zustimmung** ✔ geprüft
- Beleg: `OAuthWebService.swift:60-71` (offene DCR, `/oauth/authorize`). Dazu `OAuthAuthorization.swift:31-49` und `:77-92`: Der Code geht an den Browser, der die Anfrage begonnen hat.
- Szenario:
  1. Ein Dritter erreicht den öffentlichen TLS-Endpunkt und registriert einen Client mit einer Redirect-URI auf chatgpt.com oder claude.ai.
  2. Er startet `/authorize` mit eigenem PKCE. In der App erscheint eine Anfrage mit dem Label „ChatGPT“/„Claude“, das nur aus dem Host abgeleitet ist.
  3. Bestätigt der Eigentümer diese Zeile, erhält der Browser des Angreifers den Code mitsamt `state` und kann ihn mit seinem Verifier einlösen.
- Einziger Schutz ist der visuelle Vergleich der 8-stelligen Kennung. Mit bis zu 128 gleichzeitigen Anfragen lässt sich eine Verwechslung provozieren.
- Relevant ist das nur, wenn der HTTP/OAuth-Weg öffentlich bereitgestellt ist.
- Empfehlung:
  - Die Kennung in der App eintippen lassen statt nur vergleichen.
  - Anfragen nur annehmen, solange lokal ein Verbindungsvorgang aktiv ist.
  - Client-ID, Redirect und Erstellzeit anzeigen.
  - Je Quelle begrenzen.

### Mittel
- **S2: Unauthentifizierter DoS auf OAuth.**
  - Bis zu 256 Clients, inaktive werden erst nach 24 h entfernt (`OAuthStore.swift:66`).
  - Bis zu 128 offene Anfragen; jede schreibt die bis zu 4 MB große JSON-Datei mit fsync.
  - 64 Verbindungen mit je 40 s Timeout.
  - Empfehlung: Rate-Limit, eigenes Kontingent für CIMD-Clients, ungenutzte Registrierungen nach Minuten entfernen, kürzeres Header-Timeout.
- **S3: Relay-Agent löscht die Gerätekopplung bei einer Stopp-Anfrage** ✔ geprüft.
  - Beleg: `VauldyRelayAgent/main.swift:80`. `guard !service.stopRequested … else { throw RelayFailure.signInRequired }` führt bei `:85` zu `clearDevice`.
  - Folge: Trennen, `updateGrant` oder `rotate` während eines laufenden Jobs löschen das lokale Gerätetoken. Dasselbe gilt für jede vorübergehende 401/403 (`RelayClient.swift:24`).
  - Das verletzt die Invariante „updateGrant erhält die Geräteidentität“, und der Cloud-Eintrag bleibt bis zu 30 Tage aktiv.
  - Empfehlung: Stopp als eigenen Fall behandeln und nur bei bestätigtem 401 auf Geräteendpunkten löschen.
- **S4: Relay-Kopplung ohne Out-of-band-Bestätigung, Routing an das neueste Gerät.**
  - Beleg: `index.js:55`, `ORDER BY created DESC LIMIT 1`.
  - Szenario: Wer den Servicezugang besitzt, kann den Eigentümer per `/pair?id=`-Link dazu bringen, ein fremdes Gerät zu koppeln. Danach gehen alle Werkzeugaufrufe an dieses Gerät, und es kann gefälschte Inhalte einspeisen.
  - Empfehlung: einen Bestätigungscode auf Mac und Pair-Seite abgleichen und eine aktive Kopplung nicht stillschweigend verdrängen.
  - Zu klären: Der Servicezugang steht im eigenen Header `OAI-Sites-Authorization` (`RelayClient.swift:34`). Das ist plattformbedingt plausibel, widerspricht aber der Header-Begründung in AGENTS.md. Prüfen, ob die Sites-Logs ihn erfassen.
- **S5: Prompt-Injection.**
  - Segmenttext wird ohne strukturelle Markierung als Fremdinhalt ausgegeben (`ReadOnlyMCPRuntime.swift:763-766`).
  - `LocalEmail.swift:296-299` behält versteckten HTML-Text (`display:none`, weiße Schrift) und dekodiert Bidi-Steuerzeichen.
  - Empfehlung: ein Feld `untrusted`/Begrenzer je Segment, Steuer- und Bidi-Zeichen entfernen, versteckte Elemente verwerfen.
- **S6: Die Ausgabevalidierung prüft keine Namen.** `protectForSending` prüft nur Regex-Kennungen (`IdentifierPrivacySession.swift:66-71`). NER läuft nur beim Aufbau, von NLTagger übersehene Namen gehen ungesperrt hinaus.
  - Empfehlung: Im `disclosure` ehrlich als „best effort“ ausweisen, optional eine konservative Schlussprüfung.
- **S7: Unverschlüsselter SHA-256 der Originalbytes geht nach außen** ✔ geprüft (`ReadOnlyMCPRuntime.swift:733`, `MCPDocumentInventory.swift:24`).
  - Folge: Der Anbieter kann bestätigen, dass der Nutzer eine bekannte Datei besitzt, und Dokumente über Verbindungen hinweg verknüpfen.
  - Empfehlung: HMAC mit einem Schlüssel je Verbindung.

### Niedrig
- **Trennen löscht lokal vor dem Fern-Widerruf** ✔ geprüft (`RelayUIControl.swift:158-159`). Scheitert das Netzwerk, bleibt das Cloud-Gerät aktiv, ohne dass der Mac es noch widerrufen kann.
- **Kurzes Rechte-Fenster:** `.atomic` schreibt mit umask-Rechten, `chmod 0600` folgt erst danach (`MCPAccessProfile.swift:82`, `MCPInstallation.swift:31`). Ein bereits bestehendes Verzeichnis wird nicht auf 0700 gesetzt.
- **Backups der Client-Konfiguration bleiben liegen:** `config.toml.vauldy-backup-<UUID>` werden nie entfernt (`MCPClientRegistration.swift:94-97`) und können Secrets enthalten.
- **Update bei Ad-hoc-Signatur:** Bei ad-hoc-signierter Installation wird jedes ad-hoc-signierte Bundle akzeptiert (`MCPSoftwareUpdate.swift:364-377`). Das Paket ist standardmäßig ad-hoc und ohne Hardened Runtime.
- **Platzhalterförmiger Text:** Text der Form `[V_<HEX>_X_n]` wird bei Erkennung und Validierung ausgelassen. Besser nur den eigenen Namespace auslassen.
- **Schwache Grenzen bei `/api/pair/*`:** keine Mindestlänge für das Gerätetoken beim Abschluss; eine globale Grenze von 16 offenen Kopplungen.
- **Doku-Drift:** „vier lesende Werkzeuge“, tatsächlich sind es 9.
- **Plausibel, nicht verifiziert:** Der Worker vertraut `oai-authenticated-user-id`. Das ist nur sicher, solange Sites diesen Header vom Client verlässlich entfernt.

---

## 3. UX/UI

### P1
**U1: Die OAuth-Zustimmung ist schwer zu finden**
- Beleg:
  - „Freigaben bestätigen“ liegt in einer standardmäßig zugeklappten Gruppe in einer weiteren Gruppe (`SetupOAuthView.swift:9-70`, `SetupView.swift:159`).
  - Der Deeplink öffnet nur die äußere Gruppe.
  - Die Webseite verweist auf einen Eintrag „ChatGPT & Claude“, den die Seitenleiste nicht zeigt (`OAuthWebService.swift:82`).
- Vorschlag: Offene Anfragen als oberste Karte oder Sheet mit Badge zeigen.
- Das verstärkt S1: Eine schlecht sichtbare Zustimmung wird eher hastig erteilt.

**U2: Die Chatbot-Auswahl ist für Laien nicht entscheidbar**
- Beleg: fünf Optionen mit Begriffen wie „OAuth“, „lokaler MCP-Host“ und „Runtime-Schlüssel“ (`SetupWizardView.swift:64-74`).
- Vorschlag: Zuerst nur „ChatGPT oder Claude?“ fragen, dann den empfohlenen Weg vorschlagen; alles andere unter „Erweitert“.

**U3: Destruktive Aktionen sind uneinheitlich abgesichert** ✔ geprüft
- Ohne Rückfrage:
  - ChatGPT-„Verbindung löschen“ und „Anmeldung abbrechen“; beide rufen `disconnectRelay` auf (`SetupRelayView.swift:29,40`)
  - „Zugriff widerrufen“
  - Ordner „Entfernen“
  - „Verbindung löschen“ im Web, ohne Angabe, welcher Mac gemeint ist
- Nur das Löschen eines Profils fragt nach.

### P2
- **U4: Die Server-Instruktionen widersprechen sich** ✔ geprüft. `ServerFactory.swift:160` empfiehlt `get_topic_overview` (topic=insurance), `:161` empfiehlt für denselben Fall `list_documents` mit any-term-substring.
  - Die Werkzeuge überschneiden sich: Inventar vs. List vs. Search.
  - Die Instruktionen sind englisch, die Werkzeugbeschreibungen deutsch, die von `list_documents` hat rund 1000 Zeichen.
  - Vorschlag: eine Entscheidungstabelle und eine Sprache; dazu A1.
- **U5: Fehlermeldungen leiten nicht zum Handeln an** ✔ geprüft. Alle Argumentfehler ergeben „Ungültige Anfrage. Bitte die beschriebenen Werkzeugparameter verwenden.“ (`MCPAccessProfile.swift:44`). Das Modell kann sich so nicht selbst korrigieren.
  - Vorschlag: Feld und Regel nennen, z. B. „query nur mit view=passages“ oder „ohne cursor neu beginnen“.
- **U6: Rückmeldungen erscheinen außer Sicht.** `model.message` steht am Ende der scrollenden Seite (`SetupView.swift:38`), ohne VoiceOver-Ansage. Vorschlag: ein Banner oben.
- **U7: Fachjargon und uneinheitliche Begriffe.**
  - Begriffe in Hauptabläufen: „MCP-Bestand“, „App-Build“, „SQLite“, „Client-Eintrag“.
  - Für ein Konzept gibt es Prüfhinweise, Prüfstellen, Prüffälle und Prüfdetails.
  - „Empfänger“ bezeichnet einmal die Verbindung und einmal ein Dokumentfeld.
  - Der App-Name schwankt zwischen „Vauldy MCP Einrichtung“, „Vauldy · MCP“ und „Vauldy.app“.
  - Vorschlag: ein Glossar mit einem Begriff je Konzept.
- **U8: Plural und Lokalisierung.** Texte wie „die 1 Dokumente“ an mehreren Stellen (`SetupRelayView.swift:45`, `SetupOAuthView.swift:42`). Es gibt keinen String Catalog.
- **U9: Wenig Rückmeldung bei langen OCR-Läufen.** Einzelnes „Text erneut lesen“ zeigt nur einen Spinner und blockiert das Sheet. Es gibt keine Mitteilung bei Abschluss, und die Restliste eines Stapels überlebt kein Beenden der App.
- **U10: Barrierefreiheit.**
  - Insgesamt nur rund 10 a11y-Labels.
  - Zeilenbuttons ohne Dokumentbezug.
  - Kein `.defaultAction` bei Primäraktionen.
  - Warnungen nur als orangefarbener Text.
  - Die OAuth-Seite lädt sich alle 2 s per `meta refresh` neu, das stört Screenreader.

### P3
- Feste Sheetgrößen, z. B. 860×740.
- UUID-Präfixe als Dokumentname im Bestandsabgleich.
- Bis zu fünf Aufklappbereiche je Dokumentzeile, Basisangaben doppelt.
- Die Freigabeliste wird nicht lazy aufgebaut.
- „Beispieldokument ausprobieren“ ohne Button.
- Leere Relay-Auswahl ohne Erklärung.
- `MCPPassagesResult.title` ist fest „Freigegebenes Dokument“ ✔ geprüft. Das ist eine bewusste Privacy-Entscheidung, nimmt dem Modell aber die Orientierung; ein pseudonymisierter Titel wäre zu prüfen.
- Der `disclosure`-Block mit rund 280 Zeichen steht in jeder Antwort.
- Die Fortsetzungssignale sind uneinheitlich.

---

## Stärken
- **Abhängigkeiten:** eine klare Richtung, ein gemeinsamer Dispatcher für stdio und HTTP, und der Relay delegiert an den lokalen stdio-Server.
- **Revalidierung:** Epoche, Profil und Dateiversion werden vor der Antwort geprüft, `MCPResponseAccess.verify` und eine HTTP-Tokenprüfung folgen danach. Handles und Cursor sind an Lease, Revision und Fingerprint gebunden.
- **OAuth:** nur S256-PKCE, Code nur einmal einlösbar (erneutes Einlösen widerruft den Grant), Refresh-Rotation mit Erkennung wiederverwendeter Tokens, Tokens nur als Hash gespeichert, Host-Allowlist, CIMD nur von festen Hosts.
- **Relay-Kryptografie:** ECDH mit HKDF und AES-GCM mit Richtungs-AAD; der private Serverschlüssel existiert nur je Aufruf. Offline und Timeout sind Fehler, nie leere Listen. CSRF-Schutz und CSP sind vorhanden.
- **Dateien und Parser:** O_NOFOLLOW/O_EXCL, Prüfung von Eigentümer und Rechten, fsync, Änderungen an der TOML werden mit dem echten Parser geprüft. SQL nur mit gebundenen Parametern, MIME-Parser begrenzt.
- **UX:** zweistufige Freigabe mit Diff, „Nur lokal behalten“, klarer nächster Schritt, gute Fortschrittsanzeige beim Import. Abdeckung und Vollständigkeit sind im MCP sauber getrennt.

## Empfohlene Reihenfolge
1. **S3 und Löschreihenfolge beim Trennen beheben:** Stopp ist kein Sign-in-Fehler; erst fern widerrufen, dann lokal löschen. Das ist klein und verhindert Datenverlust bei Verbindungen.
2. **A2 und A1:** sofortige Fehlerantwort im Relay; Instruktionen und Version generieren und in die Paritätsprüfung aufnehmen.
3. **S1 zusammen mit U1:** OAuth-Zustimmung mit eingetippter Kennung, nur bei lokal gestartetem Verbindungsvorgang, als prominentes Sheet.
4. **U3:** einheitliche Bestätigungsdialoge für alle destruktiven Aktionen.
5. **U4, U5 und A4:** Instruktionen bereinigen, präzise Fehlercodes, Ursachen nicht zusammenfalten.
6. **S7, S5 und S6:** Hash per HMAC, Fremdinhalte markieren, Namensgrenze ehrlich ausweisen.
7. Danach strukturell: A3, A7, A9 und A8.

Für die Punkte 1–3 gilt laut AGENTS.md: neues Paket, RelayConnectionTests, OAuthConnectionTests und `oauth_smoke_test.py`, stdio-Wiretests sowie die gesamte Regression.
