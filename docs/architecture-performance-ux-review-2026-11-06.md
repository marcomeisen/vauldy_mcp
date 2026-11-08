# Review: Architektur, Performance, UX und Textqualität

Stand: 06.11.2026, Branch `codex/local-first-product-readiness`, Basiscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6` einschließlich des bestehenden Arbeitsstands.
Review der aktuellen Quellen; keine Produktivdaten, Profile, Originale, Keychain-Einträge
oder installierten Programme verändert. Die laufende Zielchat-Abnahme bleibt offen.

## Gesamturteil

Die lokale Modularchitektur ist eine brauchbare Grundlage. Core, Privacy, MCP-Runtime,
Protokoll, Setup und optionaler Relay haben erkennbare Zuständigkeiten. Stdio benötigt
keine Cloud. Freigaben, Quellseiten, Widerruf und konservative Feldbelege sind im Code
verankert. Der gemeinsame DocumentCore enthält bisher hauptsächlich den Seitenmarkierungsvertrag;
die Domänenmodelle liegen weiterhin in Core. Eine erneute Extraktion für die ausgeschiedene
Vauldy-App hat derzeit keinen Produktnutzen.

Die nächsten Investitionen sollten die Qualität und Auffindbarkeit vorhandenen Textes,
eindeutige Betriebsdiagnose und größenunabhängigere Speicherung betreffen. Neue Agenten
und weitere Fachwerkzeuge beheben diese Grundlagenprobleme nicht.

## Befunde nach Priorität

### P1: Ein zusätzliches Dokument kann alle Freigaben unbenutzbar machen

`ReadOnlyMCPRuntime.authorizedDocuments` begrenzt den gesamten geladenen Bestand auf 20.000
Dokumente, bevor die individuelle Freigabe gefiltert wird. Neu gemessen: 20.000 kurze
synthetische Datensätze funktionieren mit genau einer Freigabe. Bei 20.001 scheitern alle
vier Statusabrufe mit „Der freigegebene lokale Bestand ist nicht lesbar“.

Zusätzlich begrenzt `FileVaultSnapshotSource` den gesamten JSON-Snapshot auf 128 MiB.
Bei 20.000 Dokumenten bleiben im Durchschnitt rund 6,7 kB JSON pro Dokument einschließlich
OCR und Metadaten. Bisherige Erfolge mit kurzen synthetischen Dokumenten bestätigen deshalb
keinen Betrieb mit 20.000 längeren Verträgen. `LocalDocumentStore.save` liest, kodiert und
sichert den gesamten Snapshot bei jedem Speichern.

**Nächster Schritt:** Grenzen verständlich vor einem Import anzeigen; die harte globale
Dokumentgrenze und den vollständigen Lade-/Schreibpfad gemeinsam überarbeiten. Einen
additiven lokalen Storage-Piloten mit langen Texten, Backup, Restore und lesbarem Alt-JSON
prüfen. Kein ungeprüftes Erhöhen aller Grenzen, keine automatische Migration.

### P1: Cachegrenze verursacht wiederholtes vollständiges JSON-Dekodieren

Im Standardbetrieb behält `MCPVaultSnapshotCache` maximal 64 MiB. Oberhalb davon werden
Snapshot und autorisierter Cache nicht behalten. Der optionale größere Cache verschiebt
diese Grenze auf 96 MiB und beseitigt die Struktur nicht. Kompakte Folgeseiten sind ein
separater optimierter Pfad; sie lösen nicht jede Status-/Such-/Inhaltsabfrage.

Neue Messung mit je 500 synthetischen Dokumenten und einer Freigabe:

| JSON-Größe | Erster Statusabruf | Drei weitere Abrufe |
|---|---:|---|
| 60.058.500 Bytes | 120,6 ms | 20,1 / 9,1 / 19,8 ms |
| 70.054.500 Bytes | 143,7 ms | 112,8 / 128,4 / 104,9 ms |

Die Daten belegen die Grenze an diesem Testbestand, keine allgemeine Laufzeitprognose.
Der beobachtete Effekt erklärt allein keine vierminütige Chatantwort. Dafür müssen
Werkzeugwahl, Wiederholungen, Relay, Modellwartezeit und Tabellenanzeige getrennt gemessen werden.

### P1: Suchtext verliert Treffer bei Worttrennungen

`VaultDocumentFilter` und `VaultRuntime` normalisieren Groß-/Kleinschreibung und Diakritika,
verbinden aber keine getrennten Wörter. Neu geprüft: Von drei freigegebenen Dokumenten mit
`Versicherung`, `Versiche-\nrung` und `Versiche\u00adrung` finden sowohl `list_documents`
als auch `search_documents` bei „Versicherung“ nur eines.

**Nächster Schritt:** Eine separate Suchprojektion mit Soft-Hyphen-Behandlung und konservativer
Zeilentrennungsauflösung aufbauen. Originaltext und Quellkoordinaten erhalten. Echte Bindestriche,
Kennungen und Beträge dürfen nicht verändert werden. FTS, Listenfilter, Suche und Fundstellen
müssen dieselbe Suchnormalisierung verwenden; Varianten sollen auf ursprüngliche Belege zeigen.

### P1: Der OCR-Zweitlauf verbessert im aktuellen Korpus noch keine exakten Felder

Die neun gezielten Swift-Tests wurden erneut ausgeführt und bestanden. Das bedeutet
Regressionserhalt, nicht vollständige Erkennungsqualität:

| Synthetischer Scan | Erstlauf exakt | Zweitlauf exakt | Zweitversuche | Review vorher/nachher |
|---|---:|---:|---:|---|
| Saubere Kontrolle | 4/4 | 4/4 | 0 | nein/nein |
| Kleine Schrift | 4/4 | 4/4 | 0 | nein/nein |
| Blasse Kopie | 4/4 | 4/4 | 0 | nein/nein |
| Schräger Scan | 4/4 | 4/4 | 0 | nein/nein |
| Schwieriges Raster-PDF | 0/4 | 0/4 | 4 | nein/ja |
| Mehrdeutige Kennung | 3/4 | 3/4 | 1 | nein/ja |
| Dichte Beträge | 4/4 | 4/4 | 0 | nein/nein |
| Gesamt | 23/28 | 23/28 | 5 | zwei zusätzliche Warnungen |

Es wurden keine Zeilen repariert. Beim Raster-PDF stieg die Erkennungszeit von 184 auf
335 ms, bei der mehrdeutigen Kennung von 120 auf 188 ms. Die Warnungen sind nützlich;
eine bessere Zeichenerkennung ist damit nicht belegt. Die Tests verlangen für schwierige
Fälle überwiegend, dass richtige Erstlauf-Felder erhalten bleiben. Sie verlangen noch
keinen Qualitätsgewinn für das Raster-PDF.

Konkrete Ansatzpunkte im Code:

- `NativeLocalDocumentOCR` sucht Retry-Ziele nur unter vorhandenen Vision-Zeilen.
  Vollständig übersehene Bereiche können dadurch nicht nachgelesen werden.
- Bilder und PDF-Renderings sind im gewöhnlichen Seitenpfad auf 3072 Pixel lange Kante
  begrenzt. `lineCrop` vergrößert einen Ausschnitt dieses bereits gerenderten Bildes.
  Dabei vorher verlorene Details kommen durch Vergrößerung nicht zurück.
- `isUsableEmbeddedText` prüft im Wesentlichen Textlänge, alphanumerische Zeichen und
  zwei ungültige Zeichen. Plausibel aussehende, aber falsche PDF-Textschichten können
  diesen Test bestehen. Nicht jede solche Seite wird visuell gegengeprüft.
- Vision-Geometrie wird bei der Erkennung verwendet, aber nicht als Zeilen-/Blockstruktur
  gespeichert. Mehrspaltigkeit, Tabellen und die Zuordnung von Betrag zu Beschriftung
  bleiben anfällig. Überlappende Kacheln behalten bewusst doppelte Zeilen.
- Durchschnittliche Seitenkonfidenz beweist keine Vollständigkeit. Der fehlgeschlagene
  Rasterfall wurde im Erstlauf sogar ohne Review markiert.

**Empfohlene OCR-Reihenfolge:** Zuerst den schwierigen Rasterfall als echtes Qualitätsziel
fixieren. Danach schwache Bereiche aus dem Original mit begrenzter zusätzlicher Auflösung
neu rendern; Schräglagen-/Kontrastvarianten nur gezielt und im A/B-Test prüfen. Unbeobachtete
Textregionen und verdächtige eingebettete Textschichten separat erkennen. Anschließend
Layoutinformationen additiv speichern und Lesereihenfolge verbessern. Rohtext, Varianten,
Quellseite und Unsicherheit getrennt erhalten; Kennungen bei Widerspruch nicht erraten.

Ein zusätzlicher vollständig lokaler OCR-Motor ist eine spätere Vergleichsoption. Seine
Einführung ist erst begründet, wenn ein gleicher annotierter Korpus bessere exakte Felder,
weniger Auslassungen und vertretbare Laufzeit/Speicherlast zeigt. Für diese Prüfung wurde
kein Motor installiert, kein Modell geladen und kein Dokument übertragen.

### P1: Gleiche Versionsanzeige verdeckt unterschiedliche Fähigkeiten

`MCPBuild.version` ist weiterhin 0.13.0. Das dokumentierte Paket vom 05.11. enthält sechs
Werkzeuge, die aktuelle Quelle acht. `MCPLocalProbe` prüft Version und die vier Basiswerkzeuge;
die ermittelte Werkzeugliste wird im Diagnosedialog nicht angezeigt. Ein erfolgreicher
lokaler Test garantiert deshalb nicht, dass Fristenübersicht und Vergleich verfügbar sind.

Der Updater vergleicht zusätzlich Paketsignaturen und schützt Generationen/Rollback;
er entscheidet ausdrücklich nicht nur anhand dieser Versionsnummer. Das Problem betrifft
Nachvollziehbarkeit und Fähigkeitserkennung. Inkompatibilitäten haben zudem einen sehr
allgemeinen Fehlertext.

**Nächster Schritt:** Buildkennung und Werkzeugfähigkeiten in Paket, laufendem Prozess und
Diagnose sichtbar machen. Fehlende Fähigkeit, nicht neu gestarteter Prozess, Architektur-,
Schema- und Signaturproblem mit eigener Handlungsempfehlung ausweisen.

## UX/UI

Die aktuellen SwiftUI-Views haben gute Grundlagen: Gesamtfortschritt für rekursive Imports,
Datei/Phase/Seiten, Abbruchzustand, getrennte Importergebnisse und bewusste Freigabe.
„Text erneut lesen“ ist vorhanden. Die Verbindungsdiagnose weist korrekt darauf hin,
dass ihr lokaler Test keine erfolgreiche ChatGPT-Anfrage bestätigt.

Die größte UX-Lücke ist der nachvollziehbare nächste Schritt:

1. Nach dem Import direkt zu problematischen Seiten führen: Original und erkannter Text,
   konkreter Prüfgrund, gezielter erneuter Durchlauf und Vorher-/Nachher-Vergleich. Die
   technische Einrichtungsoberfläche bleibt dafür zuständig; fachliche Arbeit bleibt im Chat.
2. Lokaler Dienst, Freigabe, optionaler Relay, Client-Werkzeugstand und letzter erfolgreicher
   Chatabruf als getrennte Zustände anzeigen. Zu jedem Fehler genau eine passende Aktion.
3. Im unbereitgestellten Relay-Zustand erklärt die View eine notwendige Bereitstellung,
   bietet dort aber nur eine Statusprüfung. Einen ausführbaren Einrichtungsweg oder klare
   Voraussetzungen anbieten. Der separate Testtunnel ist nicht mit diesem Produktweg gleichzusetzen.
4. Tastaturbedienung, VoiceOver, schmale Fenster, lange Dateinamen und große Listen in einer
   frischen isolierten Instanz erneut prüfen.

Diese UX-Befunde stammen aus den aktuellen Views und den bereits dokumentierten Abläufen.
Es wurde in diesem Review keine neue native Bildschirm-/Accessibility-Abnahme durchgeführt.

## Neu ausgeführte Prüfungen und Grenzen

[Maschinenlesbarer Nachweis](quality/architecture-review-2026-11-06.json).
Sources und Tests stimmen per `diff -qr` mit der bestehenden isolierten Buildkopie überein.
Kein neuer Build; keine historischen Ergebnisse als neue Ergebnisse übernommen.

Vom Repository aus ausgeführt:

```sh
diff -qr -x .DS_Store Sources /private/tmp/vauldy-deadlines.kTXJpJXZ/source/Sources
diff -qr -x .DS_Store Tests /private/tmp/vauldy-deadlines.kTXJpJXZ/source/Tests
swift test --package-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source --disable-sandbox --cache-path /private/tmp/vauldy-deadlines.kTXJpJXZ/cache --disable-automatic-resolution --scratch-path /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build --skip-build --no-parallel --filter 'OCRTargetedRetryTests|OCRWhiteMarginsTests'
python3 scripts/mcp/architecture_review_probe.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp --output docs/quality/architecture-review-2026-11-06.json
python3 scripts/mcp/deadline_overview_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
python3 scripts/mcp/field_extraction_smoke_test.py /private/tmp/vauldy-deadlines.kTXJpJXZ/source/.build/release/vauldy-mcp
```

Ergebnis: Neun Swift-Tests in zwei Suites in 2,880 s bestanden; Fristentest mit 22 synthetischen
Datensätzen bestanden (ein gemessener Aufruf für fünf Dokumente: 177,4 ms nach Auswahl);
Feldauslese mit sieben Dokumenten und 17 Prüfgruppen bestanden. Der Review-Probe meldet
auch die beschriebenen Fehler und Suchlücken; sein erfolgreicher Programmabschluss ist
keine bestandene Produktabnahme. Ein vorheriger explorativer Lauf mit ungültigem Testprofil
wurde verworfen und nicht als Performancebeleg verwendet.

Keine neue P95-/Peak-RSS-, vollständige Workerlast-, Installer-, Notarisierungs-, Offline-Mac-
oder reguläre ChatGPT-Abnahme. Keine Aussage zur tatsächlichen vierminütigen Vertragsanfrage.

**GO:** kontrollierte Entwicklung und synthetischer Pilot. **NO-GO:** uneingeschränkte
Kundenzusage für 20.000 beliebige Dokumente, belastbare Chatlatenz oder vollständig
abgenommene Kundeninstallation. Die offenen Release- und Zielclient-Gates bleiben bestehen.
