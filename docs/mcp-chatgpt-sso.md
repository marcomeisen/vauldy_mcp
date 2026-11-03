# ChatGPT-Verbindung ohne manuelle Schlüssel (0.12.1)

Der eigenständige MCP verwendet für normale ChatGPT-Chats einen privaten,
verwalteten Sites-MCP mit ChatGPT-Anmeldung. Ein lokaler stdio-Eintrag allein
macht Dokumente nicht in gehosteten Chats verfügbar. Der frühere Secure-MCP-
Tunnel mit manuell einzufügendem Runtime-Schlüssel ist nicht dieser Verbindungsweg.
Die ChatGPT-Anmeldung für KI-Inferenz aus dem alten App-Repository ist ebenfalls
ein anderer Dienst; dessen Tokens werden nicht als MCP-Zugangsdaten verwendet.

## Nutzerablauf

1. „Vauldy MCP Einrichtung“ öffnen → „ChatGPT & Claude“ → ChatGPT.
2. Eine bestehende aktive Dokumentauswahl wählen und die Cloud-Weitergabe bestätigen.
3. „Mit ChatGPT verbinden“: Im Browser mit dem ChatGPT-Konto anmelden und die selbst
   gestartete Mac-Kopplung bestätigen. Die lokale Freigabe bleibt unverändert.
4. Das private Vauldy-Plugin in ChatGPT verbinden und im gewünschten Chat auswählen.
5. Zuerst `get_vault_status`, danach vollständige Listen über `list_documents` und
   alle Fortsetzungen. Offline-Fehler sind keine leeren Dokumentbestände.

Kein Nutzer muss einen API- oder Runtime-Schlüssel kopieren. Die Bereitstellung
hinterlegt den privaten Sites-Servicezugang automatisch über stdin im nativen
Schlüsselbund. Nur der Agent greift auf diesen Eintrag zu. Die Oberfläche ruft
seine lokale Verwaltung auf und erhält ausschließlich Status und Anmeldelink;
Schlüsselbund-Zugriffsrechte werden nicht erweitert. Er ist ein Betreiberzugang zum owner-private Gateway, kein
ChatGPT-Benutzerkonto. Browseridentität kommt ausschließlich vom verwalteten
Sites-Login; Servicezugang kann kein Konto vortäuschen. Nichts davon gehört in
Quellcode, Paket, Kommandoargumente, Logs oder Verbindungs-JSON.

## Grenzen und Betrieb

Dieses Deployment ist nur für seinen Eigentümer vorgesehen. Keine öffentliche
Freigabe, keine Workspace-Verbreiterung und keine Wiederverwendung für fremde
Accounts. Andere Eigentümer brauchen ein eigenes privates Deployment samt
automatisierter Bereitstellung. Dies ist keine behauptete universelle ChatGPT/
Claude-SSO-Schnittstelle. Claude kann weiterhin den vorhandenen Standard-OAuth-
Anschluss mit eigenem öffentlichem HTTPS-Endpunkt nutzen.

Der Mac benötigt Internet und einen laufenden `vauldy-relay`-Prozess. Kein
Routereingriff, offener Mac-Port oder zusätzlicher lokaler TLS-Proxy. Nach einem
Mac-Neustart den Dienst in der Einrichtung starten; kein Login-Daemon wird
ungefragt installiert. Zugriff endet nach 30 Tagen, bei Online-Widerruf oder
lokalem Entfernen/Pausieren/Ändern der bestätigten Profilrevision. Eine geänderte
Auswahl erfordert erneute Bestätigung, auch wenn sie kleiner geworden ist.

Ein bestehendes Profil wird durch Kopplung nicht gespeichert oder erweitert.
Originale und OCR bleiben lokal. Der Agent nutzt einen persistenten, vorhandenen
MCP-Prozess mit unverändertem Audit, Privacy-Prüfung und quellgebundenen Cursorn.
Vor Anfrage und Ergebnisweitergabe werden lokale Zustimmung und Profilrevision
geprüft. Der Dienst akzeptiert nur die vier lesenden Werkzeuge.

Nachrichten in D1 sind verschlüsselt (P-256 ECDH, HKDF-SHA256, AES-256-GCM,
Anfragekennung und Richtung als Bindung). Pro Aufruf existiert der private
Serverschlüssel nur im laufenden HTTP-Aufruf; weder Suchtexte noch OCR-Ergebnisse
werden im Klartext persistiert. Jobs verfallen nach 60 Sekunden und werden bei
Antwort/Abbruch oder nachfolgendem Verkehr gelöscht. Ohne weiteren Verkehr können
abgelaufene Ciphertexte länger gespeichert bleiben; sie sind nicht ausführbar.
Es gibt keine Cloud-Dokumentkopie. Der berechtigte ChatGPT-Aufruf erhält das
entschlüsselte, bereits lokal bereinigte Ergebnis.

Sites prüft private Zugriffspolicy vor der Anwendung. Ein öffentlich geschaltetes
Deployment wäre mit dieser Architektur unzulässig. Source und SQL-Migration liegen
in `cloud/chatgpt-relay`; die Sites-Source-Veröffentlichung ist eine separate,
inhaltlich identische Deploymentkopie dieses Ordners. Keine zweite MCP-Codebasis.

## Nachweis

Die gesamte Regression ergänzt Swift-Krypto-/Freigabe-/Transporttests, echte lokale
stdio-Abfragen, Worker-SQL-Integration mit synthetischen Geräten, Kontoisolation,
PKCE, Widerruf, verschlüsselte Queue und exakte Discovery-Parität. Tests verändern
weder Produktivbestand noch installierte Verbindungen oder Schlüsselbund.

Ein lokaler Test beweist keine Verfügbarkeit im Zielchat. Erst private Publikation,
Plugin-Verbindung, native Zustimmung und ein erfolgreicher Werkzeugaufruf aus einem
normalen ChatGPT-Chat belegen die vollständige Einrichtung.

Die Verbindungsverwaltung startet beim Öffnen keinen Import-/OCR-Worker. Bereits laufende
Worker bleiben unabhängig. Ordnerüberwachung nach einem Neustart ausdrücklich unter
„Ordner“ starten; die gespeicherte Ordnerauswahl und Freigaben bleiben erhalten.

## Bereitstellung vom 03.11.2026

Version 0.12 ist installiert; der owner-private Anschluss ist veröffentlicht und die
Plattform meldet das kanonische Vauldy-Plugin als installiert. Die automatische
Servicebereitstellung im allein vom Agenten gelesenen Schlüsselbund ist erfolgt.
Alle 19 Regressionen mit 153 Swift-Tests und sieben Worker-Integrationstests bestehen.
[Nachweis und offene Zielchat-Prüfung](quality/chatgpt-sso-2026-11-03.json).

Beim Öffnen der bisherigen Oberfläche zum persönlichen Anmeldeschritt wurde deren
vorhandener Watch-Worker unbeabsichtigt fortgesetzt. Er aktualisierte Referenzmetadaten
in Haupt-/Backupsnapshot. Diese Dateien sind daher nicht als bytegleich zum Beginn
zu bezeichnen. Der Lauf wurde geordnet gestoppt; der beobachtete Bestand blieb bei
2.219 Dokumenten, Profile und Clientkonfiguration bytegleich. Die aktuelle Oberfläche
startet keinen Worker mehr beim Öffnen; dies ist mit einem synthetischen nativen
Starttest abgesichert. Seit dem Stopp bleiben die geschützten Dateien unverändert.
Es wurden keine Originaldateien durch die SSO-Implementierung geschrieben oder gelöscht.

Die persönliche Dokumentbestätigung, Browseranmeldung und ein echter Aufruf aus dem
normalen Chat bleiben ein separater letzter Nutzerschritt. Das veröffentlichte Plugin
allein berechtigt den Dienst noch nicht zum Lesen eines Dokuments.

## 0.12.1: Abschluss der persönlichen Anmeldung

Die native Auswahl von 147 bestehenden Dokumenten und die ChatGPT-Browseranmeldung sind
bestätigt. Der laufende Mac-Agent hat die Kopplung übernommen. Beim Live-Statuscheck wurde
die Browserprüfung vom reservierten MCP-Pfad auf einen eigenen, angemeldeten und
CSRF-geschützten API-Pfad umgestellt; der MCP-Transport bleibt separat geschützt.

Infrastrukturprotokolle können eigene HTTP-Header erfassen. Gerätezugänge werden deshalb
ab 0.12.1 ausschließlich im TLS-geschützten JSON-Inhalt der privaten Geräterouten übertragen.
Keine Request-Bodies oder Geheimnisse loggen; Diagnoseausgaben nur mit freigegebenen Feldern,
niemals vollständige Infrastruktur-Request-Header ausgeben. Legacy-Header authentifizieren
keine Geräte mehr. Die Erneuerung eines Gerätezugangs hält Besitzer, Geräteidentität, Profil
und Ablaufdatum konstant und verwirft den alten Zugang; verlorene Antworten sind über einen
privat im Schlüsselbund gespeicherten nächsten Zugang wiederholbar.

Alle 19 Regressionen mit 154 Swift-Tests und zehn Worker-Integrationstests bestehen.
macOS kann nach Aktualisierung des lokalen Entwicklungspakets die Freigabe für den eigenen
Schlüsselbundeintrag erneut verlangen. Diesen geschützten Systemdialog bestätigt der Nutzer
direkt auf seinem Mac. Dafür wird kein API-Schlüssel eingegeben und keine Freigabe für ein
anderes Programm eingerichtet. Zum dokumentierten Zeitpunkt wartet die abschließende
Zugangserneuerung auf diesen Systemdialog; der Mac-Dienst ist dafür pausiert.
