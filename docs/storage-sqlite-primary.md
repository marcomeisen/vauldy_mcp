# Ausdrückliche SQLite-Primäraktivierung · 0.13.1

`LocalStorageMigration.activateSQLite` stellt einen vorhandenen lokalen JSON-Bestand
auf eine vorher additiv übertragene und unabhängig geprüfte SQLite um. Dies ist ein
lokaler Verwaltungsauftrag, kein MCP-Werkzeug und keine automatische Startmigration.

```sh
vauldy-local storage-preview --store /bestand --format sqlite
vauldy-local storage-migrate --store /bestand --format sqlite --to /neue-sicherung --expected FINGERPRINT
vauldy-local storage-activate-sqlite --store /bestand --prepared /neue-sicherung --expected FINGERPRINT
```

Das Sicherungsziel muss neu sein und außerhalb des Bestands liegen. Ein geänderter
Bestand, laufender Worker, ausstehende OCR, beschädigte Sicherung oder ein abweichendes
vorbereitetes SQLite-Dokument verhindert die Aktivierung.

Der Dienst hält bestehende Worker-, OCR- und Writersperren, vergleicht alle typisierten
Dokumentdaten einschließlich Originalverweisen und Originalkopien und erstellt über
SQLite-Online-Backup ein neues privates Datenbankverzeichnis am bestehenden Bestandsort.
Die JSON-Dateien werden verlustlos nach `activation-source-UUID` im Sicherungsziel
verschoben. Das unabhängige manifestgeprüfte `backup` bleibt zusätzlich erhalten.
Originale und bestehende Profilbindungen werden nicht neu erstellt.

`store.json` mit `kind=vauldy-local-core, version=4` ist die ausdrückliche Auswahl der
führenden SQLite. Nur dieser Marker erlaubt `LocalVaultSnapshotSource`, alte logische
`documents.json`-Pfade bestehender Freigaben auf `sqlite/records.sqlite` aufzulösen.
Profile, Revisionen, Gerätefingerprints und Auswahl bleiben bytegleich. Caches, Handles
und Cursor werden über die neue Quellenidentität/Transaktionsgeneration ungültig.
Die SQLite-Datensätze sind führend; Payload-JSON innerhalb einer SQL-Zeile ist deren
Serialisierung, keine zweite führende JSON-Datei. Such-/Rangprojektionen sind abgeleitet.

`SQLITE_ACTIVATION_PENDING` blockiert aktuelle Lese-/Schreibdienste während der
Umschaltung. Ein Fehler löst unter denselben Sperren einen verifizierten Rückweg aus.
Nach Prozessverlust erfolgt kein stiller Restore. Der explizite Befehl lautet:

```sh
vauldy-local storage-recover-activation --store /bestand
```

Dabei werden weder abweichende aktuelle JSON-Dateien noch unerwartete spätere
SQLite-Schreibvorgänge überschrieben. SQL-Zwischenstände werden im Archiv erhalten.
Solange die Prüfung scheitert, bleibt der Bestand gesperrt.

Softwarekompatibilitätsepoche 2 verhindert den regulären Rollback auf alte Writer.
Der neue Updater darf eine geprüfte Epoche-1-Generation ausschließlich als aktuellen
Ausgangsstand lesen. Ein altes Programm scheitert selbst bei manuellem Start am
unbekannten Storeformat 4. Bestehende Clientpfade bleiben stabil; laufende alte
Hostprozesse müssen nach der Softwareaktualisierung neu gestartet werden.

Neue fremde Bestände werden weiterhin nicht automatisch adoptiert/migriert. Es gibt
keine Qualitätsänderung oder erneute OCR durch die reine Speicherungsmigration.

Nachweis: `SQLitePrimaryActivationTests` prüft verlustlose Aktivierung, unveränderte
Freigabe und Gerätefingerprints, Quellen-/Cursorwechsel, SQL-Schreibpfad, fehlerbedingten
Rückweg, rekonstruierte Unterbrechung und Schutz späterer SQL-Änderungen.
`sqlite_primary_smoke_test.py` prüft tatsächliche Paketprogramme mit synthetischem
nativen Vision-Import vor/nach Umschaltung, realem Epoche-1-Upgrade, abgewiesenem
Altwriter/Rollback, identischem Profil sowie stdio-Suche, Privacy und Widerruf.
Rekonstruierte Unterbrechungen sind kein Nachweis gegen tatsächlichen Stromverlust.
