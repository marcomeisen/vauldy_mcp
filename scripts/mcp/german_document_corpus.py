#!/usr/bin/env python3
"""Create German synthetic raster-only PDFs and OCR-independent ground truth.

No model calls, external documents, production data or network access.
Run with the bundled PDF Python (Pillow, reportlab, pypdf).
"""
from pathlib import Path
import argparse, hashlib, io, json, random, textwrap
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader

FONTDIR = Path('/System/Library/Fonts/Supplemental')
FONTS = {'sans': FONTDIR/'Arial.ttf', 'bold': FONTDIR/'Arial Bold.ttf',
         'serif': FONTDIR/'Times New Roman.ttf', 'mono': FONTDIR/'Courier New.ttf'}


def page(title, fields, paragraphs, table=None, columns=False):
    return dict(title=title, fields=fields, paragraphs=paragraphs, table=table, columns=columns)


def table(headers, rows, widths=None):
    return dict(headers=headers, rows=rows, widths=widths)


def specification():
    return [
      dict(kind='Werkstattrechnung', issuer='Kühn & Söhne Fahrzeugtechnik GmbH', pages=[
        page('Rechnung für Wartung und Reparatur', [('Rechnungsnummer','WS-2026-08417'),('Rechnungsdatum','06.11.2026'),('Empfänger','Jörg Müller'),('Kennzeichen','PR-Ö 482'),('Fälliger Betrag','183,56 €')],
          ['Sehr geehrter Herr Müller, wir berechnen die vereinbarten Arbeiten an Ihrem Fahrzeug. Die Inspektion wurde am 04.11.2026 durchgeführt. Die Bremsanlage wurde geprüft und die Flüssigkeit vollständig erneuert. Alle eingebauten Teile entsprechen der dokumentierten Freigabe.',
           'Bitte überweisen Sie den Rechnungsbetrag bis zum 20.11.2026 unter Angabe der Rechnungsnummer. Ein bereits erteilter Kostenvoranschlag wird durch diese Rechnung abgeschlossen. Bei Rückfragen nennen Sie bitte zusätzlich das Kennzeichen.'],
          table(['Pos.','Leistung','Menge','Einzelpreis','Gesamt'],[['01','Inspektion gemäß Wartungsplan','2 Std.','45,00 €','90,00 €'],['02','Ölfilter für Prüfstandfahrzeug','1 Stück','18,75 €','18,75 €'],['03','Bremsflüssigkeit erneuern','1 Satz','45,50 €','45,50 €'],['','Nettobetrag','','','154,25 €'],['','Umsatzsteuer 19 %','','','29,31 €'],['','Bruttobetrag','','','183,56 €']],[.07,.48,.13,.16,.16])),
        page('Arbeitsnachweis und Gewährleistung', [('Auftragsnummer','AU-48392'),('Fahrgestellnummer','TESTWVWZZZ26K08417'),('Kilometerstand','84.219 km'),('Übergabedatum','05.11.2026'),('Ansprechpartnerin','Anke Groß')],
          ['Die ausgebauten Teile wurden dem Auftraggeber zur Einsicht bereitgehalten. Es wurden keine zusätzlichen Arbeiten außerhalb des bestätigten Umfangs ausgeführt. Eine spätere Hauptuntersuchung ist nicht Bestandteil dieses Auftrags.',
           'Die Hinweise zur Nachkontrolle betreffen ausschließlich den im Auftrag genannten Prüfumfang. Bitte prüfen Sie den Flüssigkeitsstand nach ungefähr zweihundert Kilometern erneut. Bei ungewöhnlichen Geräuschen wenden Sie sich an die Werkstatt. Dieser Nachweis ersetzt keine eigenständige Fahrzeugprüfung.'],
          table(['Prüfpunkt','Ergebnis','Ausgeführt durch'],[['Beleuchtung','ohne Befund','A. Groß'],['Reifendruck','angepasst auf 2,4 bar','M. Weiß'],['Probefahrt','12,8 km durchgeführt','A. Groß'],['Fehlerspeicher','keine neuen Einträge','M. Weiß']],[.32,.43,.25]))]),
      dict(kind='Versicherungspolice',issuer='Nordstern Muster-Versicherung AG',pages=[
        page('Versicherungsschein Hausrat', [('Versicherungsnummer','HR-71-608294'),('Versicherungsnehmerin','Özlem Schäfer'),('Versicherungsort','Große Mühlenstraße 18, 12345 Prüfstadt'),('Versicherungsbeginn','01.01.2027'),('Monatsbeitrag','28,63 €')],
          ['Versichert ist der private Hausrat der bezeichneten Wohnung. Die Wohnfläche beträgt 86 Quadratmeter. Versicherungsschutz besteht gegen die in der Leistungsübersicht genannten Gefahren. Der Vertrag gilt für den im Versicherungsschein ausdrücklich bezeichneten Versicherungsort.',
           'Der Beitrag wird monatlich zum dritten Werktag eingezogen. Eine frühere Beitragsangabe im Antrag ist durch die hier genannte Bestätigung ersetzt. Bitte prüfen Sie Anschrift und Leistungsumfang. Veränderungen der Nutzung sind dem Versicherer mitzuteilen.'],
          table(['Baustein','Versicherungssumme','Selbstbeteiligung'],[['Hausrat Grundschutz','86.000,00 €','150,00 €'],['Fahrraddiebstahl','4.300,00 €','0,00 €'],['Glasbruch','3.000,00 €','100,00 €'],['Elementarschäden','86.000,00 €','500,00 €']],[.46,.30,.24])),
        page('Leistungsübersicht und Ausschlüsse', [('Tarif','Komfort Plus 2027'),('Vertragsablauf','31.12.2027'),('Kündigungsfrist','3 Monate zum Ablauf'),('Fahrradschutz','auch außerhalb verschlossener Räume')],
          ['Der Versicherungsschutz umfasst Leitungswasser, Sturm, Hagel und die ausdrücklich eingeschlossenen Zusatzbausteine. Für Fahrräder gilt die vereinbarte Sicherungspflicht. Ein Zahlenschloss allein erfüllt diese Pflicht nicht. Schmuck ist innerhalb der ausgewiesenen Entschädigungsgrenzen versichert.',
           'Nicht versichert sind Schäden durch gewöhnlichen Verschleiß oder bewusst herbeigeführte Beschädigungen. Eine vorübergehende Abwesenheit von mehr als sechzig Tagen ist anzuzeigen. Diese Übersicht erläutert den Vertrag; die im Versicherungsschein bezeichneten Bedingungen bleiben maßgeblich.'],
          table(['Risiko','Einschluss','Grenze je Schaden'],[['Überspannung','ja','10.000,00 €'],['Grobe Fahrlässigkeit','ja','86.000,00 €'],['Bargeld im Schrank','begrenzt','1.500,00 €'],['Beruflich genutzte Geräte','begrenzt','5.000,00 €']],[.46,.22,.32])),
        page('Nachtrag zur Beitragsberechnung', [('Nachtragsnummer','NT-2026-1183'),('Wirksam ab','01.02.2027'),('Bisheriger Monatsbeitrag','28,63 €'),('Neuer Monatsbeitrag','30,14 €'),('Änderungsgrund','zusätzlicher Fahrradeinschluss')],
          ['Auf Ihren Wunsch wird die besondere Fahrradabsicherung erweitert. Die übrigen Vereinbarungen bleiben bestehen. Der neue Beitrag gilt erst ab dem bezeichneten Wirksamkeitsdatum. Für Januar wird weiterhin der bisherige Beitrag berechnet.',
           'Dieser Nachtrag gehört zum Versicherungsschein. Bitte bewahren Sie beide Dokumente gemeinsam auf. Die abweichenden Beträge stehen für unterschiedliche Zeiträume und sind kein Rechenfehler. Eine Änderung der Wohnfläche wurde nicht beantragt.'])]),
      dict(kind='Kontoauszug',issuer='Musterbank Prüfstadt eG',pages=[
        page('Kontoauszug November 2026', [('Auszugsnummer','11/2026-0048'),('Kontoinhaber','Björn Weiß'),('Kontokennung','TEST-KONTO-638510'),('Anfangssaldo','2.184,33 €'),('Endsaldo','2.569,81 €')],
          ['Die nachfolgenden Buchungen betreffen den Zeitraum vom 01.11.2026 bis zum 06.11.2026. Belastungen sind mit einem Minuszeichen ausgewiesen. Wertstellung und Buchungstag können voneinander abweichen. Alle Kontokennungen dieses Belegs sind künstliche Testwerte.',
           'Bitte prüfen Sie die Umsätze und bewahren Sie diesen Auszug zusammen mit den zugehörigen Zahlungsbelegen auf. Die Darstellung einer Zahlung bestätigt nicht den Inhalt eines zugrunde liegenden Vertrags.'],
          table(['Buchung','Wertstellung','Verwendungszweck','Betrag'],[['02.11.2026','02.11.2026','Gehalt Musterbetrieb','+2.684,18 €'],['03.11.2026','03.11.2026','Miete Große Straße','-1.180,00 €'],['03.11.2026','04.11.2026','Stadtwerke Abschlag','-126,00 €'],['05.11.2026','05.11.2026','Überweisung an J. Kühn','-992,70 €'],['06.11.2026','06.11.2026','Zinsgutschrift','+0,00 €']],[.18,.18,.43,.21])),
        page('Entgeltübersicht und Kontoinformation', [('Abrechnungsmonat','November 2026'),('Kontoführungsentgelt','6,90 €'),('Erstatteter Betrag','6,90 €'),('Reklamationskennzeichen','RK-269714')],
          ['Das zunächst vorgemerkte Kontoführungsentgelt wurde aufgrund einer Aktionsvereinbarung vollständig erstattet. Die beiden gleich hohen Beträge dürfen deshalb nicht als zwei Belastungen zusammengefasst werden. Diese Entgeltübersicht verändert den auf Seite eins genannten Endsaldo nicht.',
           'Für Nachfragen nutzen Sie bitte das Reklamationskennzeichen. Antworten auf allgemeine Anfragen sind keine Bestätigung einzelner Zahlungsaufträge. Die angebotenen Kommunikationswege setzen die zuvor vereinbarte Identitätsprüfung voraus.'],columns=True)]),
      dict(kind='Mietvertrag',issuer='Wohnraum Musterhof Verwaltung GmbH',pages=[
        page('Wohnraummietvertrag', [('Vertragsnummer','MV-2026-0318'),('Vermieterin','Wohnraum Musterhof Verwaltung GmbH'),('Mieter','René König'),('Mietobjekt','Ahornweg 7, Wohnung 3 links'),('Mietbeginn','01.12.2026')],
          ['Vermietet werden drei Zimmer, Küche, Bad und ein zugeordneter Kellerraum. Die angegebene Wohnfläche von 74,5 Quadratmetern dient der Beschreibung des Objekts. Die Wohnung wird ausschließlich zu Wohnzwecken überlassen. Eine gewerbliche Nutzung bedarf einer gesonderten Vereinbarung.',
           'Zum Übergabetermin wird ein gemeinsames Protokoll erstellt. Darin werden Zählerstände, Schlüsselanzahl und erkennbare Mängel dokumentiert. Das Protokoll ist eine Anlage dieses Vertrags und wird von beiden Parteien aufbewahrt.'],
          table(['Monatliche Zahlung','Betrag','Fälligkeit'],[['Nettokaltmiete','815,00 €','3. Werktag'],['Betriebskostenvorauszahlung','142,00 €','3. Werktag'],['Heizkostenvorauszahlung','98,00 €','3. Werktag'],['Gesamtzahlung','1.055,00 €','3. Werktag']],[.52,.23,.25])),
        page('Kaution, Anpassung und Nebenabreden', [('Mietsicherheit','2.445,00 €'),('Erste Kautionsrate','815,00 €'),('Staffelbeginn','01.12.2027'),('Neue Nettokaltmiete','839,00 €'),('Vertragsart','unbefristeter Mietvertrag')],
          ['Die Mietsicherheit kann in drei gleichen Teilbeträgen geleistet werden. Die erste Rate ist zu Beginn des Mietverhältnisses fällig. Die vereinbarte Staffel betrifft ausschließlich die Nettokaltmiete. Vorauszahlungen für Betriebs- und Heizkosten werden dadurch nicht automatisch geändert.',
           'Die Parteien haben keine zusätzliche mündliche Vereinbarung über eine kürzere Vertragslaufzeit getroffen. Das Recht zur Kündigung richtet sich nach den vereinbarten Vertragsbedingungen. Eine frühere unverbindliche Reservierung ist mit Unterzeichnung dieses Vertrags erledigt.']),
        page('Übergabeprotokoll als Vertragsanlage', [('Übergabedatum','30.11.2026'),('Stromzähler','Z-8846102'),('Stromzählerstand','18.492 kWh'),('Übergebene Schlüssel','6 Stück'),('Festgestellter Mangel','Kratzer an der Küchentür')],
          ['Die Wohnung wurde gemeinsam besichtigt. Der bezeichnete Kratzer ist bei Einzug bereits vorhanden und wird im Protokoll festgehalten. Weitere sichtbare Schäden wurden nicht festgestellt. Die Erfassung eines Mangels stellt keine Aussage über seine technische Ursache dar.',
           'Die Hausordnung wurde ausgehändigt. Der Mieter bestätigt den Empfang der aufgeführten Schlüssel. Ein fehlender Briefkastenschlüssel soll innerhalb von sieben Tagen nachgereicht werden. Die Anlage umfasst diese eine Protokollseite.'],
          table(['Schlüsselart','Anzahl','Bemerkung'],[['Haustür','2','beide übergeben'],['Wohnung','3','beide Schließzylinder'],['Keller','1','gekennzeichnet'],['Briefkasten','0','Nachlieferung vereinbart']],[.35,.15,.50]))]),
      dict(kind='Nebenkostenabrechnung',issuer='Hausverwaltung Berg & Brüder OHG',pages=[
        page('Betriebskostenabrechnung 2025', [('Abrechnungszeitraum','01.01.2025 bis 31.12.2025'),('Ausstellungsdatum','08.10.2026'),('Nutzerin','Gülcan Özdemir'),('Wohnungskennung','WE-12-045'),('Nachzahlung','218,47 €')],
          ['Die Abrechnung bezieht sich auf das abgeschlossene Kalenderjahr 2025. Das Ausstellungsdatum liegt im Folgejahr. Die Wohnung wurde im gesamten Abrechnungszeitraum genutzt. Ihr Anteil wird nach den in der Tabelle benannten Schlüsseln ermittelt.',
           'Die ausgewiesenen Vorauszahlungen wurden vollständig berücksichtigt. Belege können nach Terminvereinbarung eingesehen werden. Eine Anpassung künftiger Vorauszahlungen wird auf der letzten Seite gesondert erläutert.'],
          table(['Kostenart','Gesamtkosten','Ihr Anteil'],[['Wasserversorgung','3.849,26 €','284,83 €'],['Müllabfuhr','2.118,40 €','156,76 €'],['Gebäudereinigung','4.726,15 €','349,73 €'],['Versicherung Gebäude','3.904,80 €','288,95 €'],['Hausbeleuchtung','862,40 €','63,81 €'],['Grundsteuer','2.702,70 €','200,00 €']],[.48,.26,.26])),
        page('Heizung und Warmwasser', [('Heizungszähler','HK-507381'),('Ablesedatum','31.12.2025'),('Verbrauchseinheiten','4.382,6 Einheiten'),('Heizkostenanteil','892,39 €'),('Warmwasseranteil','238,00 €')],
          ['Die Heizkosten werden nach einem Grundkostenanteil und einem Verbrauchskostenanteil verteilt. Für Warmwasser wird die gemessene Entnahmemenge zugrunde gelegt. Die hier genannten Verbrauchseinheiten sind keine Kilowattstunden und dürfen nicht unmittelbar in einen Stromverbrauch umgerechnet werden.',
           'Die Ablesewerte wurden elektronisch übernommen. Ein Gerätewechsel im Oktober ist in der gesonderten Aufstellung berücksichtigt. Der alte und der neue Zählerstand sind verschiedenen Geräten zugeordnet.'],
          table(['Gerät','Alter Stand','Neuer Stand','Differenz'],[['Heizkörper Küche','512,8','1.483,9','971,1'],['Heizkörper Wohnraum','834,2','2.610,4','1.776,2'],['Heizkörper Schlafzimmer','201,7','1.837,0','1.635,3'],['Warmwasserzähler','86,240 m³','117,960 m³','31,720 m³']],[.40,.20,.20,.20])),
        page('Abrechnungsergebnis und Vorauszahlung', [('Kosten gesamt','2.474,47 €'),('Vorauszahlungen gesamt','2.256,00 €'),('Zahlbar bis','15.11.2026'),('Neue Vorauszahlung','206,00 € monatlich'),('Neue Vorauszahlung ab','01.12.2026')],
          ['Aus den abgerechneten Kosten und den bereits geleisteten Vorauszahlungen ergibt sich die auf Seite eins genannte Nachzahlung. Die erhöhte Vorauszahlung beginnt erst im Dezember. Die Nachzahlung wird nicht zusätzlich auf die monatliche Vorauszahlung aufgeschlagen.',
           'Bitte geben Sie bei Überweisungen die Wohnungskennung an. Einwendungen zu einzelnen Positionen können mit Bezeichnung der Kostenart und des betreffenden Zeitraums eingereicht werden. Eine fehlende Anlage ist der Verwaltung zeitnah mitzuteilen.'])]),
      dict(kind='Stromabrechnung',issuer='Stadtwerke Grünau Testversorgung GmbH',pages=[
        page('Jahresabrechnung Strom', [('Kundennummer','K-4901738'),('Rechnungsnummer','ST-2026-66291'),('Abrechnungszeitraum','01.10.2025 bis 30.09.2026'),('Verbrauch','2.684 kWh'),('Guthaben','74,82 €')],
          ['Die Jahresabrechnung beruht auf den übermittelten Zählerständen. Der Verbrauch verteilt sich auf zwei Preisabschnitte. Das Guthaben wird mit der nächsten fälligen Zahlung verrechnet, sofern keine abweichende Auszahlung vereinbart wurde.',
           'Der auf der Folgeseite genannte Abschlag gilt für den neuen Zeitraum. Er ist weder der Rechnungsbetrag noch der durchschnittliche monatliche Verbrauch. Bitte halten Sie bei Nachfragen die Kundennummer bereit.'],
          table(['Preisabschnitt','Menge','Arbeitspreis','Kosten'],[['01.10.2025 bis 31.03.2026','1.482 kWh','31,20 ct/kWh','462,38 €'],['01.04.2026 bis 30.09.2026','1.202 kWh','29,80 ct/kWh','358,20 €'],['Grundpreis für zwölf Monate','12 Monate','12,80 €/Monat','153,60 €'],['Gezahlte Abschläge','','','1.049,00 €']],[.43,.19,.20,.18])),
        page('Zählerdaten und neuer Abschlagsplan', [('Zählernummer','1TEST00389147'),('Anfangsstand','24.183 kWh'),('Endstand','26.867 kWh'),('Neuer Abschlag','83,00 €'),('Erster Abschlag','05.11.2026')],
          ['Der neue Abschlag berücksichtigt den bisherigen Jahresverbrauch und die bekannten Preise des Folgezeitraums. Eine tatsächliche Verbrauchsänderung kann zu einer späteren Anpassung führen. Die Zählernummer bezeichnet das Messgerät und ist nicht mit der Kundennummer identisch.',
           'Die Ablesung erfolgte am letzten Tag des Abrechnungszeitraums. Der dokumentierte Stand wurde plausibilisiert. Eine Schätzung war nicht erforderlich. Bitte melden Sie einen bevorstehenden Umzug rechtzeitig mit Datum und neuem Zählerstand.'])]),
      dict(kind='Lohnabrechnung',issuer='Prüfwerk Maschinenbau GmbH',pages=[
        page('Entgeltabrechnung Oktober 2026', [('Personalnummer','P-004791'),('Arbeitnehmerin','Sörenja Großmann'),('Abrechnungsmonat','Oktober 2026'),('Gesamtbrutto','4.186,40 €'),('Nettoauszahlung','2.684,18 €')],
          ['Diese Abrechnung enthält laufende Bezüge sowie eine einmalige Schichtzulage. Die Werte dienen ausschließlich dem synthetischen OCR-Test. Die hier verwendeten Abzüge stellen keine Berechnung für eine tatsächliche Person dar.',
           'Bitte unterscheiden Sie zwischen Gesamtbrutto, steuerpflichtigem Brutto und Auszahlung. Die Arbeitgeberanteile gehören nicht zu den Abzügen vom Nettobetrag. Rückfragen richten Sie mit der Personalnummer an die Entgeltabrechnung.'],
          table(['Bezug oder Abzug','Kennung','Betrag'],[['Grundentgelt','L-100','3.950,00 €'],['Schichtzulage','L-215','236,40 €'],['Lohnsteuer','A-410','612,74 €'],['Sozialversicherung','A-520','889,48 €'],['Auszahlung','N-900','2.684,18 €']],[.53,.20,.27])),
        page('Arbeitszeitkonto und Bescheinigung', [('Bescheinigungsnummer','BZ-2026-1928'),('Eintrittsdatum','15.03.2021'),('Beschäftigungsumfang','38,5 Stunden pro Woche'),('Resturlaub','8,5 Tage'),('Zeitguthaben','12,75 Stunden')],
          ['Das Arbeitszeitkonto wird unabhängig von der Entgeltabrechnung geführt. Nicht jede Zeitbuchung löst eine zusätzliche Auszahlung aus. Der ausgewiesene Resturlaub bezieht sich auf den Stand am Ende des Abrechnungsmonats.',
           'Die Bescheinigung wurde auf Wunsch der Arbeitnehmerin erstellt. Sie bestätigt das Beschäftigungsverhältnis zu den angegebenen Bedingungen. Eine Zusage über künftige Sonderzahlungen ist damit nicht verbunden.'],columns=True)]),
      dict(kind='Steuerbescheid',issuer='Finanzamt Musterstadt - Teststelle',pages=[
        page('Bescheid über Einkommensteuer 2025', [('Steuernummer','TEST-19/482/73016'),('Bescheiddatum','21.09.2026'),('Veranlagungsjahr','2025'),('Steuerpflichtiger','André Jäger'),('Erstattungsbetrag','1.284,37 €')],
          ['Die Festsetzung betrifft das Veranlagungsjahr 2025. Das Datum des Bescheids liegt im folgenden Kalenderjahr. Die Berechnungsgrundlagen und bereits berücksichtigten Zahlungen sind auf den nachfolgenden Seiten erläutert. Dieser Beleg ist ausschließlich ein künstliches Testdokument.',
           'Die Erstattung wird nach der dokumentierten Zahlungsverrechnung ausgeführt. Ein früher genannter Vorauszahlungsbetrag ist kein zusätzlicher Erstattungsbetrag. Bitte prüfen Sie die Zuordnung der Zahlungen zu den jeweiligen Steuerarten.'],
          table(['Steuerart','Festgesetzt','Angerechnet','Saldo'],[['Einkommensteuer','7.412,00 €','8.696,37 €','-1.284,37 €'],['Solidaritätszuschlag','0,00 €','0,00 €','0,00 €'],['Kirchensteuer','0,00 €','0,00 €','0,00 €']],[.34,.22,.22,.22])),
        page('Berechnungsgrundlagen', [('Bruttoarbeitslohn','52.840,00 €'),('Werbungskosten','2.146,00 €'),('Sonderausgaben','5.372,00 €'),('Zu versteuerndes Einkommen','45.322,00 €')],
          ['Die Übersicht ordnet die erklärten Beträge den verwendeten Berechnungsschritten zu. Die Zahlen sind didaktische Testwerte. Es wird keine Auskunft über einen tatsächlichen Steuerfall erteilt. Die Darstellung darf nicht als allgemeine steuerliche Berechnungsregel verwendet werden.',
           'Belege zu Fahrtkosten und Fortbildung wurden der Erklärung zugeordnet. Aufwendungen ohne ausreichenden Bezug wurden nicht zusätzlich berücksichtigt. Eine doppelte Zuordnung desselben Belegs ist in dieser Zusammenstellung nicht vorgesehen.'],
          table(['Aufwandsart','Erklärt','Berücksichtigt'],[['Fahrtkosten','1.486,00 €','1.486,00 €'],['Fortbildung','420,00 €','420,00 €'],['Arbeitsmittel','240,00 €','240,00 €'],['Spenden','180,00 €','180,00 €']],[.46,.27,.27])),
        page('Erläuterungen und Verfahrenshinweis', [('Aktenzeichen','E-2025-781460'),('Bekanntgabehinweis','Versand am 22.09.2026'),('Zahlungsverrechnung','abgeschlossen'),('Anlagen','2 Berechnungsseiten')],
          ['Die Erläuterungen beziehen sich auf die für diesen Testfall getroffenen Annahmen. Eine Änderung künftiger Vorauszahlungen ist in diesem Bescheid nicht enthalten. Die auf Seite eins dargestellte Erstattung bleibt das abschließende Zahlungsergebnis.',
           'Für Rückfragen ist das Aktenzeichen maßgeblich. Im Schriftverkehr sollen die betroffene Position und das Veranlagungsjahr genannt werden. Dieser künstliche Verfahrenshinweis enthält bewusst keine rechtsverbindliche Fristberechnung.'])]),
      dict(kind='Arztbefund',issuer='Praxisgemeinschaft Dr. Prüf & Kolleginnen',pages=[
        page('Befundbericht zur Verlaufskontrolle', [('Befundnummer','BF-2026-38172'),('Patientin','Märta Schröder'),('Geburtsdatum','14.02.1984'),('Untersuchungsdatum','03.11.2026'),('Berichtsdatum','05.11.2026')],
          ['Die Patientin stellte sich zur vereinbarten Verlaufskontrolle vor. Im Gespräch wurden Beschwerden bei längerer Belastung angegeben. Der Bericht enthält künstliche Angaben für einen Dokumententest. Er stellt weder eine Diagnose noch eine medizinische Handlungsempfehlung für eine tatsächliche Person dar.',
           'Die Untersuchung und die Laborentnahme fanden am selben Tag statt. Die Befundfreigabe erfolgte nach Vorliegen aller Messwerte. Die auf der Folgeseite aufgeführten Referenzbereiche dienen ausschließlich der Darstellung einer typischen Tabelle.'],
          table(['Untersuchung','Ergebnis','Einheit'],[['Blutdruck systolisch','128','mmHg'],['Blutdruck diastolisch','82','mmHg'],['Puls in Ruhe','71','pro Minute'],['Körpertemperatur','36,7','°C']],[.56,.20,.24])),
        page('Laborwerte und Befundfreigabe', [('Laborauftrag','LAB-672905'),('Probenentnahme','03.11.2026 um 08:42 Uhr'),('Freigabe durch','Dr. Hannah Weiß'),('Kontrolltermin','17.11.2026 um 09:15 Uhr')],
          ['Die Probe wurde vor dem Versand eindeutig dem Laborauftrag zugeordnet. Es handelt sich um einen künstlichen Laborbefund ohne Aussage zu einem wirklichen Gesundheitszustand. Ein markierter Wert darf nicht isoliert als vollständige medizinische Beurteilung verstanden werden.',
           'Der Folgetermin dient im Testdokument der Besprechung der Ergebnisse. Der Termin ist kein Ausstellungsdatum und kein Geburtsdatum. Diese Rollen sollen bei einer späteren strukturierten Extraktion getrennt erhalten bleiben.'],
          table(['Parameter','Messwert','Einheit','Referenzbereich'],[['Hämoglobin','13,8','g/dl','12,0 bis 16,0'],['Leukozyten','6,42','10³/µl','4,00 bis 10,00'],['Glukose nüchtern','94','mg/dl','70 bis 99'],['Kreatinin','0,81','mg/dl','0,50 bis 1,10'],['CRP','2,4','mg/l','unter 5,0']],[.36,.18,.18,.28]))]),
      dict(kind='Schulzeugnis',issuer='Gesamtschule Am Mühlenberg - Testschule',pages=[
        page('Halbjahreszeugnis 2026/2027', [('Schülerin','Léonie Küster'),('Klasse','8b'),('Schulhalbjahr','1. Halbjahr 2026/2027'),('Zeugnisdatum','29.01.2027'),('Versäumte Stunden','12 Stunden, davon 0 unentschuldigt')],
          ['Léonie beteiligt sich regelmäßig am Unterricht und bearbeitet Aufgaben überwiegend sorgfältig. In Gruppenarbeiten übernimmt sie vereinbarte Aufgaben zuverlässig. Der folgende Leistungsstand ist vollständig erfunden und dient ausschließlich der Prüfung deutscher Dokumentverarbeitung.',
           'Die Bezeichnungen der Fächer, ihre Bewertungen und ergänzende Bemerkungen bilden getrennte Tabellenzellen. Die Reihenfolge der Noten muss dem jeweiligen Fach erhalten bleiben. Eine bloße Sammlung aller Zahlen reicht für eine Zeugnisinterpretation nicht aus.'],
          table(['Fach','Bewertung','Bemerkung'],[['Deutsch','gut','mündlich sehr aktiv'],['Mathematik','befriedigend','sicher im Grundwissen'],['Englisch','gut','flüssiges Lesen'],['Französisch','ausreichend','Übung empfohlen'],['Naturwissenschaften','gut','sorgfältige Versuche'],['Sport','sehr gut','ausdauernde Mitarbeit']],[.38,.25,.37])),
        page('Lernentwicklung und ergänzende Angaben', [('Zeugniskennung','ZG-27-00842'),('Klassenleitung','Frau Anne Krüger'),('Beratungstermin','10.02.2027 um 16:30 Uhr'),('Förderschwerpunkt','schriftliche Ausdrucksfähigkeit')],
          ['Für das kommende Halbjahr wurden kurze wöchentliche Schreibübungen vereinbart. Dabei sollen Satzbau, Begründung und die Überarbeitung eigener Texte geübt werden. Die Aufgaben werden gemeinsam mit der Klassenleitung ausgewählt und in angemessenen Abständen besprochen.',
           'Die vereinbarte Förderung ist keine zusätzliche Fachnote. Die Bestätigung des Erhalts durch die Erziehungsberechtigten dokumentiert ausschließlich die Übergabe des Zeugnisses. Der Beratungstermin bleibt eine gesonderte Terminangabe.'],columns=True)]),
      dict(kind='Telekommunikationsrechnung',issuer='Funknetz Musterkommunikation GmbH',pages=[
        page('Mobilfunkrechnung Oktober 2026', [('Rechnungsnummer','MF-2026-570219'),('Kundennummer','KD-841670'),('Vertragsinhaber','Günter Fröhlich'),('Leistungszeitraum','01.10.2026 bis 31.10.2026'),('Rechnungsbetrag','42,73 €')],
          ['Der Rechnungsbetrag umfasst den monatlichen Tarif sowie die ausgewiesenen zusätzlichen Verbindungen. Verbindungen innerhalb der enthaltenen Freimenge werden nicht erneut berechnet. Die Testnummern dieses Belegs sind nicht für eine Kontaktaufnahme vorgesehen.',
           'Die Einziehung erfolgt am angegebenen Zahlungstag. Der Einzelverbindungsnachweis enthält nur abrechnungsrelevante Testeinträge. Die Dauer eines Gesprächs darf nicht mit einem Geldbetrag verwechselt werden.'],
          table(['Position','Zeitraum oder Menge','Netto','Brutto'],[['Tarif Alles Muster','Oktober 2026','29,40 €','34,99 €'],['Auslandsverbindungen','18 Minuten','4,61 €','5,49 €'],['Serviceverbindung','1 Verbindung','1,89 €','2,25 €']],[.40,.28,.16,.16])),
        page('Einzelverbindungsnachweis', [('Anschlusskennung','TEST-MOBIL-2617'),('Zahlungstag','12.11.2026'),('Nachweisnummer','EVN-570219-02'),('Abrechnungswährung','EUR')],
          ['Der Nachweis zeigt beispielhafte Zeitangaben und Gebühren. Für diesen synthetischen Test werden keine tatsächlich anwählbaren Zielrufnummern verwendet. Die Daten dürfen deshalb nicht als Telefonprotokoll einer wirklichen Person interpretiert werden.',
           'Bitte beachten Sie die Zuordnung zwischen Datum, Uhrzeit, Dauer und Betrag. Ein Vergleich der OCR-Lösungen muss auch diese Tabellenstruktur prüfen. Die Gesamtrechnung steht auf der vorherigen physischen Seite.'],
          table(['Datum','Uhrzeit','Zielkennung','Dauer','Betrag'],[['09.10.2026','14:08','TEST-ZIEL-A','06:32 min','1,83 €'],['17.10.2026','09:41','TEST-ZIEL-B','11:28 min','3,66 €'],['25.10.2026','18:53','TEST-SERVICE-C','02:14 min','2,25 €']],[.19,.16,.30,.18,.17]))]),
      dict(kind='Gebührenbescheid',issuer='Stadt Prüfhausen - Bürgerdienste',pages=[
        page('Gebührenbescheid zur Anmeldung', [('Aktenzeichen','BD-2026-083719'),('Adressatin','Dörte Bär'),('Antragsdatum','28.10.2026'),('Bescheiddatum','04.11.2026'),('Gesamtgebühr','37,50 €')],
          ['Für den bezeichneten künstlichen Verwaltungsvorgang werden die aufgeführten Gebühren erhoben. Die Einzelpositionen sind in der Tabelle getrennt dargestellt. Dieser Testbescheid ist ungültig und enthält keine Zahlungsaufforderung an eine tatsächliche Person.',
           'Die Zahlung soll dem Aktenzeichen zugeordnet werden. Ein anderer Verwendungszweck kann eine manuelle Klärung erforderlich machen. Der Bescheid und seine Anlage gehören zu demselben Vorgang, stellen aber zwei physische Seiten dar.'],
          table(['Leistung','Anzahl','Gebühr je Einheit','Summe'],[['Bearbeitung der Testanmeldung','1','24,00 €','24,00 €'],['Beglaubigte Testabschrift','2','5,50 €','11,00 €'],['Portopauschale','1','2,50 €','2,50 €']],[.49,.11,.22,.18])),
        page('Anlage: Zahlungszuordnung und Rückfragen', [('Kassenzeichen','KZ-91-738204'),('Zahlbar bis','25.11.2026'),('Sachbearbeiterin','Frau Helga Süß'),('Zimmer','B 2.14'),('Sprechzeit','Dienstag 09:00 bis 12:00 Uhr')],
          ['Bitte verwenden Sie für Rückfragen das Aktenzeichen und für die Zahlungszuordnung das Kassenzeichen. Die beiden Kennungen erfüllen unterschiedliche Aufgaben und dürfen nicht gegeneinander ausgetauscht werden. Die Sachbearbeiterin ist keine Empfängerin einer Überweisung.',
           'Ein persönlicher Besuch ist nur während der bezeichneten Sprechzeit oder nach Terminvereinbarung vorgesehen. Das Datum der Fälligkeit betrifft ausschließlich diesen Testvorgang. Diese Anlage enthält keinen rechtsverbindlichen Hinweis zu einem echten Verwaltungsverfahren.'])])
    ]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(root):
    root.mkdir(parents=True,exist_ok=True);pdfdir=root/'pdf';pngdir=root/'pages'
    pdfdir.mkdir();pngdir.mkdir();rng=random.Random(20261108)
    manifest=dict(schemaVersion=2,seed=20261108,synthetic=True,dpi=200,
      scope='12 German document types; source-defined truth frozen before OCR; not a statistical sample of customer archives',
      normalization='NFC, HTML entities, remove presentation Markdown/HTML, collapse whitespace; preserve case, accents, punctuation and numeric formatting',
      fonts={n:dict(path=str(p),sha256=digest(p)) for n,p in FONTS.items()},documents=[],pages=[])
    W,H=1654,2339;scale=W/595.28
    for di,doc in enumerate(specification(),1):
        docid=f'doc-{di:03d}';pdfpath=pdfdir/(docid+'.pdf');c=canvas.Canvas(str(pdfpath),pagesize=(595.28,841.89),invariant=1)
        record=dict(id=docid,kind=doc['kind'],issuer=doc['issuer'],pdf='pdf/'+pdfpath.name,pageIDs=[])
        for pi,p in enumerate(doc['pages'],1):
            pageid=docid+f'-p{pi:02d}';record['pageIDs'].append(pageid)
            im=Image.new('RGB',(W,H),'white');draw=ImageDraw.Draw(im);runs=[];fields=[];tables=[];y=48
            quality=['clean','skew','faded'][(di+pi-2)%3]
            family='serif' if di in [4,8,9] else 'mono' if di==3 else 'sans'
            def font(size,bold=False):return ImageFont.truetype(str(FONTS['bold' if bold else family]),round(size*scale))
            def text(s,x=46,ypos=None,size=10.5,bold=False,maxwidth=503,store=True):
                nonlocal y
                baseline=y if ypos is None else ypos;f=font(size,bold);line='';lines=[]
                for word in s.split():
                    proposal=(line+' '+word).strip()
                    if draw.textlength(proposal,font=f)>maxwidth*scale and line:lines.append(line);line=word
                    else:line=proposal
                lines.append(line)
                for li,line in enumerate(lines):
                    draw.text((x*scale,(baseline+li*(size*1.45))*scale),line,fill=(20,25,31),font=f)
                if store:runs.append(s)
                bottom=baseline+len(lines)*size*1.45
                if ypos is None:y=bottom
                return bottom
            text(doc['issuer'],size=15,bold=True);y+=11
            text(p['title'],size=19,bold=True);y+=14
            # Deliberate, domain-dependent placement; fields are role-labelled, not filename-derived.
            if di in [3,7,10]:
                starts=[];rowbottom=y
                for fi,(label,value) in enumerate(p['fields']):
                    if fi%2==0:starts.append(y);rowbottom=y
                    yy=starts[-1];x=46 if fi%2==0 else 315
                    bottom=text(label+': '+value,x=x,ypos=yy,size=9.8,maxwidth=234)
                    rowbottom=max(rowbottom,bottom)
                    fields.append(dict(id=pageid+f'-f{fi+1:02d}',label=label,value=value,text=label+': '+value))
                    if fi%2 or fi==len(p['fields'])-1:y=rowbottom+9
            else:
                for fi,(label,value) in enumerate(p['fields']):
                    text(label+': '+value,size=10.5);y+=4
                    fields.append(dict(id=pageid+f'-f{fi+1:02d}',label=label,value=value,text=label+': '+value))
            y+=15
            if p['columns']:
                start=y;end=[]
                for ci,s in enumerate(p['paragraphs']):end.append(text(s,x=46+ci*263,ypos=start,size=10.5,maxwidth=240))
                y=max(end)+15
            else:
                text(p['paragraphs'][0],size=10.5);y+=15
            if p['table']:
                t=p['table'];cols=t['headers'];widths=t['widths'] or [1/len(cols)]*len(cols);assert abs(sum(widths)-1)<.001
                start=y;cells=[];f=font(9.3)
                for ri,row in enumerate([cols]+t['rows']):
                    assert len(row)==len(cols)
                    heights=[];wrapped=[]
                    for ci,s in enumerate(row):
                        limit=503*widths[ci]-10;line='';lines=[]
                        for word in s.split():
                            proposal=(line+' '+word).strip()
                            if draw.textlength(proposal,font=f)>limit*scale and line:lines.append(line);line=word
                            else:line=proposal
                        lines.append(line);wrapped.append(lines);heights.append(len(lines)*13+10)
                    height=max(heights);x=46
                    for ci,s in enumerate(row):
                        w=503*widths[ci];box=[x*scale,y*scale,(x+w)*scale,(y+height)*scale]
                        draw.rectangle(box,fill=(230,235,239) if ri==0 else (255,255,255),outline=(122,130,136),width=1)
                        for li,line in enumerate(wrapped[ci]):draw.text(((x+5)*scale,(y+5+li*13)*scale),line,font=font(9.3,ri==0),fill=(18,22,28))
                        cells.append(dict(row=ri,col=ci,text=s,bbox=[v for v in [x/595.28,y/841.89,w/595.28,height/841.89]]));x+=w
                        if s:runs.append(s)
                    y+=height
                tables.append(dict(id=pageid+'-table',rows=len(t['rows'])+1,cols=len(cols),cells=cells,
                                   bbox=[46/595.28,start/841.89,503/595.28,(y-start)/841.89]));y+=18
            if not p['columns']:text(p['paragraphs'][1],size=10.5);y+=12
            assert y<754,(pageid,y)
            footer=f'Synthetischer Testbeleg - keine echten Vorgänge | Seite {pi} von {len(doc["pages"])}'
            text(footer,ypos=794,size=8.2)
            # Deterministic scan degradation; no OCR-dependent changes.
            angle=0
            if quality=='skew':angle=(-.7 if (di+pi)%2 else .8);im=im.rotate(angle,resample=Image.Resampling.BICUBIC,fillcolor='white')
            if quality=='faded':
                im=im.convert('L').point([round(90+.64*v) for v in range(256)]).filter(ImageFilter.GaussianBlur(.35)).convert('RGB')
                # Mild uneven exposure; all reference content remains present.
                shade=Image.new('L',(W,H));shade.putdata([int(12*x/W) for yy in range(H) for x in range(W)])
                from PIL import ImageChops
                im=ImageChops.subtract(im,Image.merge('RGB',(shade,shade,shade)))
            file=pngdir/(pageid+'.png');im.save(file,optimize=True)
            c.drawImage(ImageReader(im),0,0,width=595.28,height=841.89,mask=None);c.showPage()
            manifest['pages'].append(dict(id=pageid,documentID=docid,physicalPage=pi,kind=doc['kind'],image='pages/'+file.name,
                sha256=digest(file),pixelSHA256=hashlib.sha256(im.tobytes()).hexdigest(),size=[W,H],blank=False,
                scan=dict(quality=quality,rotationDegrees=angle),text='\n'.join(runs),fields=fields,tables=tables))
        c.save();record['sha256']=digest(pdfpath);manifest['documents'].append(record)
    for i in range(3):
        docid=f'control-{i+1:02d}';pid=docid+'-p01';im=Image.new('RGB',(W,H),(255,255,255))
        if i:
            import numpy as np
            pixels=np.random.default_rng(20261108+i).integers(247,256,size=(H,W),dtype=np.uint8)
            im=Image.fromarray(pixels).convert('RGB')
        path=pngdir/(pid+'.png');im.save(path,optimize=True);pdf=pdfdir/(docid+'.pdf');c=canvas.Canvas(str(pdf),pagesize=(595.28,841.89),invariant=1);c.drawImage(ImageReader(im),0,0,width=595.28,height=841.89);c.showPage();c.save()
        manifest['documents'].append(dict(id=docid,kind='Leerbildkontrolle',issuer=None,pdf='pdf/'+pdf.name,sha256=digest(pdf),pageIDs=[pid]))
        manifest['pages'].append(dict(id=pid,documentID=docid,physicalPage=1,kind='Leerbildkontrolle',image='pages/'+path.name,sha256=digest(path),pixelSHA256=hashlib.sha256(im.tobytes()).hexdigest(),size=[W,H],blank=True,scan=dict(quality='blank-noise-'+str(i)),text='',fields=[],tables=[]))
    for d in manifest['documents']:
        pdf=PdfReader(root/d['pdf']);assert len(pdf.pages)==len(d['pageIDs'])
        for pageid,pdfpage in zip(d['pageIDs'],pdf.pages):
            assert not (pdfpage.extract_text() or '').strip(),'A scan must not have an embedded text layer'
            images=list(pdfpage.images);assert len(images)==1
            pixels=images[0].image.convert('RGB').tobytes();truth=next(p for p in manifest['pages'] if p['id']==pageid)
            assert hashlib.sha256(pixels).hexdigest()==truth['pixelSHA256'],'PDF pixels differ from PNG input'
    # Randomized execution order is fixed before any model sees a document.
    order=[d['id'] for d in manifest['documents']];rng.shuffle(order);manifest['executionOrder']=order
    manifest['generatorSHA256']=digest(Path(__file__))
    manifest['statistics']=dict(documents=len(manifest['documents']),documentTypes=len(set(d['kind'] for d in manifest['documents'] if d['issuer'])),
      pages=len(manifest['pages']),blankPages=sum(p['blank'] for p in manifest['pages']),
      criticalFields=sum(len(p['fields']) for p in manifest['pages']),
      distinctCriticalTexts=len({f['text'] for p in manifest['pages'] for f in p['fields']}),
      tables=sum(len(p['tables']) for p in manifest['pages']),tableCells=sum(len(t['cells']) for p in manifest['pages'] for t in p['tables']),
      sourceCharacters=sum(len(p['text']) for p in manifest['pages']))
    (root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    (root/'requests.json').write_text(json.dumps([dict(id=d['id'],pdf=d['pdf'],sha256=d['sha256'],pages=[dict(id=p['id'],image=p['image'],sha256=p['sha256']) for pid in d['pageIDs'] for p in manifest['pages'] if p['id']==pid]) for did in order for d in manifest['documents'] if d['id']==did],indent=2))
    print(json.dumps(manifest['statistics'],indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    build(parser.parse_args().output)
