# R3d.3 · SQLite-Abnahme mit paralleler OCR

Der ausführbare Prüfer `scripts/mcp/sqlite_combined_acceptance.py` baut fünf separate
Bestände mit 1.000, 2.000, 5.000, 10.000 und 20.000 Einträgen auf. Er verwendet
dieselben synthetischen Langtextdatensätze mit rund 32 KiB pro Dokument wie R3d.2.
Je Größe werden zwei Dokumente über den nativen Import erfasst. Die übrigen
Datensätze werden als geprüfte synthetische SQLite-Fixtures eingebracht. Der CLI
baut die Projektionen und den Index auf. Die Messung verwendet lokales stdio.

Der echte Import einer 24-seitigen Raster-PDF beginnt mit voller Freigabe aller
bereits vorhandenen Einträge, also jeweils N−1. Der Prüfer kontrolliert nach
dem Commit, dass die bisherige Freigabe bytegleich ist und die neue Datei erst
nach einer ausdrücklichen Testfreigabe sichtbar wird. Anschließend werden alle
N Einträge freigegeben. Mit `retry --fresh` läuft die native OCR derselben
Raster-PDF erneut. Damit ist auch bei der Bestandsgrenze von 20.000 eine volle
Freigabe mit aktiver OCR messbar. Die Import- und OCR-Schritte lassen die
Dateihashes der Originale sowie die übrigen Datensätze unverändert.

Eine Beobachterverbindung tastet den SQLite-Zustand `recognizing` ab. Eine
Anfrage zählt nur als überlappend, wenn ihr Zeitintervall diesen beobachteten
OCR-Zeitraum schneidet. Erfolgreiche Antworten müssen die unabhängige Sollzahl
und die Anzahl der Freigaben enthalten. Bei einem Quellwechsel akzeptiert der
Prüfer nur die vorgesehenen Fehler ohne strukturierte Dokumentdaten. Er zählt
sie gesondert. Ein Timeout ist ein fehlgeschlagener Versuch. Bei stabiler Quelle
prüft er nach dem OCR-Commit, dass alte Handles und Cursor abgewiesen werden.

Die wiederholten Abfragen sind der kompakte Filter `Versicherung`, die gerankte
Suche nach `Pruefmarker000000` und die gerankte Suche nach `Versicherung`. Der
Prüfer fordert zehn Wiederholungen für die beiden ersten und drei für die
breite Rangsuche. Bei einem Timeout beendet er den Messblock und hält die
unvollständige Stichprobe fest. Für die kurzen Abfragen während Vollfreigabe
sind je mindestens zwei erfolgreiche Überlappungen gefordert. Die breite
Rangsuche hat eine eigene OCR-Runde mit einem überlappenden Versuch.

Die vorhandenen Grenzen bleiben bei 5 s für den ersten Status, 1 s P95 für
warme Status- und kompakte Listenabfragen, 5 s für einen Textfilter und 512 MiB
Peak-RSS des MCP-Prozesses. Für wiederholte Suchen gilt in dieser Abnahme ein
P95 von höchstens 5 s je Abfragetyp. Für die Suchmessblöcke endet eine Einzelanfrage
nach 15 s. P95 wird per Nearest Rank aus den abgeschlossenen Aufrufen ermittelt.
Fehlende Stichproben und Timeouts führen unabhängig davon zum NO-GO.
Der RSS-Wert umfasst jeweils den MCP-Prozess. Die native OCR läuft im separaten
Worker. Die Messung liefert keine Aussage zum Gesamt-RAM oder zur Chat-Laufzeit.

Am 20.000er-Bestand beendet der Prüfer den eigenen CLI-Indexaufbau mit SIGKILL,
sobald ein befülltes Rollback-Journal beobachtet wurde. Er vergleicht danach
Generation, Datensatzprüfsummen und Indexzählungen, prüft die SQLite-Integrität
und führt mit voller Freigabe Suchanfragen aus. Ein erneuter Aufbau muss das
Journal entfernen. Danach werden die Vollfreigabe-Abfragen wiederholt.

**Abnahmeentscheidung NO-GO.**

| Vollfreigabe | Filter P95 | Seltener Rangtreffer P95 | Breite Rangsuche P95 | Filter während OCR P95 | Seltener Rangtreffer während OCR P95 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1.000 | 0,111 s | 0,383 s | 2,865 s | 0,088 s | 0,068 s |
| 2.000 | 0,083 s | 0,389 s | 5,322 s | 0,084 s | 0,075 s |
| 5.000 | 0,086 s | 0,412 s | 12,807 s | 0,110 s | 0,242 s |
| 10.000 | 0,134 s | 0,480 s | Timeout (0/3) | 0,281 s | 0,634 s |
| 20.000 | 0,146 s | 0,503 s | Timeout (0/3) | 0,386 s | 0,510 s |

Die Tabelle zeigt P95 aus erfolgreichen, jeweils nach Abfragetyp getrennten
Antworten. Die Rohdaten enthalten Stichprobengrößen, Peak-RSS, Quellwechsel und Timeouts.
Der Pilot verwendet eine kleinere Zahl von Wiederholungen und fließt in die Entscheidung
der vollständigen Matrix nicht ein.

Bei 20.000 endete die breite Rangsuche sowohl während OCR als auch im ruhenden
Bestand nach 15 s. Im ruhenden Bestand blieb der Block deshalb bei
1 von 3 geplanten Versuchen. Während OCR scheiterte der
eine überlappende Versuch. Der Peak-RSS der Basisprüfung lag bei 80.5 MiB.

Der Implementierung zufolge lädt die breite Rangsuche weiterhin jeden gefundenen
Kandidaten und berechnet dessen Wertung am vollständigen Text. Die Begrenzung
auf einen ausgegebenen Treffer ändert diese Bewertungsarbeit nicht. Für den
synthetischen Versicherungsbegriff gibt es 5.000 Kandidaten. Das erklärt den
Unterschied zum kompakten Filter und zum seltenen Rangtreffer auf Codeebene.
Ein Sampling-Profil zur Aufteilung der CPU-Zeit wurde nicht erhoben.

Der Indexabbruch bei 20.000 ist bestanden. Beim SIGKILL war das beobachtete Journal
460,164 Byte groß. Generation, Datensatzprüfsummen und Indexzählungen
entsprachen nach dem Abbruch dem letzten Commit. Die SQLite-Integritätsprüfung meldete
`ok`. Die Vollfreigabe-Abfragen nach Rollback und nach dem Neuaufbau lieferten
ihre erwarteten Treffer. Der erneute Aufbau entfernte das Journal.

Die Release-Binaries stammen aus der vorherigen Buildkopie. 135 Paket-, Quell- und
Testdateien wurden für diese Iteration bytegenau verglichen. Die Änderungen betreffen
den Prüfer und die Dokumentation. Die Lastmatrix und der Pilot wurden neu ausgeführt.
[Rohmesswerte und Hashes](quality/storage-r3d3-2026-11-06.json).

```sh
python3 scripts/mcp/sqlite_combined_acceptance.py /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-local /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-mcp --counts 20000,1000,2000,5000,10000 --output /private/tmp/vauldy-r3d3.U1sJmijI/matrix.json
python3 scripts/mcp/sqlite_combined_acceptance.py /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-local /private/tmp/vauldy-r3d2.rFwXXTwt/.build/release/vauldy-mcp --counts 1000 --samples 3 --repeats 3 --broad-repeats 1 --output /private/tmp/vauldy-r3d3.U1sJmijI/pilot.json
python3 -m py_compile scripts/mcp/sqlite_combined_acceptance.py
git diff --check
```
