# Fünf offene OCR-Fälle mit v13 erneut geprüft · 08.11.2026

MCP-Branch `codex/local-first-product-readiness`, Basiscommit `87ab76c3d7f79b53a2723235c036bf224c7573d6`,
vorhandene lokale Änderungen erhalten. Installierte Version 0.13.0, Serverbuild
`macho.e19c2c835af53f2d927c68b4eb371739`, OCR-Konfiguration v13. Keine Codeänderung,
kein neues Paket, kein Commit/Push und kein Cloud-Rollout dieser Wartung.

Auf ausdrücklichen Auftrag wurden die fünf tatsächlichen offenen Dokumente lokal
erneut gelesen: zuerst private Kandidatenkopie, dann aktiver Bestand. Je Durchlauf
22 physische Seiten, insgesamt 44 native Seitenverarbeitungen. Alle aktiven Seiten
haben die neue OCR-Konfiguration; kein Cachetreffer und kein Rückfall auf alte
Seiten durch den Belegschutz. Kandidat und aktiver Lauf liefern identische OCR-Texte.

| Fall | Seiten pro Durchlauf | Zeichen vorher → nachher | Zusätzliche Zeilen | Markierte Seiten vorher → nachher |
| --- | ---: | ---: | ---: | ---: |
| D1 | 9 | 29.332 → 29.332 | 0 | 4 → 5 |
| D2 | 1 | 1.147 → 1.147 | 0 | 1 → 1 |
| D3 | 4 | 9.410 → 9.410 | 0 | 1 → 1 |
| D8 | 2 | 3.294 → 3.294 | 0 | 2 → 2 |
| D9 | 6 | 7.595 → 7.663 | 9 | 5 → 5 |
| **Gesamt** | **22** | **+68 Zeichen** | **9** | **13 → 14** |

Die Bezeichnungen D1…D9 entsprechen den früheren privaten Prüfläufen. Dateinamen,
Dokumentkennungen, tatsächliche Werte und Originale werden nicht im Repository abgelegt.
Alle fünf `refine`-Befehle je Durchlauf melden korrekt Exitcode **2 / partial**.
Die beiden Prüfskripte melden Exitcode 0 nach bestandenen Erhaltungsbedingungen;
das wird nicht als vollständige Texterkennung ausgegeben.

## Was die neue OCR tatsächlich verbessert

D9 Seite 5/6 kann den zuvor begrenzten visuellen Vergleich jetzt über 165 bzw.
135 Regionen ausführen, bei weiterhin höchstens 128 gespeicherten Regionen.
Beide Vergleiche wechseln von `limited` zu `checked`. Vier begrenzte Nachleseversuche
je Seite ergänzen sechs bzw. drei Zeilen. Es bleiben sichtbare Abdeckungslücken.
Die unterschiedliche Detektionsbreite erlaubt keine Ableitung einer Zeichenfehlerrate.

Die neun zusätzlichen Zeilen enthalten ausschließlich Ziffern/Trennzeichen, keine
Buchstaben. Sechs passen technisch zu Datumsmustern; keine enthält das geprüfte
Betragsmuster mit EUR/€. Diese Formprüfung bestätigt weder die korrekte Abschrift
noch die fachliche Rolle der Werte. Eine unabhängige visuelle Genauigkeitsmessung
an den echten Originalen wurde nicht durchgeführt. D1/D2/D3/D8 liefern keinen Zusatztext.

Der Quellenzustand bleibt vier vollständig verarbeitet / fünf prüfbedürftig.
14 Seiten bleiben markiert: sieben mit geometrischen Lücken, elf mit Zeilen unter
0,6 nativer Konfidenz; Gruppen überlappen. Keine begrenzten Abdeckungsvergleiche mehr
in den 22 neu verarbeiteten Seiten. Native Konfidenz ist kein gemessener Genauigkeitswert.

D1 erhält bei unverändertem Text zwei neue Prüfmarkierungen (Seiten 4 und 8);
auf Seite 6 entfällt eine alte Markierung. Netto steigt der Gesamtprüfbedarf um eine
Seite. Die Anzahl niedriger Zeilenkonfidenzen und die Geometrie dieser drei Seiten
bleiben dabei gleich. Diesen Statuswechsel der Kontext-/Bestätigungsprüfung separat
reproduzieren und begründen, bevor daraus ein Qualitätsgewinn abgeleitet wird.

## Einfluss auf Chatantworten und Basisanalyse

Für D9 steht zusätzlicher Datums-/Zahlentext als mögliche Quelle bereit. Die fünf
bisherigen gespeicherten Analysebelege sind insgesamt unverändert; es entstehen keine
zusätzlichen belegten Analysefelder und keine gespeicherten Fristen. Alle neun
Basisanalysen bleiben `needsReview`. Die fünf bearbeiteten Analysen wurden durch den
normalen Importabschluss aktualisiert, vier andere Datensätze insgesamt nicht verändert.

Neue Zahlen-/Datumszeilen erst mit ihrem lokalen Seitenkontext einer Rolle zuordnen.
Aus einem isolierten Datum folgt kein belegter Vertragsbeginn, Kündigungstermin oder
Fälligkeitswert. Ein messbarer Gewinn in regulären Chatantworten ist in dieser Wartung
nicht geprüft. Der tatsächliche ChatGPT-Anschlussstatus bestätigt weiterhin
`available=true`, neun freigegebene und neun durchsuchbare Dokumente; keine fehlen
oder warten. Über diesen Anschluss wurden ausschließlich Statuszahlen, keine echten
Dokumenttexte abgerufen.

## Belegerhalt und Sicherung

Private Sicherung vor Beginn:
`/Users/marcomeisen/Library/Application Support/Vauldy Backups/v13-ocr-review-20261108-092714`.

- Neun Originale per SHA-256 unverändert, alle neun IDs und Originalreferenzen erhalten.
- Jede bisherige nichtleere OCR-Zeile bleibt pro physischer Seite in gleicher Reihenfolge
  und mit Wiederholungen vorhanden; alle bisherigen Belegzitate bleiben auf ihrer Seite.
- Fünf gespeicherte Analysebelegdatensätze unverändert. Die vier nicht beauftragten
  Dokumentdatensätze sind insgesamt gleich geblieben.
- Zwei Verbindungsdateien und die bestehende Clientkonfiguration bytegleich.
  Kopplungsmetadaten und Profilzuordnung unverändert. Relay läuft ohne neue
  Schlüsselbundfreigabe; kein Worker oder Watcher für diese Wartung gestartet.
- Regulär ergänztes Audit: alter Inhalt als Präfix erhalten, Prüfkette verifiziert.
  Keine Daten aus Sicherungen zurückgespielt oder Auditdateien bereinigt.
- Neuer lokaler Start-/Discoverytest: korrekter installierter Build, acht Werkzeuge,
  neun Freigaben. Originale und echte Texte bleiben lokal.

## Ausgeführte Befehle und Grenzen

```sh
python3 /private/tmp/vauldy-v13-ocr-prepare.py
python3 /private/tmp/vauldy-v13-ocr-review.py stage
python3 /private/tmp/vauldy-v13-ocr-review.py apply
python3 /private/tmp/vauldy-v13-ocr-diagnostics.py stage
python3 /private/tmp/vauldy-v13-ocr-diagnostics.py apply
python3 /private/tmp/vauldy-v13-ocr-finalize.py
```

Die beiden Review-Treiber verwenden seriell den installierten Befehl
`vauldy-local refine --store … --document …`: ohne OCR-Cache, mit schreibgeschütztem
Original-Lease, Quellenhash und erwartetem Datensatz beim Commit sowie dem vorhandenen
`EvidencePreservingLocalOCR`. Tatsächliche IDs und Detailprotokolle liegen nur privat.

Aktive OCR-Zeiten je Dokument: 10,418 / 1,389 / 4,011 / 2,310 / 8,160 s.
Die Kandidatenprüfung hatte einen kälteren ersten Aufruf; keine allgemeine
Laufzeit- oder Performanceverbesserung daraus ableiten.

Ein erster Diagnosebericht konnte wegen der Sandbox nicht in die private Library-
Sicherung geschrieben werden; mit passenden Dateirechten wiederholt. Die erste
Abschlussprüfung benutzte einen falschen Auditpfad; anhand des Codes auf `logs/audit.jsonl`
korrigiert und erfolgreich wiederholt. Beide betrafen Hilfsskripte, keine fehlgeschlagene
OCR und keinen zusätzlichen nativen Nachlauf.

Die zuvor bei Paketbau ausgeführten 97 Swift-Tests werden hier **nicht als erneut
ausgeführt** gezählt. Produktcode und Installation unverändert; dieser Auftrag wurde
durch tatsächliche lokale OCR-Ausführung und Erhaltungsprüfungen abgearbeitet.
[Paketnachweis](v13-package-update.md),
[maschineller Wartungsnachweis](quality/ocr-v13-real-review-2026-11-08.json).

Nächste Qualitätsarbeit: unabhängige dichte Raster-/Tabellenseiten und verrauschte
Einzelzeilen mit exakten Sollwerten prüfen; Review-Wechsel der Kontextprüfung
nachvollziehbar machen. Die fünf realen Fälle bleiben fachlich offen.
