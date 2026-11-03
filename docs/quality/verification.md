# Verifikation MCP 0.8.1: OCR-Korrektur und bestehende UI

Stand: 02.11.2026. Ausschließlich künstliche Dokumente und isolierte Bestände.

| Prüfung | Ergebnis |
| --- | --- |
| Vollständige Swift-Regression | 100 Tests, 15 Suiten bestanden |
| Gesamtlauf | Alle 13 Regressionsstufen bestanden |
| Textkorpus | 26 Fälle aus 14 Domänen; sämtliche annotierten Sollwerte erfüllt |
| Rollenfelder im Textkorpus | 87 korrekt, 0 falsch gefüllt, 0 fehlend |
| Kritische Übersichtsinhalte im Textkorpus | 43 von 43 erhalten |
| Native Rastermessung vorher → nachher | 5/8 → 8/8 vollständige Sollwerttreffer |
| Rollenfelder im Rasterkorpus vorher → nachher | 27 → 30 korrekt, 3 → 0 fehlend, weiterhin 0 falsch gefüllt |
| Kritische Rasterinhalte vorher → nachher | 11/15 → 15/15 erhalten |
| Original → echtes CLI → echter MCP | 33 Originale und Metadatenlesungen, einschließlich aller acht Rasterfälle |
| Bestehender P0-/LVM-Test | Alle 12 P0-Prüfungen bestanden |
| Paketprüfung | Release-Build, Ad-hoc-Signaturen, vollständiges App-Bundle samt Helfern und Anleitungen bestanden |
| Native UI | Drei betroffene Scans importiert, belegte Übersicht angezeigt, ein Dokument ausdrücklich freigegeben |
| UI: Text erneut lesen | Cachefrei, Originalbytes/Identität/Freigabe erhalten, alter MCP-Handle ungültig |
| UI: Pausieren und Neustart | Derselbe laufende MCP-Prozess lehnt Inhalt ab; Pause bleibt nach UI-Neustart erhalten |

Die Auslassungen in Kontoauszug, Behördenbescheid und Fahrzeugunterlage wurden zuerst mit
den unveränderten Rasteroriginalen reproduziert. Anschließend wurden nur weiße Außenränder
mit Sicherheitsabstand aus dem Vision-Eingabebild entfernt. Die Erkennung bleibt genau,
mit Sprachkorrektur und echten nativen Konfidenzen. Auflösung und Review-Grenzen wurden
nicht gelockert. Einpixelige, nahezu weiße farbige Randzeichen, isolierte Fußmarken,
randfüllende Inhalte, Leerbilder, Speichergrenzen und alte Cache-Konfigurationen haben
zusätzliche Regressionen. Die vorhandenen Solltexte und Annotationen wurden nicht angepasst.
Alle acht Rasterfälle sind jetzt blockierende Sollwerttests statt bloßer Review-Akzeptanz.

Der vollständige Lauf umfasst Swift, Paket, stdio, breiten Originalkorpus, Import-/Worker-
Lebenszyklus, Audit, Desktopregistrierung, Verwaltung, Statusmenü, Ordnerüberwachung,
Tunnel-Launcher mit lokalem Stub, sequenziellen OCR-/Cachevergleich und P0/LVM. Der Tunnel-
Test verwendet kein Netzwerk. Clienttests schreiben ausschließlich in künstliche Homes.
Gemessene Zeiten sind keine allgemeine Performancezusage.

Die native UI wurde aus dem exakt gebauten Repository-Bundle mit `--setup-root` gestartet.
Sie zeigt die neuen persistierten Rollen und Quellseiten an. Der Test nutzte nur eine
manuelle synthetische Verbindung; kein produktiver Chatbot wurde registriert. Ein echter
Cloud-Chat wurde nicht getestet. Nach der Prüfung wurden nur die eigenen Testprozesse beendet.

Reproduktion:

```sh
python3 scripts/mcp/regression_test.py --update-reports
python3 scripts/mcp/run_ui.py --setup-root /absoluter/isolierter/testordner
```

Die UI startet als vollständiges Bundle unter `dist/mcp/Vauldy MCP Einrichtung.app`.
`run_ui.py --no-open` bereitet es ohne Start vor. `--skip-build` setzt einen aktuellen
Release-Build voraus. „Text erneut lesen“ liest das Original ausdrücklich frisch; bestehende
Produktionsdatensätze werden durch das Softwareupdate nicht automatisch neu verarbeitet.

Maschinenlesbar: [Gesamtlauf](regression-summary.json), [native UI](ui-regression.json),
[Raster-Vorherstand](native-raster-before-ocr-fix.json), [Raster-Ergebnis](native-raster-baseline.json),
[Textkorpus](transcript-baseline.json), [Wire](base-analysis-wire.json), [P0](p0-retrieval.json).

## Weiterhin offene Qualitätsgrenzen

Acht passende künstliche Scans belegen keine universelle Qualität für reale Archive.
Texterkennung ist keine unabhängige Sachprüfung. Die Basisanalyse bleibt regelbasiert,
und es wurde kein Sprachmodell bewertet. Organisationsauflösung und fachliche Fristen-/
Versionsvergleiche sind weiter offen. Der ältere P0-Bericht behält `quality_pass: false`,
weil er zusätzliche, nicht implementierte fachliche Auditziele enthält; `p0_pass` ist wahr.

Der konservative übernommene Privacy-Detektor verändert im erweiterten Wire-Test 17 Titel.
Eine annotierte semantische Falschpositivrate ist daraus nicht ableitbar. Gespeicherte
Dokumentqualität und externe Antwortqualität bleiben getrennte Messaufgaben.

Das App-Repository wurde nicht geändert. Produktionsarchive, installierte Profile und
Clientkonfigurationen wurden nicht verwendet oder verändert. Das lokale Paket ist
Ad-hoc-signiert, nicht als notarisierte öffentliche macOS-Veröffentlichung ausgewiesen.

## Ergänzung: OAuth 0.10.0 (03.11.2026)

Alle 15 aktuellen Regressionsstufen sind bestanden, einschließlich 134 Swift-Tests in 19 Suiten,
aller nativen Rasterfälle und des bestehenden P0-Tests. Der neue reale HTTP-Wiretest prüft beide
künstlichen Anbieterclients, 55 künstliche Dokumente mit getrennten Freigaben, vollständige
Pagination, Privacy, PKCE, Refresh, Replay-Sperre, unabhängigen Widerruf und Dienstneustart.

Ein zusätzliches isoliertes App-Bundle bestätigte die native Freigabe mit eingefrorener Auswahl,
Tokenausgabe, MCP-Dokumentabruf und UI-Widerruf. Das künstliche Archiv und sein Profil blieben
bytegleich; keine produktive Verbindung oder Anbieteranmeldung wurde eingerichtet. Der lokale
macOS-Eigentümer autorisiert den Zugriff. Dies bestätigt keine Anbieteridentität per SSO.

Das Paket enthält den OAuth-HTTP-Dienst und die Bedienoberfläche. Öffentliche HTTPS-Bereitstellung
und tatsächliche Nutzung aus ChatGPT/Claude sind separate noch ausstehende Abnahmen. Details und
Reproduktion: [OAuth-Verbindungen](../mcp-oauth.md). Die oben dokumentierten fachlichen und
OCR-Qualitätsgrenzen bleiben bestehen.
