# OCR-v11-Paket und lokale Aktualisierung vom 07.11.2026

Paket: `dist/mcp/vauldy-v11-2026-11-07-v0s9nktc/Vauldy.zip`.
Version 0.13.0, Serverbuild `macho.c20e99b2d8f73daaadac2a08ff2846c9`, Apple Silicon,
macOS ab 14. SHA-256:
`7ea72798d1ff99dfaae9aee283733392957f8552bb3554aa7078ea2609764118`.

Das Paket enthält den aktuellen MCP-Arbeitsbaum mit OCR-Konfiguration v11, begrenzten
vergrößerten Regionslesungen, Belegzeilenerhalt und Schutz vor veralteten Verfeinerungsentwürfen.
Der native Installationsassistent bleibt enthalten. Keine Dokumentmigration und keine neue
Standarddatenbank. Die Produktversion wurde nicht allein zur Unterscheidung der Builds erhöht.

## Tatsächliche Prüfung und Installation

Branch `codex/local-first-product-readiness`, Basiscommit `87ab76c`, mit vorhandenen lokalen
Änderungen. Alle 149 Quell-/Test-/Package-Dateien wurden bytegleich mit der lokalen Buildkopie
verglichen. Der Quellhash entspricht dem vorherigen OCR-Prüfstand mit 78 bestandenen nativen
Swift-Tests. Diese Tests wurden in dieser Paketiteration nicht als neuer Lauf ausgegeben.

Neu ausgeführt:

- Release-Build erfolgreich, 51,37 Sekunden. Paketierung danach mit `--skip-build` aus
  genau diesen gebauten Programmen. `buildMode=reused` behauptet keinen sauberen Releasecommit.
- Versions-, Build-, Werkzeug- und Plattformgates für die Paketkomponenten bestanden.
  Finales ZIP neu entpackt und Codesignatur geprüft.
- `software_update_smoke_test.py` gegen das neue Bundle bestanden: synthetisches Update,
  Authentizitäts-/Kompatibilitätsfehler, fehlgeschlagener Start, SIGKILL, konkurrierendes
  Update, geprüfter Rollback und reales stdio. Keine echten Dokumente als Testfixtures.
- Lokale Installation unter `/Applications/Vauldy.app` über den regulären atomaren
  Software-Updater aktualisiert. Vorherige App privat gesichert; vorige Programmgeneration
  vom Updater als authentifizierter Rückweg behalten.
- Lokaler Start-/Discoverytest bestätigt den neuen Build, acht Werkzeuge und neun
  freigegebene Dokumente. App, installierte Setup- und Status-Bundles bestehen die Signaturprüfung.
  Die vier installierten CLI-/Serverdateien entsprechen den Paketressourcen bytegenau.
- Native Einstellungen zeigen „Die installierten Programme entsprechen dieser App“ und
  den verfügbaren Rückweg „Vorversion wiederherstellen“.

Ausgeführt in der Buildkopie `/private/tmp/vauldy-ocr-vector-wtr5pb1z`:

```sh
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
python3 scripts/mcp/package.py --skip-build --name Vauldy --archive-only --output /Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp/dist/mcp/vauldy-v11-2026-11-07-v0s9nktc
python3 scripts/mcp/software_update_smoke_test.py /private/tmp/vauldy-v11-2026-11-07-v0s9nktc/Vauldy.app
```

Tatsächliche lokale Aktualisierung:

```sh
/Applications/Vauldy.app/Contents/Resources/vauldy-local update-software --root "/Users/marcomeisen/Library/Application Support/VauldyMCP" --from-app /Applications/Vauldy.app --allow-ad-hoc
codesign --verify --deep --strict /Applications/Vauldy.app
```

Der zusätzliche `check-connection --profile` verwendete das bestehende Profil. Dessen
Kennung wird ausschließlich privat lokal protokolliert. Die Diagnose fragt keinen Dokumenttext ab.

## Erhalt der Daten und der ChatGPT-Kopplung

44 erfasste Bestands-/Freigabedateien und die vorhandene Clientkonfiguration haben nach
dem Update unveränderte SHA-256-Prüfsummen. Alle neun Dokumente und deren Auswahl blieben
erhalten. Keine Neuanmeldung, Kopplungsneuanlage, Provisionierung oder explizite Tokenrotation.
Zugangsdaten wurden weder exportiert noch zurückgesetzt.

Der neue ad-hoc-signierte Agent benötigte erneut eine bewusste macOS-Schlüsselbundfreigabe.
Die erste gemeldete Bestätigung genügte dem frischen Hintergrundtest noch nicht. Nach einem
zweiten ausdrücklich geöffneten Vorgang bestätigte der Eigentümer „Immer erlauben“; der neue
Agent besteht nun auch einen frischen nichtinteraktiven Zugriff. Diese Systemfreigabe wird
nicht als bytegleich unveränderte Schlüsselbund-ACL ausgegeben.

Während dieser Freigabeprüfung wurde kurzfristig der signaturgeprüfte, zuvor autorisierte
Transport aus dem Retentionsslot verwendet. Er nutzte bereits den neuen lokalen MCP-Server.
Nach erfolgreicher Freigabe wurde dieser Altprozess geordnet beendet. Abschließend laufen
der neue installierte Agent und der neue MCP-Server; kein temporärer Alttransport bleibt aktiv.
Öffentliche Kopplungsmetadaten und die Profilzuordnung stimmen mit dem Vorher-Stand überein.

Der abschließende tatsächliche Werkzeugaufruf über den bestehenden ChatGPT-Anschluss
bestätigt `available=true`, neun freigegebene und neun durchsuchbare Dokumente. Die bisherigen
Qualitätshinweise bleiben korrekt sichtbar: vier Quellen vollständig verarbeitet, fünf mit
Prüfhinweisen, neun Basisanalysen prüfbedürftig. Das Update verändert diese Befunde nicht.

## Rückweg und offene Kundendistribution

Der geprüfte Rückweg ist in Einstellungen als „Vorversion wiederherstellen“ verfügbar.
Er betrifft Programme; Bestand und Freigaben werden nicht zurückgespielt oder gelöscht.
Für eine Rückkehr der separat installierten App liegt deren vorheriges Bundle in der
privaten lokalen Updatesicherung. Bei laufenden Verbindungen den betroffenen Vauldy-Dienst
geordnet neu starten. Keine Auditdateien oder Profile zur Reparatur löschen.

Auf dem Build-Mac waren bei Paketbau null gültige Developer-ID-Identitäten verfügbar.
Das ZIP ist ad hoc signiert und nicht notarisiert. Developer ID Application, ein sauberer
Releasecommit, Notarisierungszugang und Kundenprüfung auf einem frischen physisch
netzgetrennten Mac bleiben separate offene Gates. Gatekeeper wurde nicht abgeschaltet.

[Maschinenlesbarer Nachweis](quality/v11-package-update-2026-11-07.json).
