# Vauldy v12: Paket, Installation und erneute OCR-Prüfung

Stand 07.11.2026. MCP-Branch `codex/local-first-product-readiness`, Basiscommit
`87ab76c`, vorhandener Arbeitsbaum. Produktversion weiterhin **0.13.0**;
**v12 bezeichnet die OCR-Konfiguration**, keine neue behauptete Produktversion.

- ZIP: `/Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp/dist/mcp/vauldy-v12-2026-11-07-7q1qtsui/Vauldy.zip`
- SHA-256: `819e21be44a33be905bddfea64e61f82339aa017d752527789c194c052553d3e`
- Serverbuild: `macho.0c63515acdd13a019ed1aad469f2880e`
- Native Einrichtung: `macho.fcf9cbc03b613386bc64879d4a3e1410`.
- Apple Silicon, macOS ab 14, ad hoc signiert und **nicht notarisiert**.
- Bestehende geführte Installation enthalten. Keine primäre SQLite-Migration.

## Tatsächlich neu ausgeführt

Release-Build: erfolgreich / 53,07 s. Danach Paketierung genau dieser Programme mit
`--skip-build`; Manifest `buildMode=reused`, `sourceCommit=null` wegen des Arbeitsbaums.
ZIP nach Entpacken signaturgeprüft. Die Programmbuildkennung unterscheidet gleich
nummerierte Pakete eindeutig.

Die neue paketierte CLI importierte frische synthetische 4-/5-Punkt-Originale. Beide
liefern alle drei exakten Sollfelder, erhalten den unabhängigen Selbstbehalt und sind
über den echten geschützten stdio-MCP lesbar. Paketiertes Update/Rollback einschließlich
Authentizität, Kompatibilität, fehlgeschlagenem Start, SIGKILL, konkurrierendem Update
und echtem stdio bestanden.

Die 88 Swift-Tests aus der vorherigen Kleinstschriftiteration wurden **nicht erneut als
neuer Lauf ausgegeben**. Alle 194 Quell-, Test- und Skriptdateien sind zum geprüften Stand
bytegleich; dieser vorherige Nachweis bleibt gesondert referenziert. Eine vollständige
Release-/Installerregression und ein frischer physischer Offline-Kunden-Mac wurden nicht
in dieser Iteration abgenommen.

`/Applications/Vauldy.app` und die lokale Programmgeneration sind aktualisiert. Native
Einstellungen zeigen „Die installierten Programme entsprechen dieser App“ und den
verfügbaren Rückweg „Vorversion wiederherstellen“. Drei App-Bundles bestehen die tiefe
strikte Codesignaturprüfung; vier installierte CLI-/Serverprogramme entsprechen den
Paketressourcen bytegenau. Lokaler Start-/Discoverytest: neuer Build, acht Werkzeuge,
neun freigegebene Dokumente. Das vorherige Statusmenü wurde mit den neuen Programmen
wieder geöffnet.

## Die fünf realen OCR-Fälle

Zuerst private Kandidatenkopie des tatsächlich vorhandenen Bestands, danach die
beauftragte Verfeinerung der aktiven fünf Datensätze. Vor dem aktiven Lauf wurde der
gesamte Dokumentbaseline erneut verglichen. Verfeinerung verwendet weiterhin den
Quellenhash, Original-Lease, erwarteten Datensatz und Belegzeilenerhalt.

| Fall | Seiten erneut gelesen | Markierte Seiten vorher → nachher | Zusätzliche Zeichen |
| --- | ---: | ---: | ---: |
| D1 | 9 | 4 → 4 | 0 |
| D2 | 1 | 1 → 1 | 0 |
| D3 | 4 | 1 → 1 | 0 |
| D8 | 2 | 2 → 2 | 0 |
| D9 | 6 | 5 → 5 | 0 |
| **Gesamt** | **22** | **13 → 13** | **0** |

Alle 22 Seiten tragen nach dem aktiven Lauf die neue OCR-Konfiguration. Alle fünf
CLI-Verfeinerungen melden korrekt Exitcode 2 / `partial`; sie wurden nicht als
abgeschlossene Texterkennung umgedeutet. Die Prüfskripte bestätigen erfolgreich die
Erhaltungsbedingungen. Es gab keinen Rückfall auf alten Text durch die Belegschutz-
Fallbackfunktion: Die neue Erkennung lieferte hier bereits denselben gespeicherten Text.
Die lokale Basisanalyse wurde für die fünf betroffenen Dokumente im normalen Ablauf
neu berechnet. Insgesamt bleiben neun Basisanalysen prüfbedürftig.

Der konkrete synthetische Kleinstschriftgewinn verbessert **diese fünf realen Fälle
noch nicht**. Zehn markierte Seiten enthalten Zeilen mit niedriger nativer Konfidenz;
sieben weisen nicht abgedeckte Detektorbereiche auf. Die Gruppen überlappen. Auf zwei
dichten D9-Seiten ist der geometrische Vergleich durch Regions-/Zeichenlimits begrenzt.
D9 Seite 3/4 erreichen jeweils vier Regionsversuche und behalten 10/8 unbedeckte Bereiche.
Das rechtfertigt keine pauschale Lockerung der Bestätigungs- oder Reviewgrenzen.

Beispiele ohne Dokumentinhalt: D2 Seite 1 hat eine hohe durchschnittliche Konfidenz,
aber eine einzelne unsichere Zeile; sie ist deshalb weiterhin markiert. D9 Seite 3/4
haben hohe Konfidenz für erkannten Text, während zusätzliche sichtbare Bereiche fehlen.
Native Konfidenz misst keine tatsächliche Transkriptionsgenauigkeit.

**Auswirkung auf den Chat:** Der verfügbare Text ist in allen neun Dokumenten gleich
geblieben. Das Update liefert für diese Fälle deshalb noch keine zusätzliche inhaltliche
Antwortgrundlage. Vorhandene Fundstellen bleiben nutzbar; eine vollständige fachliche
Antwort ist durch weiterhin markierte Bereiche nicht belegt.

## Datenerhalt und bestehende ChatGPT-Verbindung

Vorherige App, Originale und Snapshot samt Backup sind privat lokal gesichert:
`/Users/marcomeisen/Library/Application Support/Vauldy Backups/v12-update-ocr-20261107-230058`. Die realen Titel und Kennungen liegen ausschließlich in der privaten
Datei `document-labels.json`; öffentliche Nachweise verwenden nur D1…D9.

Neun Originale, alle neun IDs und bisherigen OCR-Texte erhalten. Ein Freigabeprofil,
zwei Verbindungsdateien und die bestehende Clientkonfiguration sind bytegleich.
Die vier nicht beauftragten Datensätze sind insgesamt unverändert. Die fünf beauftragten
Datensätze enthalten neue lokale OCR-/Analyse-Prüfmetadaten; sie werden nicht als
bytegleich unveränderte Datensätze ausgegeben.

Der neue ad-hoc-signierte Relay erforderte erneut macOS-Schlüsselbundfreigabe. Der Nutzer
bestätigte „Immer erlauben“. Danach bestand ein frischer nichtinteraktiver Zugriff.
Bestehender Agent geordnet beendet und neuer Agent mit dem neuen lokalen Server gestartet.
Kopplungsmetadaten einschließlich Profilzuordnung unverändert; keine Neuprovisionierung,
Neukopplung, Trennung oder explizite Tokenrotation. Credentialinhalte wurden nicht
exportiert. Die bewusst erteilte Systemfreigabe ist keine Behauptung bytegleicher
Schlüsselbund-ACLs.

Abschließender tatsächlicher Statusaufruf über den vorhandenen ChatGPT-Anschluss:
`available=true`, neun freigegebene und neun durchsuchbare Dokumente; vier Quellen
vollständig verarbeitet, fünf mit Prüfhinweisen. Keine fehlenden oder laufenden
Dokumente. [Beobachteter Anschlussstatus](quality/v12-chatgpt-status-2026-11-07.json).
Keine echten Dokumenttexte über den Chatanschluss abgerufen.

## Befehle, Rückweg und verbleibende Gates

```sh
swift build -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none
python3 scripts/mcp/package.py --skip-build --name Vauldy --archive-only --output /Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp/dist/mcp/vauldy-v12-2026-11-07-7q1qtsui
python3 scripts/mcp/software_update_smoke_test.py /private/tmp/vauldy-v12-stage-yar1vwun/Vauldy.app
python3 /private/tmp/vauldy-v12-package-ocr-smoke.py
```

Die Befehle oben liefen in `/private/tmp/vauldy-ocr-vector-wtr5pb1z`. Quellen/Tests wurden zuvor mit dem Checkout
verglichen. Tatsächliche Aktualisierung und Wartung:

```sh
/Applications/Vauldy.app/Contents/Resources/vauldy-local update-software --root "/Users/marcomeisen/Library/Application Support/VauldyMCP" --from-app /Applications/Vauldy.app --allow-ad-hoc
python3 /private/tmp/vauldy-v12-review.py stage
python3 /private/tmp/vauldy-v12-review.py apply
python3 /private/tmp/vauldy-v12-finalize.py
```

Die beiden Verfeinerungsprüfungen liefen seriell, zuerst Kandidat, dann aktiver Bestand.
Es wurde kein paralleler OCR-Qualitätsbenchmark als Laufzeitnachweis verwendet.
Ein erster Versuch, den privaten inhaltsfreien Diagnosebericht unter der Library zu
schreiben, wurde von der Sandbox verhindert. Die autorisierte lokale Berichtablage
wurde anschließend mit den erforderlichen Dateirechten erfolgreich wiederholt; kein
OCR-Fehlschlag und kein Datenverlust.

Der geprüfte Rollback betrifft die authentifizierte vorige **Programmgeneration**;
er setzt keine Dokumente, Freigaben oder Auditdateien zurück. Die vorige native App
ist zusätzlich privat gesichert. Keine echten Daten automatisch rückspielen.

Nächste OCR-Arbeit: dichte Seiten in begrenzte, koordinatengebundene Prüfbereiche
aufteilen, nicht abgedeckte Bereiche über begrenzte Fortsetzungen bearbeiten und
unsichere Einzelzeilen unabhängig an synthetischen Reproduktionen vergleichen.
Developer ID Application, Notarisierungszugang, sauberer Releasecommit und physische
Offline-Kundenabnahme bleiben für die Kundendistribution offen.

Geänderte Repo-Dateien dieser Paketiteration: diese Dokumentation,
`docs/quality/v12-package-ocr-review-2026-11-07.json`,
`docs/quality/v12-chatgpt-status-2026-11-07.json`, `docs/local-first-todo.md`.
Kein zusätzlicher Produktcode, kein Commit/Push/PR und kein Cloud-Rollout.

[Maschinenlesbarer Nachweis](quality/v12-package-ocr-review-2026-11-07.json).
