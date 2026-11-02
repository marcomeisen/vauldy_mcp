import Foundation
import Testing
@testable import VauldyPrivacy

@Suite("Complete identifier protection")
struct IdentifierPrivacyCompletionTests {
    @Test func overlappingLabelCannotLeaveAnUnprotectedPostalAddress() throws {
        let source = "12345 Testort Dr: eine lange vertrauliche Zusatzangabe.\nBetrag 49,99 EUR."
        let session = try IdentifierPrivacySession(contents: [source, "Name: Dr: eine lange vertrauliche Zusatzangabe."])
        let protected = try session.protectForSending(source)
        #expect(!protected.contains("12345") && !protected.contains("Testort"))
        #expect(protected.contains("49,99 EUR"))
        #expect(session.restore(protected) == source)
    }
    @Test func shortNumericNamesCannotRewriteReplacementBookkeeping() throws {
        let lines = (0..<30).map { "Kundennummer: Vertragskennung-\($0)-ABCDEFGHIJ" }
        let source = (lines + ["Patient: 12", "Betrag 49,99 EUR."]).joined(separator: "\n")
        let session = try IdentifierPrivacySession(contents: [source])
        let protected = try session.protectForSending(source)
        #expect(!protected.contains("\u{E000}") && !protected.contains("\u{E001}"))
        #expect(!protected.contains("Vertragskennung"))
        #expect(protected.contains("49,99 EUR"))
        #expect(session.restore(protected) == source)
    }
    @Test func currencyCodesRemainUsefulButExplicitPersonalValuesStayProtected() throws {
        let source = "Rechnung Wartung 49,99 EUR.\n12345 Testort Dr: eine lange vertrauliche Zusatzangabe.\nName: Dr: eine lange vertrauliche Zusatzangabe."
        let session = try IdentifierPrivacySession(contents: [source])
        #expect(try session.protectForSending(source).contains("49,99 EUR"))
        let labelled = try IdentifierPrivacySession(contents: ["Name: EUR"])
        #expect(try !labelled.protectForSending("Name: EUR").contains("EUR"))
    }
    @Test func unknownOutgoingIdentifiersStillFailClosed() throws {
        let session = try IdentifierPrivacySession(contents: ["Unverfänglicher Text."])
        #expect(throws: ExternalAIPrivacyError.personalDataRemaining) {
            try session.protectForSending("E-Mail: synthetic-private@example.com")
        }
    }
}
