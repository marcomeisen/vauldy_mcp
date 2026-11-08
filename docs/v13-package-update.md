# Vauldy-Paket mit Mehrfach-OCR · 08.11.2026

MCP-Branch `codex/local-first-product-readiness`, Basiscommit
`87ab76c3d7f79b53a2723235c036bf224c7573d6` mit vorhandenem Arbeitsbaum.
Produktversion **0.13.0**, OCR-Konfiguration **v13**. Die OCR-Konfigurationsnummer
ist keine neue Produktversion. Enthalten sind die Mehrfach-OCR, Gesamtfortschritt,
getrennte Freigabeauswahl und Verbesserungen für dichte Seiten/Zeilenkontext aus
[der vorherigen Implementierungsiteration](ocr-dense-batch-ux.md).

- ZIP: `dist/mcp/vauldy-v13-2026-11-08-nyvj7krs/Vauldy.zip`
- SHA-256: `b491f426cd9384fddfbd43b5fbd9253afca90f85293c74dafa2e712627c410b8`
- Serverbuild: `macho.e19c2c835af53f2d927c68b4eb371739`
- Setup-Build: `macho.6f82dee23a773761a0e52e72752d54d6`
- Apple Silicon, macOS ab 14, ad hoc signiert, **nicht notarisiert**.
- Bestehender geführter Installationsassistent enthalten. Ein Softwareupdate
  fordert weder eine neue Dokumentfreigabe noch eine Neukopplung an.

## Paketprüfung

Alle 197 Quell-, Test-, Package- und MCP-Pythonskriptdateien zwischen Repository und
lokalem Build-Checkout byteverglichen. SHA-256 des Prüfinventars:
`6830fa2e110e245aeb3717b8a6e86786debc663181889c82efb8ffec8c9c669d`.
Build-Checkout `/private/tmp/vauldy-ocr-vector-wtr5pb1z`; Abhängigkeitspins erhalten.

Neu ausgeführt:

- Release-Build erfolgreich, Swift meldet 39,46 s; Wrapper einschließlich Start
  45,022 s. Anschließend **97 Swift-Tests / 18 Suites bestanden**, 26,600 s reine
  Testzeit. Build und Tests zusammen im Testkommando 114,845 s. Historische Zahlen
  aus früheren Iterationen werden damit nicht als neuer Nachweis ausgegeben.
- Paketierung genau dieser Programme mit `--skip-build`, Manifest korrekt
  `buildMode=reused`, `sourceCommit=null`. Keine Behauptung eines sauberen Releases.
  Alle Komponenten bestehen Versions-, Plattform- und Fähigkeitsgates.
- Endgültiges ZIP neu entpackt und tief/strikt signaturgeprüft. Metadatenprüfung
  besteht einschließlich Quarantäneerhalt, unveränderten signierten Bytes,
  Idempotenz und Symlinkabwehr.
- Paketiertes Update/Rollback besteht mit Authentizität, Kompatibilität,
  fehlgeschlagenem Start, SIGKILL, konkurrierendem Update und tatsächlichem stdio.
  Ausschließlich synthetischer Bestand, kein produktiver Rollback als Test.
- Neuer paketierter OCR-/MCP-Lauf: fünf exakte Zusatzfelder auf einer dichten
  synthetischen Seite, 147 verglichene/128 gespeicherte Regionen, bisheriger
  Selbstbehalt erhalten, frischer Nachlauf mit demselben Worker und Widerruf geprüft.
- Bestehender Wirelauf mit drei synthetischen PDFs: sechs Zusatzfelder, drei
  erhaltene Werte, Zahlenkonflikt, Privacy-/Quellseitenbindung, Cache und Widerruf
  bestanden. Native 4-/5-Punkt- und Rasterregressionen Teil der 97 Swift-Tests.
- Native Startprüfung des vollständigen Pakets mit isoliertem Testpfad und aktivem
  synthetischem Watch-Ordner bestanden: Öffnen startet keinen Import-Worker und
  verändert weder Originale noch Snapshots. Die sichtbare Mehrfachauswahl mit
  Abbruch/Fortsetzung wurde in der vorherigen Implementierungsiteration geprüft;
  kein neuer vollständiger GUI-Durchlauf dieser Paketiteration behauptet.

## Lokale Installation und Erhalt

Vorherige App, kompletter Vault und Verbindungsdateien wurden ausschließlich lokal
unter `~/Library/Application Support/Vauldy Backups/v13-package-update-…` gesichert.
Kein Schlüsselbundexport, keine echten Dokumente im Paket oder Repository.

`/Applications/Vauldy.app` wurde über einen geprüften temporären App-Pfad ersetzt,
die lokale Programmgeneration über `update-software` atomar aktiviert. Die vier
installierten CLI-/Serverprogramme und der native Setup-Build entsprechen dem neuen
Paket. App und installierte Setup-/Status-Bundles bestehen die Codesignaturprüfung.
Der neue lokale Start-/Discoverytest bestätigt Buildkennung, acht Werkzeuge und
neun freigegebene Dokumente.

Nachprüfung: **alle neun vollständigen Dokumentdatensätze einschließlich OCR und
Analyse sowie neun Originale unverändert**. 26 erfasste unveränderliche Dateien
und eine bestehende Clientkonfiguration bytegleich. Das lokale Start-/Statuslesen
ergänzte reguläre Auditeinträge: vorheriger Auditinhalt als Präfix erhalten und
Prüfkette erfolgreich verifiziert. Die Auditdatei wird ausdrücklich nicht als
bytegleich unverändert ausgegeben. Kein OCR-Worker gestartet, keine reale
Dokumentmigration oder Nachbearbeitung ausgeführt. Die bisherigen vier vollständig
verarbeiteten und fünf prüfbedürftigen Quellen bleiben fachlich unverändert.

## Bestehende ChatGPT-Kopplung

Vor dem Update bestätigte der tatsächliche Anschlussstatus: `available=true`,
neun freigegebene und neun durchsuchbare Dokumente. Es wurden keine Dokumenttexte
übertragen. Der neue ad-hoc-signierte Relay benötigte erneut macOS-Schlüsselbundzugriff
auf den bestehenden Zugang. Der erste Freigabeaufruf lief nach 315 Sekunden ab;
die danach gemeldete Bestätigung genügte der frischen Hintergrundprüfung nicht.
Der Vorgang wurde einmal neu geöffnet, vom Nutzer mit „Immer erlauben“ bestätigt
und anschließend in einem frischen nichtinteraktiven Prozess erfolgreich geprüft.
Bis dahin blieb der bisherige Agent aktiv; dann wurde er geordnet beendet und
der neue installierte Relay mit dem neuen lokalen Server gestartet.

**Abgeschlossen:** Der tatsächliche Anschlussstatus über den neuen Agenten bestätigt
`available=true` und 9/9 freigegeben/durchsuchbar. Vier Quellen vollständig verarbeitet,
fünf mit bisherigen OCR-Prüfhinweisen, neun Basisanalysen weiterhin prüfbedürftig.
Kopplungsmetadaten und Profilzuordnung unverändert; keine Trennung,
Neuprovisionierung, Neukopplung oder explizite Tokenrotation durchgeführt.
Die bewusste macOS-Freigabe wird nicht als unveränderte Schlüsselbund-ACL ausgegeben.
Abschließender Dateivergleich, Signaturprüfung und neuer lokaler Starttest bestanden.

Eine erste Abschlussassertion wertete fehlende Kopplungsmetadaten im gesperrten
Schlüsselbundstatus fälschlich als Änderung. Die Installation selbst war bereits
erfolgreich. Nach Unterscheidung von gesperrter Sicht und tatsächlicher Änderung
wurde der Datenerhalt separat erfolgreich geprüft. Eine zweite zu breite
Dateiprüfung erfasste auch die regulär ergänzte Auditdatei; deren erhaltenes Präfix
und gültige Kette wurden statt Bytegleichheit geprüft. Keine Produktdateien zur
Umgehung verändert oder gelöscht.

## Befehle und Grenzen

Ausgeführt im oben genannten Build-Checkout:

```sh
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
# Exakter Swift-Testfilter und die Fixture-Umgebung stehen im JSON-Nachweis.
python3 scripts/mcp/package.py --skip-build --name Vauldy --archive-only --output /Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp/dist/mcp/vauldy-v13-2026-11-08-nyvj7krs
python3 scripts/mcp/package_metadata_smoke_test.py
python3 scripts/mcp/software_update_smoke_test.py /var/folders/jm/g1jk_46x6gz9gpmvnwrg087r0000gn/T/vauldy-v13-package-stage-ia2gofzy/Vauldy.app
python3 scripts/mcp/dense_ocr_smoke_test.py /var/folders/jm/g1jk_46x6gz9gpmvnwrg087r0000gn/T/vauldy-v13-package-stage-ia2gofzy/Vauldy.app/Contents/Resources/vauldy-local /var/folders/jm/g1jk_46x6gz9gpmvnwrg087r0000gn/T/vauldy-v13-package-stage-ia2gofzy/Vauldy.app/Contents/Resources/vauldy-mcp dense-fixtures
python3 scripts/mcp/visual_coverage_smoke_test.py /var/folders/jm/g1jk_46x6gz9gpmvnwrg087r0000gn/T/vauldy-v13-package-stage-ia2gofzy/Vauldy.app/Contents/Resources/vauldy-local /var/folders/jm/g1jk_46x6gz9gpmvnwrg087r0000gn/T/vauldy-v13-package-stage-ia2gofzy/Vauldy.app/Contents/Resources/vauldy-mcp region-fixtures
python3 scripts/mcp/setup_startup_smoke_test.py /var/folders/jm/g1jk_46x6gz9gpmvnwrg087r0000gn/T/vauldy-v13-package-stage-ia2gofzy/Vauldy.app
/Applications/Vauldy.app/Contents/Resources/vauldy-local update-software --root "/Users/marcomeisen/Library/Application Support/VauldyMCP" --from-app /Applications/Vauldy.app --allow-ad-hoc
python3 /private/tmp/vauldy-v13-restart-relay.py
python3 /private/tmp/vauldy-v13-finish.py
```

Die exakten ausgeführten Argumentlisten, Laufzeiten und Rückgabecodes stehen im
[maschinellen Nachweis](quality/v13-package-update-2026-11-08.json). Rohprotokolle
liegen neben dem ZIP; private Erhaltungsnachweise ausschließlich in der lokalen Sicherung.

Rollback betrifft die authentifizierte vorige Programmgeneration; Dokumente,
Freigaben und Audit werden nicht zurückgespielt. Vorige App zusätzlich privat
gesichert. Keine echte Datenwiederherstellung oder Produktionsrollback ausprobiert.

Weiter offen: Developer ID Application, Notarisierung, sauberer Releasecommit und
physischer Offline-Kundenmac. Keine gültige Developer-ID-Application-Identität
gefunden; vorhandene Apple-Development-/Distribution-Identitäten ersetzen diese
nicht. Gatekeeper unverändert. Die gesamte Release-Regressionssammlung wurde
nicht ausgeführt, sondern die aufgeführten gezielten Prüfungen. Reale OCR-Fälle
und dauerhafte Wiederherstellung des ganzen OCR-Stapels bleiben gesonderte Aufgaben.

Geänderte Repo-Dateien dieser Paketiteration: dieses Dokument,
`quality/v13-package-update-2026-11-08.json`, `local-first-todo.md`. Kein zusätzlicher
Produktcode, kein Commit/Push/PR und kein Cloud-Rollout.

Anschließend auf gesonderten Auftrag die fünf offenen Dokumente mit v13 erneut
gelesen: [reale Nachprüfung vom 08.11.](ocr-v13-real-review.md). Diese spätere
OCR-Wartung ergänzt den historischen Datenerhaltsnachweis des reinen Softwareupdates.
