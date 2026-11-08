import Foundation
import Testing
@testable import VauldyCore
@testable import VauldyMCPRuntime

@Suite("R3 JSON storage boundaries")
struct StorageBoundaryTests {
    @Test func streamingReaderPreservesEscapesUnicodeNestedModelsAndChunkEdges() throws {
        try withStorageFixture { root in
            let file = root.appendingPathComponent("documents.json")
            let documents = (0..<5).map { index in
                VaultDocument(title: "Beleg \(index)", sourceName: "synthetic.pdf",
                    ocrText: String(repeating: "Ä { [ \\\" } ] \n 📝 ", count: 6000), pageCount: 1)
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode(documents); try bytes.write(to: file)
            let source = FileVaultSnapshotSource(fileURL: file)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let legacy = try decoder.decode([VaultDocument].self, from: bytes)
            #expect(try source.loadDocuments() == legacy)
            #expect(try source.loadDocuments(allowedIDs: [documents[2].id]) == [legacy[2]])
            // Every grammar error must fail, even after a valid selected record.
            for data in [Data(bytes.dropLast()), bytes + Data("x".utf8),
                         Data("[".utf8) + Data(bytes.dropFirst().dropLast()) + Data(",]".utf8),
                         Data("{}".utf8), Data("[null]".utf8)] {
                try data.write(to: file)
                #expect(throws: VaultSnapshotError.invalidFormat) { try source.loadDocuments(allowedIDs: []) }
            }
            try encoder.encode([documents[0], documents[1], documents[1]]).write(to: file)
            #expect(throws: VaultSnapshotError.invalidFormat) { try source.loadDocuments(allowedIDs: [documents[0].id]) }
        }
    }

    @Test func scopedCacheBudgetAndSelectionChangeKeepAuthority() throws {
        try withStorageFixture { root in
            let file = root.appendingPathComponent("documents.json")
            let small = VaultDocument(title: "Klein", sourceName: "synthetic.pdf")
            let large = VaultDocument(title: "Groß", sourceName: "synthetic.pdf", ocrText: String(repeating: "Text ", count: 5000))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode([small, large]); try bytes.write(to: file)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let legacy = try decoder.decode([VaultDocument].self, from: bytes)
            var cache = MCPVaultSnapshotCache(maximumBytes: 4096)
            for _ in 0..<3 { #expect(try cache.load(file.path, allowedIDs: [small.id]).documents == [legacy[0]]) }
            #expect(cache.decodeCount == 1 && cache.retainsDocuments)
            #expect(try cache.load(file.path, allowedIDs: [large.id]).documents == [legacy[1]])
            #expect(cache.decodeCount == 2 && !cache.retainsDocuments)
            #expect(try cache.load(file.path, allowedIDs: []).documents.isEmpty)
            #expect(cache.decodeCount == 3)
            // An atomic replacement invalidates even an empty cache selection.
            try encoder.encode([small]).write(to: file, options: .atomic)
            #expect(try cache.load(file.path, allowedIDs: []).documents.isEmpty)
            #expect(cache.decodeCount == 4)
        }
    }

    @Test func uncachedFullSelectionNeverSurvivesGrantOrSourceChange() throws {
        try withStorageFixture { root in
            let file = root.appendingPathComponent("documents.json")
            let first = VaultDocument(title: "Freigegeben", sourceName: "test.pdf", ocrText: String(repeating: "Text ", count: 2000))
            let second = VaultDocument(title: "Nicht freigegeben", sourceName: "test.pdf")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([first]).write(to: file)
            var cache = MCPVaultSnapshotCache(maximumBytes: 4096)
            for _ in 0..<3 { #expect(try cache.load(file.path, allowedIDs: [first.id]).documents.map(\.id) == [first.id]) }
            #expect(cache.decodeCount == 3 && !cache.retainsDocuments)
            try encoder.encode([first, second]).write(to: file, options: .atomic)
            #expect(try cache.load(file.path, allowedIDs: [first.id]).documents.map(\.id) == [first.id])
            #expect(try cache.load(file.path, allowedIDs: []).documents.isEmpty)
            #expect(try cache.load(file.path, allowedIDs: [second.id]).documents.map(\.id) == [second.id])
        }
    }

    @Test func oversizedFileHasExplicitErrorWithoutAllocation() async throws {
        let root = try storageRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("documents.json")
        try Data("[]".utf8).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(VaultStorageLimits.snapshotBytes + 1)); try handle.close()
        #expect(throws: VaultSnapshotError.tooLarge) { try FileVaultSnapshotSource(fileURL: file).loadDocuments() }
        let source = try storageProfile(root, file: file, ids: [UUID()])
        let runtime = ReadOnlyMCPRuntime(profiles: source)
        await #expect(throws: MCPAccessError.tooLarge) { try await runtime.list(includeExcerpts: false) }
    }

    @Test func twentyThousandAndOneRecordsWithOneGrantRemainReadableAndRevocable() async throws {
        let root = try storageRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("documents.json")
        let documents = (0..<20_001).map { VaultDocument(title: "Beleg \($0)", sourceName: "synthetic.pdf", ocrText: "Versicherung") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(documents).write(to: file)
        let source = try storageProfile(root, file: file, ids: [documents[0].id])
        let runtime = ReadOnlyMCPRuntime(profiles: source)
        let first = try await runtime.list(query: "Versicherung", includeExcerpts: false)
        #expect(first.totalCount == 1)
        let handle = try #require(first.items.first?.document)
        #expect(try await runtime.list(includeExcerpts: false).totalCount == 1)
        #expect(await runtime.snapshotDecodeCount == 1)
        var profile = try source.load(); profile.enabled = false; profile.revision = UUID(); try source.save(profile)
        await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.read(document: handle) }
    }

    @Test func snapshotBytePreflightPreservesBackupAndDoesNotCopyOriginal() async throws {
        let root = try storageRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDocumentStore(root: root.appendingPathComponent("store"))
        _ = try await store.documents()
        var documents = (0..<500).map { index -> VaultDocument in
            var document = VaultDocument(title: "Beleg \(index)", sourceName: "synthetic.pdf",
                ocrText: String(repeating: "x", count: 267_000))
            document.localImport = LocalImportMetadata(contentHash: String(format: "%064x", index), fileExtension: "pdf")
            return document
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let initialSize = try encoder.encode(documents).count
        let remaining = VaultStorageLimits.snapshotBytes - initialSize
        #expect(remaining > 0)
        for index in documents.indices {
            documents[index].ocrText += String(repeating: "x", count: remaining / 500 + (index == 0 ? remaining % 500 : 0))
        }
        let bytes = try encoder.encode(documents)
        #expect(bytes.count == VaultStorageLimits.snapshotBytes)
        try bytes.write(to: store.snapshotURL)
        let backup = store.root.appendingPathComponent("documents.backup.json")
        try Data("previous backup".utf8).write(to: backup)
        let file = root.appendingPathComponent("next.pdf"); try Data("synthetic not yet OCR".utf8).write(to: file)
        await #expect(throws: LocalStoreCapacityError.snapshotBytes) { try await store.stage(file: file) }
        #expect(try Data(contentsOf: store.snapshotURL) == bytes)
        #expect(try Data(contentsOf: backup) == Data("previous backup".utf8))
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("originals").path))
    }

    @Test func importCountPreflightPreservesSnapshotBackupAndOriginals() async throws {
        let root = try storageRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDocumentStore(root: root.appendingPathComponent("store"))
        _ = try await store.documents()
        let documents = (0..<20_000).map { index -> VaultDocument in
            var document = VaultDocument(title: "Beleg \(index)", sourceName: "synthetic.pdf")
            document.localImport = LocalImportMetadata(contentHash: String(format: "%064x", index), fileExtension: "pdf")
            return document
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(documents); try bytes.write(to: store.snapshotURL)
        let backup = store.root.appendingPathComponent("documents.backup.json")
        try Data("previous backup".utf8).write(to: backup)
        let file = root.appendingPathComponent("next.pdf"); try Data("synthetic not yet OCR".utf8).write(to: file)
        await #expect(throws: LocalStoreCapacityError.documentCount) { try await store.stage(file: file) }
        #expect(try Data(contentsOf: store.snapshotURL) == bytes)
        #expect(try Data(contentsOf: backup) == Data("previous backup".utf8))
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("originals").path))
    }
}

private func storageRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-r3-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}
private func withStorageFixture(_ body: (URL) throws -> Void) throws {
    let root = try storageRoot(); defer { try? FileManager.default.removeItem(at: root) }; try body(root)
}
private func storageProfile(_ root: URL, file: URL, ids: Set<UUID>) throws -> FileMCPProfileSource {
    let source = FileMCPProfileSource(url: root.appendingPathComponent("profile.json"))
    var profile = MCPAccessProfile(vaultPath: file.path)
    profile.enabled = true; profile.acknowledgedCloudDisclosure = true; profile.allowedDocumentIDs = ids
    try source.save(profile); return source
}
