---
name: vauldy-import-ocr-sync
description: Entwickle Vauldys lokalen macOS-Import, rekursive Ordnerauswahl, Importfortschritt, OCR-Zweitlauf, Worker, Originalreferenzen und Bestandsabgleich im Repository vauldy_mcp. Verwenden für Import-/OCR-Regressionen; frühere Share Extension und iCloud-App-Synchronisation gehören nicht zum aktuellen Entwicklungsumfang.
---

# Vauldy lokaler Import und OCR

Der Skillname bleibt für bestehende Verweise erhalten. Aktiver Produktpfad ist der eigenständige
MCP auf dem Kunden-Mac. Die frühere iOS-App, Share Extension und deren iCloud-Synchronisierung
sind kein aktueller Implementierungsauftrag. Aktuelles Checkout, `AGENTS.md`,
`docs/base-analysis.md` und betroffenen Code lesen, statt alte App-Pfade zu verwenden.

## Lokaler Ablauf und Zuständigkeiten

`bewusste Dateiauswahl/Ordneraktion -> LocalImportService/LocalDocumentStore -> dauerhafte Queue
-> LocalImportWorker -> Originalzugriff + NativeLocalDocumentOCR -> OCR/regelbasierte Basisanalyse
-> atomarer JSON-Bestand + Backup -> autorisierte Suche/MCP`

Import, Originalzugriff, Cache und OCR liegen in `Sources/VauldyCore`; technisches UI in
`Sources/VauldyMCPSetup`. Relevante Typen über `rg` finden: `LocalImportService`,
`LocalDocumentStore`, `LocalImportWorker`, `NativeLocalDocumentOCR`, `LocalOCRPageCache`,
`LocalOriginalAccess`, `LocalWatchedFolderStore`, `LocalWatchedFolderMonitor`.
MCP-Werkzeuge sind lesend und nehmen keine Importpfade an. Ein Import erweitert keine Freigabe.

Dateiimport, einmaligen rekursiven Ordnerimport und dauerhafte Überwachung getrennt halten.
Unterordner berücksichtigen. Gesamtfortschritt bezieht sich auf den ganzen ausgewählten Batch,
nicht nur auf das gerade geöffnete Unterverzeichnis. Datei, Arbeitsschritt und Seitenfortschritt
zeigen. Neue, vorhandene, fehlgeschlagene und übersprungene Dateien im Bericht trennen.
Gefilterte Auswahl, aktuell sichtbare Auswahl und Gesamtauswahl nicht verwechseln.

## Originale und Freigaben

- Einzelimporte halten standardmäßig verwaltete Kopien, Ordnerimporte schreibgeschützte
  Security-Scoped Bookmarks. Keine PDF-Rohbytes in `documents.json` einbetten.
- Originalzugriff über einen Lease bis zum tatsächlichen Ende von OCR/Quick Look halten,
  auch nach Swift-Abbruch oder Zeitlimit. Kein Rohpfad-Fallback bei fehlgeschlagenem Bookmark.
- Hash und Identität vor Erkennung und vor Commit prüfen. Geänderte Quelle macht alten Text
  historisch, fehlende Quelle löscht weder Datensatz noch gespeicherten Text.
- Quellen-Neuauswahl darf Autorität nur nach vollständiger Inhaltsgleichheit erneuern. ID,
  vorhandenen Text und Freigaben erhalten. Migration eigener Alt-Kopien ist explizite lokale
  Wartung unter den vorgesehenen Sperren, kein automatischer Start-/MCP-Schritt.
- Bestandsabgleich, Qualitätsbericht und neue Chatfreigabe sind getrennte Nutzerentscheidungen.
  Kurzlebige Originalfähigkeiten an konkrete Queuejobs/Prozessinstanz binden und nach Ende verwerfen.

## OCR und gezielter zweiter Durchlauf

Lesbaren eingebetteten PDF-Text verwenden. Rasterregionen bzw. konservativ ganze Rasterseiten
mit nativer Apple Vision erkennen. Physische Seitenmarkierungen und Leer-/unlesbar-/Review-Zustände
erhalten. Keine erfundene hohe Konfidenz, keine Kennung durch erwarteten Solltext ersetzen.

`OCRWhiteMargins` entfernt ausschließlich weiße Außenränder mit Sicherheitsabstand. Helle farbige
Randzeichen, Fußzeilen und Tabellen dürfen nicht verloren gehen. Keine pauschale Verkleinerung,
keine gelockerten Konfidenzschwellen und keinen Anbieterwechsel als beiläufige Optimierung.

Der gezielte Zweitlauf gehört zu `NativeLocalDocumentOCR` und `OCRLineRecovery`. Er arbeitet
bei begründet schwachen/auffälligen Zeilen lokal mit begrenztem Retrybudget. Widersprüche und
unsichere Kennungen müssen Review auslösen. Einen bloßen Wiederholungsversuch oder mehr Review-
Markierungen nicht als bewiesene Qualitätsverbesserung darstellen. `targetedRetries` und
`recoveredLines` in `LocalOCRMetrics` getrennt von exakten Sollfeldern und Fehlalarmen auswerten.

OCR-Konfigurationsänderungen müssen alte Checkpoints ausschließen. Cacheversion bindet Original,
Dateityp, Konfiguration und Systemstand. Nur erfolgreiche Seiten ohne Review wiederverwenden.
Explizites „Text erneut lesen“/`fresh: true` gilt auch für abgeschlossene Importe, umgeht den Cache
und erhält Original, Identität und Freigaben. Alte abgeschlossene Bestände nicht automatisch umschreiben.

## Worker und Wiederanlauf

Ein per Vault gesperrter Worker besitzt die langlebige Queue und native OCR-Laufzeit. Keine
Parallelworker über mehrere UI-Instanzen starten. Der anfragende Client besitzt nicht die native
OCR-Anfrage. Abbruch erst nach tatsächlichem nativen Ende abschließen und alte Versuche vor Commit
abweisen. Nach Prozessabbruch den Sperrzustand prüfen, bevor verwaiste Aufträge normalisiert werden.

Einrichtungs-/Verbindungsstart startet keine neuen Watcher. Einmaliger Abgleich aktiviert keine
bisher gestoppte Überwachung. Zustände, begrenzte Wiederanläufe und Stop-nach-aktuellem-Auftrag
erhalten. Weitere CPU-/Speicherschutz- und Lastabnahmen anhand der aktuellen To-do-Liste behandeln;
keine bereits abgeschlossene Ressourcenabnahme unterstellen.

## Prüfen

Aktuelle Tests und Kommandos stehen in
[der Entwicklungsreferenz](../vauldy-mcp-development/references/verification.md).
Bei OCR-Änderungen native PDF-/PNG-Erkennung, `OCRWhiteMarginsTests`, `OCRTargetedRetryTests`
und betroffene echte Worker-/MCP-Wiretests ausführen. Cache, Frischerkennung und gespeicherten
Text bis zur MCP-Ausgabe prüfen. Die acht Rasterfälle bleiben strikte Sollwertprüfungen.

Benchmarks sequenziell am gleichen synthetischen Korpus, mit identischen Seiten und unabhängig
geprüften Sollwerten durchführen. Erster Systemaufruf, warmer neuer Import und Cachetreffer sind
verschiedene Fälle. Native Konfidenz, exakte Felder, Fehlalarme, vollständige Zeilen und Laufzeit
getrennt berichten. Eine Sandbox-Verweigerung ist keine OCR-Qualitätsaussage.

Native UI nur als vollständiges Bundle aus `scripts/mcp/run_ui.py` mit isoliertem `--setup-root`
prüfen. Produktivarchive, Keychain und Hostkonfiguration nicht für Tests verwenden. Bestehende
Datensätze/Freigaben nicht migrieren. Nach der Iteration tatsächlichen Fortschritt und offene
Qualitätsnachweise in `docs/local-first-todo.md` ergänzen.
