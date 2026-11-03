# Geführter Bestandsabgleich und Freigabeaktualisierung (0.13.0)

Einstieg in „Dokumente“ über „Bestand abgleichen und neu freigeben …“ oder bei einer
bestehenden ChatGPT-Anmeldung über „Bestand und Freigabe aktualisieren …“.

1. **Bestand abgleichen:** konfigurierte Quellen auswählen oder weitere Ordner für diesen
   einmaligen Lauf hinzufügen. Eine Vorschau zeigt neue, geänderte, vorhandene, ausstehende
   und inhaltsgleiche Dateien sowie Zugriffs-/Größenprobleme. Erst der nächste ausdrückliche
   Schritt importiert. Alternativ lässt sich nur der gespeicherte Bestand prüfen.
2. **Qualitätsbericht:** Originale erneut auf Zugriff und Inhaltsgleichheit prüfen. Pro
   Dokument Seitenverarbeitung, Basisanalyse und unbelegte Basisangaben getrennt anzeigen.
   Originalvorschau und frisches erneutes Lesen sind explizite Einzelaktionen. Lesbare
   Dokumente mit Prüfhinweisen sind gesondert auswählbar. Fehlende, veränderte oder nicht
   überprüfbare Originale sowie Dokumente ohne durchsuchbaren Text sind nicht neu freigebbar.
3. **Neu freigeben:** Empfänger, gesamte Auswahl, hinzugefügte/entfernte Dokumente und
   Prüfhinweise anzeigen. Weitergabe und eingeschlossene Prüfhinweise separat bestätigen.
   Der abschließende Dialog friert Profil, Bestand und Auswahl ein. Leere Auswahl pausiert;
   eine bereits pausierte Verbindung wird nicht automatisch aktiviert.

Die Quellenprüfung umfasst unterstützte PDFs/Bilder in den gewählten Ordnern. Versteckte
Dateien, Pakete und symbolische Links werden nicht importiert; Grenzen und Zugriffsprobleme
bleiben sichtbar. Der Qualitätsbericht bezieht sich auf den gesamten gespeicherten lokalen
Bestand. Im geführten Ablauf werden die geprüften Quellenzustände anschließend unter
Snapshot-Sperre als eigene Metadaten veröffentlicht, damit der Chat fehlende oder veränderte
Originale mit aktuellen Verarbeitungshinweisen sieht. Text, Basisanalyse und Freigaben
bleiben dabei erhalten. Die alleinige Vorschau und die CLI-Qualitätsdiagnose schreiben diese
Zustände nicht zurück. Fehlende Originale und historische Einträge werden nicht gelöscht. Der Ablauf
verändert keine Originalbytes und entfernt keine bestehenden Kopien. Ordnerimporte speichern
weiterhin schreibgeschützte Verweise. Neue Importe bleiben bis zur Bestätigung ohne Freigabe.

„Ohne offene Hinweise“ bedeutet vollständig gemeldete Quellenverarbeitung und abgeschlossene
regelbasierte Basisanalyse. Optionale, nicht belegte Angaben bleiben leer. Es ist keine
fachliche Prüfung, keine garantierte OCR-Genauigkeit und keine Qualitätszusage für Chatprosa.
Der Bericht ist ausschließlich lokal; rohe Titel und dauerhafte Kennungen gehen nicht durch
neue MCP-Werkzeuge nach außen. Die bestehenden vier lesenden Werkzeuge, Datenschutzprüfung,
Belege, Verarbeitungsabdeckung und vollständige Listenpagination bleiben die Chat-Grenze.

## Bestehende ChatGPT-Verbindung aktualisieren

Die native, nichtinteraktive Agentenoperation `updateGrant` verlangt eine ausdrückliche
Bestätigung, exaktes Profil samt kanonischem Fingerprint, Revision, Dokumentauswahl und
Snapshot-Hash. Vor dem Umschalten prüft der Originalzugriff besitzende Prozess die Quellen erneut.
Er übergibt dem Agenten einen lokalen Prüfbeleg mit Snapshot-Hash, Zeitpunkt und exakt
verifizierten Kennungen. Dieser Beleg gilt höchstens 120 Sekunden, ist keine kryptografische
Remote-Identität und wird ausschließlich über die vertrauenswürdige lokale Verwaltungs-IPC
angenommen. MCP und HTTP bieten keine entsprechende Freigabeoperation. Der Agent prüft
Berichtsbindung, Seiten-/Analysezustand und gewählte Dokumente nochmals.
Während des lokalen Commits bleibt der Snapshot unter seiner Writer-Sperre unverändert;
die Profiländerung prüft die eingefrorene Empfänger-/Freigabebindung unter ihrer eigenen Sperre.
Der alte Agent wird vor dem Wechsel angehalten; ein neuer stdio-Prozess erhält die neue Revision.
Alte Handles/Cursor werden nicht als Fortsetzung einer anderen Auswahl übernommen.

Nur die lokale Auswahlbindung wird erneuert. Profilkennung, Client-Eintrag, Gerätezugang,
Geräteschlüssel, Cloud-Eigentümer und bestehendes Ablaufdatum bleiben erhalten. Es gibt weder
Verbindungslöschung noch neue Geräte-Kopplung oder automatische Laufzeitverlängerung. Eine
bereits abgelaufene oder widerrufene Anmeldung benötigt weiterhin eine neue Anmeldung.

Ein Abbruch vor der Bestätigung erweitert keine Freigabe; bereits importierte Datensätze bleiben
lokal erhalten. Während des bestätigten Commits ist der Abbruchknopf gesperrt. Scheitert nach
der Profiländerung der Schlüsselbund-Commit, passt die alte Gerätebindung nicht zur neuen
Revision und der Relay bleibt gesperrt. Bericht erneut prüfen und dieselbe Verbindung nochmals
bestätigen; keine Zugangsdaten löschen oder ACL erweitern. Status öffnet weiterhin keine
Schlüsselbunddialoge. Eventuell nötige Systemfreigabe nur über den bestehenden expliziten Knopf.

Der einmalige Worker startet keine zuvor gestoppten Ordnerüberwachungen. Ein unabhängig bereits
laufender Watch-Worker bleibt unabhängig. Ein ausdrücklicher gewöhnlicher Watch-Start kann
auch einen einmalig gestarteten Worker wieder für die konfigurierten Ordner aktivieren.

## Prüfung

`InventoryWorkflowTests` verwendet ausschließlich künstliche Originale, lokale Profile und
synthetische Credential-Persistence. Geprüft werden Vorschau ohne Snapshotänderung, stale
Pläne/Berichte, fehlende/veränderte Originale, separate Review-Einwilligung, Profil-Manipulation,
große fragmentierte IPC-Auswahlen, pausierte/leere Auswahl, Fehler zwischen Profil-/Credential-
Commit, Wiederbestätigung und bestehende MCP-Handles nach einem Freigabewechsel.
Die gesamte Regression läuft über `python3 scripts/mcp/regression_test.py`.
Eine synthetische Prüfung ersetzt keinen echten Werkzeugaufruf aus einem normalen Zielchat.

## macOS-Dateizugriff zwischen Oberfläche und Worker

Persistente app-gebundene Leseverweise bleiben beim besitzenden Prozess. Für einen
konkreten OCR-Auftrag öffnet dieser das Original, verifiziert es und übergibt dem Worker
einen impliziten kurzlebigen Bookmark aus dem bereits schreibgeschützten Zugriff. Der
Worker löst diese eigene Übergabe ohne Dialog auf und prüft Inhaltshash, Dateiidentität
und Ausschluss des eigenen Bestands vor OCR und beim Commit. Der Zugriff bleibt bis
zum tatsächlichen Ende der nativen Erkennung erhalten. Ungültige/abgelaufene Übergaben
führen zu einem Fehler; es gibt keinen Pfad-Fallback. Die private Auftragsdatei verwirft
die Übergabe nach Abschluss. Nicht abgeschlossene Aufträge können nach einem Neustart
eine erneute bewusste Freigabe benötigen.

Apples [Bookmark-Optionen](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withoutimplicitsecurityscope)
beschreiben die implizite, für andere Prozesse auflösbare kurzlebige Security-Scope-Übergabe;
sie ist keine neue persistente Berechtigung. Bestehende Schlüsselbund-ACLs, Codesign-
Anforderungen und Originalbytes werden nicht verändert. Worker prüfen ihre IPC-Version
gebunden an die aktuelle Prozessinstanz; alte laufende Worker übernehmen keine neuen
Übergabeaufträge. Sie müssen geordnet beendet werden, bevor neue Aufträge starten.

Wird ein alter Originalverweis unlesbar, bietet der ausdrückliche Quellenabgleich
„Originalzugriffe erneuern“ an. Nur eine erneut gewählte Quelle mit vollständig gleichem
Inhaltshash ersetzt diesen Verweis. Dokumentkennung, OCR und Freigabe bleiben erhalten.
Managed Copies werden dadurch nicht automatisch ersetzt oder entfernt.

Für eine lokale Bestandsdiagnose liefert `vauldy-local inventory-quality --store /bestand`
ausschließlich Zählwerte für Bereitschaft, Prüfbedarf und Originalzugriff sowie den
Snapshot-Hash. Keine Originalinhalte, Titel, Bookmarks oder Zugangsdaten werden ausgegeben.

Die Oberfläche lädt nach Abschluss Bestand und gespeicherte Auswahl neu. Ältere lokale
Agentenantworten bleiben lesbar, melden aber keine Update-Fähigkeit. Bei einer bestehenden
ChatGPT-Anmeldung führt der neue Ablauf dann zuerst zu „Einstellungen → Software aktualisieren“;
er ersetzt die Verbindung nicht durch eine lokale Ausweichfreigabe. Nach Softwarewechseln
kann macOS eine erneute eigene Schlüsselbundfreigabe oder die erneute Auswahl eines
Quellordners verlangen. Weder Systemschutz noch fehlgeschlagene Bookmarks werden umgangen.

Die native Abnahme verwendet ein separates App-Bundle, einen künstlichen lokalen Bestand
und eine nicht verbundene Statusattrappe. Sie prüft keine produktive Cloud-Freigabe. Gleiche
Verbindungskennung, gültige neue Revision, Abbruch vor Übernahme, keine Erfassung des
abgewählten Watch-Ordners, Originalvorschau, Erneuerung von Verweisen nach neuem App-Build,
aktualisierte Hauptliste und echte anschließende stdio-Listen-/Leseaufrufe sind separat belegt.
Anmeldung und Gerätebindung werden zusätzlich mit synthetischer Credential-Persistence geprüft;
ein echter Zielchat-Aufruf ist kein Bestandteil dieser isolierten Abnahme.

## Abnahme vom 03.11.2026

Alle 19 Regressionen mit 177 Swift-Tests in 24 Suiten sowie zehn Worker-SQL-Integrationstests
bestehen. Das finale Paket hat zusätzlich den stdio-Wiretest und die exakte Vier-Werkzeug-
Parität bestanden. Die native Abnahme prüfte 1→2 Dokumente, Abbruch ohne Freigabeänderung,
Review-Einwilligung, Originalvorschau, anschließende echte MCP-Pagination und bereinigtes
Lesen sowie 2→1 Auswahl mit automatisch aktualisierter Hauptliste. Ein nach neuem Test-App-
Build unlesbarer Verweis wurde nach Inhaltsvergleich bei gleicher Identität erneuert.
[Maschinenlesbarer Nachweis](quality/inventory-workflow-2026-11-03.json).

Die produktive Installation und ihre 147-Dokument-Freigabe wurden für diese Abnahme nicht
aktualisiert oder verwendet. Das geprüfte 0.13-Paket liegt in `dist/mcp/`. Für die Nutzung die
neue Einrichtung öffnen und unter „Einstellungen“ die installierte Software aktualisieren;
erst der ausdrücklich bestätigte geführte Ablauf ändert die Auswahl. Eine echte produktive
SSO-Freigabeänderung und ein Werkzeugaufruf aus dem Zielchat wurden hier nicht als Test ausgeführt.
