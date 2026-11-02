import Foundation
import Testing
import VauldyCore
import VauldyPrivacy
@testable import VauldyMCPRuntime

@Suite("MCP privacy and permission boundary")
struct MCPPrivacyBoundaryTests {
    @Test func defaultDeniesContentAndDoesNotCountPrivateDocuments() async throws {
        try await fixture { f in
            var profile = f.profile; profile.enabled = false; try f.save(profile)
            let status = try await f.runtime.status()
            #expect(status.grantedDocumentCount == 0)
            await #expect(throws: MCPAccessError.notAuthorized) { try await f.runtime.search(query: "Rechnung") }
        }
    }

    @Test func onlyExplicitGrantsAreSearchable() async throws {
        try await fixture { f in
            let result = try await f.runtime.search(query: "UnfreigegebenesSuchwort")
            #expect(result.hits.isEmpty)
            let status = try await f.runtime.status()
            #expect(status.grantedDocumentCount == 1)
            #expect(status.searchableDocumentCount == 1)
        }
    }

    @Test func serializedSearchAndReadProtectAllChannels() async throws {
        try await fixture { f in
            let search = try await f.runtime.search(query: "Rechnung")
            let hit = try #require(search.hits.first)
            let read = try await f.runtime.read(document: hit.document)
            for value in [try encoded(search), try encoded(read)] {
                for secret in ["Erika Musterfrau", "erika@example.com", "DE89370400440532013000", "12345678901",
                               "/Users/erika", f.document.id.uuidString, "privater-dateiname"] {
                    #expect(!value.localizedCaseInsensitiveContains(secret), "Unexpected private value in serialized output")
                }
                #expect(value.contains("49,99 EUR"))
                #expect(value.contains("hostCanReadResults"))
            }
            #expect(hit.document != f.document.id.uuidString)
            #expect(read.sourceCoverage == "all-declared-pages-have-ocr-text")
            #expect(read.containsEntireAvailableText)
        }
    }

    @Test func labeledNameOnLaterPageProtectsEarlierMention() async throws {
        var document = sample()
        document.ocrText = "--- Seite 1 ---\nRechnung für Erika Musterfrau. 49,99 EUR.\n--- Seite 2 ---\nName: Erika Musterfrau\n"
        document.pageCount = 2
        try await fixture(document) { f in
            let search = try await f.runtime.search(query: "Rechnung")
            #expect(try !encoded(search).contains("Erika"))
        }
    }

    @Test func revokeInvalidatesExistingProcessAndHandles() async throws {
        try await fixture { f in
            let hit = try #require(try await f.runtime.search(query: "Rechnung").hits.first)
            var profile = f.profile; profile.enabled = false; profile.revision = UUID(); try f.save(profile)
            await #expect(throws: MCPAccessError.notAuthorized) { try await f.runtime.read(document: hit.document) }
            profile.enabled = true; profile.revision = UUID(); try f.save(profile)
            await #expect(throws: MCPAccessError.stale) { try await f.runtime.read(document: hit.document) }
        }
    }

    @Test func revokedDuringLoadingCannotReturnAResult() async throws {
        try await fixture { f in
            let reader = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: f.profileURL), loadVault: { _ in
                var disabled = f.profile; disabled.enabled = false; disabled.revision = UUID()
                try f.save(disabled)
                return [f.document]
            })
            await #expect(throws: MCPAccessError.stale) { try await reader.search(query: "Rechnung") }
        }
    }

    @Test func documentChangesInvalidatePagingAndSessionHandlesCannotBeReused() async throws {
        try await fixture { f in
            let hit = try #require(try await f.runtime.search(query: "Rechnung").hits.first)
            let other = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: f.profileURL))
            await #expect(throws: MCPAccessError.stale) { try await other.read(document: hit.document) }
            var changed = f.document; changed.ocrText += "\nKorrigierter Inhalt."
            try f.write([changed])
            await #expect(throws: MCPAccessError.stale) { try await f.runtime.read(document: hit.document) }
        }
    }

    @Test func pagedTextHasNoSilentTruncationOrBrokenPlaceholders() async throws {
        var document = sample()
        document.pageCount = 2
        document.ocrText = "--- Seite 1 ---\nRechnung. " + String(repeating: "Leistung 49,99 EUR. ", count: 1_500)
            + "E-Mail: erika@example.com\n--- Seite 2 ---\nENDE_DER_QUELLE"
        try await fixture(document) { f in
            let hit = try #require(try await f.runtime.search(query: "Rechnung").hits.first)
            var cursor: String?
            var collected = ""
            var calls = 0
            repeat {
                let result = try await f.runtime.read(document: hit.document, cursor: cursor)
                #expect(!result.containsEntireAvailableText)
                #expect(try JSONEncoder().encode(result).count < 180_000)
                for segment in result.segments {
                    #expect(segment.text.filter { $0 == "[" }.count == segment.text.filter { $0 == "]" }.count)
                    collected += segment.text
                }
                cursor = result.nextCursor; calls += 1
                #expect(calls < 10)
            } while cursor != nil && calls < 10
            #expect(collected.contains("ENDE_DER_QUELLE"))
            #expect(!collected.contains("erika@example.com"))
            #expect(collected.components(separatedBy: "Leistung 49,99 EUR.").count - 1 == 1_500)
        }
    }

    @Test func missingPagesRemainExplicitAndUnmarkedPrefixIsPreserved() async throws {
        var document = sample()
        document.pageCount = 3
        document.ocrText = "Vorspann\n--- Seite 1 ---\nRechnung.\n--- Seite 3 ---\nLetzte Seite."
        try await fixture(document) { f in
            let hit = try #require(try await f.runtime.search(query: "Rechnung").hits.first)
            let result = try await f.runtime.read(document: hit.document)
            #expect(result.sourceCoverage == "incomplete-or-unknown")
            #expect(result.availablePages == [1, 3])
            #expect(result.segments.first?.page == nil)
            #expect(result.segments.first?.text == "Vorspann")
        }
    }

    @Test func badProfileAndSourceFailClosedWithoutLeakingDetails() async throws {
        try await fixture { f in
            try Data("{broken secret content".utf8).write(to: f.profileURL)
            await #expect(throws: MCPAccessError.configuration) { try await f.runtime.search(query: "Rechnung") }
            try f.save(f.profile)
            try Data("{broken personal source".utf8).write(to: f.vaultURL)
            await #expect(throws: MCPAccessError.unavailable) { try await f.runtime.search(query: "Rechnung") }
        }
    }

    @Test func invalidArgumentsAndOversizeSourcesFailExplicitly() async throws {
        try await fixture { f in
            await #expect(throws: MCPAccessError.invalidArguments) { try await f.runtime.search(query: String(repeating: "x", count: 2_001)) }
            let hit = try #require(try await f.runtime.search(query: "Rechnung").hits.first)
            await #expect(throws: MCPAccessError.invalidArguments) { try await f.runtime.read(document: hit.document, cursor: "foreign:3") }
            var large = f.document; large.ocrText = "Rechnung " + String(repeating: "x", count: 1_000_001)
            try f.write([large])
            await #expect(throws: MCPAccessError.tooLarge) { try await f.runtime.search(query: "Rechnung") }
        }
    }

    @Test func completeListingAndReadingSurviveOverlappingIdentifierContexts() async throws {
        var document = sample()
        document.ocrText = "--- Seite 1 ---\nRechnung Wartung 49,99 EUR.\n12345 Testort Dr: eine lange vertrauliche Zusatzangabe.\nName: Dr: eine lange vertrauliche Zusatzangabe.\n--- Seite 2 ---\nDie Wartung wurde abgeschlossen."
        document.pageCount = 2
        try await fixture(document) { f in
            let before = try Data(contentsOf: f.vaultURL)
            let list = try await f.runtime.list(pageSize: 1)
            #expect(list.totalCount == 1 && list.retrievalComplete)
            let handle = try #require(list.items.first?.document)
            let read = try await f.runtime.read(document: handle)
            let json = try encoded(read)
            #expect(!json.contains("12345") && !json.contains("Testort"))
            #expect(json.contains("49,99 EUR"))
            #expect(try Data(contentsOf: f.vaultURL) == before)
        }
    }

    @Test func originalsAndArchiveBytesAreNeverModified() async throws {
        try await fixture { f in
            let before = try Data(contentsOf: f.vaultURL)
            let hit = try #require(try await f.runtime.search(query: "Rechnung").hits.first)
            _ = try await f.runtime.read(document: hit.document)
            #expect(try Data(contentsOf: f.vaultURL) == before)
        }
    }
}

private func sample() -> VaultDocument {
    VaultDocument(title: "Rechnung Erika Musterfrau", sourceName: "privater-dateiname.pdf", category: "invoice",
        ocrText: "--- Seite 1 ---\nRechnung: 49,99 EUR.\nName: Erika Musterfrau\nE-Mail: erika@example.com\nIBAN: DE89370400440532013000\nSteuer-ID: 12345678901\n/Users/erika/Dokumente/privat.pdf", pageCount: 1)
}
private func encoded<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
private struct Fixture: Sendable {
    let root: URL
    let document: VaultDocument
    let profile: MCPAccessProfile
    let runtime: ReadOnlyMCPRuntime
    var vaultURL: URL { root.appendingPathComponent("documents.json") }
    var profileURL: URL { root.appendingPathComponent("profile.json") }
    func save(_ profile: MCPAccessProfile) throws { try FileMCPProfileSource(url: profileURL).save(profile) }
    func write(_ documents: [VaultDocument]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(documents).write(to: vaultURL, options: [.atomic])
    }
}
private func fixture(_ document: VaultDocument = sample(), body: (Fixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-mcp-test-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = MCPAccessProfile(vaultPath: root.appendingPathComponent("documents.json").path,
                                   allowedDocumentIDs: [document.id], enabled: true, acknowledgedCloudDisclosure: true)
    let f = Fixture(root: root, document: document, profile: profile,
                    runtime: ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: root.appendingPathComponent("profile.json"))))
    try f.save(profile)
    try f.write([document, VaultDocument(title: "UnfreigegebenesSuchwort", sourceName: "secret.pdf", ocrText: "UnfreigegebenesSuchwort")])
    try await body(f)
}
