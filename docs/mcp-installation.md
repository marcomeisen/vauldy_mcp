# Vauldy MCP einrichten (macOS, Version 0.14.3)

Vauldy kann Dokumente eigenständig lokal importieren, Text erkennen und für MCP bereitstellen.
Die bisherige Vauldy-App wird dafür nicht benötigt. Der Import erfolgt über den mitgelieferten
Assistenten oder `vauldy-local`; die MCP-Schnittstelle bleibt ausschließlich lesend.

## Dokumentauswahl und Originalzugriff

Die **Übersicht** zeigt den nächsten nötigen Schritt für die gewählte Verbindung.
Neue Importe werden nicht automatisch freigegeben. „Dokumente auswählen“ führt zur
Entscheidung für neue Dokumente; „Nur lokal behalten“ speichert die Entscheidung für
diesen Empfänger und diese Inhaltsfassung. Du kannst sie später ändern.

**„Freigabe bearbeiten“** öffnet unter Dokumente, Verbindungen und in der Menüleiste
immer denselben Ablauf. Empfänger, zusätzliche und entfernte Dokumente bleiben sichtbar.
Eine bestehende ChatGPT-Anmeldung muss dafür nicht gelöscht werden.
**„Originalzugriff wiederherstellen“** wird bei nicht erreichbaren oder veränderten
Originalen angeboten. Dieser Quellenabgleich ist von der Freigabe neuer Dokumente
getrennt. [Ablauf und Grenzen](inventory-workflow.md).

## Einrichtung ohne bestehende App

1. `Vauldy.zip` entpacken, `Vauldy.app` nach Programme verschieben und öffnen. Pakete mit den bisherigen Namen `Vauldy-MCP-macOS.zip` / `Vauldy MCP Einrichtung.app` werden genauso verwendet. Voraussetzung: macOS 14 oder neuer und eine zum Paket passende Prozessorarchitektur.
2. Beim ersten gewöhnlichen Start ohne installierte Software und ohne Verbindungen öffnet sich der Installationsassistent automatisch. Er zeigt Version und Speicherort. Mit **„Installieren“** werden die lokalen Programme geprüft, eingerichtet und mit einem synthetischen Profil gestartet. Der Abschluss zeigt die installierte Version und das Ergebnis des lokalen Starttests. Für diesen Schritt brauchst du kein Konto. Nach „Abbrechen“ kannst du ihn über **Übersicht → Installation starten** wieder öffnen.
3. Am erfolgreichen Abschluss **„Chatbot verbinden“** wählen. Dieser eigene Assistent führt durch **Chatbot → Dokumente → Verbindung**. Mit **„Später einrichten“** beendest du die Installation ohne Chatbot-Verbindung. Der Verbindungsassistent bleibt über die Übersicht erreichbar.
4. Chatbot und optional einen Verbindungsnamen wählen. Unter „Dokumente“ PDFs oder Bilder mit „Neue Dateien hinzufügen …“ lokal kopieren, mit „Ordner einmal importieren …“ Originale am vorhandenen Ort verknüpfen oder über „Weitere Quellen“ das künstliche Beispieldokument ausprobieren. Beim einmaligen Ordnerimport können mehrere Ordner ausgewählt werden. „Unterordner einbeziehen“ ist vorausgewählt. Der Fortschritt zeigt die Gesamtzahl gefundener unterstützter Dokumente, die aktuelle Datei und den Verarbeitungsschritt. „Import abbrechen“ zeigt den laufenden Abbruch. Beim Schließen des Assistenten läuft der Import weiter. Die Freigabe erfolgt separat.
5. „Dokumente auswählen“ öffnet die gemeinsame Freigabeansicht. Lesbare Dokumente markieren, mit „Auswahl überprüfen“ Empfänger und Änderungen prüfen und die mögliche Weitergabe an dessen Cloud-Anbieter ausdrücklich bestätigen.
6. „Auswahl für … freigeben“ speichert die Dokumentauswahl. Mit „Fertig“ zur Einrichtung zurückkehren. Für normale Chats anschließend unter „Verbindungen“ den OAuth-Anschluss im Chatbot abschließen und die Anfrage lokal bestätigen. Bei einem ausdrücklich gewählten lokalen MCP-Host wird ein passender Client-Eintrag angelegt. Konflikte mit bestehenden Einträgen bleiben sichtbar. Bei manueller Einrichtung steht „Konfiguration kopieren“ zur Verfügung.
7. Der lokale Protokolltest prüft Handshake und Freigabestatus. Aktiviere Vauldy anschließend im Chatbot und starte dessen Verbindung bei Bedarf neu. Unter **Verbindungen** kannst du einzelne Zugriffe pausieren oder nach Bestätigung fortsetzen.

**Dokumente** bietet Suche, Auswahl-/Qualitätsfilter und eine lokale Vorschau importierter Originale.
Der Importbericht bleibt oberhalb der Liste sichtbar und unterscheidet neue, bereits vorhandene, fehlgeschlagene und übersprungene Dateien. „Fehler anzeigen“ führt zu den betroffenen Dateinamen und Gründen. Hinweise zu Texterkennung und Basisanalyse erscheinen separat. „Neu importierte Dokumente anzeigen“ filtert die Liste auf diesen Import.

In **„Freigabe bearbeiten“** ergänzt „Lesbare Treffer hinzufügen“ die aktuelle Auswahl
um die lesbaren Treffer der Suche und Filter. „Auswahl überprüfen“ zeigt anschließend
alle Änderungen. Erst die ausdrückliche Bestätigung speichert die Freigabe.
Ein pausierter Zugriff bleibt pausiert; eine leere Auswahl sperrt den Zugriff.
Nicht erreichbare, zuvor freigegebene Originale bleiben ausgewählt, bis du sie ausdrücklich
entfernst. Zusätzliche Dokumente mit Prüfhinweisen benötigen eine gesonderte Zustimmung.
„Nur Dokumente mit offener Freigabeentscheidung“ blendet bereits freigegebene und bewusst
lokal behaltene Dokumente aus. Über alle Dokumente kannst du diese Entscheidung später ändern.

Die Auswahlkästchen in der normalen **Dokumentliste** dienen dagegen ausschließlich dem
optionalen „Ausgewählten Text erneut lesen“. „Prüfstellen ansehen“ öffnet Original und
gespeicherten Text ohne erneute Texterkennung. Diese Aktionen ändern keine Freigabe.

Unter **Einstellungen** erfolgt das Softwareupdate unabhängig von Freigaben und Client-Einträgen.
Bestehende Profile bleiben bytegenau erhalten, einschließlich pausierter Zustände. Das Update startet die Statusanzeige neu, aber keine Chatbot-Verbindung. Bereits laufende Server müssen im Chatbot neu gestartet werden.

Eine veraltete Installation kann gültige neuere Auditereignisse nicht lesen und beim Start `auditUnavailable` melden. Dafür die Software aktualisieren; keine Logs oder Freigaben löschen. Die Aktualisierung ist auch über den CLI-Helfer aus dem neuen Paket möglich:

```sh
vauldy-local update-software --root /bestehende/installation --from-app "/pfad/Vauldy MCP Einrichtung.app"
vauldy-local check-connection --profile /bestehende/installation/connections/UUID/profile.json
```

Der Check prüft die tatsächliche Serverversion, alle neun Werkzeuge und den Freigabestatus. Er lädt keine Dokumenttexte und ist kein Nachweis eines verbundenen fremden Chats. Bestehende Hostprozesse benötigen nach dem Softwareupdate einen gezielten MCP-Neustart. Normale gehostete Chats benötigen zusätzlich ihren eigenen eingerichteten Plugin-/Remote-Anschluss. [Architekturanalyse und Skalierung](https://github.com/marcomeisen/vauldy_mcp/blob/main/docs/audits/mcp-2026-11-03-architecture/README.md).

„Lokalen MCP-Bestand laden“ lädt frühere Importe und erkennt unterbrochene OCR-Läufe. Für fehlgeschlagene,
unterbrochene, teilweise und bereits als abgeschlossen markierte Dokumente steht „Text erneut lesen“ zur Verfügung.
Das liest die gesicherte Originalkopie cachefrei neu und aktualisiert die Basisanalyse,
auch wenn die importierte Quelldatei verschoben wurde. Originale und Freigaben bleiben erhalten.
„Übersicht und Basisangaben“ zeigt die gespeicherten Angaben mit ihren Quellseiten.
„Import abbrechen“ wartet auf das tatsächliche Ende der laufenden System-OCR. Ein Worker-/Prozessabbruch
hinterlässt einen wiederaufnehmbaren Datensatz; er wird nicht als erfolgreicher Import angezeigt.

Die Entwicklung erfolgt im eigenständigen Repository `marcomeisen/vauldy_mcp`.
Es wird kein App-Archiv automatisch gesucht oder übernommen. Ein ausdrücklich ausgewählter
kompatibler Snapshot kann weiterhin ausschließlich gelesen werden.

## ChatGPT und Claude ohne manuelle API-Schlüssel

Ab 0.12 bietet ChatGPT eine private, verwaltete Anmeldung samt ausgehendem Mac-Agenten.
Nutzer bestätigen ihre Dokumentauswahl und melden sich im Browser mit ihrem ChatGPT-Konto an.
Die Betreiberbereitstellung hinterlegt Zugangsdaten automatisch im Schlüsselbund; Nutzer
kopieren keine API- oder Runtime-Schlüssel. [ChatGPT-SSO und Betriebsgrenzen](mcp-chatgpt-sso.md).
Claude und eigene HTTPS-Deployments behalten den [Standard-OAuth-Ablauf](mcp-oauth.md).

## Mit ChatGPT verbinden

Stand: 03.11.2026, anhand der [offiziellen OpenAI-Dokumentation](https://learn.chatgpt.com/docs/extend/mcp).
Der lokale MCP-Host und reguläre gehostete ChatGPT-Gespräche verwenden unterschiedliche Anschlusswege.
Eine erfolgreiche lokale Prüfung bestätigt keine Verbindung zu einem anderen ChatGPT-Gespräch.

### Lokaler MCP-Host auf demselben Mac

1. Im Vauldy-Assistenten Dokumente auswählen, **ChatGPT · lokaler MCP-Host** wählen und die Weitergabe bestätigen.
2. „Freigeben und einrichten“ legt `vauldy` in `~/.codex/config.toml` an. Dazu muss die aktuelle
   ChatGPT-App in `/Applications` oder `~/Applications` installiert sein und ihre Codex-CLI enthalten.
3. Die Verbindung im lokalen Host neu laden und die dort angebotene MCP-Verwaltung prüfen. Der Installer beendet keinen laufenden Chat.
4. In einem Gespräch dieses Hosts mit verfügbaren Vauldy-Werkzeugen beim künstlichen Beispiel fragen: „Suche in Vauldy nach Fahrradwartung und nenne den Betrag mit Seite.“

Für einen anderen lokalen stdio-fähigen Host stehen Programm und die zwei Argumente `--profile`,
absoluter Profilpfad im Wizard und in der erzeugten `mcp-config.json`. Umgebungsvariablen und
Arbeitsverzeichnis bleiben leer.

`/mcp` und ein `@`-Auswahlmenü sind keine universellen Verbindungstests. Verfügbare Befehle und
Erwähnungen hängen vom Host und Gespräch ab. Insbesondere erzeugt die lokale Registrierung keine
App/Plugin-Verbindung für reguläre gehostete ChatGPT-Gespräche, auch wenn diese in einer Desktop-App
angezeigt werden.

### Reguläre gehostete ChatGPT-Gespräche

Der vorgesehene Weg ab 0.12 ist die [private ChatGPT-Anmeldung](mcp-chatgpt-sso.md).
Die folgenden Abschnitte beschreiben alternative Betreiberanschlüsse. Sie sind keine
zusätzlichen Schritte für Nutzer des verwalteten Anschlusses.

Das lokale Programm kann nicht einfach als Server-URL eingetragen werden. ChatGPT web verbindet
MCP über Plugins mit HTTPS oder einen **Secure MCP Tunnel**. Der Tunnel kann einen lokalen stdio-Server
anbinden und benötigt ausgehendes HTTPS, keinen öffentlich geöffneten Port. Dafür sind eine unterstützte
OpenAI-Organisation/Workspace-Zuordnung und die dortigen Freigaben erforderlich. Siehe
[Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels).

Vauldys Paket enthält derzeit keinen eingerichteten Tunnel und keinen öffentlichen HTTPS-Endpunkt.
Es werden keine Originale automatisch hochgeladen. Auch über einen Tunnel verlassen freigegebene,
lokal bereinigte Tool-Antworten den Mac.

#### Eigener HTTPS-Zugang auf dem Mac über den Router

Dieser Anschluss benötigt keinen OpenAI-Tunnel und keinen OpenAI-API-Schlüssel. ChatGPT verbindet
sich mit einer eigenen öffentlichen HTTPS-Adresse. Die Verarbeitung angeforderter Werkzeugantworten
erfolgt weiterhin bei ChatGPT; eigene Netzwerkinfrastruktur verhindert diese Weitergabe nicht.

Voraussetzungen sind ein von außen erreichbarer Anschluss, eine geeignete öffentliche Adresse und
ein öffentlich vertrauenswürdiges, automatisch erneuertes TLS-Zertifikat. Eine dynamische IP-Adresse
benötigt für eine dauerhaft gleichbleibende Server-URL einen vorhandenen DNS-/DynDNS-Namen oder eine
andere Lösung für Adresswechsel. Eine lokale Adresse wie `192.168.x.x` ist aus ChatGPT nicht erreichbar.
Bei IPv4 hinter CGNAT/DS-Lite genügt eine Portweiterleitung nicht; die tatsächliche externe
Erreichbarkeit muss separat geprüft werden. Der Mac muss für Anfragen eingeschaltet, wach und online sein.

Vor einer Router-Freigabe den neuen Streamable-HTTP-/OAuth-Dienst `vauldy-mcp-http` konfigurieren und lokal prüfen. Er bindet ausschließlich Loopback; TLS, Domain und Proxy richtet der Betreiber separat ein. Der stdio-Server allein ist kein HTTP-Dienst. Ein HTTPS-Reverse-Proxy
darf nur den dafür vorgesehenen MCP-/OAuth-Dienst veröffentlichen, niemals den Dokumentordner, die
Verwaltungsoberfläche des Routers oder beliebige lokale Ports. Die vorhandene Profilprüfung und
lokale Bereinigung bleiben vor jeder Inhaltsausgabe verpflichtend. Nicht angemeldete Anfragen dürfen
keine Dokumentdaten erhalten. Ein API-Schlüssel in der URL ersetzt diese Anmeldung nicht.

Nach erfolgreicher externer HTTPS-/OAuth-Prüfung auf `chatgpt.com/plugins` unter **Hinzufügen →
Benutzerdefinierten MCP-Server hinzufügen** die **Server-URL** und **OAuth** wählen, das Plugin
installieren und im Zielgespräch verwenden. Zuerst nur `get_vault_status` aufrufen; erst dieser Aufruf
aus dem Zielgespräch belegt die tatsächliche Verbindung. Siehe
[eigene MCP-Server](https://developers.openai.com/api/docs/guides/custom-mcp-server) und
[OAuth-Anforderungen](https://developers.openai.com/plugins/build/auth).

Der HTTP-/OAuth-Adapter ist ab 0.10.0 im Paket enthalten. Eine aktive Router-/HTTPS-Freigabe wird dadurch nicht bestätigt oder automatisch eingerichtet.

#### Optionaler OpenAI-Tunnel (Betreiber-/Entwickleroption)

Dieser manuelle Schlüsselweg gehört nicht zum normalen Nutzerablauf. Nutzer verbinden sich über OAuth; technische Transport-Zugangsdaten verwaltet gegebenenfalls der Betreiber.

Ein Eintrag in `~/.codex/config.toml` verbindet den lokalen MCP-Host; er erstellt keine zusätzliche
ChatGPT-App für gehostete ChatGPT-Gespräche. Auf `chatgpt.com/plugins` führt **Hinzufügen →
Benutzerdefinierten MCP-Server hinzufügen → Tunnel** zum separaten Anschluss. Dafür müssen ein
passend zugeordnetes Tunnel-Konto und ein laufender offizieller OpenAI-`tunnel-client` vorhanden sein.
Ein API-Runtime-Schlüssel benötigt Tunnels Read + Use und gehört nicht in Chat, Kommandozeilenargumente
oder YAML-Dateien; die Konfiguration verwendet `env:CONTROL_PLANE_API_KEY`.

Für einen bereits installierten `bin/tunnel-client` und ein vorbereitetes
`tunnel/vauldy-chatgpt.yaml` bietet `scripts/mcp/start_chatgpt_tunnel.command` eine verdeckte lokale
Schlüsseleingabe, `doctor`-Prüfung und eine ausdrückliche START-Abfrage. Der Vordergrundprozess bleibt
an das Terminal gebunden; er ist kein Login-Dienst. Der Startdialog speichert keinen Schlüssel.
Eine ChatGPT-Anbindung gilt erst nach erfolgreicher Tool-Erkennung und einem Aufruf aus dem
betroffenen ChatGPT-Gespräch als bestätigt.

## Mit Claude Desktop verbinden

Im Wizard **Claude Desktop** wählen und installieren. Vauldy ergänzt
`~/Library/Application Support/Claude/claude_desktop_config.json` um `mcpServers.vauldy`.
Eine fehlende Datei wird erstellt. Anschließend Claude Desktop vollständig beenden und wieder öffnen;
der Installer startet oder beendet Claude nicht. Die Anleitung folgt dem
[offiziellen MCP-Leitfaden für Claude Desktop](https://modelcontextprotocol.io/docs/develop/connect-local-servers).
Claude im Browser und Claude Code verwenden andere Anschlusswege und werden damit nicht eingerichtet.

## Automatische Registrierung und Skriptbetrieb

Die Registrierung ist Teil der Installation für den ausgewählten Desktop-Client. Ein bereits
identischer Eintrag bleibt unverändert. Ein anders belegter oder deaktivierter `vauldy`-Eintrag
wird als Konflikt angezeigt und nicht ersetzt. Bitte einen solchen Eintrag im Client prüfen und
gegebenenfalls entfernen; danach unter „Verbindung prüfen“ erneut eintragen. Beschädigte oder über Symlinks
umgeleitete Konfigurationen werden abgelehnt. Vor einer Änderung wird neben der Konfiguration eine
private Sicherung mit `.vauldy-backup-<ID>` angelegt; sie bleibt zur Wiederherstellung erhalten.

ChatGPTs Parser prüft die bestehende und ergänzte TOML-Datei in einem temporären isolierten Verzeichnis.
Der Installer hängt nur die neue Tabelle an; vorhandener Text und Kommentare bleiben unverändert.
Bei Claude werden vorhandene JSON-Einstellungen und Server übernommen. Gleichzeitige Vauldy-Installer
werden gesperrt; erkannte externe Änderungen führen zum Abbruch und können erneut versucht werden.
Während der Einrichtung die Client-Konfiguration nicht gleichzeitig bearbeiten.

Für Installationsskripte enthält das Paket denselben Ablauf ohne UI:

```sh
"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" connect \
  --client chatgpt --profile "/absoluter/pfad/zur/freigegebenen/profile.json"

"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" connect \
  --client claude --profile "/absoluter/pfad/zur/anderen/freigegebenen/profile.json"
```

Die Profile werden zuvor im Wizard ausdrücklich freigegeben. `connect` verändert weder Dokumentauswahl
noch Freigaben. Exitcode 1 zeigt einen Fehler an; ein bereits identischer Eintrag ist erfolgreich.
Für isolierte Tests dient `--client-home /absoluter/testpfad`; beim Wizard leitet `--setup-root`
auch beide Client-Konfigurationen nach `<testpfad>/test-client-home` um. Tests ändern keine echten
Client-Einstellungen. Anmeldung und Anbieter-/Workspace-Freigaben bleiben Aufgabe des jeweiligen Clients.
Ein erfolgreicher lokaler Test bestätigt noch keinen Cloud-Chat mit Dokumentinhalten.

### Formatfehler beim Verbindungsaufbau

Die Meldung „The data couldn’t be read because it isn’t in the correct format“ kann
bereits beim MCP-Handshake auftreten: Das verwendete Swift-MCP-SDK 0.12.1 erwartet
für experimentelle Client-Fähigkeiten Zeichenketten, während MCP auch JSON-Objekte
erlaubt. Vauldy ignoriert deshalb vor der SDK-Decodierung ausschließlich die von
diesem Server nicht unterstützten experimentellen Erweiterungswerte. Standardfähigkeiten,
Tool-Anfragen und Dokumentfreigaben werden dadurch nicht verändert.

Nach dem Austausch des Serverprogramms die Verbindung in den Client-Einstellungen
neu starten. Bereits fehlgeschlagene Verbindungen eines laufenden Chats laden ein
ersetztes Programm nicht automatisch. Ein erfolgreicher `tools/list`-Test bestätigt
die Erkennung, aber noch keinen Tool-Aufruf aus einem Chat.

## Lokale Texterkennung und Qualitätsgrenzen

Unterstützt: PDF, PNG, JPEG, TIFF und HEIC/HEIF; höchstens 50 MiB Originaldatei, 200 Seiten und
900 KB erkannter UTF-8-Text pro Dokument. Mehrseitige TIFFs behalten ihre physischen Seiten.
Gesperrte PDFs müssen vor dem Import lokal entsperrt werden.

Brauchbarer eingebetteter PDF-Text wird direkt gelesen; textbasierte PDF-Formobjekte lösen keine
pauschale OCR aus. Kleine, vom Text getrennte Bildbereiche erhalten eigene genaue OCR. Große,
überlappende, inline eingebundene oder unklar zugeordnete Bilder behalten die vollständige Seiten-OCR.
Apples genaue Vision-Erkennung und Sprachkorrektur bleiben aktiv.
Die Auflösung richtet sich bei PDF-Text nach der beobachteten Schriftgröße. Lange Belege werden
in überlappenden Ausschnitten verarbeitet, ohne ihre physische Seitennummer zu ändern. Wiederholte
Zeilen in Überlappungen bleiben erhalten; Tabellen und Beträge werden dadurch nicht neu interpretiert.
Die erste System-OCR kann deutlich länger brauchen als folgende Seiten; der Assistent zeigt
Seitenfortschritt. Leere, unlesbare und prüfbedürftige Seiten werden unterschieden.

„Text erfasst“ bestätigt ausschließlich die Quellenverarbeitung. Eine getrennte lokale,
regelbasierte Basisanalyse erzeugt belegte Übersichten und optionale Rollenfelder.
Sie ist kein Sprachmodell und keine fachliche Prüfung. Fehlende Angaben bleiben leer;
Fristen und Beziehungen werden nicht erfunden. Analysezustände stehen in `analysisCoverage`
und in `read_document` mit `view: "metadata"`. [Vertrag und Grenzen](base-analysis.md). Bei `nextCursor`
muss er weiterlesen; fehlende oder ungeprüfte Seiten dürfen nicht als vollständig gelesen gelten.
Tabellenzuordnungen und OCR-Inhalte sind nicht unabhängig sachlich verifiziert.

## Speicherung und Betrieb ohne Oberfläche

Unter `~/Library/Application Support/VauldyMCP/` liegen:

- `vault/store.json`: Kennzeichnung des eigenständigen Bestands;
- `vault/documents.json` und `documents.backup.json`: atomarer Such-/OCR-Bestand und letzter gültiger Vorzustand;
- `vault/originals/`: inhaltsadressierte Kopien von Einzelimporten und noch nicht migrierten Altimporten; keine zusätzlichen Kopien neuer Ordnerimporte;
- `vault/ocr-cache/`: begrenzte, versionsgebundene Seiten-Ergebnisse; keine neuen Freigaben;
- `vault/worker/`: private Auftragswarteschlange, Fortschritt und kurzzeitig aufbewahrte Ergebnisse;
- `vault/writer.lock` und `ocr.lock`: Prozesssperren gegen verlorene Schreibzugriffe und parallele OCR im selben Bestand;
- `bin/vauldy-mcp`, `bin/vauldy-mcp-http` und `bin/vauldy-local`: eigenständige Programme;
- `oauth/`: nur nach expliziter Einrichtung private OAuth-Konfiguration, verschlüsselte Kurzzeitcodes und gehashte Tokens;
- `bin/Vauldy MCP Status.app`: die separate Menüleistenanzeige;
- `Vauldy MCP Einrichtung.app`: die installierte Verwaltungs-App für Menü-Einstiege;
- `software.json`: Versionsmanifest der installierten Software;
- `runtime-status/`: inhaltsfreie Laufzeitmarken und Sperren;
- `connections/<ID>/profile.json` und `mcp-config.json`: lokale Freigabe und Clientkonfiguration;
- optional `example/`: künstliche Beispieldateien.

Beschädigte oder fremde Bestände werden nicht durch leere Dateien ersetzt. Originale und bestehende
Sicherung bleiben erhalten. Es gibt derzeit keine automatische Wiederherstellung einer beschädigten
JSON-Datei und keine automatische Löschung verwaister Originale.

Nach der lokalen Installation lassen sich Dateien ohne geöffneten Assistenten importieren:

```sh
"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" import \
  --store "$HOME/Library/Application Support/VauldyMCP/vault" /absoluter/pfad/beleg.pdf

"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" status \
  --store "$HOME/Library/Application Support/VauldyMCP/vault"

"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" retry \
  --store "$HOME/Library/Application Support/VauldyMCP/vault" --document UUID
```

Alternativ liegt `vauldy-local` bereits im App-Paket unter `Contents/Resources/`. Status und
Import-Ergebnisse stehen als JSON auf stdout, inhaltsfreier Fortschritt auf stderr. Exitcode 2
bedeutet ein nicht vollständig erfolgreiches OCR-Ergebnis; Exitcode 1 einen Fehler. Ein CLI-Batch
stoppt beim ersten geworfenen Fehler; bereits gespeicherte Originale bleiben im Bestand.

MCP startet keine Importe oder Schreibaktionen. Der Client startet den lesenden Server bei Bedarf.
Ein gemeinsamer lokaler Worker verarbeitet Importe des Assistenten und der Kommandozeile für denselben
Bestand. Aufträge bleiben beim Schließen des Fensters erhalten. Der Worker beendet sich nach zwei Minuten
Leerlauf, sofern keine Ordnerüberwachung aktiv ist; „Worker nach Auftrag beenden“ beendet ihn nach dem aktiven Auftrag. Ausstehende Aufträge bleiben
für den nächsten ausdrücklich gestarteten Import/Wiederholungsauftrag erhalten. Kein Autostart beim Login,
kein offener Netzwerkport. Ordner werden nur nach ausdrücklicher Auswahl beobachtet. Der Mac und der lokale Bestand müssen erreichbar sein. Die exportierte Konfiguration ist
clientneutral; die optionale Desktop-Registrierung ergänzt bestehende Client-Konfigurationen. Diese Version enthält
keinen Remote-Server, Tunnel oder fertiges ChatGPT-/Claude-Verzeichnispaket.

## Wiederaufnahme, frische OCR und Worker-Steuerung

Vollständig erkannte Seiten werden unter einem Schlüssel aus Originalbytes, Dateiformat,
OCR-Konfiguration und Betriebssystemversion gespeichert. Unlesbare oder prüfbedürftige Seiten werden
nicht als erfolgreiche Cache-Treffer übernommen. Nach Unterbrechung werden fehlende Seiten ergänzt;
Seitenangaben und ursprüngliche Qualitätswerte bleiben erhalten. Ein geänderter Inhalt erhält einen
anderen Schlüssel. Der Cache enthält höchstens 32 Dokumentfassungen und ist lokale abgeleitete Daten.

`retry` verwendet vorhandene vollständige Seiten. Eine ausdrücklich frische Erkennung umgeht den Cache:

```sh
"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" retry \
  --store "$HOME/Library/Application Support/VauldyMCP/vault" --document UUID --fresh

"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" worker-status \
  --store "$HOME/Library/Application Support/VauldyMCP/vault"

"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" worker-stop \
  --store "$HOME/Library/Application Support/VauldyMCP/vault"
```

Der Worker serialisiert native OCR. Abbruch wartet weiterhin auf das tatsächliche Ende der nativen
Arbeit. Nach einem Worker-Absturz versucht ein wartender Client höchstens drei Neustarts; ansonsten
meldet er eine Unterbrechung. Ohne wartenden Client erfolgt die Wiederaufnahme beim nächsten Auftrag.
Statusaufrufe starten keine OCR. Der Worker ist kein rund um die Uhr laufender Systemdienst.

Lokal gespeicherte Seitenmetriken trennen PDF-Prüfung, Rendering, Erkennung und Cache-Zugriff.
CLI-Ergebnisse enthalten außerdem Originalprüfung, OCR- und Speicherzeiten. Suchvorbereitung und
bereinigte Textfassungen werden pro MCP-Prozess begrenzt wiederverwendet und bei Inhalts-/Freigabeänderung
verworfen; die Freigabeprüfung erfolgt weiterhin vor und nach jeder Anfrage.

## Diagnose-Logs und Audit-Trail

Version 0.6 protokolliert lokal pro Profil unter `connections/<ID>/logs/`:

- Serverstart/-ende und Werkzeugliste;
- Beginn einer Tool-Anfrage und Vorbereitung ihrer Antwort mit eigener Anfrage-/Sitzungskennung;
- Operation, UTC-Zeit, Laufzeit, Anzahl der Ergebnisse und feste Fehlercodes;
- flüchtige Dokument-Handles, um Suche und Lesen innerhalb einer Sitzung zuzuordnen;
- gespeicherte/pausierte Freigaben mit Revision und Anzahl sowie erfolgreiche Client-Registrierung.

Suchtexte, Argumente, Dokumentinhalte, Dateinamen, Originalpfade, Personenangaben und Zugangsdaten
werden nicht geloggt. Der Server schreibt ausschließlich MCP-Protokoll auf stdout. Sichere Fehlercodes
und Anfragekennungen erscheinen zusätzlich auf stderr, also auch in den Diagnoseanzeigen des Clients.
Fehler wie `notAuthorized`, `stale`, `privacy`, `unavailable` und `auditUnavailable` lassen sich so unterscheiden.
Die rohen SDK-Debugausgaben bleiben aus, da sie Anfrageinhalte enthalten können.

Im Wizard bei der Verbindung **„Logs öffnen“** wählen. Ohne UI:

```sh
"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" logs \
  --profile "/absoluter/pfad/profile.json"

"$HOME/Library/Application Support/VauldyMCP/bin/vauldy-local" logs \
  --profile "/absoluter/pfad/profile.json" --verify
```

Der erste Aufruf prüft die aufbewahrte Kette und zeigt die letzten 100 Einträge als JSON-Zeilen;
der zweite meldet nur die Prüfung. Dateien sind nur für den lokalen Benutzer lesbar/schreibbar
(0600, Ordner 0700). Prozesssperre und Synchronisierung schützen parallele Schreiber. Eine Datei ist
höchstens 1 MiB groß; vier Archive begrenzen die Aufbewahrung auf rund 5 MiB pro Profil. Ältere
Einträge entfallen bei Rotation. Benötigte Audit-Dateien vorher gesichert aufbewahren.

Eine SHA-256-Kette erkennt beschädigte oder veränderte Einträge und Lücken innerhalb des aufbewahrten
Ausschnitts. Das ist **kein manipulationssicherer oder revisionssicherer externer Nachweis**: Der lokale
Benutzer kann Dateien und die gesamte Kette ersetzen oder löschen. `responsePrepared` belegt die
Vorbereitung der Ausgabe, nicht den Empfang oder die spätere Cloud-Verwendung durch den Client.
Ein harter Prozessabbruch kann keinen Abschlusseintrag schreiben. Nicht jede JSON-RPC-Protokollnachricht
ist ein Tool-Aufruf und wird erfasst.

Ist das Protokoll nicht schreibbar oder der aktuelle Abschnitt beschädigt, werden keine Dokumentinhalte
ausgegeben. Speicherplatz/Zugriffsrechte prüfen; bei Beschädigung den gesamten Logs-Ordner zunächst
sichern und anschließend bewusst einen neuen beginnen. Die Diagnose repariert oder löscht keine
beschädigten Einträge automatisch. „Pausieren“ sperrt die Freigabe auch dann, wenn das Logging fehlschlägt.

## MCP-Status in der macOS-Menüleiste

Die Einrichtung startet eine kleine separate App **„Vauldy MCP Status“** ohne Dock-Fenster.
Nach der Installation startet auch ein vom Chatbot gestarteter MCP-Server diese Anzeige bei Bedarf.
Sie bleibt sichtbar, wenn das Einrichtungsfenster geschlossen wird oder der letzte Server endet.
Mehrere Client-Verbindungen derselben Installation teilen sich ein Symbol.

Die Menüleiste zeigt **MCP ✓** nur dann grün, wenn alle gespeicherten Verbindungen freigegeben sind und passende aktuelle Serverprozesse laufen. Andernfalls zeigt das Symbol den Bereitschafts-, Pausen- oder Prüfzustand; die genaue Erklärung steht im Menü.

Das Menü enthält für jede Verbindung den Serverstatus, die Anzahl ausgewählter Dokumente und den getrennten Freigabestatus. Im Untermenü lassen sich Zugriffe sofort pausieren, nach Bestätigung fortsetzen, die Auswahl bearbeiten und ein lokaler Verbindungstest öffnen. Direkte Einstiege führen zur Übersicht, Verbindungsverwaltung, Dokumentprüfung, Ordnerverwaltung und den Einstellungen. Beobachtete Ordner lassen sich unabhängig pro Ordner pausieren oder fortsetzen.

Die Anzeige aktualisiert sich etwa alle zwei Sekunden; Ordnerzustände etwa alle zehn Sekunden. Ein Serverprozess ist kein Nachweis einer erfolgreichen Cloud-Verbindung. „Wartet auf Chatbot“ ist ein normaler Bereitschaftszustand. Lokale Diagnoseprozesse zählen nicht als Chatbot-Prozesse. Ältere, nicht zuordenbare Server werden als unklar angezeigt.

Die Anzeige verwendet private, leere Prozessmarken mit Betriebssystem-Sperren. Eine zusätzliche begrenzte Metadatendatei enthält nur die lokale Verbindungs-ID, Serverversion, Diagnosekennzeichnung und gegebenenfalls den Zeitpunkt der letzten MCP-Werkzeuganfrage. Sie enthält keine Dokument-IDs, Inhalte, Suchanfragen, Pfade oder Prozess-IDs und wird nicht über MCP ausgegeben. Eine zurückgelassene Datei allein gilt nicht als laufender Prozess. Die Menüleiste basiert auf Apples [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar).

**„Statusanzeige beenden“** beendet ausschließlich die Anzeige. Server, Freigaben und Importe bleiben unverändert. Unter **Einstellungen → Statusanzeige öffnen** lässt sie sich wieder öffnen; auch ein neu gestarteter installierter MCP-Server öffnet sie bei Bedarf. Es wird kein Login-Autostart eingerichtet.

CLI-Steuerung (mit `vauldy-local` aus dem installierten `bin`-Ordner):

```sh
vauldy-local mcp-status --root "/absoluter/pfad/VauldyMCP"
vauldy-local status-menu --root "/absoluter/pfad/VauldyMCP"
vauldy-local status-menu-stop --root "/absoluter/pfad/VauldyMCP"
```

`mcp-status` liest Anzahl und Anzeigenstatus als JSON, ohne Server, Importe oder einen neuen Bestand
zu starten. Diese lokalen Verwaltungsbefehle verändern keine MCP-Dokumentfreigaben.

## Einen oder mehrere Ordner beobachten

Im Assistenten unter **Ordner → „Ordner zur Überwachung hinzufügen …“** einen oder mehrere Ordner
wählen. „Unterordner … einbeziehen“ gilt für neu hinzugefügte Ordner; standardmäßig wird nur die
oberste Ebene gelesen. Vorhandene und später hinzugefügte PDFs und Bilder werden über dauerhafte,
schreibgeschützte Dateiverweise durch denselben OCR-Worker verarbeitet. Neue Dokumente erscheinen in der Dokumentauswahl und müssen
weiterhin ausdrücklich pro MCP-Verbindung freigegeben werden. Keine automatische Chatbot-Freigabe.

Die Liste bleibt im eigenen Bestand unter `vault/watched-folders.json` gespeichert. Jeder Ordner
lässt sich pausieren, fortsetzen oder entfernen. Entfernen oder Löschen einer Quelldatei löscht keine
gespeicherten Dokumenteinträge oder deren OCR. Ohne erreichbares Original sind Vorschau und erneute
OCR nicht möglich. Geänderte Dateiinhalte erzeugen einen neuen Datensatz; identische
Bytes werden auch über mehrere Ordner hinweg per SHA-256 dedupliziert. Fehlgeschlagene oder teilweise
erkannte Originale werden nicht endlos neu erkannt; dafür „Text erneut lesen“ verwenden.

Die Prüfung erfolgt etwa alle fünf Sekunden zwischen OCR-Aufträgen. Eine Datei muss in zwei Prüfungen
unveränderte Größe und Änderungsdaten haben, bevor sie importiert wird. Laufende OCR kann die nächste
Prüfung verzögern. Versteckte Dateien, Paket-Inhalte, symbolische Links und nicht unterstützte Formate
werden übersprungen. Höchstens 32 Ordner und 20.000 Einträge je Ordner; der eigene Bestand und ihn
enthaltende Ordner werden abgelehnt. Fehlender Zugriff, zu große Verzeichnisse und Importfehler
erscheinen beim Ordnerstatus. Datei-Anbieter müssen die Dateien lokal lesbar bereitstellen.

Bei aktiven Ordnern läuft der Worker auch nach Schließen des Einrichtungsfensters weiter. Der Mac muss
aktiv und der Ordner erreichbar sein. „Worker nach Auftrag beenden“ stoppt auch die Überwachung.
Nach Neustart oder Prozessabbruch in der Einrichtung unter „Ordner“ ausdrücklich „Ordnerüberwachung starten“ wählen oder `watch-start` ausführen. Das Öffnen der Einrichtung startet keine Importe. Es wird kein
Login-Dienst installiert. Eine veraltete Installation kann gültige neuere Auditereignisse nicht lesen und beim Start `auditUnavailable` melden. Dafür die Software aktualisieren; keine Logs oder Freigaben löschen. Die Aktualisierung ist auch über den CLI-Helfer aus dem neuen Paket möglich:

```sh
vauldy-local update-software --root /bestehende/installation --from-app "/pfad/Vauldy MCP Einrichtung.app"
vauldy-local check-connection --profile /bestehende/installation/connections/UUID/profile.json
```

Der Check prüft die tatsächliche Serverversion, alle neun Werkzeuge und den Freigabestatus. Er lädt keine Dokumenttexte und ist kein Nachweis eines verbundenen fremden Chats. Bestehende Hostprozesse benötigen nach dem Softwareupdate einen gezielten MCP-Neustart. Normale gehostete Chats benötigen zusätzlich ihren eigenen eingerichteten Plugin-/Remote-Anschluss. [Architekturanalyse und Skalierung](https://github.com/marcomeisen/vauldy_mcp/blob/main/docs/audits/mcp-2026-11-03-architecture/README.md).

„Lokalen MCP-Bestand laden“ zeigt die importierten Dokumente. Eine bereits
geöffnete lokale Dokumentliste aktualisiert sich automatisch, ohne neue Freigaben zu setzen.
Die Ordnerüberwachung der bisherigen Vauldy-App bleibt unabhängig.

CLI-Beispiele mit dem mitgelieferten `vauldy-local` (absolute Pfade):

```sh
vauldy-local watch-add --store /pfad/zum/vault /pfad/ordner1 /pfad/ordner2
vauldy-local watch-add --store /pfad/zum/vault /pfad/ordner3 --recursive
vauldy-local watch-list --store /pfad/zum/vault
vauldy-local watch-pause --store /pfad/zum/vault --folder UUID
vauldy-local watch-resume --store /pfad/zum/vault --folder UUID
vauldy-local watch-remove --store /pfad/zum/vault --folder UUID
vauldy-local watch-start --store /pfad/zum/vault
```

`watch-add` und `watch-resume` starten den Worker. `watch-list` zeigt Konfiguration, Workerzustand
und letzte Prüfergebnisse, startet aber keine Importe. Diese Befehle gehören ausschließlich zur
vertrauenswürdigen lokalen CLI; die MCP-Werkzeuge bleiben lesend und akzeptieren keine Ordnerpfade.

## Datenschutz und Widerruf

Die ausgegebenen Inhalte werden vor jeder Übertragung lokal pseudonymisiert. Namen, Kontaktangaben
und Kennungen werden heuristisch erkannt; nicht jede Person oder jedes identifizierende Detail
ist zuverlässig erkennbar. Fachliche Inhalte können personenbezogen bleiben. Originale, Dateipfade
und dauerhafte Archiv-IDs werden nicht an MCP ausgegeben. Direkt im Chat eingegebene Angaben oder
hochgeladene Originale durchlaufen diese Prüfung nicht.

Die Freigabe ersetzt keine Prüfung von Anbieterbedingungen und erforderlichen rechtlichen Grundlagen.
Jede Verbindung erhält eigene Dokumentfreigaben. Neue Importe erweitern sie nicht automatisch.
In der Einrichtung unter „Verbindungen verwalten“ auf „Pausieren“ klicken. Bestehende MCP-Prozesse
prüfen die Freigabe vor und nach jeder Anfrage. Bereits übermittelte Chat-Inhalte werden dadurch
nicht zurückgerufen. „Freigabe bearbeiten“ erlaubt eine neue Auswahl.

## Entfernen und Paketbau

Zum Entfernen die Verbindungen pausieren, im Client trennen, laufende lokale Imports beenden und die Statusanzeige über ihr Menü schließen.
Vor dem Löschen von `~/Library/Application Support/VauldyMCP/` den Unterordner `vault` sichern:
**Er enthält jetzt den eigenständigen Dokumentbestand einschließlich Originalen.** Nur `bin` und
`connections` zu entfernen lässt den Dokumentbestand erhalten. Das bisherige Vauldy-App-Archiv
liegt außerhalb dieses Verzeichnisses und bleibt unverändert.

`python3 scripts/mcp/package.py` erstellt ein selbstenthaltendes ZIP für die Architektur des
Build-Rechners. Swift, Python oder Node sind zur Nutzung der sechs mitgelieferten Programme nicht erforderlich.
Standardmäßig ist das Paket ad-hoc für lokale Tests signiert, nicht für öffentliche Verteilung
notarisiert. Gatekeeper nicht pauschal deaktivieren. Für öffentliche Verteilung sind Developer ID,
Notarisierung und Neuinstallation auf unterstützten Systemen zusätzlich zu prüfen:

```sh
python3 scripts/mcp/package.py --identity 'Developer ID Application: …' --notary-profile '…'
```

Für synchronisierte oder File-Provider-Ausgabeordner kann ausschließlich das ZIP ausgegeben werden:

```sh
python3 scripts/mcp/package.py --name Vauldy --archive-only --output /absoluter/ausgabeordner
```

Mit `--name Vauldy` enthält `Vauldy.zip` die `Vauldy.app`. Ohne `--name` gelten
die bisherigen Paketnamen. Der Name im Finder ist unabhängig von der macOS-Bundle-ID.

Das vermeidet ein loses App-Bundle, dem der Dateianbieter nach dem Kopieren erneut Finder-Metadaten
hinzufügen kann. Das tatsächlich ausgegebene ZIP wird in einem lokalen Stagingordner erneut entpackt
und auf seine Signatur geprüft. Bei der Paketierung werden aus eigenen generierten Bundles nur
`com.apple.FinderInfo` und `com.apple.ResourceFork` entfernt. Quarantäne und andere Sicherheitsattribute
bleiben erhalten. Die Prüfung ist mit `scripts/mcp/package_metadata_smoke_test.py` reproduzierbar.

## Vorhandene MCP-UI aus diesem Repository starten

```sh
python3 scripts/mcp/run_ui.py
```

Der Befehl baut die Einrichtung, den Server, das lokale Importprogramm und die Menüleiste
zu `dist/mcp/Vauldy MCP Einrichtung.app`. Diese App lässt sich danach direkt öffnen.
`--skip-build` verwendet den bereits vorhandenen Release-Build, `--no-open` baut nur das Paket.
Für native Tests `--setup-root /absoluter/isolierter/testordner` angeben. Dadurch bleiben auch
Testverbindungen und ihre Clientregistrierung im Testbereich. Ein ungepacktes Swift-Executable
hat die benötigten Bundle-Ressourcen nicht vollständig.

Gesamte synthetische Regression: `python3 scripts/mcp/regression_test.py`.
Der Lauf umfasst Swift, Paket, echten stdio-Verkehr, 25 textbasierte und acht Raster-Originale,
Import, Audit, Clientregistrierung, Verwaltung, Menüleiste, Ordnerüberwachung, lokalen
Tunnel-Launcher-Stub, OCR-Qualität/Cache und die P0-/LVM-Prüfungen. Er installiert keine
produktive Verbindung und aktualisiert Qualitätsberichte nur mit `--update-reports`.


## Originalverweise und bestehende Kopien (ab 0.9.0)

**Ordner → „Ordner einmal importieren …“** importiert ohne dauerhafte Überwachung. Für beide
Ordnerimportwege bleiben Dateien an ihrem ursprünglichen Ort. Vauldy speichert private
Security-Scoped Bookmarks und Metadaten, OCR, Basisanalyse und begrenzte OCR-Checkpoints.
Einzeldateiimporte, etwa aus temporären Übergaben, behalten weiterhin eine eigene Originalkopie.
Es werden weder Originalbytes noch Berechtigungen oder Änderungsdaten der Quellen verändert.

**„Originalzugriff prüfen“** prüft gespeicherte Verweise und Hashes. Vorschau und OCR prüfen den
Inhalt ebenfalls. Die Zustände geben den zuletzt geprüften Zugriff wieder, keine permanente
Überwachung aller Dateizugriffsrechte. Fehlende Quellen behalten ihren Dokumenteintrag und Text.
Geänderte Quellen kennzeichnen den alten Text als historisch und die Basisanalyse als veraltet;
die neue Fassung separat importieren und ausdrücklich freigeben. Verweise können nach einem
Verschieben vom Betriebssystem aufgelöst werden; dies ist für fremde Volumes und Dateianbieter
nicht garantiert. Es gibt keinen stillen Rückfall auf einen gespeicherten Klartextpfad.

Für Altimporte **„Bestehende Kopien prüfen …“** wählen und die ursprünglichen Quellordner angeben.
Die Vorschau verändert keine Dokumente. Nur vollständig bytegleiche Kopien mit unabhängig erneut
geöffnetem Original werden zur Umstellung angeboten. Beim Bestätigen werden Datensatz, Zugriff,
Hash und vollständiger Inhalt erneut geprüft. Zuerst werden Hauptsnapshot und Sicherung auf den
Originalverweis umgestellt und synchronisiert, danach wird ausschließlich die eigene verwaltete
Kopie entfernt. Originaldateien bleiben unverändert. Fehlende, abweichende, verlinkte, gleichzeitig
veränderte oder aktiv verarbeitete Dateien bleiben erhalten; ein laufender OCR-Prozess sperrt die
Migration. Nach Abbruch zwischen Metadatenumstellung und Kopienentfernung ist die Prüfung wiederholbar.
IDs, Text, Basisanalyse und Dokumentfreigaben bleiben bei erfolgreicher Migration erhalten.
Es gibt keine automatische produktive Migration und keine Löschung über MCP.

```sh
vauldy-local import-folder --store /pfad/zum/vault /pfad/zur/quelle --recursive
vauldy-local check-originals --store /pfad/zum/vault
vauldy-local originals-preview --store /pfad/zum/vault /pfad/zur/quelle
vauldy-local originals-migrate --store /pfad/zum/vault /pfad/zur/quelle
```

Die CLI-Migration prüft rekursiv. Sie gibt nur lokale Verwaltungsberichte aus. Pfade, Bookmarks
und Dateiidentitäten werden niemals als MCP-Dokumentmetadaten ausgegeben. Der lokale Storemarker
wird vor dem ersten aktiven Originalverweis auf Formatversion 2 angehoben. Ältere Programme dürfen
diesen Bestand nicht mehr schreiben; nach Softwareaktualisierung alte Worker kontrolliert beenden
und neu starten. Ein Downgrade auf Programme ohne Verweisunterstützung ist für diesen Bestand
nicht vorgesehen.


## Bestehende Verbindung löschen (0.9.1)

Unter **Verbindungen → „Verbindung löschen“** die konkrete Verbindung bestätigen. Vauldy
sperrt zuerst deren Zugriff und entfernt sie aus der aktiven Liste. Ein exakt zu dieser
Verbindung gehörender ChatGPT-/Claude-Eintrag wird entfernt; fremde oder anders gebundene
Einträge bleiben erhalten. Schlägt die Clientbereinigung fehl, bleibt der Vauldy-Zugriff
bereits gesperrt und die Oberfläche fordert zur manuellen Prüfung auf.

Deine Dokumente und andere Verbindungen bleiben erhalten. Deaktiviertes Profil, Konfiguration
und Auditverlauf liegen lokal unter `removed-connections/<ID>/`. Diese Ablage ist eine
Sperrmarke gegen versehentliche Wiederbelebung durch alte Prozesse; sie ist keine aktive
Verbindung. Ein alter Server verliert seinen Zugriff auch mit zuvor ausgegebenen Handles.
Bereits an den Chatbot übergebene Inhalte werden dadurch nicht aus dessen Verlauf gelöscht.

Die Dokumentlisten verwenden weiterhin die Datenschutzprüfung vor jeder Ausgabe. Überlappende
Erkennungen werden im gemeinsamen Dokumentkontext vervollständigt; unbekannte ausgehende
Kennungen stoppen die Ausgabe weiterhin. Währungskürzel wie EUR werden bei der heuristischen
Namenserkennung erhalten, ausdrücklich beschriftete persönliche Angaben bleiben geschützt.
Nach Softwareaktualisierung die Vauldy-MCP-Verbindung im Chatbot neu starten, damit ein bereits
laufender Prozess die neue Version verwendet. Ein erfolgreicher lokaler Statusaufruf allein
bestätigt noch keine vollständige Dokumentliste.
