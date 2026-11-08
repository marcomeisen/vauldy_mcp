import Foundation
import Testing
import VauldyDocumentCore
@testable import VauldyMCPRuntime

@Suite("MCP literal field roles and evidence")
struct MCPFieldExtractionTests {
    private func extract(_ texts: [String], fields: [MCPExtractionField]) throws -> [MCPExtractedField] {
        try MCPFieldExtraction.extract(sections: texts.enumerated().map {
            .init(page: $0.offset + 1, text: $0.element)
        }, handle: "synthetic", fields: fields, sourceCoverage: "complete")
    }

    @Test func amountsKeepTheirRolesAndLateDisagreementIsNotHidden() throws {
        let rows = try extract([
            "Leasingvertrag\nMonatsrate: 249,99 EUR\nGesamtkosten: 8999,64 EUR\nKündigungsfrist: 3 Monate",
            "Monatliche Rate: 249,99 EUR\nKündigungsfrist: 6 Monate"
        ], fields: [.cost, .noticePeriod])
        #expect(rows[0].status == "multiple-values")
        #expect(rows[0].evidence.map(\.label) == ["Monatsrate", "Gesamtkosten"])
        #expect(rows[0].evidenceCount == 2) // Alias repetition is not another contract or amount.
        #expect(rows[1].status == "conflicting")
        #expect(rows[1].evidence.map(\.page) == [1, 2])
    }

    @Test func nextLineKeepsExactPhysicalQuoteAndReportsUnexaminedContinuation() throws {
        let rows = try extract(["Laufzeit:\n  36 Monate\nZusatzregel im Folgeabsatz."], fields: [.term])
        #expect(rows[0].evidence.first?.value == "36 Monate")
        #expect(rows[0].evidence.first?.quote == "Laufzeit:\n  36 Monate")
        #expect(rows[0].warnings.contains("FIELD_EXTRACTION_INCOMPLETE"))
        #expect(rows[0].evidence.first?.source == "[Quelle:synthetic:S.1]")
    }

    @Test func mentionsAmbiguousRolesAndOtherLabelsAreNotFieldAuthority() throws {
        let rows = try extract([
            "Im Leasingvertrag steht eine Laufzeit von 24 Monaten.\nVertragspartner: Kunde\n"
            + "Geburtsdatum: 01.01.1980\nBeginn: 01.01.2027\nZahlungsfrist: 14 Tage\nKündigungsfrist:\nLaufzeit: 36 Monate"
        ], fields: [.contractType, .issuer, .startDate, .noticePeriod, .term])
        #expect(rows.prefix(4).allSatisfy { $0.status == "not-evidenced" })
        #expect(rows[3].warnings.contains("FIELD_EXTRACTION_INCOMPLETE"))
        #expect(rows[4].evidence.first?.value == "36 Monate")
    }

    @Test func malformedPagesAndOversizedEvidenceAreNeverPresentedAsLocatedFacts() throws {
        let rows = try MCPFieldExtraction.extract(sections: [
            .init(page: nil, text: "Kosten: 10 EUR"),
            .init(page: 2, text: "Kosten: " + String(repeating: "x", count: 1_300))
        ], handle: "synthetic", fields: [.cost], sourceCoverage: "incomplete-or-unknown")
        #expect(rows[0].status == "not-evidenced")
        #expect(rows[0].warnings == ["FIELD_EXTRACTION_INCOMPLETE", "UNLOCATED_SOURCE_TEXT"])
    }

    @Test func distinctEvidenceIsBoundedInsteadOfSilentlyDroppingLateConflicts() throws {
        #expect(throws: MCPAccessError.tooLarge) {
            try extract([(0...512).map { "Kosten: \($0) EUR" }.joined(separator: "\n")], fields: [.cost])
        }
    }
}
