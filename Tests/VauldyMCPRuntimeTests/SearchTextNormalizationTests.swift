import Foundation
import CryptoKit
import SQLite3
import Testing
@testable import VauldyCore
@testable import VauldyMCPRuntime

@Suite("Source-bound search normalization")
struct SearchTextNormalizationTests {
    @Test func splitWordsAndInvisibleSeparatorsKeepLiteralSourceRanges() {
        for spelling in ["Versiche-\nrung", "Versiche-\r\n  rung", "Versiche‐\nrung",
                         "Versiche\u{AD}rung", "Versiche\u{AD}\nrung", "Versiche\u{200B}rung",
                         "Versiche\u{2060}rung", "Versiche\u{FEFF}rung", "Versiche-\nrungs-\nbeitrag"] {
            let source = "👩🏽‍💻 Äpfel davor.\n" + spelling + " 49,99 EUR.\nVersicherung danach."
            let projection = VaultSearchText(source)
            #expect(projection.source == source)
            #expect(projection.text.contains(spelling.hasSuffix("beitrag") ? "Versicherungsbeitrag" : "Versicherung"))
            let matches = projection.ranges(of: spelling.hasSuffix("beitrag") ? "versicherungsbeitrag" : "versicherung")
            #expect(matches.first.map { String(source[$0]) } == spelling)
            #expect(projection.ranges(of: "versicherung", limit: 1).first == matches.first || spelling.hasSuffix("beitrag"))
        }
    }

    @Test func genuineHyphensIdentifiersNumbersParagraphsAndPagesAreNotJoined() {
        for source in ["Kfz-Versicherung", "Kosten-Nutzen", "AB-\nCD", "AB12-\ncd34", "49,\n99 EUR",
                       "Vertragsnummer: abc-\ndef", "IBAN: de\u{AD}abc", "Versiche-\n\nrung",
                       "Versiche-\n--- Seite 2 ---\nrung", "Versiche-\nRung", "abc-\ndef123", "abc/def-\nghi"] {
            #expect(VaultSearchText(source).text == source, Comment(rawValue: source))
        }
        #expect(VaultSearchText("[V_0123456789ABCDEF0123456789ABCDEF_PERSON_1]").text
                == "[V_0123456789ABCDEF0123456789ABCDEF_PERSON_1]")
    }

    @Test func aliasesPreserveOldTokensAndMatchQueriesSymmetrically() throws {
        let split = VaultDocument(title: "Beleg", sourceName: "synthetic.pdf", ocrText: "Versiche-\nrung")
        let plain = VaultDocument(title: "Beleg", sourceName: "synthetic.pdf", ocrText: "Versicherung")
        #expect(VaultDocumentFilter.matches(split, query: "Versicherung"))
        #expect(VaultDocumentFilter.matches(split, query: "Versiche rung"))
        #expect(VaultDocumentFilter.matches(plain, query: "Versiche\u{AD}rung"))
        #expect(VaultDocumentFilter.matches(split, query: "versicher", mode: .anyTermSubstring))
        #expect(!VaultDocumentFilter.matches(split, query: "Versicherungen"))
        let index = try SQLiteVaultTokenIndex()
        try index.reconcile([(split, Data([1])), (plain, Data([2]))])
        #expect(try index.matchingIDs(for: "Versicherung") == [split.id, plain.id])
        #expect(try index.matchingIDs(for: "Versiche rung") == [split.id])
        #expect(try index.matchingIDs(for: "Versiche\u{AD}rung") == [split.id, plain.id])
    }

    @Test func sourceWindowsKeepLatePhysicalPagesAndPrivacyTokensIntact() throws {
        let token = "[V_0123456789ABCDEF0123456789ABCDEF_PERSON_1]"
        let text = String(repeating: "Vorlauf ", count: 200) + token + " Versiche-\nrung 49,99 EUR"
        let sections = [VaultPageMarkedText.Section(page: 7, text: text)]
        let result = try MCPSourceExcerpt.passages(sections: sections, terms: ["versicherung"])
        #expect(result.count == 1 && result[0].page == 7)
        #expect(text.contains(result[0].text) && result[0].text.contains("Versiche-\nrung"))
        #expect(result[0].text.contains(token))
        let excerpt = MCPSourceExcerpt.select(sections: sections, summary: "", terms: ["versicherung"], preferredPage: nil)
        #expect(excerpt.text.contains("Versiche-\nrung") && text.contains(excerpt.text))
        #expect(MCPSourceExcerpt.terms(in: token) == [token])
    }

    @Test func previousSQLiteSemanticsAreRejectedAndCurrentIndexReopens() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("vauldy-search-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.sqlite")
        let document = VaultDocument(title: "Beleg", sourceName: "synthetic.pdf", ocrText: "Versiche\u{AD}rung")
        do {
            let index = try #require(try? SQLiteVaultTokenIndex(file: file, scope: "synthetic"), "Create current index")
            let fingerprint = Data(SHA256.hash(data: Data([1])))
            let generation = Data(SHA256.hash(data: fingerprint))
            try index.reconcile([(document, fingerprint)], generation: generation) { MCPSourceState($0).projection(for: $0) }
        }
        do {
            let index = try #require(try? SQLiteVaultTokenIndex(file: file, scope: "synthetic", create: false), "Reopen current index")
            #expect(try index.matchingIDs(for: "Versicherung") == [document.id])
        }
        var database: OpaquePointer?
        #expect(sqlite3_open(file.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA user_version=2", nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { try SQLiteVaultTokenIndex(file: file, scope: "synthetic", create: false) }
    }
}
