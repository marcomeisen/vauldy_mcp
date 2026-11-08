---
name: vauldy-mcp-development
description: Entwickle Vauldys eigenständigen lokalen macOS-Dokumentendienst, Swift-Package-Architektur, Persistenz, Freigaben, Setup, OAuth/Relay und Releases. Verwenden für Architektur- und Implementierungsarbeiten im Repository vauldy_mcp; die frühere Vauldy-iOS-App gehört nicht zum aktuellen Entwicklungsumfang.
---

# Vauldy MCP entwickeln

## Aktueller Produktumfang

Vauldy läuft auf dem eigenen Mac jedes Kunden. Core, Originale, OCR, Analyse, Suche und lokaler
MCP bleiben dort. Der Entwickler-Mac ist kein Kundenhost. Offline-stdio braucht weder Relay
noch Lizenzserver. Dokumentarbeit erfolgt über einen Chatbot. Die vorhandene native Setup- und
Statusoberfläche dient technischer Einrichtung, Import, Freigaben und Diagnose.

Das aktive Produkt ist `marcomeisen/vauldy_mcp`. Die frühere App `marcomeisen/vauldy` ist aus der
Entwicklung ausgeschieden. Keine App-Quellpfade, iOS-Features, Cloud-OCR, zentralen KI-Worker oder
SaaS-Infrastruktur als Voraussetzung ergänzen. Ein optionales Remote-Konzept bleibt getrennt.

## Vor einer Änderung

Das tatsächliche Checkout über Arbeitsverzeichnis und Git-Remote feststellen. `AGENTS.md`,
`Package.swift`, aktuellen Branch/Commit und den betroffenen Code lesen. Die To-do-Liste liegt
in `docs/local-first-todo.md`, Architektur und Verträge in `docs/mcp-mvp.md`. Versionen aus dem
aktuellen Code prüfen. Frühere Testzahlen und Benchmarkwerte sind historische Nachweise.

Im bestehenden MCP-Arbeitsbranch weiterarbeiten, wenn der Auftrag das vorgibt. Fremde lokale
Änderungen erhalten. Eine Umsetzung oder Skillpflege erteilt keine zusätzliche Befugnis für
Produktivinstallation, Veröffentlichung, Freigabeerweiterung oder einen Relay-Rollout.

## Zuständigkeiten im Swift-Package

| Bereich | Verantwortung |
| --- | --- |
| `Sources/VauldyDocumentCore` | Bisher extrahierter gemeinsamer Seitenmarkierungsvertrag. Keine vollständig abgeschlossene Domainmigration unterstellen. |
| `Sources/VauldyCore` | Lokale Dokumentmodelle, Originalzugriff, JSON-Speicher, OCR, Worker und Such-/Indexadapter. Rohdaten sind keine MCP-Ausgabe. |
| `Sources/VauldyDocumentIntelligence` | Lokale regelbasierte Basisanalyse und Quellenprüfung. Keine Modellinferenz voraussetzen. |
| `Sources/VauldyPrivacy` | Eigenständige lokale Privacy-Verarbeitung des MCP-Repositories. |
| `Sources/VauldyMCPRuntime` | Autorisierung, Quellenbindung, geschützte Ausgabe-DTOs, begrenzte Caches, Audit und lokale Verwaltungsdienste. |
| `Sources/VauldyMCPProtocol` | Gemeinsamer Dispatcher und Discovery für stdio und HTTP. |
| `Sources/VauldyOAuth`, `Sources/VauldyMCPHTTP`, `Sources/VauldyRelay` | Getrennte optionale Zugangswege, Token-/Gerätebindung und Relay-Client. |
| `Sources/VauldyMCPSetup`, `Sources/VauldyMCPStatus`, `Sources/VauldyLocalCLI` | Native technische Bedienung und vertrauenswürdige lokale Verwaltung. Keine OCR-/Privacy-Logik in Views. |

JSON und vorhandenes Backup bleiben der führende Bestand. Kompakte Pagination ohne Auszüge ist
lokaler stdio-Standard. Der persistente SQLite-/FTS5-Index ist optional und aus JSON wiederaufbaubar.
Neue Storage-Arbeit hinter bestehende Abstraktionen legen. Keine automatische Migration realer
Bestände und keine Behauptung einer bereits erfolgten Umstellung auf eine primäre SQLite-Datenbank.

## Grenzen erhalten

- Originale, IDs, Profile, bestehende Zugriffe, OAuth-Geräte, Keychain und Clientkonfigurationen
  nicht für Entwicklungstests verändern. Neue Importe erweitern keine Freigabe.
- Jede externe Antwort durch `ReadOnlyMCPRuntime` führen. Freigabe und aktuelle Quelle vor der
  Ausgabe erneut prüfen, auch nach Actor-Reentrancy, Audit und Serialisierung. Keine Rohpfade,
  Originalbytes, dauerhaften Archiv-IDs oder reversiblen Privacy-Mappings ausgeben.
- OAuth-Token, Profilrevision, Client, Redirect, Resource, Geräteidentität und Lebensdauer
  getrennt binden. Lokale Zustimmung ist keine behauptete Anbieter-SSO-Identität.
- Ein Softwareupdate ist von Freigabeänderung und Hostneustart getrennt. Rollback darf kein
  altes Programm gegen inkompatible Daten starten und keine Auditdateien zur Reparatur löschen.
- Keine automatische Aktivierung von Watchern beim Öffnen der Einrichtung. Diagnosen und
  Hintergrundabfragen dürfen keinen Schlüsselbunddialog auslösen.
- Audit enthält technische Codes, Anzahlen und Zeiten. Keine Suchtexte, Dokumentinhalte,
  Credentials oder rohe Fehler. Ein vorbereiteter Antwortdatensatz beweist keinen Empfang im Chat.

Für Such-/MCP-Verträge [die Retrieval-Referenz](../vauldy-ai-search-assistant/references/local-mcp.md)
lesen. Für Import-/OCR-Änderungen den Skill [vauldy-import-ocr-sync](../vauldy-import-ocr-sync/SKILL.md)
verwenden. Native Verwaltung bleibt von der Dokumentinteraktion im Chat getrennt.

## Prüfung und Iterationsabschluss

[references/verification.md](references/verification.md) für passende Tests, Builds und Releasegates
lesen. Nur betroffene Prüfungen ausführen. Für eine Veröffentlichung gelten die zusätzlichen
Gates aus `AGENTS.md`. Die tatsächlichen Ergebnisse, Abweichungen und offenen Zielclient-Prüfungen
berichten. Nach jeder Iteration `docs/local-first-todo.md` aktualisieren, einschließlich Fortschritt,
Prüfbefehlen und nächstem Schritt. Synthetische 20.000er-Tests sind keine Abnahme realer Kundenarchive.

Diese Entwicklungsskills bleiben vom distributablen Anweisungspaket
`skills/vauldy-lokale-dokumente` getrennt. Keine Entwicklerreferenzen, Quellarchive, lokalen
Pfade oder Secrets in das Agensi-Paket übernehmen.
