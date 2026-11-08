# R5 · Seitenprüfung aus dem Importbericht

Im Importbericht öffnet **Prüffälle anzeigen** die Dokumente mit OCR- oder
Analysehinweisen. **Seite prüfen** öffnet den lokalen Vergleich beim ersten
betroffenen Seitenhinweis. Die Seitenauswahl ist nummeriert. Originalvorschau,
gespeicherter Text und Prüfgrund stehen gemeinsam in einem Dialog. Uneindeutig
markierter Text wird keiner physischen Seite zugeschrieben. Die Basisanalyse
hat einen eigenen Hinweis für das gesamte Dokument.

Die Originalvorschau liest über den vorhandenen lokalen Originalzugriff und
rendert nur die gewählte Seite. Die geprüfte Prüfsumme gehört zu genau den
Bytes, aus denen die Vorschau entsteht. Beim Schließen des Zugriffs bleibt nur
das begrenzte Vorschaubild im Arbeitsspeicher der Einrichtung.

**Text erneut lesen** startet die vorhandene frische OCR über den lokalen
Worker. Der Vergleich zeigt den zuvor gespeicherten und den danach erkannten
Text derselben Seite. Textänderungen werden als solche benannt. Der Prüfgrund
bleibt für beide Stände sichtbar. Der Bericht aktualisiert die Prüfflags des
betroffenen Dokuments. Die Freigabeauswahl ist ein eigener Arbeitsschritt.

Die Seitenbuttons haben Tastenkürzel mit der Wahltaste und den Pfeiltasten.
Escape schließt den Dialog. Die Bildvorschau und Steuerelemente haben
zugängliche Bezeichnungen. Bei wenig Platz stehen Vorschau und Text
untereinander.

Geprüft wurde das vollständige native Testbundle mit eigenem `--setup-root`
und einer bereits gespeicherten synthetischen Freigabe. Ein neues zweitseitiges
Test-PDF mit langem Dateinamen wurde über die Dateiauswahl importiert. Seite 2
enthält nur Grafik. Der Bericht zeigte den Prüffall an, und die Prüfung öffnete
direkt Seite 2 mit sichtbarer Grafik und dem Grund „kein lesbarer Text erkannt“.

Im 540 Punkte breiten Dialog wechselten Wahltaste und Pfeiltasten zwischen
beiden Seiten. Seite 1 zeigte ihren erkannten Belegtext. Nach **Text erneut lesen**
waren beide Vergleichsstände sichtbar. Die Ansicht meldete den unveränderten
Text korrekt. Escape führte zurück zum Importbericht. Der lokale Bestand
enthielt zwei abgeschlossene native Aufträge für die Datei. Das gespeicherte
Original und das synthetische Freigabeprofil waren bytegleich. Die neue Datei
erschien nicht in der bestehenden Freigabe.

Im nativen Test wurden zwei Fehler gefunden und erneut geprüft. Eine
Layoutschleife im flexiblen Dialog wurde durch einen schmalen gestapelten
Dialog behoben. Die Originalvorschau wählt im JSON-Bestand ausdrücklich
die passende Dokument-ID aus. Ein Regressionstest prüft die Auswahl aus
zwei gespeicherten Dokumenten und das Rendern verschiedener physischer Seiten.

34 gezielte Swift-Tests in fünf Suites bestanden. Tastatur und die
Accessibility-Beschriftungen wurden im nativen Testfenster geprüft.
Die separate VoiceOver-Abnahme entfällt auf ausdrücklichen Nutzerwunsch vom
7. November 2026. VoiceOver wurde für den begonnenen Versuch vorübergehend
aktiviert und nach dem Abbruch wieder ausgeschaltet. R5 ist im vereinbarten
Umfang abgeschlossen.
[Prüfnachweis](quality/setup-quality-r5-2026-11-06.json).

```sh
cd /private/tmp/vauldy-r5.K37DxogZ
swift test -c release --disable-sandbox --disable-automatic-resolution --jobs 4 -debug-info-format none --no-parallel --filter 'LocalDocumentReviewTests|LocalImportTests|LocalOriginalReferenceTests|OCRTargetedRetryTests|OCRWhiteMarginsTests'
python3 scripts/mcp/run_ui.py --skip-build --no-open
open -n "dist/mcp/Vauldy MCP Einrichtung.app" --args --setup-root /private/tmp/vauldy-r5.K37DxogZ/ui-root
```

Für die native Bedienprüfung wurde das temporäre Bundle zusätzlich mit
einer eigenen App-Kennung versehen, sein URL-Schema entfernt und die
lokale Signatur erneut geprüft.
