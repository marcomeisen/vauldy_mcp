import Foundation
import Testing
@testable import VauldyCore
@testable import VauldyMCPRuntime
@testable import VauldyRelay

@Suite("Explicit primary SQLite activation")
struct SQLitePrimaryActivationTests {
    private enum Injected: Error { case interruption }

    @Test func logicalGrantAndCacheFollowSQLiteWithoutJSONFallbackOrScopeExpansion() async throws {
        try await fixture { root, store, prepared, token in
            let originals = try await store.documents(), logical = store.snapshotURL
            let allowed = Set(originals.prefix(2).map(\.id))
            let profile = MCPAccessProfile(vaultPath: logical.path, allowedDocumentIDs: allowed,
                                           enabled: true, acknowledgedCloudDisclosure: true)
            let profileURL = root.appendingPathComponent("profile.json")
            let profiles = FileMCPProfileSource(url: profileURL); try profiles.save(profile)
            let profileBytes = try Data(contentsOf: profileURL)
            var credentials = RelayCredentials(serviceToken: "synthetic-service")
            credentials.paired = true; credentials.profileID = profile.connectionID; credentials.revision = profile.revision
            credentials.profileFingerprint = try RelayCredentials.fingerprint(profile)
            let oldFingerprint = try profile.disclosureFingerprint()
            var cache = MCPVaultSnapshotCache()
            let old = try cache.load(logical.path, allowedIDs: allowed)
            let runtime = ReadOnlyMCPRuntime(profiles: profiles)
            let first = try await runtime.list(pageSize: 1, includeExcerpts: false)
            let cursor = try #require(first.nextCursor)
            let result = try LocalStorageMigration(source: store.root).activateSQLite(from: prepared, expected: token)
            #expect(result.verified && result.storage == "sqlite" && !result.profilesChanged)
            #expect(store.storageKind == "sqlite" && store.snapshotURL.lastPathComponent == "records.sqlite")
            #expect(!FileManager.default.fileExists(atPath: logical.path))
            #expect(LocalVaultSnapshotSource(fileURL: logical).fileURL == store.snapshotURL)
            #expect(try Data(contentsOf: profileURL) == profileBytes)
            #expect(try profiles.load().disclosureFingerprint() == oldFingerprint)
            #expect(try RelayCredentials.fingerprint(profile) == credentials.profileFingerprint)
            #expect(try Set(LocalVaultSnapshotSource(fileURL: logical).loadDocuments().map(\.id)) == Set(originals.map(\.id)))
            #expect(try LocalInventoryFingerprint.snapshot(logical) == LocalInventoryFingerprint.snapshot(store.snapshotURL))
            let fresh = try cache.load(logical.path, allowedIDs: allowed)
            #expect(fresh.version != old.version && Set(fresh.documents.map(\.id)) == allowed)
            await #expect(throws: MCPAccessError.stale) { try await runtime.list(cursor: cursor) }
            #expect(try await runtime.list(includeExcerpts: false).totalCount == allowed.count)
            try store.locked {
                var values = try store.read(ids: allowed); values[0].title = "Neue SQLite-Fassung"
                try store.save(values)
            }
            #expect(!FileManager.default.fileExists(atPath: logical.path))
            #expect(try cache.load(logical.path, allowedIDs: allowed).documents.contains { $0.title == "Neue SQLite-Fassung" })
            #expect(try Data(contentsOf: profileURL) == profileBytes)
        }
    }

    @Test(arguments: ["prepared", "marker-published"])
    func failureRollsBackUnderLocksWithoutLosingJSONOrOriginals(phase: String) async throws {
        try await fixture { _, store, prepared, token in
            let before = try await store.documents(), bytes = try Data(contentsOf: store.snapshotURL)
            #expect(throws: Injected.interruption) {
                try LocalStorageMigration(source: store.root).activateSQLite(from: prepared, expected: token) {
                    if $0 == phase { throw Injected.interruption }
                }
            }
            #expect(store.storageKind == "json-snapshot")
            #expect(try Data(contentsOf: store.snapshotURL) == bytes)
            #expect(try await store.documents() == before)
            #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("SQLITE_ACTIVATION_PENDING").path))
        }
    }

    @Test func reconstructedCrashStateBlocksReadersAndRecoversLosslessly() async throws {
        try await fixture { _, store, prepared, token in
            let before = try await store.documents()
            var interrupted: [String: Data] = [:]
            #expect(throws: Injected.interruption) {
                try LocalStorageMigration(source: store.root).activateSQLite(from: prepared, expected: token) {
                    if $0 == "marker-published" { interrupted = try snapshot(store.root); throw Injected.interruption }
                }
            }
            try restore(interrupted, at: store.root)
            #expect(store.storageKind == "sqlite")
            await #expect(throws: LocalImportError.storageUnavailable) { try await store.documents() }
            #expect(throws: VaultSnapshotError.unreadable) { try LocalVaultSnapshotSource(fileURL: store.root.appendingPathComponent("documents.json")).loadDocuments() }
            let recovered = try LocalStorageMigration(source: store.root).recoverSQLiteActivation()
            #expect(recovered.storage == "json-snapshot" && recovered.verified)
            #expect(try await store.documents() == before)
        }
    }

    @Test func recoveryNeverDiscardsUnexpectedLaterSQLWrites() async throws {
        try await fixture { _, store, prepared, token in
            var interrupted: [String: Data] = [:]
            #expect(throws: Injected.interruption) {
                try LocalStorageMigration(source: store.root).activateSQLite(from: prepared, expected: token) {
                    if $0 == "marker-published" { interrupted = try snapshot(store.root); throw Injected.interruption }
                }
            }
            try restore(interrupted, at: store.root)
            let db = try SQLiteDocumentStore(directory: store.root.appendingPathComponent("sqlite"))
            let old = try #require(db.documents().first); var changed = old; changed.title = "Nicht verwerfen"
            try db.replace(changed, ifCurrent: old)
            #expect(throws: LocalStorageMigration.Failure.verification) { try LocalStorageMigration(source: store.root).recoverSQLiteActivation() }
            #expect(try db.document(id: changed.id)?.title == "Nicht verwerfen")
            #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("SQLITE_ACTIVATION_PENDING").path))
        }
    }

    @Test func stalePreviewAndModifiedPreparedCopyCannotBeActivated() async throws {
        try await fixture { _, store, prepared, token in
            let before = try Data(contentsOf: store.snapshotURL)
            let db = try SQLiteDocumentStore(directory: prepared.appendingPathComponent("vault/sqlite"))
            let old = try #require(db.documents().first); var changed = old; changed.title = "Fremde Änderung"
            try db.replace(changed, ifCurrent: old)
            #expect(throws: LocalStorageMigration.Failure.verification) { try LocalStorageMigration(source: store.root).activateSQLite(from: prepared, expected: token) }
            #expect(try Data(contentsOf: store.snapshotURL) == before)
            #expect(throws: LocalStorageMigration.Failure.changed) { try LocalStorageMigration(source: store.root).activateSQLite(from: prepared, expected: "stale") }
            #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("SQLITE_ACTIVATION_PENDING").path))
        }
    }

    @Test func markerAloneNeverFallsBackToAnOldJSONSnapshot() async throws {
        try await fixture { _, store, _, _ in
            let logical = store.snapshotURL
            try store.privateWrite(Data("{\"kind\":\"vauldy-local-core\",\"version\":4}".utf8), to: store.root.appendingPathComponent("store.json"))
            // A stale JSON file intentionally remains, but SQLite is missing.
            #expect(!LocalVaultSnapshotSource(fileURL: logical).isAvailable())
            #expect(throws: (any Error).self) { try LocalVaultSnapshotSource(fileURL: logical).loadDocuments() }
            await #expect(throws: LocalImportError.damagedStore) { try await store.documents() }
        }
    }

    private func fixture(_ run: (URL, LocalDocumentStore, URL, String) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-primary-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
        for i in 0..<3 {
            let file = root.appendingPathComponent("synthetic-\(i).pdf")
            try Data("synthetic original \(i)".utf8).write(to: file)
            _ = try await store.stage(file: file, storage: i == 2 ? .referenced : .managedCopy)
        }
        try store.locked {
            var records = try store.read()
            for i in records.indices {
                records[i].localImport?.state = .completed; records[i].localImport?.pages = [.init(page: 1, method: .embeddedText)]
                records[i].status = "ocrComplete"; records[i].pageCount = 1
                records[i].ocrText = "--- Seite 1 ---\nSynthetische Versicherung \(i) · Betrag: 13,80 €"
            }
            try store.save(records)
        }
        let migration = LocalStorageMigration(source: store.root), preview = try migration.preview(format: .sqlite)
        let prepared = root.appendingPathComponent("prepared")
        _ = try migration.transfer(to: prepared, format: .sqlite, expected: preview.fingerprint)
        try await run(root, store, prepared, preview.fingerprint)
    }
    private func snapshot(_ root: URL) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath()
        var files: [String: Data] = [:]
        for p in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects as! [URL] {
            if try p.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files[p.resolvingSymlinksInPath().pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")] = try Data(contentsOf: p) }
        }
        return files
    }
    private func restore(_ files: [String: Data], at root: URL) throws {
        _ = try #require(files["store.json"])
        _ = try #require(files["SQLITE_ACTIVATION_PENDING"])
        try FileManager.default.removeItem(at: root)
        for (name, data) in files {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
}
