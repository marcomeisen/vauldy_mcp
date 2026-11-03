import Foundation
import Testing
import VauldyCore
@testable import VauldyMCPRuntime

@Suite("MCP targeted source passages")
struct MCPPassageTests {
    @Test func longDocumentReturnsOnlyRelevantPhysicalPagesInOneResponse() async throws {
        let sections = (1...100).map { page in
            "--- Seite \(page) ---\n" + (page == 42 ? "Hausratversicherung: dokumentierter Beleg." : page == 87 ? "Pflegepflicht: dokumentierter Tarif." : "Unabhängiger Text ohne Fundstelle.")
        }
        try await passageFixture(text: sections.joined(separator: "\n"), pages: 100) { runtime, handle, _ in
            let result = try await runtime.passages(document: handle, query: "hausrat pflege")
            #expect(result.segments.compactMap(\.page) == [42, 87])
            #expect(result.matchingPassageCount == 2 && result.retrievalComplete && result.nextCursor == nil)
            #expect(!result.containsEntireAvailableText)
            #expect(result.segments.allSatisfy { !$0.text.contains("Unabhängiger") && $0.source.contains("S.\($0.page!)") })
            #expect(await runtime.privacyBuildCount == 1)
        }
    }
    @Test func passagesAreLiteralSeparateWindowsAndUseWholeContextPrivacy() async throws {
        let text = "--- Seite 1 ---\nKostenplan Erika Musterfrau 49,99 EUR\n" + String(repeating: "Zwischenraum ", count: 250)
            + "\nKostenplan zweiter Beleg\n--- Seite 2 ---\nName: Erika Musterfrau\nE-Mail: erika@example.com"
        try await passageFixture(text: text, pages: 2) { runtime, handle, _ in
            let full = try await runtime.read(document: handle)
            let result = try await runtime.passages(document: handle, query: "kostenplan")
            #expect(result.segments.count == 2 && result.segments.allSatisfy { $0.page == 1 })
            let source = full.segments.filter { $0.page == 1 }.map(\.text).joined()
            #expect(result.segments.allSatisfy { source.contains($0.text) })
            let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            #expect(!wire.contains("Erika Musterfrau") && !wire.contains("erika@example.com"))
        }
    }
    @Test func passageCursorBindsQueryDocumentProfileAndSource() async throws {
        let text = (1...20).map { "--- Seite \($0) ---\nSuchmarker Beleg \($0)" }.joined(separator: "\n")
        try await passageFixture(text: text, pages: 20) { runtime, handle, fixture in
            let first = try await runtime.passages(document: handle, query: "suchmarker")
            let cursor = try #require(first.nextCursor)
            await #expect(throws: MCPAccessError.invalidArguments) { try await runtime.passages(document: handle, query: "anderer", cursor: cursor) }
            var result = try await runtime.passages(document: handle, cursor: cursor)
            var pages = first.segments.compactMap(\.page) + result.segments.compactMap(\.page), calls = 2
            while let next = result.nextCursor { result = try await runtime.passages(document: handle, cursor: next); pages += result.segments.compactMap(\.page); calls += 1 }
            #expect(pages == Array(1...20) && calls == 3 && result.retrievalComplete)
            var profile = try FileMCPProfileSource(url: fixture.profile).load(); profile.enabled = false; profile.revision = UUID()
            try FileMCPProfileSource(url: fixture.profile).save(profile)
            await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.passages(document: handle, cursor: cursor) }
        }
    }
    @Test func changedSourceRejectsOldPassageCursorAndEmptySelectionIsExplicit() async throws {
        let text = (1...10).map { "--- Seite \($0) ---\nSuchmarker Beleg" }.joined(separator: "\n")
        try await passageFixture(text: text, pages: 10) { runtime, handle, fixture in
            let empty = try await runtime.passages(document: handle, query: "unauffindbar")
            #expect(empty.segments.isEmpty && empty.matchingPassageCount == 0 && empty.retrievalComplete && !empty.containsEntireAvailableText)
            let first = try await runtime.passages(document: handle, query: "suchmarker")
            let cursor = try #require(first.nextCursor)
            var document = fixture.document; document.ocrText += "\nGeänderter Text"
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([document]).write(to: fixture.vault, options: .atomic)
            await #expect(throws: MCPAccessError.stale) { try await runtime.passages(document: handle, cursor: cursor) }
        }
    }
}
private struct PassageFixture { let document: VaultDocument; let vault: URL; let profile: URL }
private func passageFixture(text: String, pages: Int, body: (ReadOnlyMCPRuntime, String, PassageFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-passages-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = VaultDocument(title: "Beleg", sourceName: "private.pdf", ocrText: text, pageCount: pages)
    let vault = root.appendingPathComponent("documents.json"), profile = root.appendingPathComponent("profile.json")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; try encoder.encode([document]).write(to: vault)
    try FileMCPProfileSource(url: profile).save(.init(vaultPath: vault.path, allowedDocumentIDs: [document.id], enabled: true, acknowledgedCloudDisclosure: true))
    let runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: profile))
    let handle = try #require(try await runtime.list(includeExcerpts: false).items.first?.document)
    try await body(runtime, handle, .init(document: document, vault: vault, profile: profile))
}
