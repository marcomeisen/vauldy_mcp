# R5, R6, OCR und Paket · 6./7. November 2026

Geprüft wurde der Arbeitsstand von `codex/local-first-product-readiness`
auf Basis von `87ab76c`. 139 Build- und Testdateien wurden zwischen
Arbeitsbaum und isolierter Buildkopie byteweise verglichen.

## R5 · VoiceOver

Der [native Test des Importdialogs](setup-quality-r5.md) deckt Tastaturbedienung,
die Accessibility-Beschriftungen, den Seitenwechsel und die OCR-Vergleichsansicht
ab. Die separate VoiceOver-Abnahme entfällt auf Nutzerwunsch vom 7. November.
R5 ist im vereinbarten Umfang abgeschlossen.

Am 7. November wurde der Bildschirm nach dem Entsperren erneut erreicht. Der
synthetische Prüffall öffnete die Originalvorschau von Seite 2 mit dem Hinweis
auf fehlenden lesbaren Text. In den Systemeinstellungen war VoiceOver ausgeschaltet.
Die automatische Freigabeprüfung lehnte das Einschalten wegen der bestehenden
Vorgabe zu unveränderten Host-Konfigurationen ab. Nach ausdrücklicher
Freigabe wurde VoiceOver eingeschaltet. Eine beobachtbare Screenreader-Ausgabe
und eine erfolgreiche Navigation waren noch nicht nachgewiesen. Der Nutzer
beendete den Versuch und nahm VoiceOver aus dem Abnahmeumfang. Anschließend
wurde VoiceOver ausgeschaltet und der Schalterzustand „off“ geprüft.

## R6 · Fristenpilot

Der Server wurde aus dem finalen ZIP extrahiert und per stdio mit einer
frischen Kopie des synthetischen Fristenpilot-Profils gestartet. Die
Werkzeugerkennung ergab acht Werkzeuge. `list_documents` mit „Fristenpilot“
lieferte die drei freigegebenen Dokumente in 16,4 ms. `get_deadline_overview`
lieferte in 57,0 ms drei Zeilen mit den Ergebnissen „berechnet“, „explizites
Datum“ und „offen“ und Quellenbelegen auf Seite 1. Eine separate Prüfung
nach Widerruf bestätigte die Zugriffssperre. Die zwei gemessenen Aufrufe
summieren sich lokal auf 73,4 ms.

Der zusätzliche Fristen-Smoke-Test gegen denselben Server bestand mit 22
synthetischen Datensätzen. Ein gemessener Aufruf für fünf Dokumente dauerte
107,6 ms. Für die Zielchat-Abnahme waren der Mac gesperrt und kein isolierter
Fristenpilot-Tunnel verfügbar. Werkzeugzahl und Zeit bis zur sichtbaren
Tabelle im regulären ChatGPT-Gespräch wurden daher nicht erhoben.

Die Nachprüfung am 7. November bestätigte die Anmeldung in Safari. Im frischen
Chat und im persönlichen Plugin-Verzeichnis war ausschließlich die bestehende
Vauldy-Verbindung sichtbar. Der Dialog für einen zusätzlichen Tunnel verlangte
eine Tunnel-ID. Im isolierten Fristenpilot-Verzeichnis lagen weder eine
Bereitschaftsdatei noch ein Chat-Audit vor. Die Einrichtung wurde ohne Speichern
geschlossen. Die Zielchat-Messung bleibt bis zur Bereitstellung des separaten
synthetischen Testanschlusses offen.

## OCR · Eingebettete PDF-Textschicht

Der synthetische A/B-Test verwendet eine PDF, deren sichtbare Seite „Police“
und „49,99 EUR“ enthält. Die eingebettete Zeichenzuordnung ersetzt das
große P durch U+E000. Der bisherige Pfad übernahm dieses Zeichen. Der neue
Pfad verwirft die beschädigte Textschicht der Seite und erkennt beide
Solltexte per Apple Vision. Die Prüfung greift auch bei unerwarteten
Steuerzeichen. Die OCR-Cachekonfiguration wurde auf v6 erhöht. Gespeicherte
Texte können bei Bedarf ausdrücklich über „Text erneut lesen“ aktualisiert
werden. 35 gezielte Swift-Tests in fünf Suites bestanden.

## Paket und Prüfkommandos

`Vauldy.zip` enthält `Vauldy.app` 0.13.0 für Apple Silicon und macOS ab 14.
Die Ad-hoc-Signatur wurde nach dem Entpacken geprüft, der SHA-256-Abgleich
war erfolgreich. Developer-ID-Signatur, Notarisierung und die Abnahme auf
einem frischen Offline-Mac bleiben separate Freigabeschritte.

Die ersten beiden Befehle liefen in der isolierten Buildkopie. Für die
letzten beiden Prüfungen wird das ZIP in einen lokalen temporären Ordner
entpackt und sein enthaltener Server verwendet.

```sh
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalDocumentReviewTests|LocalImportTests|LocalOriginalReferenceTests'
python3 scripts/mcp/package.py --skip-build --name Vauldy --archive-only --output /Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp/dist/mcp/vauldy-r5-ocr-2026-11-06
codesign --verify --deep --strict "$extracted/Vauldy.app"
python3 scripts/mcp/deadline_overview_smoke_test.py "$extracted/Vauldy.app/Contents/Resources/vauldy-mcp"
```

## Temporäre Dateien

93 Vauldy-Testartefakte wurden aus `/private/tmp` entfernt. Darunter waren
überholte Build- und Benchmark-Ordner, doppelte Testbundles, ersetzte Logs
und die Buildkopie für dieses ZIP. Eigentümer, Symlinks und laufende
Zugriffe wurden vor dem Entfernen geprüft. Die isolierte UI-Testinstanz
und die Fristenpilot-Fixtures sind weiterhin verfügbar.
