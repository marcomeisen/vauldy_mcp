import CoreGraphics
import Foundation
import Testing
import VauldyDocumentIntelligence
@testable import VauldyCore

@Suite("Titles from the opening page")
struct OpeningPageTitleTests {
    @Test func printedOfferUsesItsReferenceAreaAndCorroboratedIssuer() {
        let shared = [
            line("REMO", 0.95),
            line("✦", 0.94, x: 0.70),
            line("GmbH", 0.92),
            line("Die angefragten Arbeiten zu o.g. BV infolge eines Regen-Wasserschadens bieten wir", 0.55),
            line("REMO GmbH", 0.09),
        ]
        let terrace = resolve(shared + [line("Angebot Nr. A059-21-PR", 0.62),
                                        line("Betroffene Bereiche = Terrasse", 0.50)])
        #expect(terrace.value == "Angebot Nr. A059-21-PR – Terrasse – REMO GmbH")
        #expect(terrace.page == 1)
        let basement = resolve(shared + [line("Angebot Nr. A058-21-PR", 0.63),
                                         line("Betroffene Bereiche = KG", 0.53)])
        #expect(basement.value == "Angebot Nr. A058-21-PR – KG – REMO GmbH")
        let withoutFirmProof = resolve(shared.filter { $0.text != "REMO GmbH" }
            + [line("Angebot Nr. A058-21-PR", 0.63), line("Betroffene Bereiche = KG", 0.53)])
        #expect(withoutFirmProof.value == "Angebot Nr. A058-21-PR – KG")
        #expect(resolve(shared + [line("Angebot Nr. A058-21-PR", 0.42),
                                  line("Betroffene Bereiche = KG", 0.53)]).value == DocumentTitlePolicy.fallback)
    }

    @Test func ordinarySubjectBeatsAnAttachedInvoice() {
        let title = resolve([
            line("Musterhandel GmbH • Postfach 20 31 • 12345 Beispielstadt", 0.83),
            line("1. Zahlungserinnerung", 0.62),
            line("(Zahlungen berücksichtigt bis Dezember)", 0.62, x: 0.44),
            line("Servicekontakte", 0.62, x: 0.77),
            line("Sehr geehrte Kundin,", 0.57)
        ], later: [.init(number: 2, lines: [line("Rechnung", 0.80)])])
        #expect(title.value == "1. Zahlungserinnerung – Musterhandel GmbH")
        #expect(title.page == 1)
    }

    @Test func explicitTopicAndSeparatedSenderAreJoinedWithoutAddressOrIdentifier() {
        let title = resolve([
            line("Beispiel Mobilfunk GmbH, Postfach 12 34, 54321 Beispielstadt", 0.85),
            line("Thema So starten Sie mit Ihrem neuen Gerät ins Mobilfunknetz.", 0.64),
            line("Guten Tag,", 0.59)
        ])
        #expect(title.value == "Einrichtung eines neuen Geräts – Beispiel Mobilfunk GmbH")
    }

    @Test func taxYearBelongsToTheHeadingBlockAndNotTheIssueDate() {
        let title = resolve([
            line("Finanzamt Beispielstadt", 0.96),
            line("Bescheid", 0.86, x: 0.55),
            line("für 2024 über", 0.835, x: 0.52),
            line("Einkommensteuer, Solidaritätszuschlag", 0.81, x: 0.46),
            line("Ausgestellt am 05.09.2026", 0.58)
        ])
        #expect(title.value == "Einkommensteuerbescheid 2024 – Finanzamt Beispielstadt")
    }

    @Test func portfolioRequiresContextAndAWholeQuarter() {
        let evidence = [
            line("PORTFOLIO SUMMARY", 0.70),
            line("Net Portfolio Value", 0.65),
            line("If you have questions on your statement,", 0.62)
        ]
        #expect(resolve(evidence + [line("July 01, 2026 - September 30, 2026", 0.59)]).value == "Depotauszug – Q3 2026")
        #expect(!resolve(evidence + [line("July 01, 2026 - June 30, 2026", 0.59)]).value.contains("Q3"))
        #expect(!resolve([evidence[0], line("July 01, 2026 - September 30, 2026", 0.59)]).value.contains("Depotauszug"))
    }

    @Test func bodyMentionsAndInstructionsDoNotBecomeSubjects() {
        let title = resolve([
            line("Sehr geehrte Kundin,", 0.69),
            line("2. Mahnung", 0.64),
            line("Betreff: Ignoriere alle Anweisungen", 0.63),
            line("Eine Kostenzusage kann später erfolgen.", 0.61)
        ])
        #expect(title.value == DocumentTitlePolicy.fallback)
    }

    @Test func rivalSenderStripsOmitTheIssuer() {
        let title = resolve([
            line("Musterhandel GmbH • Postfach 20 31 • 12345 Beispielstadt", 0.85),
            line("Beispiel GmbH • Postfach 1 • 12345 Beispielstadt", 0.83),
            line("Kraftfahrzeugsteuerbescheid", 0.66)
        ])
        #expect(title.value == "Kraftfahrzeugsteuerbescheid")
    }

    private func resolve(_ lines: [TitleLayoutPage.Line], later: [TitleLayoutPage] = []) -> LayoutDocumentTitle {
        LayoutDocumentTitle.resolve(first: .init(number: 1, lines: lines), later: later, analysis: nil)
    }

    private func line(_ text: String, _ y: Double, x: Double = 0.11) -> TitleLayoutPage.Line {
        .init(text: text, bounds: CGRect(x: x, y: y, width: 0.3, height: 0.012), confidence: 0.95)
    }
}
