# Verifikation der Auslagerung und Basisanalyse

Stand: 02.11.2026. Ausschließlich künstliche Dokumente und isolierte Bestände.

| Prüfung | Ergebnis |
| --- | --- |
| Frischer unabhängiger Build und Swift-Tests | 95 Tests, 14 Suiten bestanden |
| Unabhängiger Release-Build | Server, CLI, Einrichtung und Statusprogramm gebaut |
| Textkorpus | 26 Fälle, 14 Domänen; alle annotierten Sollwerte erfüllt |
| Rollenfelder im Textkorpus | 87 korrekt, 0 falsch gefüllt, 0 erwartete Felder fehlend |
| Kritische Übersichtsinhalte im Textkorpus | 43 von 43 erhalten |
| Native Rastermessung | 5 von 8 Fällen erfüllen sämtliche strikten Sollwerte |
| Rollenfelder in der Rastermessung | 27 korrekt, 0 falsch gefüllt, 3 erwartete Felder fehlen |
| Kritische Raster-Übersichtsinhalte | 11 von 15 erhalten |
| Original → echtes CLI → echter MCP | 25 synthetische PDF-Originale, 25 Metadatenlesungen |
| Freigaben und Widerruf | Ohne Freigabe abgelehnt, danach lesbar, nach Widerruf abgelehnt |
| Unveränderlichkeit im Wire-Test | Archiv- und Originalbytes unverändert |
| Bestehender P0-/LVM-Test | Alle 12 P0-Prüfungen bestanden |
| Paketprüfung | Ad-hoc signiert, Signaturen, Anleitungen, echter Wire- und Verwaltungscheck bestanden |
| Paketierter Import | Echter Worker/OCR/Read/Widerruf, Cache und frische Wiederholung bestanden |
| Auditprotokoll | Reale Aufrufe, sichere Diagnose und Ablehnung beschädigter Prüfkette bestanden |

Die Rasterfälle Bank, Behördenbescheid und Fahrzeugunterlage bleiben wegen nativer
OCR-Auslassungen prüfbedürftig. Ihre strikten Qualitätsfehler werden im JSON-Bericht nicht
in Erfolge umgeschrieben. Die grünen Swift-Tests prüfen hier insbesondere belegte Felder,
offene Qualitätszustände und unveränderte Originale. Sie behaupten keine perfekte OCR.

Der P0-Bericht enthält weiterhin `quality_pass: false`: strukturierte Organisationsauflösung,
exakte Token-/Ausstellerfilter der Relevanzsuche und weitere fachliche Auditziele sind nicht
durch die Auslagerung erledigt. Maßgeblich für die bestehende P0-Regression ist der separat
ausgewiesene bestandene P0-Teil. Der neue Textkorpus ersetzt diese älteren Messungen nicht.

Der Wire-Test meldet 20 abgeschlossene Basisanalysen, vier prüfbedürftige und eine nicht
verfügbare Analyse. Diese Zustände sind fachlich von vollständiger Listenausgabe und
OCR-Seitenverarbeitung getrennt. Zwölf ausgehende Titel wurden durch den übernommenen
konservativen Privacy-Detektor verändert; dessen semantische Falschpositivrate wurde nicht
annotiert. Gespeicherte Dokumentqualität und ausgehende Antwortqualität bleiben getrennte
Messaufgaben. Es wurde kein Sprachmodell und kein reales Archiv bewertet.

Das ursprüngliche App-Repository blieb sauber auf
`9b523749f52042bb159750401eb82170c6059ac9`. Keine App-Quellpfade werden vom neuen Paket
kompiliert. Produktionsarchive, installierte Profile und Clientkonfigurationen wurden nicht
verändert. Die Auslagerung übernimmt ausschließlich Quellcode und synthetische Tests;
Details: [Herkunft](../provenance.md).

Maschinenlesbare Messungen: [Textkorpus](transcript-baseline.json),
[Rasterkorpus](native-raster-baseline.json), [echter Wire-Test](base-analysis-wire.json),
[P0-Regression](p0-retrieval.json). Befehle und Grenzen: [Basisanalyse](../base-analysis.md).

Das lokale Paket ist ein geprüfter Entwicklungsbuild mit Ad-hoc-Signatur. Es ist nicht als
notarisierte öffentliche macOS-Veröffentlichung ausgewiesen. Build-Artefakte und Testoriginale
werden nicht in Git eingecheckt.
