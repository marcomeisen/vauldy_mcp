import Foundation
import SQLite3
import Testing
import VauldyCore
@testable import VauldyMCPRuntime

@Suite("MCP scaling, candidate retrieval and cache authority")
struct MCPScalabilityTests {
    @Test func compactEnumerationOfTwoThousandDocumentsSkipsPrivacyButKeepsReadAuthority() async throws {
        try await withScalingFixture { root in
            let documents = (0..<2000).map { index in
                VaultDocument(title: "Private title Erika Musterfrau", sourceName: "secret-file-\(index).pdf",
                              ocrText: "--- Seite 1 ---\nBeleg \(index)\nName: Erika Musterfrau\nE-Mail: erika@example.com", pageCount: 1)
            }
            let fixture = try ScalingFixture(root: root, documents: documents)
            let runtime = fixture.runtime
            var page = try await runtime.list(pageSize: 100, includeExcerpts: false)
            let handle = try #require(page.items.first?.document)
            var handles = Set(page.items.map(\.document)), calls = 1
            while let cursor = page.nextCursor {
                page = try await runtime.list(cursor: cursor)
                handles.formUnion(page.items.map(\.document)); calls += 1
                #expect(page.items.allSatisfy { $0.title == "Freigegebenes Dokument" && $0.excerpt.isEmpty && $0.page == nil })
            }
            #expect(handles.count == 2000 && calls == 20 && page.retrievalComplete)
            #expect(await runtime.privacyBuildCount == 0)
            #expect(await runtime.snapshotDecodeCount == 1)
            let read = try await runtime.read(document: handle)
            let text = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
            #expect(!text.contains("erika@example.com") && !text.contains("Erika Musterfrau"))
            #expect(await runtime.privacyBuildCount == 1)
            try fixture.pause()
            await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.read(document: handle) }
        }
    }

    @Test(arguments: [("versicher polic pension", "Krankenversicherung", "Police"),
                       ("rechn kostenvoranschlag", "Handwerkerrechnung", "Kostenvoranschlag"),
                       ("einkommen lohnsteuer", "Einkommensteuerbescheid", "Lohnsteuerbescheinigung"),
                       ("befund rezept", "Arztbefund", "Privatrezept")])
    func genericOrCandidatesKeepExactDefaultAndBindEveryCursor(example: (String, String, String)) async throws {
        try await withScalingFixture { root in
            let documents = (0..<60).map { index in
                VaultDocument(title: "Beleg", sourceName: "source", ocrText: index < 30 ? example.1 : example.2)
            } + [VaultDocument(title: "Fremd", sourceName: "foreign", ocrText: "Unabhängige Terminnotiz")]
            let fixture = try ScalingFixture(root: root, documents: documents)
            let first = try await fixture.runtime.list(query: example.0, pageSize: 25, matchMode: .anyTermSubstring, includeExcerpts: false)
            #expect(first.totalCount == 60)
            #expect(first.warnings.contains("BROAD_TEXT_CANDIDATES_NOT_CLASSIFICATION"))
            let cursor = try #require(first.nextCursor)
            await #expect(throws: MCPAccessError.invalidArguments) { try await fixture.runtime.list(cursor: cursor, matchMode: .allTokens) }
            await #expect(throws: MCPAccessError.invalidArguments) { try await fixture.runtime.list(cursor: cursor, includeExcerpts: true) }
            var page = try await fixture.runtime.list(cursor: cursor), ids = Set(first.items.map(\.document))
            ids.formUnion(page.items.map(\.document))
            while let next = page.nextCursor { page = try await fixture.runtime.list(cursor: next); ids.formUnion(page.items.map(\.document)) }
            #expect(ids.count == 60 && page.retrievalComplete)
            #expect(try await fixture.runtime.list(query: example.0).items.isEmpty)
            await #expect(throws: MCPAccessError.invalidArguments) { try await fixture.runtime.list(pageSize: 26) }
            await #expect(throws: MCPAccessError.invalidArguments) { try await fixture.runtime.list(query: "ab", matchMode: .anyTermSubstring) }
        }
    }

    @Test func sqliteTokenPilotPreservesTextMatchingAndRevocation() async throws {
        try await withScalingFixture { root in
            var document = documentWithText("Käse Rechnung")
            let nearMatch = documentWithText("Käse Rechnungen")
            let fixture = try ScalingFixture(root: root, documents: [document, nearMatch], experimentalSQLiteIndex: true)
            let runtime = fixture.runtime
            try fixture.save([document, nearMatch, documentWithText("Käse Rechnung ohne Freigabe")])

            let result = try await runtime.list(query: "KÄSE rechnung", includeExcerpts: false)
            #expect(result.totalCount == 1)
            #expect(await runtime.hasSQLiteTokenIndex)
            let handle = try #require(result.items.first?.document)
            #expect(try await runtime.list(query: "rechn", matchMode: .anyTermSubstring).totalCount == 2)

            document.ocrText = "Brot Quittung"
            try fixture.save([document, nearMatch], atomic: true)
            #expect(try await runtime.list(query: "Käse Rechnung").totalCount == 0)
            #expect(try await runtime.list(query: "Brot Quittung").totalCount == 1)
            await #expect(throws: MCPAccessError.stale) { try await runtime.read(document: handle) }
            try fixture.pause()
            await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.list(query: "Brot") }
            #expect(await !runtime.hasSQLiteTokenIndex)
        }
    }

    @Test func sqliteTokenUpdateCommitsOnlyChangedRowsAndRollsBackFailedReconcile() throws {
        let index = try SQLiteVaultTokenIndex()
        var first = documentWithText("Brot")
        let second = documentWithText("Käse")
        let initial = [(first, Data([1])), (second, Data([2]))]
        #expect(try index.reconcile(initial) == 2)
        #expect(try index.reconcile(initial) == 0)
        #expect(try index.matchingIDs(for: "Käse") == [second.id])

        first.ocrText = String(repeating: "a", count: 4097)
        #expect(throws: (any Error).self) { try index.reconcile([(first, Data([3]))]) }
        #expect(try index.matchingIDs(for: "Brot") == [first.id])
        #expect(try index.matchingIDs(for: "Käse") == [second.id])

        first.ocrText = "Milch"
        #expect(try index.reconcile([(first, Data([4]))]) == 2)
        #expect(try index.matchingIDs(for: "Brot").isEmpty)
        #expect(try index.matchingIDs(for: "Käse").isEmpty)
        #expect(try index.matchingIDs(for: "Milch") == [first.id])
    }

    @Test func persistentSQLiteReusesUpdatesRebuildsAndPurgesItsPrivateCache() async throws {
        try await withScalingFixture { root in
            var document = documentWithText("Käse Rechnung")
            let second = documentWithText("Käse Rechnungen")
            let fixture = try ScalingFixture(root: root, documents: [document, second])
            let source = FileMCPProfileSource(url: fixture.profileURL)
            func runtime() -> ReadOnlyMCPRuntime {
                ReadOnlyMCPRuntime(profiles: source, indexFeatures: [.persistentTokenIndex])
            }
            let first = runtime()
            #expect(try await first.list(query: "Käse Rechnung", includeExcerpts: false).totalCount == 1)
            let directory = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".vauldy-index-") })
            let database = directory.appendingPathComponent("index-v1.sqlite")
            try #require(FileManager.default.fileExists(atPath: database.path), "First build published a database")
            let initial = try Data(contentsOf: database)
            #expect(initial.starts(with: Data("SQLite format 3".utf8)))
            #expect(initial.range(of: Data("Rechnung".utf8)) == nil)
            let mode = try FileManager.default.attributesOfItem(atPath: database.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)

            let reopened = runtime()
            #expect(try await reopened.list(query: "Käse Rechnung", includeExcerpts: false).totalCount == 1)
            try #require(FileManager.default.fileExists(atPath: database.path), "Reopened database exists")
            #expect(try Data(contentsOf: database) == initial)
            let inode = try MCPFileVersion(database).inode

            document.ocrText = "Brot Quittung"
            try fixture.save([document, second], atomic: true)
            #expect(try await reopened.list(query: "Käse Rechnung", includeExcerpts: false).totalCount == 0)
            #expect(try await reopened.list(query: "Brot Quittung", includeExcerpts: false).totalCount == 1)
            #expect(try MCPFileVersion(database).inode == inode)

            // A structurally valid FTS edit still fails the cache's payload-digest validation.
            try replaceIndexTokens(database)
            let interrupted = directory.appendingPathComponent(".build-" + UUID().uuidString)
            try Data("partial build".utf8).write(to: interrupted)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: interrupted.path)
            let rebuilt = runtime()
            #expect(try await rebuilt.list(query: "Brot Quittung", includeExcerpts: false).totalCount == 1)
            #expect(try MCPFileVersion(database).inode != inode)
            #expect(!FileManager.default.fileExists(atPath: interrupted.path))

            let before = try Data(contentsOf: fixture.vault)
            try Data("corrupt sqlite file".utf8).write(to: database)
            #expect(try await rebuilt.list(query: "Brot Quittung", includeExcerpts: false).totalCount == 1)
            #expect(try Data(contentsOf: database).starts(with: Data("SQLite format 3".utf8)))
            #expect(try Data(contentsOf: fixture.vault) == before)
            try fixture.pause()
            #expect(!FileManager.default.fileExists(atPath: database.path))
            await #expect(throws: MCPAccessError.notAuthorized) { try await rebuilt.list(query: "Brot") }
        }
    }

    @Test func compactProjectionPreservesCoverageAndStopsWhenTheSourceOrGrantChanges() async throws {
        try await withScalingFixture { root in
            var document = VaultDocument(title: "Beleg", sourceName: "source", ocrText: "--- Seite 1 ---\nBrot", pageCount: 1)
            let second = documentWithText("Käse")
            let fixture = try ScalingFixture(root: root, documents: [document, second])
            let projected = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: fixture.profileURL),
                                               indexFeatures: [.compactProjection])
            let expected = try await fixture.runtime.list(pageSize: 1, includeExcerpts: false)
            let actual = try await projected.list(pageSize: 1, includeExcerpts: false)
            let next = try #require(actual.nextCursor)
            let expectedCursor = try #require(expected.nextCursor)
            let expectedNext = try await fixture.runtime.list(cursor: expectedCursor)
            let actualNext = try await projected.list(cursor: next)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #expect(try encoder.encode(expected.coverage) == encoder.encode(actual.coverage))
            #expect(actual.warnings == expected.warnings)
            #expect(actual.items.first?.processingStatus == expected.items.first?.processingStatus)
            #expect(actualNext.items.first?.sourceCoverage == expectedNext.items.first?.sourceCoverage)
            #expect(actualNext.retrievalComplete)
            let handle = try #require(actual.items.first?.document)
            #expect(try await projected.read(document: handle).document == handle)

            document.ocrText = "geändert"
            try fixture.save([document, second], atomic: true)
            await #expect(throws: MCPAccessError.stale) { try await projected.list(cursor: next) }
            let fresh = try await projected.list(pageSize: 1, includeExcerpts: false)
            let current = try #require(fresh.nextCursor)
            try fixture.pause()
            await #expect(throws: MCPAccessError.notAuthorized) { try await projected.list(cursor: current) }
        }
    }

    @Test func sameSizeEditWithRestoredModificationDateInvalidatesSnapshotCursorAndHandle() async throws {
        try await withScalingFixture { root in
            var document = VaultDocument(title: "Beleg", sourceName: "source", ocrText: "Fahrrad")
            let fixture = try ScalingFixture(root: root, documents: [document, documentWithText("Andere Unterlage")])
            let first = try await fixture.runtime.list(query: "Fahrrad", includeExcerpts: false)
            let handle = try #require(first.items.first?.document)
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.vault.path)
            let before = try Data(contentsOf: fixture.vault)
            document.ocrText = "Schrank"
            var documents = fixture.documents; documents[0] = document
            try fixture.save(documents)
            #expect(try Data(contentsOf: fixture.vault).count == before.count)
            try FileManager.default.setAttributes([.modificationDate: try #require(attributes[.modificationDate])], ofItemAtPath: fixture.vault.path)
            await #expect(throws: MCPAccessError.stale) { try await fixture.runtime.read(document: handle) }
            #expect(try await fixture.runtime.list(query: "Fahrrad").totalCount == 0)
            #expect(try await fixture.runtime.list(query: "Schrank").totalCount == 1)
            #expect(await fixture.runtime.snapshotDecodeCount == 2)
        }
    }

    @Test func sourceReplacementInvalidatesListAndCorruptionCannotUseCachedContent() async throws {
        try await withScalingFixture { root in
            let fixture = try ScalingFixture(root: root, documents: [documentWithText("Erster Beleg"), documentWithText("Zweiter Beleg")])
            let first = try await fixture.runtime.list(pageSize: 1, includeExcerpts: false)
            let cursor = try #require(first.nextCursor)
            let handle = try #require(first.items.first?.document)
            try fixture.save([documentWithText("Neuer Beleg")], atomic: true)
            await #expect(throws: MCPAccessError.stale) { try await fixture.runtime.list(cursor: cursor) }
            try Data("[corrupt".utf8).write(to: fixture.vault)
            await #expect(throws: MCPAccessError.unavailable) { try await fixture.runtime.read(document: handle) }
            try FileManager.default.removeItem(at: fixture.vault)
            await #expect(throws: MCPAccessError.unavailable) { try await fixture.runtime.status() }
            try fixture.save(fixture.documents)
            await #expect(throws: MCPAccessError.stale) { try await fixture.runtime.read(document: handle) }
            #expect(try await fixture.runtime.status().grantedDocumentCount == 2)
        }
    }

    @Test func sourceChangesAtFinalPermissionCheckSuppressTheResponse() async throws {
        try await withScalingFixture { root in
            let fixture = try ScalingFixture(root: root, documents: [documentWithText("Erster Beleg")])
            let replacement = try fixture.encoded([documentWithText("Geänderter Beleg")])
            let source = ChangingProfileSource(profile: fixture.profile, file: fixture.vault, replacement: replacement)
            let runtime = ReadOnlyMCPRuntime(profiles: source)
            await #expect(throws: MCPAccessError.stale) { try await runtime.status() }
            #expect(try await runtime.status().grantedDocumentCount == 0)
        }
    }
}

private func replaceIndexTokens(_ url: URL) throws {
    var connection: OpaquePointer?
    try #require(sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    try #require(sqlite3_exec(connection, "UPDATE tokens SET body = 'damaged'", nil, nil, nil) == SQLITE_OK)
}

private func documentWithText(_ text: String) -> VaultDocument { .init(title: "Beleg", sourceName: "source", ocrText: text) }
private struct ScalingFixture {
    let documents: [VaultDocument]
    let vault: URL
    let profileURL: URL
    let profile: MCPAccessProfile
    let runtime: ReadOnlyMCPRuntime
    init(root: URL, documents: [VaultDocument], experimentalSQLiteIndex: Bool = false) throws {
        self.documents = documents; vault = root.appendingPathComponent("documents.json"); profileURL = root.appendingPathComponent("profile.json")
        profile = MCPAccessProfile(vaultPath: vault.path, allowedDocumentIDs: Set(documents.map(\.id)), enabled: true, acknowledgedCloudDisclosure: true)
        runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: profileURL),
                                     experimentalSQLiteIndex: experimentalSQLiteIndex)
        try FileMCPProfileSource(url: profileURL).save(profile); try save(documents)
    }
    func encoded(_ documents: [VaultDocument]) throws -> Data { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(documents) }
    func save(_ documents: [VaultDocument], atomic: Bool = false) throws { try encoded(documents).write(to: vault, options: atomic ? .atomic : []) }
    func pause() throws { var next = profile; next.enabled = false; next.revision = UUID(); try FileMCPProfileSource(url: profileURL).save(next) }
}
private final class ChangingProfileSource: MCPProfileSource, @unchecked Sendable {
    let lock = NSLock()
    let profile: MCPAccessProfile
    let file: URL
    let replacement: Data
    var loads = 0
    init(profile: MCPAccessProfile, file: URL, replacement: Data) { self.profile = profile; self.file = file; self.replacement = replacement }
    func load() throws -> MCPAccessProfile {
        lock.lock(); defer { lock.unlock() }; loads += 1
        if loads == 2 { try replacement.write(to: file, options: .atomic) }
        return profile
    }
}
private func withScalingFixture(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-scaling-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}
