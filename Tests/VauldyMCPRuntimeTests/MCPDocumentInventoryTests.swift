import Foundation
import CryptoKit
import Testing
@testable import VauldyCore
@testable import VauldyMCPRuntime

@Suite("Authorized stable document inventory")
struct MCPDocumentInventoryTests {
    private func document(_ seconds: Double?) -> VaultDocument {
        var d = VaultDocument(title: "Private synthetic title", sourceName: "private-source.pdf",
            importedAt: seconds.map(Date.init(timeIntervalSince1970:)) ?? .distantPast,
            ocrText: "--- Seite 1 ---\nPrivate synthetic content", pageCount: 1)
        var info = LocalImportMetadata(contentHash: String(repeating: "a", count: 64), fileExtension: "pdf")
        info.state = .completed; info.originalState = .available
        info.pages = [.init(page: 1, method: .vision)]
        d.localImport = info
        return d
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-inventory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ docs: [VaultDocument], to file: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(docs).write(to: file, options: .atomic)
    }
    private func profile(_ root: URL, vault: URL, docs: [VaultDocument]) throws -> FileMCPProfileSource {
        let profile = MCPAccessProfile(vaultPath: vault.path, allowedDocumentIDs: Set(docs.map(\.id)), enabled: true, acknowledgedCloudDisclosure: true)
        let source = FileMCPProfileSource(url: root.appendingPathComponent("profile.json"));try source.save(profile);return source
    }

    @Test(arguments: [false, true])
    func globallySortedBeforePaginationAndUnknownLast(sqlite: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let granted = [document(20),document(40),document(10),document(nil),document(40)]
        let hidden = document(1000)
        let vault: URL
        if sqlite {
            let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"));vault = store.snapshotURL
            try SQLiteDocumentStore(directory: vault.deletingLastPathComponent()).save(granted+[hidden])
        } else { vault = root.appendingPathComponent("documents.json");try write(granted+[hidden],to:vault) }
        let before = try Data(contentsOf: vault)
        let source = try profile(root,vault:vault,docs:granted), runtime = ReadOnlyMCPRuntime(profiles: source)
        var result = try await runtime.documentInventory(pageSize: 2)
        var items = result.items
        #expect(result.totalCount == 5 && result.items.count == 2 && !result.retrievalComplete)
        while let cursor = result.nextCursor { result = try await runtime.documentInventory(cursor:cursor);items += result.items }
        let tied = [granted[1],granted[4]].map { MCPDocumentIdentity.reference($0.id) }.sorted()
        #expect(items.map(\.documentID) == tied + [granted[0],granted[2],granted[3]].map { MCPDocumentIdentity.reference($0.id) })
        #expect(items.last?.importedAt == nil && result.retrievalComplete)
        #expect(items.allSatisfy { $0.contentHash == String(repeating:"a",count:64) })
        let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for privateValue in [root.path,hidden.id.uuidString.lowercased(),"Private synthetic","private-source.pdf"] { #expect(!wire.lowercased().contains(privateValue.lowercased())) }
        #expect(await runtime.privacyBuildCount == 0)
        if sqlite { #expect(await runtime.snapshotDecodeCount == 0) }
        #expect(try Data(contentsOf: vault) == before)
        let ascending = try await runtime.documentInventory(pageSize: 100,order:.importedAscending)
        #expect(ascending.items.first?.documentID == MCPDocumentIdentity.reference(granted[2].id))
        #expect(ascending.items.last?.importedAt == nil)
        if let path = ProcessInfo.processInfo.environment["VAULDY_DOCUMENT_INVENTORY_FIXTURES"] {
            let target = URL(fileURLWithPath: path).appendingPathComponent(sqlite ? "sqlite" : "json")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let exported: URL
            if sqlite {
                let directory = target.appendingPathComponent("vault")
                try FileManager.default.copyItem(at: vault.deletingLastPathComponent(), to: directory)
                exported = directory.appendingPathComponent(vault.lastPathComponent)
            } else {
                exported = target.appendingPathComponent("documents.json")
                try Data(contentsOf: vault).write(to: exported)
            }
            try JSONSerialization.data(withJSONObject: ["vault": exported.path,
                "granted": granted.map { $0.id.uuidString }, "hidden": hidden.id.uuidString,
                "origin": "controlled synthetic metadata; no OCR claim"], options: [.sortedKeys])
                .write(to: target.appendingPathComponent("fixture.json"))
        }
    }

    @Test func identitySurvivesRestartGrantRevisionAndSourceChangesButNeverAuthorizesRead() async throws {
        let root = try root();defer { try? FileManager.default.removeItem(at:root) }
        var docs = [document(30),document(20),document(nil)]
        let vault = root.appendingPathComponent("documents.json");try write(docs,to:vault)
        let source = try profile(root,vault:vault,docs:docs), old = ReadOnlyMCPRuntime(profiles:source)
        let first = try await old.documentInventory(pageSize:1), cursor = try #require(first.nextCursor)
        let item = try #require(first.items.first)
        let restarted = ReadOnlyMCPRuntime(profiles:source)
        let next = try #require(try await restarted.documentInventory(pageSize:1).items.first)
        #expect(item.documentID == next.documentID && item.document != next.document)
        await #expect(throws: MCPAccessError.self) { try await restarted.read(document:item.documentID) }
        docs[0].localImport?.originalState = .changed
        try write(docs,to:vault)
        await #expect(throws: MCPAccessError.self) { try await old.documentInventory(cursor:cursor) }
        let changed = try #require(try await old.documentInventory(pageSize:1).items.first)
        #expect(changed.documentID == item.documentID && changed.importedAt == item.importedAt)
        #expect(changed.contentHash == item.contentHash && changed.originalState == "changed")
        var grant = try source.load();grant.revision = UUID();try source.save(grant)
        let revised = try #require(try await old.documentInventory(pageSize:1).items.first)
        #expect(revised.documentID == item.documentID && revised.document != changed.document)
        grant.allowedDocumentIDs.remove(docs[0].id);grant.revision = UUID();try source.save(grant)
        let reduced = try await old.documentInventory()
        #expect(reduced.totalCount == 2 && !reduced.items.contains { $0.documentID == item.documentID })
        #expect(reduced.warnings.contains("MISSING_ROW_DOES_NOT_PROVE_DELETION"))
        await #expect(throws: MCPAccessError.self) { try await old.read(document:revised.document) }
        grant.enabled = false;grant.revision = UUID();try source.save(grant)
        await #expect(throws: MCPAccessError.self) { try await old.documentInventory() }
    }

    @Test func duplicateOriginalKeepsIDImportDateAndHashAndDifferentBytesKeepPriorRecord() async throws {
        let root = try root();defer { try? FileManager.default.removeItem(at:root) }
        let store = LocalDocumentStore(root:root.appendingPathComponent("vault")), file = root.appendingPathComponent("synthetic.pdf")
        let bytes = Data("synthetic original bytes".utf8);try bytes.write(to:file)
        let first = try await store.stage(file:file)
        let duplicate = try await store.stage(file:file)
        #expect(duplicate.duplicate && duplicate.document.id == first.document.id)
        #expect(duplicate.document.importedAt == first.document.importedAt)
        #expect(duplicate.document.localImport?.contentHash == LocalOriginalAccess.hash(bytes))
        try Data("a different synthetic version".utf8).write(to:file)
        let version = try await store.stage(file:file)
        #expect(!version.duplicate && version.document.id != first.document.id)
        let prior = try #require(try await store.document(id:first.document.id))
        #expect(prior.importedAt == first.document.importedAt && prior.localImport?.contentHash == LocalOriginalAccess.hash(bytes))
        #expect(try await store.documents().count == 2)
    }

    @Test func twentyThousandRowsStayOnSmallSQLiteProjections() async throws {
        let root = try root();defer { try? FileManager.default.removeItem(at:root) }
        let store = try LocalDocumentStore.createSQLite(at:root.appendingPathComponent("vault"))
        let docs = (0..<20_000).map { document(Double(1_700_000_000 + $0)) }
        try SQLiteDocumentStore(directory:store.snapshotURL.deletingLastPathComponent()).save(docs)
        let source = try profile(root,vault:store.snapshotURL,docs:docs)
        let runtime = ReadOnlyMCPRuntime(profiles:source)
        let newest = try await runtime.documentInventory(pageSize:5)
        #expect(newest.totalCount == 20_000)
        #expect(newest.items.map(\.documentID) == docs.suffix(5).reversed().map { MCPDocumentIdentity.reference($0.id) })
        #expect(await runtime.snapshotDecodeCount == 0)
        #expect(await runtime.privacyBuildCount == 0)
        if let path = ProcessInfo.processInfo.environment["VAULDY_DOCUMENT_INVENTORY_FIXTURES"] {
            let target = URL(fileURLWithPath:path).appendingPathComponent("large")
            try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:store.snapshotURL.deletingLastPathComponent(),to:target.appendingPathComponent("vault"))
            try JSONSerialization.data(withJSONObject:["vault":target.appendingPathComponent("vault").appendingPathComponent(store.snapshotURL.lastPathComponent).path,
                "granted":docs.map { $0.id.uuidString },"origin":"controlled synthetic metadata; real SQLite writer"],options:[.sortedKeys])
                .write(to:target.appendingPathComponent("fixture.json"))
        }
    }
}
