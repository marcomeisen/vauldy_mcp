import Foundation
import SQLite3
import CryptoKit
import Testing
@testable import VauldyCore
@testable import VauldyMCPRuntime

@Suite("R3c explicit storage migration and restore")
struct StorageMigrationTests {
    @Test func backupMigrationRestoreAndCurrentSQLiteRollbackPreserveAllRecords() async throws {
        try await fixture { root, store in
            let source = try await store.documents(), before = try tree(store.root)
            let migration = LocalStorageMigration(source: store.root)
            let preview = try migration.preview(format: .sqlite)
            #expect(preview.documents == 2 && preview.originalCopies == 1 && preview.referencedDocuments == 1)
            #expect(try tree(store.root) == before) // Preview is observational, including lock file bytes.
            let output = root.appendingPathComponent("migration")
            let result = try migration.transfer(to: output, format: .sqlite, expected: preview.fingerprint)
            #expect(result.verified && !result.profilesChanged)
            #expect(try tree(store.root) == before)
            let target = LocalDocumentStore(root: output.appendingPathComponent("vault"))
            #expect(target.storageKind == "sqlite")
            #expect(try equal(await target.documents(), source))
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: target.root.appendingPathComponent("store.json"))) as! [String: Any]
            #expect(marker["version"] as? Int == 3) // Legacy v1/v2-only writers cannot adopt this store.
            let copied = try #require(source.first { $0.localImport?.originalReference == nil })
            #expect(try Data(contentsOf: await target.original(for: copied.id)) == Data("synthetic managed original".utf8))
            let referenced = try #require(source.first { $0.localImport?.originalReference != nil })
            let access = try await target.openOriginal(for: referenced.id); defer { access.close() }
            #expect(try access.readData() == Data("synthetic external original".utf8))
            #expect(!FileManager.default.fileExists(atPath: target.root.appendingPathComponent("worker").path))

            let backup = LocalStorageMigration(source: URL(fileURLWithPath: result.backupPath))
            let backupBytes = try tree(URL(fileURLWithPath: result.backupPath))
            let restorePlan = try backup.preview(format: .same)
            let restored = root.appendingPathComponent("restored")
            _ = try backup.transfer(to: restored, format: .same, expected: restorePlan.fingerprint, restoringBackup: true)
            #expect(try equal(await LocalDocumentStore(root: restored.appendingPathComponent("vault")).documents(), source))
            #expect(try Data(contentsOf: restored.appendingPathComponent("vault/documents.json")) == before["documents.json"])
            #expect(try tree(URL(fileURLWithPath: result.backupPath)) == backupBytes)

            // A later SQLite edit must survive the return path, not be discarded by restoring the old backup.
            try target.locked {
                var records = try target.read(); records[0].ocrText += "\nNach der Migration hinzugefügt."
                try target.save(records)
            }
            let current = try await target.documents()
            let rollback = LocalStorageMigration(source: target.root), plan = try rollback.preview(format: .json)
            let returned = root.appendingPathComponent("returned")
            _ = try rollback.transfer(to: returned, format: .json, expected: plan.fingerprint)
            #expect(try equal(await LocalDocumentStore(root: returned.appendingPathComponent("vault")).documents(), current))
            #expect(try tree(store.root) == before)
        }
    }

    @Test func stalePreviewCapacityExistingTargetAndActiveWorkerRefuseBeforeCopy() async throws {
        try await fixture { root, store in
            let migration = LocalStorageMigration(source: store.root)
            let plan = try migration.preview(format: .sqlite)
            let output = root.appendingPathComponent("result")
            let noSpace = LocalStorageMigration(source: store.root, availableBytes: { _ in 0 })
            #expect(throws: LocalStorageMigration.Failure.capacity) { try noSpace.transfer(to: output, format: .sqlite, expected: plan.fingerprint) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(throws: LocalStorageMigration.Failure.unsafePath) { try migration.transfer(to: store.root, format: .sqlite, expected: plan.fingerprint) }
            let worker = store.root.appendingPathComponent("worker")
            try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let lease = try LocalWorkerLease(url: worker.appendingPathComponent("worker.lock"))
            #expect(throws: LocalStorageMigration.Failure.busy) { try migration.preview(format: .sqlite) }
            lease.release()
            try store.locked { var records = try store.read(); records[0].title = "Geändert"; try store.save(records) }
            #expect(throws: LocalStorageMigration.Failure.changed) { try migration.transfer(to: output, format: .sqlite, expected: plan.fingerprint) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func unknownFieldsCorruptOriginalAndCorruptBackupAreNeverSilentlyAccepted() async throws {
        try await fixture { root, store in
            let migration = LocalStorageMigration(source: store.root)
            let original = try Data(contentsOf: store.snapshotURL)
            var array = try JSONSerialization.jsonObject(with: original) as! [[String: Any]]
            array[0]["futureField"] = ["mustNotDisappear": true]
            try JSONSerialization.data(withJSONObject: array).write(to: store.snapshotURL)
            #expect(throws: LocalStorageMigration.Failure.incompatible) { try migration.preview(format: .sqlite) }
            try original.write(to: store.snapshotURL)
            let output = root.appendingPathComponent("result")
            let plan = try migration.preview(format: .sqlite)
            let result = try migration.transfer(to: output, format: .sqlite, expected: plan.fingerprint)
            let backupURL = URL(fileURLWithPath: result.backupPath)
            let backup = LocalStorageMigration(source: backupURL), restorePlan = try backup.preview(format: .same)
            try Data("damaged".utf8).write(to: backupURL.appendingPathComponent("documents.json"))
            #expect(throws: LocalStorageMigration.Failure.verification) {
                try backup.transfer(to: root.appendingPathComponent("restore"), format: .same, expected: restorePlan.fingerprint, restoringBackup: true)
            }
            let document = try #require(try await store.documents().first { $0.localImport?.originalReference == nil })
            try Data("changed copy".utf8).write(to: await store.original(for: document.id))
            #expect(throws: LocalStorageMigration.Failure.verification) { try migration.preview(format: .sqlite) }
        }
    }

    @Test func pendingJobsAndIncompleteTransfersCannotBecomeLiveStores() async throws {
        try await fixture { root, store in
            try store.locked { var records = try store.read(); records[0].localImport?.state = .queued; try store.save(records) }
            #expect(throws: LocalStorageMigration.Failure.busy) { try LocalStorageMigration(source: store.root).preview(format: .sqlite) }
            let pending = root.appendingPathComponent("interrupted")
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data().write(to: pending.appendingPathComponent("INCOMPLETE"))
            let target = try LocalDocumentStore.createSQLite(at: pending.appendingPathComponent("vault"))
            await #expect(throws: LocalImportError.foreignStore) { try await target.documents() }
            #expect(throws: VaultSnapshotError.unreadable) { try LocalVaultSnapshotSource(fileURL: target.snapshotURL).loadDocuments() }
            #expect(throws: LocalStorageMigration.Failure.incompatible) { try LocalStorageMigration(source: target.root).preview(format: .json) }
        }
    }

    @Test func walBackupIsStandaloneAndUnknownSQLitePayloadCannotLoseFields() async throws {
        try await fixture { root, store in
            let migration = LocalStorageMigration(source: store.root), plan = try migration.preview(format: .sqlite)
            let target = root.appendingPathComponent("sql")
            _ = try migration.transfer(to: target, format: .sqlite, expected: plan.fingerprint)
            let sqlRoot = target.appendingPathComponent("vault"), file = sqlRoot.appendingPathComponent("sqlite/records.sqlite")
            var raw: OpaquePointer?
            #expect(sqlite3_open(file.resolvingSymlinksInPath().path, &raw) == SQLITE_OK)
            defer { sqlite3_close(raw) }
            #expect(sqlite3_exec(raw, "PRAGMA journal_mode=WAL; UPDATE records SET content_hash=content_hash", nil, nil, nil) == SQLITE_OK)
            let back = LocalStorageMigration(source: sqlRoot), backPlan = try back.preview(format: .json)
            let result = try back.transfer(to: root.appendingPathComponent("json"), format: .json, expected: backPlan.fingerprint)
            let backup = URL(fileURLWithPath: result.backupPath)
            #expect(try LocalVaultSnapshotSource(fileURL: backup.appendingPathComponent("sqlite/records.sqlite")).loadDocuments().count == 2)
            #expect(try FileManager.default.contentsOfDirectory(atPath: backup.appendingPathComponent("sqlite").path) == ["records.sqlite"])
            let db = try SQLiteDocumentStore(directory: file.deletingLastPathComponent(), readOnly: true)
            let record = try #require(try db.documents().first)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var value = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String: Any]
            value["futureData"] = ["keep": "required"]
            let payload = try JSONSerialization.data(withJSONObject: value)
            let bytes = payload.map { String(format: "%02x", $0) }.joined()
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            #expect(sqlite3_exec(raw, "UPDATE records SET payload=X'\(bytes)',digest=X'\(digest)' WHERE id='\(record.id.uuidString)'", nil, nil, nil) == SQLITE_OK)
            #expect(throws: LocalStorageMigration.Failure.incompatible) { try back.preview(format: .json) }
        }
    }

    private func fixture(_ operation: (URL, LocalDocumentStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-r3c-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer {
            if completed { try? FileManager.default.removeItem(at: root) }
            else { print("R3c synthetic diagnostic fixture: \(root.path)") }
        }
        let store = LocalDocumentStore(root: root.appendingPathComponent("source"))
        let managed = root.appendingPathComponent("managed.pdf"), referenced = root.appendingPathComponent("reference.pdf")
        try Data("synthetic managed original".utf8).write(to: managed)
        try Data("synthetic external original".utf8).write(to: referenced)
        _ = try await store.stage(file: managed)
        _ = try await store.stage(file: referenced, storage: .referenced)
        try store.locked {
            var records = try store.read()
            for i in records.indices { records[i].localImport?.state = .completed; records[i].status = "ocrComplete"; records[i].ocrText = "--- Seite 1 ---\nSynthetische Versicherung \(i)"; records[i].pageCount = 1 }
            try store.save(records)
        }
        try await operation(root, store)
        completed = true
    }
    private func equal(_ a: [VaultDocument], _ b: [VaultDocument]) -> Bool {
        Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: b.map { ($0.id, $0) })
    }
    private func tree(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                for (path, bytes) in try tree(url) { result[url.lastPathComponent + "/" + path] = bytes }
            } else { result[url.lastPathComponent] = try Data(contentsOf: url) }
        }
        return result
    }
}
