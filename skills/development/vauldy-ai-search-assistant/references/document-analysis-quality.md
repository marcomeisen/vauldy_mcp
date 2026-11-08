# Belegte Dokumentaussagen im lokalen Vauldy MCP

Zuerst den tatsächlichen Build, ausgewählte Quelle, OCR-Stand, Seiten, gespeicherte Basisanalyse,
Freigabe und fehlgeschlagene Phase feststellen, soweit im Auftrag zugänglich. Eine Bildschirmmeldung
beweist weder Quellinhalt noch Ursache. Produktive Dokumente nicht durch leichter lesbare Fixtures
ersetzen und deren Pass als Lösung des ursprünglichen Falls ausgeben.

## Vier getrennte Ergebnisse

1. OCR liefert lesbaren, physisch zugeordneten Quelltext samt Unsicherheiten.
2. `VauldyDocumentIntelligence` erstellt eine lokale regelbasierte Basisanalyse mit Quellenbindung.
3. MCP wählt autorisierte geschützte Werte, Listen oder Textfenster aus.
4. Der gewählte Chatbot formuliert seine Antwort auf diesen Werkzeugergebnissen.

Die Qualität einer Stufe beweist keine vollständige Qualität der anderen. Ein erfolgreicher Abruf
ist kein Nachweis korrekter OCR oder einer fachlich richtigen Antwort. Der MCP startet keine
VLM-/Cloud-Anbieterauswertung und speichert keine Chatbotbehauptung als geprüfte Tatsache.

## Rollen und Belege

- Wert, Beschriftung, wörtlichen Kontext und physische Seite gemeinsam prüfen. Ein Treffer im
  Dokument reicht für die richtige Rolle nicht aus.
- Aussteller, Versicherer, Kunde, Empfänger und unklaren Vertragspartner unterscheiden.
- Vertragsbeginn, Vertragsende, Ausstellungsdatum, Geburtstag und Zahlungsfrist nicht vertauschen.
- Monatsrate, Jahresbeitrag, Gesamtkosten, Schlussrate, Steuern, Teilbeträge und offene Beträge
  mit ihren Originalrollen erhalten. Keine nicht beauftragten oder unbelegten Berechnungen.
- Kündigungsfrist und Kündigungsbedingungen auseinanderhalten. Negationen, Ausnahmen und
  Fortsetzungen können eine kurze Belegzeile einschränken. Bei Lücken weitere Fundstellen prüfen.
- Bei mehreren logischen Vorgängen in einer PDF keine Beträge, Aussteller oder Termine aus
  verschiedenen Seiten zu einem erfundenen Vertrag zusammensetzen. Zusammengehörigkeit prüfen.
- Wiederholte Erwähnungen oder gleiche Rollenwerte sind keine verlässlich verschiedenen Verträge.
  Eine Überschrift oder Police belegt keinen aktuellen Vertragsstatus.

Die Feldauslese ist bewusst auf bekannte Beschriftungen und Überschriften begrenzt. Fehlende
Felder offenlassen, Konflikte beibehalten, Maskierungen nicht rückgängig machen. Nicht beschrifteter
Freitext kann außerhalb dieses Auslesepfads liegen. Für eine vollständige Vertragsprüfung genügen
weder `retrievalComplete` noch ein Feldstatus `evidenced` allein.

## Qualitätsänderungen prüfen

Synthetische schwierige Quellen und Ablenkungen mit unabhängig festgelegten Sollrollen verwenden:
späte relevante Seite, mehrere Kostenrollen, widersprüchliche Fristen, fehlendes Feld, maskierter
Wert, unlesbare Seite, Quellenwechsel und Widerruf. Alle angeforderten Belegseiten und alle
Folgeseiten prüfen. Erwartete Qualität nicht an das erhaltene Ergebnis anpassen.

Bei Import-/OCR-Arbeit frische Erkennung, Cache-Wiederholung, gespeicherten Text und spätere
MCP-Antwort auseinanderhalten. Originalbytes, IDs und Freigaben müssen bei einem OCR-Retry erhalten
bleiben. Bei Basisanalyseänderungen Persistenz/Reload und Quellenhash mitprüfen. Eine einzelne
erfolgreiche Wiederholung ist keine Zuverlässigkeitsmessung.

Bei Antwort-/Performancearbeit Werkzeugrunden, Fehler und Datenumfang zählen. Auswahl des Dokuments,
Inhaltsabruf, Modell-/Relayzeit und sichtbare Tabelle getrennt messen. Ergebnisse mit bestehenden
synthetischen Tests belegen und tatsächliche Zielchat- oder Originalprüfungen ausdrücklich benennen.
Keine allgemeinen Qualitätsversprechen aus kleinen Korpora oder historischen Testzahlen ableiten.
