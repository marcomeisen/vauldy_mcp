import Foundation
import Testing
import VauldyCore
@testable import VauldyMCPRuntime

@Suite("MCP exhaustive retrieval and source coverage")
struct MCPRetrievalCompletenessTests {
    @Test(arguments: [0, 1, 25, 26, 1_001])
    func completeSetsHaveNoDuplicatesAndEarlyHandlesRemainReadable(count: Int) async throws {
        let documents = count == 0 ? [record("Andere Versicherung")] : (0..<count).map { record("LVM Beleg \($0)") }
        try await withVault(documents) { f in
            var cursor: String?
            var handles: [String] = []
            repeat {
                let page = try await f.runtime.list(query: cursor == nil ? "LVM" : nil, pageSize: cursor == nil ? 25 : nil, cursor: cursor)
                #expect(page.totalCount == count)
                #expect(page.hasMore == (page.nextCursor != nil))
                #expect(page.retrievalComplete == !page.hasMore)
                #expect(page.items.count <= 25)
                #expect(page.processingComplete)
                handles += page.items.map(\.document)
                cursor = page.nextCursor
            } while cursor != nil
            #expect(handles.count == count)
            #expect(Set(handles).count == count)
            if let first = handles.first, let last = handles.last {
                #expect(try await f.runtime.read(document: first).expectedPageCount == 1)
                #expect(try await f.runtime.read(document: last).expectedPageCount == 1)
            }
        }
    }

    @Test func lvmTextListFindsGenericScanAndExcludesSubstringNoise() async throws {
        let scan = record("Epson_16062026181402", text: "LVM\nauditmarkerepson")
        let others = (0..<11).map { record("LVM LVM LVM Beitragsrechnung \($0)") }
        try await withVault(others + [scan, record("FLVMX")]) { f in
            let search = try await f.runtime.search(query: "LVM")
            #expect(search.hits.count == 5)
            #expect(search.truncated)
            #expect(search.totalCount == 13) // Ranked substring matching is still explicitly bounded.
            #expect(!search.retrievalComplete)
            let list = try await f.runtime.list(query: "LVM")
            #expect(list.totalCount == 12)
            #expect(list.retrievalComplete)
            let exact = try await f.runtime.search(query: "16062026181402")
            let hit = try #require(exact.hits.first)
            #expect(hit.page == 1)
            #expect(hit.excerpt.contains("auditmarkerepson"))
            #expect(list.items.contains { $0.document == hit.document })
            #expect(try await f.runtime.read(document: hit.document).segments.first?.text.contains("auditmarkerepson") == true)
        }
    }

    @Test func excerptIncludesLateMatchAfterWholeContextProtection() async throws {
        let document = record("Generischer Scan", text: String(repeating: "Einleitung. ", count: 160)
                              + "FUNDSTELLENMARKER 49,99 EUR.\nName: Erika Musterfrau\nE-Mail: erika@example.com")
        try await withVault([document]) { f in
            let hit = try #require(try await f.runtime.search(query: "FUNDSTELLENMARKER").hits.first)
            #expect(hit.excerpt.contains("FUNDSTELLENMARKER"))
            #expect(hit.excerpt.contains("49,99 EUR"))
            #expect(!hit.excerpt.contains("Erika Musterfrau"))
            #expect(!hit.excerpt.contains("erika@example.com"))
            #expect(hit.excerpt.filter { $0 == "[" }.count == hit.excerpt.filter { $0 == "]" }.count)
        }
    }

    @Test func coverageCountsOnlyGrantedRecordsAndEmptyResultsRemainQualified() async throws {
        let ready = record("Fertiger Beleg")
        var review = record("Pruefbedarf"); review.status = "partiallyAnalyzed"
        var queued = record("Warteschlange"); queued.status = "imported"
        var failed = record("Fehler"); failed.status = "failed"
        var unknown = record("Altbestand"); unknown.pageCount = nil
        let unapproved = record("Unfreigegebene Daten")
        let documents = [ready, review, queued, failed, unknown]
        let allowed = Set(documents.map(\.id)).union([UUID()])
        try await withVault(documents + [unapproved], allowed: allowed) { f in
            let status = try await f.runtime.status()
            #expect(status.grantedDocumentCount == 5)
            #expect(status.coverage.completeSourceDocumentCount == 1)
            #expect(status.coverage.reviewDocumentCount == 1)
            #expect(status.coverage.pendingDocumentCount == 1)
            #expect(status.coverage.failedDocumentCount == 1)
            #expect(status.coverage.unknownCoverageDocumentCount == 1)
            #expect(status.coverage.missingGrantedDocumentCount == 1)
            let all = try await f.runtime.list()
            #expect(all.items.count == 5)
            #expect(!all.processingComplete)
            let empty = try await f.runtime.list(query: "KEINTREFFER")
            #expect(empty.items.isEmpty && empty.retrievalComplete)
            #expect(!empty.processingComplete)
            #expect(empty.warnings.contains("SOURCE_PROCESSING_GAPS"))
            #expect(try await f.runtime.search(query: "Unfreigegebene").hits.isEmpty)
        }
    }

    @Test func maskedNameQuerySelectsItsOwnEvidenceInsteadOfAnotherPerson() async throws {
        let document = record("Scan", text: "FRUEHERABSCHNITT\nName: Anna Beispielfrau\n"
                              + String(repeating: "Einleitung. ", count: 180)
                              + "\nZIELABSCHNITT\nName: Erika Musterfrau\n")
        try await withVault([document]) { f in
            let hit = try #require(try await f.runtime.search(query: "Erika Musterfrau").hits.first)
            #expect(hit.excerpt.contains("ZIELABSCHNITT"))
            #expect(!hit.excerpt.contains("FRUEHERABSCHNITT"))
            #expect(!hit.excerpt.contains("Erika Musterfrau"))
        }
    }

    @Test func localReviewAndMissingPhysicalPagesNeverClaimCompleteProcessing() async throws {
        var partial = record("LVM", text: "LVM Quelle")
        var info = LocalImportMetadata(contentHash: "test", fileExtension: "pdf")
        info.state = .completed
        info.pages = [.init(page: 1, method: .vision, needsReview: true)]
        partial.localImport = info
        var missing = record("LVM zweite Quelle"); missing.pageCount = 2
        try await withVault([partial, missing]) { f in
            let page = try await f.runtime.list(query: "LVM")
            #expect(!page.processingComplete)
            #expect(page.coverage.reviewDocumentCount == 1)
            #expect(page.coverage.unknownCoverageDocumentCount == 1)
            #expect(page.items.allSatisfy { $0.sourceCoverage == "incomplete-or-unknown" })
            for item in page.items {
                #expect(try await f.runtime.read(document: item.document).sourceCoverage == item.sourceCoverage)
            }
        }
    }

    @Test func cursorsBindFilterSnapshotProfileAndProcess() async throws {
        let documents = (0..<4).map { record("LVM Beleg \($0)") }
        try await withVault(documents) { f in
            let first = try await f.runtime.list(query: "LVM", pageSize: 1)
            let cursor = try #require(first.nextCursor)
            let replay = try await f.runtime.list(cursor: cursor)
            #expect(try await f.runtime.list(cursor: cursor).items.first?.document == replay.items.first?.document)
            await #expect(throws: MCPAccessError.invalidArguments) { try await f.runtime.list(query: "Andere", cursor: cursor) }
            await #expect(throws: MCPAccessError.invalidArguments) { try await f.runtime.list(pageSize: 2, cursor: cursor) }
            await #expect(throws: MCPAccessError.invalidArguments) { try await f.runtime.list(cursor: "\(first.snapshot):3") }
            let other = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: f.profileURL))
            await #expect(throws: MCPAccessError.stale) { try await other.list(cursor: cursor) }
            var changed = documents; changed[0].ocrText += "Korrektur"
            try f.write(changed)
            await #expect(throws: MCPAccessError.stale) { try await f.runtime.list(cursor: cursor) }
            try f.write(documents)
            await #expect(throws: MCPAccessError.stale) { try await f.runtime.list(cursor: cursor) }
            var profile = f.profile; profile.enabled = false; profile.revision = UUID()
            try FileMCPProfileSource(url: f.profileURL).save(profile)
            await #expect(throws: MCPAccessError.notAuthorized) { try await f.runtime.list(cursor: cursor) }
            profile.enabled = true; profile.revision = UUID()
            try FileMCPProfileSource(url: f.profileURL).save(profile)
            await #expect(throws: MCPAccessError.stale) { try await f.runtime.list(cursor: cursor) }
        }
    }

    @Test func listCannotDiscloseAfterRevocationDuringSnapshotLoad() async throws {
        try await withVault([record("LVM")]) { f in
            let runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: f.profileURL), loadVault: { _ in
                var disabled = f.profile; disabled.enabled = false; disabled.revision = UUID()
                try FileMCPProfileSource(url: f.profileURL).save(disabled)
                return [record("LVM")]
            })
            await #expect(throws: MCPAccessError.stale) { try await runtime.list(query: "LVM") }
        }
    }

    @Test func topicOverviewRechecksGrantAfterPreparingEvidence() async throws {
        try await withVault([record("Police", text: "Versicherungsschein")]) { fixture in
            let source = OverviewRevocationSource(profile: fixture.profile)
            let runtime = ReadOnlyMCPRuntime(profiles: source)
            await #expect(throws: MCPAccessError.stale) {
                try await runtime.topicOverview(query: nil, topic: "insurance", cursor: nil)
            }
        }
    }

    @Test func fieldExtractionRechecksGrantAfterPreparingEvidence() async throws {
        try await withVault([record("Vertrag", text: "Leasingvertrag\nMonatsrate: 249,99 EUR")]) { fixture in
            let source = OverviewRevocationSource(profile: fixture.profile, revokeAt: 4)
            let runtime = ReadOnlyMCPRuntime(profiles: source)
            let page = try await runtime.list(includeExcerpts: false)
            let handle = try #require(page.items.first?.document)
            await #expect(throws: MCPAccessError.stale) {
                try await runtime.extractFields(documents: [handle], fields: nil, cursor: nil)
            }
        }
    }

    @Test func contractComparisonRechecksGrantBeforeReleasingEvidence() async throws {
        let header = "Leasingvertrag\nAussteller: Testwerk GmbH\nVertragsnummer: TEST-721\n"
        try await withVault([record("Vorher", text: header + "Monatsrate: 200 EUR"),
                             record("Nachher", text: header + "Monatsrate: 250 EUR")]) { fixture in
            let source = OverviewRevocationSource(profile: fixture.profile, revokeAt: 4)
            let runtime = ReadOnlyMCPRuntime(profiles: source)
            let handles = try await runtime.list(includeExcerpts: false).items.map(\.document)
            #expect(handles.count == 2)
            await #expect(throws: MCPAccessError.stale) {
                try await runtime.compareContractVersions(before: handles[0], after: handles[1])
            }
        }
    }

    @Test func deadlineOverviewRechecksGrantBeforeReleasingEvidence() async throws {
        let text = "Leasingvertrag\nVertragsende: 15.04.2027\nKündigungsfrist: 1 Monat vor Vertragsende"
        try await withVault([record("Testvertrag", text: text)]) { fixture in
            let source = OverviewRevocationSource(profile: fixture.profile, revokeAt: 4)
            let runtime = ReadOnlyMCPRuntime(profiles: source)
            let page = try await runtime.list(includeExcerpts: false)
            let handle = try #require(page.items.first?.document)
            await #expect(throws: MCPAccessError.stale) {
                try await runtime.deadlineOverview(documents: [handle])
            }
        }
    }
}

private final class OverviewRevocationSource: MCPProfileSource, @unchecked Sendable {
    private let profile: MCPAccessProfile
    private let lock = NSLock()
    private var reads = 0
    private let revokeAt: Int

    init(profile: MCPAccessProfile, revokeAt: Int = 3) { self.profile = profile; self.revokeAt = revokeAt }

    func load() throws -> MCPAccessProfile {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        guard reads >= revokeAt else { return profile }
        var revoked = profile
        revoked.enabled = false
        return revoked
    }
}

private func record(_ title: String, text: String? = nil) -> VaultDocument {
    VaultDocument(title: title, sourceName: title + ".pdf", ocrText: "--- Seite 1 ---\n" + (text ?? title), pageCount: 1)
}
private struct RetrievalFixture: Sendable {
    let vault: URL
    let profileURL: URL
    let profile: MCPAccessProfile
    let runtime: ReadOnlyMCPRuntime
    func write(_ documents: [VaultDocument]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(documents).write(to: vault, options: .atomic)
    }
}
private func withVault(_ documents: [VaultDocument], allowed: Set<UUID>? = nil,
                       body: (RetrievalFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-p0-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = root.appendingPathComponent("documents.json"), profileURL = root.appendingPathComponent("profile.json")
    let profile = MCPAccessProfile(vaultPath: vault.path, allowedDocumentIDs: allowed ?? Set(documents.map(\.id)),
                                   enabled: true, acknowledgedCloudDisclosure: true)
    let f = RetrievalFixture(vault: vault, profileURL: profileURL, profile: profile,
                             runtime: ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: profileURL)))
    try FileMCPProfileSource(url: profileURL).save(profile); try f.write(documents)
    let before = try Data(contentsOf: vault)
    try await body(f)
    // Mutation tests restore or deliberately replace their synthetic records only.
    if documents.count > 10 { #expect(try Data(contentsOf: vault) == before) }
}
