import Foundation
import Testing
@testable import VauldyPrivacy

/// Pins the exact pseudonymized output of `IdentifierPrivacySession` on a fixed synthetic
/// corpus, so performance work on matching cannot silently change what leaves the device.
/// Only the random per-session namespace is normalized; token order, numbering, spans and
/// fail-closed decisions must stay byte-identical.
///
/// Re-record intentionally (and review the diff) with:
/// `VAULDY_RECORD_PRIVACY_GOLDEN=1 swift test --filter PrivacyOutputGoldenTests`
@Suite("Privacy output golden")
struct PrivacyOutputGoldenTests {
    struct Probe: Codable, Equatable {
        let protected: String
        let sending: String
        let redactionRanges: [[Int]]
        let restores: Bool
    }
    struct Case: Codable, Equatable {
        let name: String
        let probes: [Probe]
    }

    static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/privacy-output-golden.json")

    static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: #"\[V_[A-F0-9]{32}_"#, with: "[V_NS_", options: .regularExpression)
    }

    static func corpus() -> [(name: String, contents: [String], probes: [String])] {
        let first = ["Erika", "Max", "Anna", "Jonas", "Lea", "Paul", "Mia", "Felix", "Sophie", "Lukas"]
        let last = ["Musterfrau", "Beispiel", "Probst", "Lindner", "Hartmann", "Vogel", "Krause", "Brandt"]
        func iban(_ i: Int) -> String { String(format: "DE%02d3704004405%010d", 10 + i % 89, i) }
        var cases: [(String, [String], [String])] = []

        let dense = (0..<120).map { i in
            "Kontoinhaber \(first[i % 10]) \(last[i % 8])\(i), IBAN \(iban(i)), E-Mail kunde\(i)@example.com, Vertragsnummer VN-\(100000 + i)."
        }
        let densePages = stride(from: 0, to: dense.count, by: 20).enumerated().map { page, start in
            "--- Seite \(page + 1) ---\n" + dense[start..<min(start + 20, dense.count)].joined(separator: " ")
        }
        let denseText = densePages.joined(separator: "\n")
        cases.append(("dense-identifiers", [denseText, "Vertrag Kontoinhaber Erika Musterfrau0"],
                      densePages + [String(denseText.prefix(240)), "Kontoinhaber Erika Musterfrau0 zahlt monatlich."]))

        let split = "Zahlung an Erika Musterfrau\nIBAN DE89 3704\n0044 0532 0130 00\nVerwendungszweck: Beitrag.\nerika.musterfrau@example.com"
        cases.append(("split-iban-email-overlap", [split], [split, "Erika Musterfrau", "IBAN DE89 3704 0044 0532 0130 00"]))

        let compounds = "Die Kinder spenden an die Kindernothilfe. Kinder und KINDER sind gemeint. Ansprechpartnerin ist Anna Probst aus Berlin."
        cases.append(("whole-word-compounds", [compounds, "Spendenquittung Kindernothilfe"], [compounds, "Kindernothilfe e.V.", "Kinder"]))

        let address = "12345 Testort Dr: eine lange vertrauliche Zusatzangabe.\nBetrag 49,99 EUR."
        cases.append(("residual-address", [address, "Name: Dr: eine lange vertrauliche Zusatzangabe."], [address]))

        let numeric = ((0..<30).map { "Kundennummer: Vertragskennung-\($0)-ABCDEFGHIJ" } + ["Patient: 12", "Betrag 49,99 EUR."]).joined(separator: "\n")
        cases.append(("numeric-bookkeeping", [numeric], [numeric]))

        let policyPages = ["Versicherungsschein\nAussteller: Nordstern Sachversicherung AG\nPolicennummer: PK-85HJ\n\nBetreff: Hausrat\nPOLICENALTT"]
            + Array(repeating: String(repeating: "Hinweise zur Bearbeitung der Unterlagen. ", count: 10), count: 4)
            + ["Kosten: Referenz PK-85HJ"]
        let policy = policyPages.enumerated().map { "--- Seite \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n")
        cases.append(("policy-label-pages", [policy], policyPages))

        let mixed = "Herr Jonas Lindner, Tel. +49 170 1234567, wohnt in der Hauptstraße 5, 80331 München. Frau Lea Vogel (lea.vogel@example.org) vertritt ihn. Steuer-ID 12 345 678 901."
        cases.append(("mixed-contacts", [mixed, "Vollmacht Lindner"], [mixed, "Lindner", "Frau Lea Vogel", "Unverfänglicher Text über Laufzeit und Beitrag."]))

        cases.append(("unknown-outgoing", ["Unverfänglicher Text."],
                      ["E-Mail: synthetic-private@example.com", "Angela Merkel", "Beitrag und Laufzeit"]))
        return cases
    }

    static func evaluate() throws -> [Case] {
        try corpus().map { item in
            let session = try IdentifierPrivacySession(contents: item.contents)
            let probes = item.probes.map { probe in
                let protected = session.protect(probe)
                let sending: String
                do { sending = normalize(try session.protectForSending(probe)) } catch { sending = "<fail-closed: \(error)>" }
                let ranges = session.redactionRanges(in: probe).map { [$0.location, $0.length] }
                return Probe(protected: normalize(protected), sending: sending,
                             redactionRanges: ranges, restores: session.restore(protected) == probe)
            }
            return Case(name: item.name, probes: probes)
        }
    }

    @Test func outputMatchesRecordedGolden() throws {
        let actual = try Self.evaluate()
        // Two independent sessions must agree after namespace normalization (determinism check).
        #expect(try Self.evaluate() == actual)
        if ProcessInfo.processInfo.environment["VAULDY_RECORD_PRIVACY_GOLDEN"] == "1" {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(actual).write(to: Self.goldenURL, options: .atomic)
            return
        }
        let golden = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.goldenURL))
        #expect(golden.count == actual.count)
        for (expected, got) in zip(golden, actual) {
            #expect(expected == got, "Privacy output changed for case \(expected.name)")
        }
    }
}
