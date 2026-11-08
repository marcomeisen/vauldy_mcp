import Foundation
import Testing
import VauldyCore
@testable import VauldyMCPSetup

@Suite("Document import date and time")
struct SetupDocumentTimestampTests {
    @Test func germanTimestampHasDateTimeAndLocalTimezone() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-08T14:20:30Z"))
        let text = SetupText.importTimestamp(date, timeZone: berlin)
        #expect(text.contains("08.11.2026") && text.contains("15:20:30"))
        #expect(SetupText.importTimestamp(date, timeZone: utc).contains("14:20:30"))
        let summer = try #require(ISO8601DateFormatter().date(from: "2026-07-08T14:20:30Z"))
        #expect(SetupText.importTimestamp(summer, timeZone: berlin).contains("16:20:30"))
    }

    @Test func legacyMissingTimestampIsNotInvented() throws {
        let source = Data(#"{"id":"A6CC245A-4EC8-4CB1-8AEE-937160E93F53","title":"Synthetisch","sourceName":"test.pdf","status":"indexed"}"#.utf8)
        let document = try JSONDecoder().decode(VaultDocument.self, from: source)
        #expect(document.importedAt == .distantPast)
        #expect(SetupText.importTimestamp(document.importedAt) == "Importzeitpunkt nicht bekannt")
        #expect(SetupText.importTimestamp(.distantFuture) == "Importzeitpunkt nicht bekannt")
        #expect(SetupText.importTimestamp(Date(timeIntervalSince1970: 0)).hasPrefix("Importiert:"))
    }

    @Test func displayDoesNotReplaceImportDateWithProcessingDate() throws {
        let imported = try #require(ISO8601DateFormatter().date(from: "2026-11-01T09:10:11Z"))
        var document = VaultDocument(title: "Synthetisch", sourceName: "test.pdf", importedAt: imported)
        var info = LocalImportMetadata(contentHash: "synthetic", fileExtension: "pdf")
        info.updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-11-08T14:20:30Z"))
        document.localImport = info
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(document)
        let text = SetupText.importTimestamp(document.importedAt, timeZone: try #require(TimeZone(secondsFromGMT: 0)))
        #expect(text.contains("01.11.2026") && text.contains("09:10:11"))
        #expect(!text.contains("08.11.2026"))
        #expect(try encoder.encode(document) == before)
    }
}
