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
