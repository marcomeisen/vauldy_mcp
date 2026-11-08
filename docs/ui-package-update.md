# UI-Paket erstellt und lokal aktualisiert · 08.11.2026

Aus dem MCP-Arbeitsbranch `codex/local-first-product-readiness`, Basiscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6` mit dem vorhandenen Arbeitsbaum.
Enthalten sind die [neuen Bestands- und Prüfhinweise](import-guidance-ui.md), der direkte
Textvergleich und die übrigen aktuellen Programme des Branches.

- ZIP: `dist/mcp/vauldy-ui-package-onjunyd_/Vauldy.zip`, **16.360.034 Bytes**.
- SHA-256: `bf80bc7b7f6cb444356907a113e896f029ad5acdec72ecb92cc32bfbe95b60b6`.
- Produktversion weiterhin **0.13.0**, neuer Serverbuild
  `macho.b4ff62e510dc350eb65b35e94db890a5`, neuer Setup-Build
  `macho.98b22d1046ed37319c70455df2800b26`.
- Vollständige App mit vorhandenem geführtem Installationsassistenten. **Lokal ad hoc
  signiert, nicht Developer-ID-signiert und nicht notarisiert.**

## Tatsächliche Signierungsschritte in Xcode

Xcode 27.2 geprüft, Apple Accounts geöffnet, vorhandenes Konto und Team ausgewählt,
**Manage Certificates … → + → Developer ID Application** aufgerufen. Apple verweigert
mit **„This operation can only be performed by the Account Holder.“** Die sichtbare
Teamrolle ist **Admin**. Kein nutzbares Developer-ID-Zertifikat wurde erstellt;
keine bestehenden Zertifikate wurden widerrufen oder private Schlüssel exportiert.
Die vorhandenen Apple-Development-/Apple-Distribution-Identitäten wurden nicht als
Developer ID ausgegeben. Die anfängliche sandboxbeschränkte Identitätsabfrage meldete
keine Identitäten; erst die reguläre macOS-Abfrage zeigte die bestehenden Zertifikate.

Apple verlangt für diese Erstellung den Account Holder des Developer-Teams.
[Offizielle Voraussetzung und Zertifikatstypen](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
Mac-Administratorrechte ersetzen diese Teamrolle nicht. Ein weiterer Versuch mit
demselben Admin-Konto behebt die Sperre nicht. Der Nutzer bestätigte, dass die
Blockiermeldung weiterhin erscheint; das ausdrücklich beauftragte lokale Update wurde
mit transparenter Ad-hoc-Signatur abgeschlossen. Notarisierung wurde nicht versucht.

Noch erforderlich für die Kundenverteilung: Account Holder erstellt lokal eine
Developer-ID-Application-Identität einschließlich privatem Schlüssel; anschließend
sauberer Releasecommit, frischer Developer-ID-Build und Notarisierung mit gültigem
passendem Notary-Zugang. Keine Passwörter, Schlüssel oder Zertifikatexporte im Chat.
Der vorhandene Paketierer unterstützt Hardened Runtime, Zeitstempel und Notarisierung;
sein Signierungsgate wurde nicht umgangen oder gelockert.

## Neue Prüfungen dieses Pakets

221 Quell-/Test-/Package-/Skriptdateien bytegleich zwischen Arbeitsbaum und lokaler
Buildkopie `/private/tmp/vauldy-ocr-vector-wtr5pb1z` geprüft. Inventar-SHA-256:
`40c4643b9f38e29739c4c6106fd01313ca6f6fcf5f8f551421ddc11d4a5ed3d8`.

- Vollständiger Release-Build erfolgreich: **46,99 s** Swift-Buildzeit.
- **30 Swift-Tests in fünf Suites neu bestanden, 5,942 s** Testzeit: UI-Zustände,
  native Importe, Duplikaterkennung, gezielter OCR-Zweitlauf, Kleinstschrift und Belegschutz.
- Paketiert mit `--skip-build` aus genau den aktuell gebauten Programmen. Manifest
  korrekt `buildMode=reused`, `sourceCommit=null`; keine Behauptung eines sauberen Releases.
- Tatsächliches ZIP erneut entpackt und tief/strikt signaturgeprüft. Metadatenprüfung
  besteht mit erhaltenen signierten Bytes, Quarantäneerhalt und Symlinkabwehr.
- Paketierter Update-/Rollback-Test besteht: Authentizität, Kompatibilität, fehlgeschlagener
  Start, SIGKILL, gleichzeitiger Updateversuch und tatsächliches stdio. Nur synthetischer
  Bestand; kein Rollback der produktiven Daten als Test.
- Tatsächlicher stdio-Smoke-Test bestanden. Neuer nativer Worker-/MCP-Lauf mit drei
  synthetischen Raster-PDFs: zwölf exakte gespeicherte Felder, physische Seiten,
  Privacy, Cache und frischer Retry sowie Widerruf bestanden.
- Nativer Setup-Starttest mit synthetischem aktiviertem Watch-Ordner bestanden:
  Öffnen startet keinen Importworker und verändert keinen Bestand.

Die vollständige Regressionssammlung, das separate 79-Felder-Verbesserungsgate,
ein physischer Offline-Kundenmac und neue frei formulierte ChatGPT-Antworten wurden
nicht geprüft. Frühere Ergebnisse werden nicht als neue Paketprüfungen ausgegeben.

## Lokale Aktualisierung und Erhalt

Private Sicherung der bisherigen App, des gesamten Vaults und der Verbindungsdateien:
`~/Library/Application Support/Vauldy Backups/ui-package-20261108-152716`.
Keine echten Dokumente im ZIP oder Repository, kein Schlüsselbundexport.

`/Applications/Vauldy.app` über einen geprüften temporären App-Pfad ersetzt;
`update-software` aktiviert den neuen lokalen Programmplatz atomar. Vorige App
privat gesichert; die Oberfläche bietet die authentifizierte Vorversion wieder an.
Keine Datenwiederherstellung oder produktive Rücksetzung durchgeführt.

Nach dem Update und erneut nach Öffnen der neuen App überprüft:

- **Neun vollständige Dokumentdatensätze einschließlich OCR und Basisanalyse unverändert.**
- **Neun Originale, 26 geschützte Dateien und eine Clientkonfiguration bytegleich.**
- Bisherige Auditdateien als bytegleiches Präfix erhalten; neue reguläre Status-
  und Prüfeinträge sind zulässig. Keine Behauptung einer insgesamt bytegleichen Auditdatei.
- Alle vier installierten CLI-/Serverprogramme und der Setup-Build stimmen mit dem
  neuen Paket überein. Drei installierte App-Bundles bestehen die Signaturprüfung.
- Neuer lokaler Start-/Discoverytest bestätigt den Paketbuild und neun Freigaben.
  Kein OCR-Worker und keine Dokumentmigration gestartet.

Die erste Nachprüfung erwartete eine fehlerfreie Relay-Statusantwort. Tatsächlich meldete
sie korrekt eine nötige Schlüsselbundbestätigung, nachdem der Softwaretausch bereits
erfolgreich war. Der Datenerhalt wurde separat bestätigt; keine erneute Installation,
keine Freigabeänderung und keine Neukopplung zur Umgehung dieser Meldung vorgenommen.

## Bestehende ChatGPT-Verbindung

Der neue Ad-hoc-Build benötigte einmalig die ausdrückliche macOS-Freigabe für denselben
bestehenden Relay-Schlüsselbundeintrag. Nutzer bestätigte **„Immer erlauben“**.
Unmittelbar danach frischen nichtinteraktiven Zugriff erfolgreich geprüft; Profil,
Kopplungskennung und Ablaufdatum identisch. Erst danach den bisherigen Relay geordnet
über seinen vorgesehenen Stopmarker beendet und den neuen Relay gestartet.

Die bewusste macOS-Freigabe wird nicht als unveränderte Schlüsselbund-ACL bezeichnet.
Es wurde kein Zugang exportiert, kein Gerät neu gekoppelt und keine Freigabe erweitert.

**Tatsächlicher privater Vauldy-Anschluss vor und nach Update/Relay-Neustart:**
`available=true`, neun freigegebene und neun durchsuchbare Dokumente. Unverändert vier
vollständig verarbeitete Quellen, fünf OCR-Prüffälle und neun prüfbedürftige Basisanalysen.
Ausschließlich Statusmetadaten angefordert; keine Dokumenttexte über den Anschluss gelesen.
Dies bestätigt die Verbindung, keine neue fachliche Chatantwort-Abnahme.

Neue installierte App auf der Einstellungsseite geöffnet: **„Die installierten Programme
entsprechen dieser App.“** Updateknopf deaktiviert, Vorversion verfügbar. Keine produktive
Dokumentansicht oder Freigabeaktion für die Sichtprüfung geöffnet.

## Befehle und Nachweise

Im genannten Buildverzeichnis neu ausgeführt, jeweils mit Exitcode 0:

```sh
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 --no-parallel --filter 'SetupDocumentGuidanceTests|LocalImportTests|OCRTargetedRetryTests|OCRSmallRegionTests|EvidencePreservingOCRTests|MCPSoftwareUpdateTests'
python3 scripts/mcp/package.py --skip-build --name Vauldy --archive-only --output /Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp/dist/mcp/vauldy-ui-package-onjunyd_
python3 scripts/mcp/package_metadata_smoke_test.py
python3 scripts/mcp/software_update_smoke_test.py /private/tmp/vauldy-ui-package-onjunyd_/extracted/Vauldy.app
python3 scripts/mcp/smoke_test.py /private/tmp/vauldy-ui-package-onjunyd_/extracted/Vauldy.app/Contents/Resources/vauldy-mcp
python3 scripts/mcp/raster_ocr_quality_smoke_test.py /private/tmp/vauldy-ui-package-onjunyd_/extracted/Vauldy.app/Contents/Resources/vauldy-local /private/tmp/vauldy-ui-package-onjunyd_/extracted/Vauldy.app/Contents/Resources/vauldy-mcp /private/tmp/vauldy-product-acceptance-v7v9vf93/raster
python3 scripts/mcp/setup_startup_smoke_test.py /private/tmp/vauldy-ui-package-onjunyd_/extracted/Vauldy.app
```

Der Swift-Filter enthält fünf tatsächlich vorhandene Suites. Die zusätzliche
`MCPSoftwareUpdateTests`-Alternative passt auf keine Swift-Suite und wird nicht als
ausgeführter Test gezählt; Update/Rollback ist durch die separate Paketprüfung belegt.

Lokaler Updateaufruf:

```sh
/Applications/Vauldy.app/Contents/Resources/vauldy-local update-software --root "/Users/marcomeisen/Library/Application Support/VauldyMCP" --from-app /Applications/Vauldy.app --allow-ad-hoc
```

[Maschineller Nachweis mit exakten Stufen, Laufzeiten und Ergebnissen](quality/ui-package-update-2026-11-08.json).
Synthetische Build-/Prüfprotokolle liegen neben dem ZIP; Erhaltungs- und
Kopplungsmetadaten ausschließlich in der privaten lokalen Sicherung.

**GO** für die geprüfte lokale Aktualisierung mit erhaltenem Bestand und Anschluss.
**NO-GO** für eine Behauptung von Developer-ID-Signierung, Notarisierung oder einer
abgenommenen Verteilung auf fremde Kunden-Macs. In dieser Paketiteration nur diese
Dokumentation, den JSON-Nachweis und die To-do-Liste geändert; kein Produktcode,
Commit, Push, PR oder Cloud-Rollout.
