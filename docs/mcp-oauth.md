# ChatGPT und Claude über OAuth verbinden (0.10.0)

Für ChatGPT mit verwalteter Anmeldung ab 0.12 siehe [ChatGPT-SSO](mcp-chatgpt-sso.md). Dieses Dokument beschreibt den weiterhin verfügbaren Standard-OAuth-Anschluss für eigene HTTPS-Deployments und Claude.

## Nutzerablauf

1. In **Verbindung hinzufügen** „ChatGPT · OAuth im normalen Chat“ oder „Claude · OAuth-Verbindung“ wählen.
2. Dokumente auswählen und die Weitergabe an diesen Chatbot bestätigen. Das speichert zunächst nur die lokale Dokumentauswahl.
3. Unter **ChatGPT & Claude** die vom Betreiber bereitgestellte Verbindungsadresse kopieren.
4. In ChatGPT unter Plugins einen benutzerdefinierten MCP-Server hinzufügen, in Claude unter Connectors einen Custom Connector. Die Adresse endet auf `/mcp`. OAuth verwenden; automatische Registrierung oder die veröffentlichte Client-Identität wählen. Keine API-Schlüssel oder eigenen Client-Secrets eingeben.
5. Im Verbindungsfenster erscheint eine Kennung. „Vauldy auf diesem Mac öffnen“ wählen oder die Einrichtung öffnen. Unter **ChatGPT & Claude** die Kennung vergleichen, die Dokumentauswahl wählen und den Zugriff bestätigen. Nur selbst gestartete Anfragen freigeben.
6. Der Browser kehrt zum Chatbot zurück. Anschließend Vauldy im Zielchat auswählen und eine konkrete Anfrage stellen.

Neue Importe bleiben gesperrt. Unter **ChatGPT & Claude → Zugriff widerrufen** wird nur die gewählte OAuth-Verbindung gesperrt. Pausieren, Löschen oder Ändern der zugrunde liegenden Dokumentauswahl sperrt deren bisherige OAuth-Tokens; für eine neue Auswahl erneut verbinden. Andere Verbindungen bleiben erhalten.

Der Mac und der Verbindungsdienst müssen erreichbar bleiben. Während der ersten Freigabe benötigt der Eigentümer Zugriff auf die lokale Vauldy-App. Nach der Freigabe erneuert der Chatbot seine Zugriffstokens automatisch. Ein neues eigenes Passwort oder ein Nutzer-API-Schlüssel ist nicht erforderlich.

## Einmalige Betreiber-Einrichtung

Das Paket enthält `vauldy-mcp-http`. Der Dienst bindet ausschließlich `127.0.0.1`; er öffnet selbst keinen Routerport, richtet kein Hosting ein und beschafft kein TLS-Zertifikat. Für Cloud-Chats wird eine öffentliche HTTPS-Adresse benötigt. Ein vom Betreiber verwalteter TLS-Proxy veröffentlicht ausschließlich die OAuth-Endpunkte und `/mcp`. Beispiel: [nginx-vauldy.conf.example](../deploy/nginx-vauldy.conf.example).

```sh
vauldy-local oauth-configure --root /eigene/installation --origin https://mcp.example.com --port 48731
vauldy-local oauth-start --root /eigene/installation
vauldy-local oauth-status --root /eigene/installation
vauldy-local oauth-stop --root /eigene/installation
```

Alternativ `vauldy-mcp-http --root /eigene/installation` im Vordergrund oder unter einem eigenen macOS-Dienstmanager betreiben. `oauth-start` verlangt ein daneben liegendes `vauldy-mcp-http` und prüft dessen lokale Metadatenantwort. Kein Login-Dienst wird automatisch angelegt. Die Dienstadresse ist nach Einrichtung unveränderlich, damit bestehende OAuth-Ressourcenbindungen nicht unbemerkt wechseln.

Der Proxy muss `Host` und `Origin` erhalten, HTTPS korrekt terminieren und nur die dokumentierten Pfade weiterleiten. Weitergeleitete Host-/Proto-Header bestimmen weder Redirects noch Issuer; maßgeblich ist ausschließlich die lokale Konfiguration. Querys, Cookies, Authorization-Header und Tokenantworten nicht in Proxy-/Debuglogs schreiben. Öffentliche Erreichbarkeit, Zertifikat und tatsächliche Aufrufe aus beiden Zielchatbots separat prüfen. Eine lokale Metadatenprüfung ist kein Nachweis einer aktiven Cloud-Verbindung.

## Autorisierungsvertrag

Dies ist der gemeinsame **OAuth-Verbindungsablauf**, keine vorgetäuschte Anmeldung als Nutzer des Chatbot-Anbieters. ChatGPT/Claude sind OAuth-Clients, Vauldy autorisiert den Zugriff auf die lokal ausgewählte Ressource. Die Freigabe erfolgt durch den angemeldeten Mac-Eigentümer in der lokalen App. Namen, `client_name`, `login_hint` und sonstige vom Client behauptete Identitäten werden nicht zur Autorisierung verwendet.

Ein zusätzliches „Sign in with ChatGPT“ als Identitätsanbieter ist ein anderer, separat freizuschaltender Anschluss; entsprechende Anbieter-SSO-Verfügbarkeit wird hier nicht vorausgesetzt. Lokale Host-Registrierungen über `config.toml` beziehungsweise Claude Desktop JSON bleiben unabhängig nutzbar.

- Discovery: `/.well-known/oauth-protected-resource` (auch `/mcp`-Variante), `/.well-known/oauth-authorization-server`.
- Authorization Code mit verpflichtendem PKCE S256, unveränderter `state`-Weitergabe und `iss` in der Autorisierungsantwort.
- Exakte Bindung an Client, registrierte Redirect-URI, Scope `documents:read` und `resource=https://…/mcp` bei Autorisierung und Tokenaustausch.
- Automatische Registrierung öffentlicher Clients (`token_endpoint_auth_method=none`). Redirects ausschließlich zu HTTPS auf `chatgpt.com`, `claude.ai` oder `claude.com`, ohne Query, Fragment, Userinfo, fremden Provider oder kodierte Pfadumwege.
- CIMD: begrenztes öffentliches Metadatendokument von denselben Anbieterhosts, keine Redirects, keine Cookies/Credentials, kein Abruf beliebiger oder lokaler URLs. Client-ID, Anbieter und Redirects müssen zusammenpassen; der Client muss öffentlichen Tokenaustausch mit `none` unterstützen. DCR bleibt verfügbar.
- Anfragen bleiben maximal zehn Minuten offen. Die lokale Freigabe prüft die im Dialog eingefrorene Profilrevision. Codes sind höchstens zwei Minuten gültig, einmalig und im privaten Zustand verschlüsselt abgelegt.
- Zugriffstoken gelten 15 Minuten. Refresh-Tokens rotieren automatisch innerhalb einer maximal 30-tägigen Familie. Wiederverwendung eines alten Refresh-Tokens sperrt die Familie. Auch Code-Wiederverwendung sperrt die daraus erzeugte Familie. Clients erhalten nie einen manuellen API-Schlüssel.
- Bearer-Tokens werden nur als Hash gespeichert. Der automatisch erzeugte lokale Schlüssel zum Schutz kurzlebiger Codes liegt ausschließlich unter `oauth/authorization.key` (0600). Konfiguration, Metadaten und Credentialzustand sind privat, begrenzt, gegen symbolische Links geschützt und werden unter Prozesssperre atomar mit fsync gespeichert. Beschädigte Zustände werden nicht überschrieben.
- Jede Anfrage und jede Antwort prüft Token, Familie, lokale Freigabe und Profilrevision erneut. HTTP-Sitzungen gehören genau einer OAuth-Familie. Tokens, Sitzung, Cursor und Dokumenthandles sind keine gegenseitigen Ersatzberechtigungen.
- Es gibt keine HTTP-Endpunkte zum Freigeben, Auswählen von Archiven oder Ändern der Dienstkonfiguration. Vertrauenswürdige lokale Verwaltung: `oauth-pending`, `oauth-approve`, `oauth-deny`, `oauth-connections`, `oauth-revoke`. Die CLI-Freigabe verlangt Anfrage-ID, Profil-ID und angezeigte Revision.

## MCP, Speicherung und Grenzen

stdio und HTTP verwenden denselben `VauldyMCPProtocol`-Dispatcher, dieselben vier Tools, Ausgabeschemata, Privacy-Prüfungen, Quellenbelege und lokalen Auditgrenzen. HTTP ergänzt OAuth-Sicherheitsmetadaten. Rohmodelle, Originaldateien, Pfade, dauerhafte Archivkennungen und Zugangsdaten gelangen nicht in MCP-Ergebnisse.

Streamable HTTP gibt begrenzte JSON-Antworten zurück; Sitzungen bleiben für Handles/Cursor erhalten. Kein unbeschränkter SSE-Replay-Verlauf. GET-Streams sind nicht implementiert (405); DELETE beendet eine Sitzung. Beim Dienstneustart müssen Clients neu initialisieren; gültige OAuth-Familien und registrierte Clients bleiben erhalten.

Grenzen: 256 Clients, 128 offene Anfragen, 512 Tokenfamilien, 4 MiB Credentialzustand, 4.096 Refresh-Rotationen je Familie; 32 HTTP-Sitzungen insgesamt, vier je Familie, zehn Minuten Leerlauf, 64 gleichzeitige Verbindungen; 64 KiB Anfragekörper, 16 KiB Header, 256 KiB HTTP-Antwort. Client-Metadaten: 16 KiB und fünf Sekunden. Ausgehende Dokument-DTOs behalten zusätzlich ihre bisherigen engeren Grenzen. Kapazitätsüberschreitungen schlagen ausdrücklich fehl.

Die öffentliche Betreiberkonfiguration benötigt ergänzende Ratenbegrenzung. Der Server prüft bereitgestellte Origin-/Host-Header und lehnt doppelte Header beziehungsweise Formularparameter und konkurrierende gleiche JSON-RPC-IDs ab. Es gibt keinen automatischen Rückfall auf ungeschützten Zugriff oder manuelle Nutzerschlüssel.

## Verifikation

`OAuthConnectionTests` prüfen beide Anbieter, Freigabe/Ablehnung, PKCE, Replay, Ressourcen-/Client-/Redirect-Bindung, Ablauf, Profiländerungen, private Speicherung, manipulierbare Metadaten und Zustandsgrenzen. `scripts/mcp/oauth_smoke_test.py` verwendet echte gebaute Programme und HTTP für beide Anbieter: Registrierung → Browserdialog → lokale Freigabe → Token → MCP → vollständige Liste → Privacy → Refresh → Widerruf → Neustart. Alle Dokumente und Profile sind künstlich und isoliert.

Am 3. November 2026 bestanden alle 15 Regressionsstufen einschließlich 134 Swift-Tests in 19 Suites. Der zusätzliche native Test bestätigte Auswahl und Freigabe in der App, Tokenausgabe, einen echten HTTP-MCP-Abruf und den UI-Widerruf. Der Test verwendete eine eigene App-Kopie ohne produktive URL-Scheme-Registrierung und ausschließlich ein künstliches Dokument; Archiv und Profil blieben bytegleich. Dies ist kein Live-Nachweis aus einem ChatGPT- oder Claude-Account.

Die gesamte Regression enthält zusätzlich unverändert die nativen OCR-, Import-, Retrieval-, stdio-, Verwaltungs- und Privacy-Tests. Die Umsetzung richtet keinen produktiven Endpunkt ein und verwendet keine produktiven Archive oder Anbieteraccounts als Testdaten. Live-Nachweis in ChatGPT und Claude benötigt anschließend die echte HTTPS-Bereitstellung und die jeweilige Plugin-/Connector-Einrichtung.

Quellen: [OpenAI OAuth-Anforderungen](https://developers.openai.com/plugins/build/auth), [ChatGPT verbinden](https://developers.openai.com/plugins/deploy/connect-chatgpt), [Claude Custom Connectors](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp), [MCP-Autorisierung](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization).
