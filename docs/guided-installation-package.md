# Geführtes Vauldy-Testpaket vom 07.11.2026

Das aktuelle Paket liegt unter `dist/mcp/vauldy-guided-2026-11-07/Vauldy.zip`.
Es enthält `Vauldy.app`, Version 0.13.0, für Apple Silicon und macOS 14 oder neuer.
Buildkennung: `macho.2a3541f019733a7c8e4c4517b61bb230`.
SHA-256: `02363d33e3bba0bb8f9a2783a90b4e398854f509b969f488b468df07d4fe62e1`.

## Nutzerablauf

ZIP entpacken, `Vauldy.app` nach Programme verschieben und öffnen. Bei einer frischen
lokalen Installation erscheint der Assistent automatisch. Er führt durch Prüfung,
Installation und lokalen MCP-Starttest. Installation bleibt eine ausdrückliche Aktion.
Nach einem Abbruch bleibt der Assistent geschlossen und kann über die Übersicht erneut
geöffnet werden. Bestehende Installationen und explizite Verwaltungsaufrufe werden nicht
mit dem ersten Installationsschritt unterbrochen.

Am erfolgreichen Abschluss öffnet „Chatbot verbinden“ direkt den eigenen Assistenten für
Chatbot-Auswahl, Import, Freigabe und Verbindungsprüfung. Der Übergang erfolgt nach dem
Schließen des Installationsdialogs. „Später einrichten“ beendet den Installationsschritt.
Eine Installation allein erstellt keine Dokumentfreigabe, Anmeldung oder Cloud-Verbindung.

## Tatsächlich geprüfter Stand

Arbeitsbranch `codex/local-first-product-readiness`, Basiscommit `87ab76c`, einschließlich
der vorhandenen uncommitteten Architektur-, Import- und OCR-Änderungen. Kein neuer Commit
und keine Veröffentlichung. Die lokale Buildkopie enthielt vor dem Build 267 bytegeprüfte
Dateien aus Package, Sources, Tests, Docs, Scripts und Skills. Alle 106 aktuellen
Produktquelldateien einschließlich Package/Lockdatei wurden danach erneut verglichen.
Der Quellhash und die Einzelergebnisse stehen im [Prüfnachweis](quality/guided-package-2026-11-07.json).

- Release-Build erfolgreich. Paketierung erst danach mit `--skip-build`; der Manifestwert
  `buildMode=reused` bezeichnet diese Wiederverwendung der gerade gebauten Programme.
  `sourceCommit=null` behauptet keinen sauberen Releasecommit für diesen Arbeitsbaum.
- 80 Swift-Tests in 13 Suites mit nativer synthetischer OCR bestanden, 22,795 Sekunden.
- Aus dem fertigen ZIP: reale stdio-, Management-, Update- und Rollbackprüfungen bestanden.
  Signaturfehler, inkompatible Pakete, fehlgeschlagener Start, SIGKILL, konkurrierendes Update
  und Rückkehr zur geprüften Vorversion sind Teil des Update-Tests. Signaturen hierbei ad hoc.
- Native Oberfläche aus dem fertigen Bundle mit frischem `--setup-root` geprüft.
  Automatischer Einstieg, Abbruch, manuelles Wiederöffnen, Installation, sichtbarer
  erfolgreicher Starttest und direkter Übergang zur Chatbot-Auswahl bestanden.
  Verbindungsassistent ohne Anmeldung oder Freigabe wieder geschlossen; Testinstanz gestoppt.
- Beobachtender UI-Start mit synthetischem Watch-Ordner und vorher gestopptem Worker bestanden.
  Bestand, Original und Konfiguration unverändert; kein automatischer Importstart.
  Zwei vorherige Versuche scheiterten während der Fixture-Vorbereitung am 25-Sekunden-Limit.
  Der erhaltene Testbestand belegte einen erfolgreich abgeschlossenen kalten Vision-Lauf mit
  etwa 40 Sekunden. Das Vorbereitungsbudget beträgt jetzt 90 Sekunden. Die eigentliche
  UI-Beobachtung bleibt unverändert fünf Sekunden. Dies ist kein bestandener Performance-Test.

Die folgenden Kommandos wurden in der bytegeprüften Buildkopie
`/private/tmp/vauldy-ocr-vector-wtr5pb1z` ausgeführt. `$PKG` bezeichnet ausschließlich
das aus dem finalen ZIP entpackte Testbundle unter `/private/tmp/vauldy-guided-package-20261107/Vauldy.app`.

```sh
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
VAULDY_OCR_REGION_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/region-fixtures VAULDY_OCR_COVERAGE_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/coverage-fixtures VAULDY_OCR_VECTOR_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/vector-fixtures VAULDY_OCR_AB_FIXTURES=/private/tmp/vauldy-ocr-vector-wtr5pb1z/raster-fixtures swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'MCPInstallationTests|MCPBuildDiagnosisTests|OCRMarkedRegionRecoveryTests|OCRBlockCoverageTests|OCRLayoutTests|PDFVectorTextOCRTests|OCRTargetedRetryTests|OCRWhiteMarginsTests|LocalImportTests|LocalOriginalReferenceTests|BaseAnalysisMCPTests|LocalDocumentReviewTests|SQLiteIntegrationTests'
python3 scripts/mcp/package.py --skip-build --name Vauldy --archive-only --output /Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp/dist/mcp/vauldy-guided-2026-11-07
PKG=/private/tmp/vauldy-guided-package-20261107/Vauldy.app
python3 scripts/mcp/smoke_test.py "$PKG/Contents/Resources/vauldy-mcp"
python3 scripts/mcp/management_smoke_test.py "$PKG/Contents/Resources"
python3 scripts/mcp/software_update_smoke_test.py "$PKG"
python3 scripts/mcp/setup_startup_smoke_test.py "$PKG"
"$PKG/Contents/MacOS/vauldy-mcp-setup" --setup-root /private/tmp/vauldy-guided-native-20261107
```

## Lokaler Neustart auf Nutzerwunsch

Auf ausdrücklichen Auftrag wurden die bisherigen lokalen Vauldy-Prozesse gestoppt,
die zwei passenden lokalen MCP-Client-Einträge entfernt und die aktive MCP-Installation
einschließlich bisherigem Dokumentbestand in eine private lokale Rücksicherung verschoben.
Andere Client-Einstellungen wurden strukturell auf unveränderten Inhalt geprüft.
Die native MCP-Einrichtungs-App ist gesichert; die frühere native Vauldy-App wurde gesichert
und über Finder in den Papierkorb verschoben. Die frühere Safari-Web-App und der einzelne
lokale Relay-Schlüsselbundeintrag wurden nach zusätzlicher ausdrücklicher Bestätigung entfernt.
23 Vauldy-Preference-Dateien sind lokal archiviert. Keine Zugangsdaten wurden exportiert.

Die abschließende Kontrolle ergab keinen aktiven MCP-Installationsordner, keinen passenden
Client-Eintrag, keine laufenden Vauldy-Prozesse und keine dieser drei Apps mehr an den alten
Installationspfaden. Originale und der frühere App-Dokumentbestand wurden erhalten.
Die private Rücksicherung enthält Hinweise zur bewussten Wiederherstellung. Sie liegt außerhalb
des Repositories. Entfernte Cloud-Konten und Chatbot-Anschlüsse wurden nicht verändert.
Eine neue lokale Installation und neue Freigaben hat dieser Bereinigungsschritt nicht angelegt.

## Noch offene Kundenabnahme

Keine gültige Developer-ID-Signieridentität ist auf dem Build-Mac verfügbar. Das ZIP ist
ad hoc signiert und nicht notarisiert. Für eine Kundenverteilung fehlen ein sauberer
Releasecommit, Developer ID Application, ein eingerichtetes Notary-Profil sowie die
Notarisierungs-/Staplingprüfung. Gatekeeper wurde nicht abgeschaltet.
Ein frischer physischer Test-Mac, vollständige Netztrennung und ein neuer regulärer
ChatGPT-End-to-End-Lauf wurden in dieser Iteration nicht geprüft. R6 bleibt zurückgestellt.

## Nachfolgende tatsächliche Installation am 07.11.2026

Auf gesonderten Nutzerauftrag wurde das Paket anschließend unter `/Applications/Vauldy.app`
installiert und am regulären Installationsort `~/Library/Application Support/VauldyMCP`
über den nativen Assistenten eingerichtet. Bei Beginn existierten inzwischen wieder ein
Profil und neun freigegebene Dokumente. Der erste Vorabcheck stoppte deshalb ohne Änderung.
Diese Daten wurden bei der anschließenden reinen Software-Neuinstallation erhalten.
Der vorherige Programmsatz ist separat lokal gesichert. Der Altbestand aus der vorherigen
Bereinigung wurde nicht zurückgespielt.

Die vorhandene App hatte zusätzliche Finder-Metadaten und bestand `codesign --verify`
nicht. Statt ihre Signatur zu verändern wurde sie durch das unveränderte Bundle aus dem
per SHA-256 geprüften ZIP ersetzt. Quarantäne und Gatekeeper wurden nicht verändert.
Der Installationsdialog zeigte am tatsächlichen Zielpfad sichtbar die installierte Version
und den bestandenen lokalen Serverstart. Der erfolgreiche Abschluss bleibt für den Nutzer
geöffnet; es wurde kein Chatbot verbunden und keine neue Freigabe angelegt.

Neue Nachprüfungen: `codesign --verify --deep --strict` für die App, die installierte
Einrichtungs-App und die Status-App jeweils erfolgreich; `vauldy-mcp --build-info` meldet
die erwartete Buildkennung. Die vier installierten CLI-/Serverprogramme sind bytegleich
zu den Paketressourcen. Alle 46 vorab erfassten Bestands- und Freigabedateien haben weiterhin
denselben SHA-256. [Installationsnachweis](quality/local-install-2026-11-07.json).
Die früheren 80 Swift-Tests wurden hierfür nicht nochmals ausgeführt. Dies ist eine
Installation auf dem vorhandenen Mac mit erhaltenem Neudatenbestand; eine Kundenabnahme
auf einem vollständig frischen, physisch netzgetrennten Mac bleibt offen.

## Anschließende ChatGPT-Verbindung

Auf weiteren Nutzerauftrag wurde die vorhandene Auswahl der neun Dokumente mit ChatGPT
verbunden. Der bestehende private Dienstzugang wurde ohne Tokenrotation über verborgenes
stdin erneut dem lokalen Agenten bereitgestellt. Weder Deployment noch Zugriffsrichtlinie
des privaten Anschlusses wurden geändert. Die native Freigabe wurde direkt vor der
Kopplung ausdrücklich bestätigt; die Browseranmeldung war bereits vorhanden.

Der [reguläre Chat](https://chatgpt.com/c/6aef1354-9d1c-83ed-bac6-3885a5044c52) nutzte den
Chat-Modus und das vorhandene Vauldy-Plugin. Er zeigt neun neutrale Inventarzeilen und
bestätigt die vollständige Liste ohne weitere Seite. Das lokale Audit bestätigt genau
einen Status- und einen Listenaufruf, beide mit neun Ergebnissen. Die lokale Vorbereitung
der Antworten betrug 92 bzw. 68 ms. Die sichtbare Tabelle wurde nach 25,516 Sekunden
beobachtet, bei der vorherigen Beobachtung nach 14,682 Sekunden war sie noch nicht
vorhanden. Dies ist ein Beobachtungsintervall und kein kontinuierlich gemessener erster
Bildaufbau. Kein `read_document`-Aufruf erfolgte. Der Prompt verlangte eine Liste ohne
Auszüge; die einzelnen Listenargumente wurden nicht zusätzlich in der Aktivitätsansicht
aufgeklappt. Die sichtbare Antwort enthält ausschließlich neutrale Kennungen und Status.

Ein nachfolgender tatsächlicher Plugin-Status bestätigt neun freigegebene, durchsuchbare
und keine fehlenden Dokumente. Sechs Dokumente haben Quellenverarbeitungslücken; drei sind
quellseitig vollständig verarbeitet. Alle neun Basisanalysen benötigen Prüfung. Das ist
eine erfolgreiche Verbindung, keine Bestätigung vollständiger OCR oder korrekter
Vertragsauslegung. Die 44 erfassten Bestands- und Freigabedateien sind unverändert.
[Prüfnachweis ohne Dokumentinhalte oder Zugangsdaten](quality/chatgpt-nine-documents-2026-11-07.json).
