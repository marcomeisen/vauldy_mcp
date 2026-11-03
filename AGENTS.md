# Vauldy MCP

Dieses Repository enthält ausschließlich den eigenständigen macOS-Dokumentendienst,
seine lokalen Programme und die lesende MCP-Schnittstelle. Änderungen an der Vauldy-App
gehören in deren eigenes Repository. Keine Abhängigkeiten auf App-Quellpfade einführen.

- Originaldateien unverändert erhalten; nur eigene Metadaten atomar speichern.
- Produktion, Benutzerarchive, bestehende Profile und installierte Clientverbindungen
  nicht für Tests verwenden. Tests und Benchmarks nutzen isolierte synthetische Bestände.
- Keine Modelle herunterladen oder Anbieter umschalten. Cloud-Inferenz benötigt eine
  gesonderte bewusste Produktentscheidung und Nutzereinwilligung.
- OCR-Abdeckung, Analysezustand und Ergebnisvollständigkeit getrennt ausweisen.
- Fehlende/mehrdeutige Angaben offenlassen. Feldrollen, physische Quellseite und wörtliche
  Belege prüfen. Dateinamen sind keine Absenderbelege.
- Alle externen Inhalte müssen die Freigabe- und Privacy-Grenze in VauldyMCPRuntime
  durchlaufen. Rohmodelle nicht ausgeben. Cursor und Handles an Freigabe und Quelle binden.
- Vor Veröffentlichung Swift-Tests mit nativer OCR sowie reale stdio-Wiretests ausführen.
  Privacy-Änderungen zusätzlich auf Suche, Text und Metadatensicht prüfen.
- Dokumenttypübergreifend testen; LVM ist ein Regressionstest unter mehreren Domänen.

Architektur: docs/mcp-mvp.md. Analysevertrag und Grenzen: docs/base-analysis.md.

## OCR und bestehende UI ab 0.8.1

`OCRWhiteMargins` darf nur weiße Außenränder mit Sicherheitsabstand entfernen. Einzelne,
helle farbige Randzeichen, Fußzeilen und Tabellen müssen erhalten bleiben. Keine pauschale
Auflösungsänderung, keine gelockerten Konfidenzgrenzen und kein Austausch durch Solltexte.
OCR-Konfigurationsänderungen müssen alte Checkpoints ausschließen. Die acht Rasterfälle
sind strikte Sollwerttests; Fehler dürfen nicht nur als Review akzeptiert werden.

Die vorhandene UI wird als vollständiges Bundle über `scripts/mcp/run_ui.py` gestartet.
Vorhandene Analyse erscheint aus dem aktuellen gespeicherten Datensatz. Explizites „Text
erneut lesen“ läuft über den Worker mit `fresh: true`, auch für abgeschlossene Importe;
Originalbytes, Identität und Freigaben bleiben erhalten. Native UI-Prüfungen verwenden
ausschließlich `--setup-root` mit einem aufgabeneigenen synthetischen Bestand.

Gesamte Regression: `python3 scripts/mcp/regression_test.py`. Keine parallel konkurrierenden
OCR-Benchmarks. Die kleinen künstlichen Vorlagen begründen keine universelle OCR-Qualitäts-
oder Performancezusage für reale Archive.

## Originalverweise ab 0.9.0

Ordnerimporte verwenden read-only Security-Scoped Bookmarks; Einzelimporte behalten standardmäßig
managedCopy. Native OCR und Quick Look halten einen Access-Lease bis zum tatsächlichen Ende.
Vor OCR und vor OCR-Commit Inhalt verifizieren. Veränderte Quellen machen alten Text historisch,
fehlende Quellen löschen keine Dokumente. Keine Pfad-Fallbacks nach fehlgeschlagenem Bookmark.

Alt-Kopien nur im expliziten lokalen Migrationsdienst entfernen: Vorschau, erneuter Vergleich unter
OCR-/Writer-Sperre, unabhängig wiedergeöffnete Quelle, persistierte und synchronisierte Haupt- und
Backupsnapshots mit Verweis, abschließender Bytevergleich. Nur eigene reguläre Kopien entfernen;
Quellen und nicht verifizierte Kopien unverändert lassen. Storeformat 2 verhindert alte Writer.
`LocalOriginalReferenceTests` und `original_reference_smoke_test.py` sind zusätzliche Regressionen.

## Verbindungen und Privacy ab 0.9.1

Entfernen widerruft zuerst Zugriff, archiviert die deaktivierte Verbindung und entfernt nur den
exakt passenden Client-Eintrag. Alte Prozesse/Handles und wiederangelegte Auditordner dürfen keine
Verbindung reaktivieren. Archive sind Sperrmarken; Originale, Bestand und andere Freigaben erhalten.
Client-TOML mit echtem Parser in privatem Staging validieren, fremde Originalbytes erhalten.

Pseudonymisierung arbeitet auf ursprünglichen Quellkoordinaten ohne numerische Zwischentokens.
Überlappende Restkennungen begrenzt im gemeinsamen Kontext vervollständigen; Ausgabe zuletzt immer
validieren und andernfalls sperren. Physische Textabschnitte gehören in denselben Privacy-Kontext.
Währungs-/Protokollkürzel nur im NER ausschließen, nie explizite persönliche Kennungsregeln umgehen.

## OAuth-Verbindungen ab 0.10.0

Nutzer verbinden ChatGPT/Claude über Standard-OAuth ohne manuelle API-Schlüssel. Die lokale App
bestätigt Eigentümer und exakte Dokumentauswahl; keine behauptete Chatbot-Identität, kein login_hint
und kein Clientname ersetzen diese Freigabe. Keine automatische Produktionseinrichtung, keinen
öffentlichen Port oder TLS-/Routerzustand für Tests ändern. Externe SSO-Anbieterfreigaben nicht erfinden.

VauldyMCPProtocol ist der gemeinsame Dispatcher für stdio und HTTP. HTTP-Sitzung, Tokenfamilie,
Profilrevision, Resource, Redirect, Client und PKCE getrennt binden. Tokens auch unmittelbar vor
Antwortausgabe prüfen. Änderungen an der Dokumentauswahl dürfen bestehende Tokens nie erweitern.
Private Credentialablage atomar und synchronisiert, keine Rohsecrets in Logs/JSON; native Zustimmung
niemals als HTTP-Endpunkt anbieten. CIMD nur von begrenzten öffentlichen Anbieter-Metadaten beziehen.
OAuthConnectionTests und oauth_smoke_test.py ergänzen sämtliche bisherigen Regressionen.
Betreibervertrag, Grenzen und noch erforderliche öffentliche Bereitstellung: docs/mcp-oauth.md.
