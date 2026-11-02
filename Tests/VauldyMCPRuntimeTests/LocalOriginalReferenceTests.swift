import Foundation
import Testing
import VauldyMCPRuntime
import VauldyDemoDocuments
@testable import VauldyCore

@Suite("Referenced folder originals and verified migration")
struct LocalOriginalReferenceTests {
    @Test func referenceSurvivesReloadWithoutCopyAndOriginalRemainsUnchanged() async throws {
        try await fixture { root, store, file in
            let bytes = try Data(contentsOf: file)
            let before = try FileManager.default.attributesOfItem(atPath: file.path)
            let outcome = try await LocalImportService(store: store, ocr: ReferenceOCR()).importFile(file, storage: .referenced)
            let reopened = LocalDocumentStore(root: store.root)
            let record = try #require(try await reopened.documents().first)
            #expect(record.id == outcome.documentID && record.localImport?.originalReference != nil)
            #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("originals").path))
            let access = try await reopened.openOriginal(for: record.id); defer { access.close() }
            #expect(try access.readData() == bytes)
            #expect(try Data(contentsOf: file) == bytes)
            let after = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
            #expect(before[.posixPermissions] as? Int == after[.posixPermissions] as? Int)
            let marker = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.root.appendingPathComponent("store.json"))) as? [String: Any])
            #expect(marker["version"] as? Int == 2)
        }
    }
    @Test func missingAndChangedSourcesAreVisibleWithoutLosingStoredText() async throws {
        try await fixture { root, store, file in
            let bytes = try Data(contentsOf: file)
            let result = try await LocalImportService(store: store, ocr: ReferenceOCR()).importFile(file, storage: .referenced)
            let saved = try #require(try await store.documents().first)
            try FileManager.default.removeItem(at: file)
            let missing = try #require(try await store.checkOriginals().first)
            #expect(missing.localImport?.originalState == .unavailable && missing.ocrText == saved.ocrText)
            try Data("changed version".utf8).write(to: file)
            await #expect(throws: LocalOriginalError.changed) { try await store.openOriginal(for: result.documentID) }
            let changed = try #require(try await store.documents().first)
            #expect(changed.localImport?.originalState == .changed && changed.baseAnalysisStatus == "stale")
            #expect(changed.ocrText == saved.ocrText)
            try bytes.write(to: file)
            #expect(try await store.checkOriginals().first?.localImport?.originalState == .available)
        }
    }
    @Test func sourceMutationDuringOCRCannotCommitNewText() async throws {
        try await fixture { _, store, file in
            await #expect(throws: LocalOriginalError.changed) {
                try await LocalImportService(store: store, ocr: ReferenceOCR(mutate: true)).importFile(file, storage: .referenced)
            }
            let record = try #require(try await store.documents().first)
            #expect(record.localImport?.originalState == .changed)
            #expect(record.ocrText.isEmpty && record.currentBaseAnalysis == nil)
        }
    }
    @Test func changedFolderVersionHasNewIdentityAndOldTextIsHistorical() async throws {
        try await fixture { _, store, file in
            let service = LocalImportService(store: store, ocr: ReferenceOCR())
            let old = try await service.importFile(file, storage: .referenced)
            try Data("new version".utf8).write(to: file)
            let new = try await service.importFile(file, storage: .referenced)
            #expect(old.documentID != new.documentID)
            let documents = try await store.documents()
            #expect(documents.first { $0.id == old.documentID }?.localImport?.originalState == .changed)
            #expect(documents.first { $0.id == new.documentID }?.localImport?.originalState == .available)
        }
    }
    @Test func migrationRemovesOnlyVerifiedCopyAndBothSnapshotsUseReference() async throws {
        try await fixture { root, store, file in
            let bytes = try Data(contentsOf: file)
            let result = try await LocalImportService(store: store, ocr: ReferenceOCR()).importFile(file)
            let before = try #require(try await store.documents().first)
            let copy = try await store.original(for: result.documentID)
            let migration = LocalOriginalMigrationService(store: store)
            let plan = try await migration.inspect(sourceFolders: [file.deletingLastPathComponent()])
            #expect(plan.report.eligibleDocuments == 1)
            #expect(FileManager.default.fileExists(atPath: copy.path))
            let report = try await migration.apply(plan)
            #expect(report.copiesRemoved == 1 && report.managedBytesRemoved == bytes.count)
            #expect(!FileManager.default.fileExists(atPath: copy.path))
            let after = try #require(try await store.documents().first)
            #expect(after.id == before.id && after.title == before.title && after.ocrText == before.ocrText && after.baseAnalysis == before.baseAnalysis)
            for snapshot in [store.snapshotURL, store.root.appendingPathComponent("documents.backup.json")] {
                let record = try #require(FileVaultSnapshotSource(fileURL: snapshot).loadDocuments().first)
                let access = try #require(record.localImport?.originalReference).open(excluding: store.root); defer { access.close() }
                #expect(try access.readData() == bytes)
            }
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try await migration.inspect(sourceFolders: [file.deletingLastPathComponent()]).report.items.first?.status == .alreadyReferenced)
        }
    }
    @Test func sourceChangedAfterPreviewRetainsCopyAndBacking() async throws {
        try await fixture { _, store, file in
            let result = try await LocalImportService(store: store, ocr: ReferenceOCR()).importFile(file)
            let copy = try await store.original(for: result.documentID), bytes = try Data(contentsOf: copy)
            let migration = LocalOriginalMigrationService(store: store)
            let plan = try await migration.inspect(sourceFolders: [file.deletingLastPathComponent()])
            try Data("changed after preview".utf8).write(to: file)
            let report = try await migration.apply(plan)
            #expect(report.copiesRemoved == 0 && report.referencedDocuments == 0)
            #expect(try Data(contentsOf: copy) == bytes)
            #expect(try await store.documents().first?.localImport?.originalReference == nil)
        }
    }
    @Test func missingSourceCorruptCopySymlinksAndChangedRecordCannotRemoveCopy() async throws {
        try await fixture { root, store, file in
            let result = try await LocalImportService(store: store, ocr: ReferenceOCR()).importFile(file)
            let copy = try await store.original(for: result.documentID)
            let migration = LocalOriginalMigrationService(store: store)
            let plan = try await migration.inspect(sourceFolders: [file.deletingLastPathComponent()])
            _ = try await store.stage(file: file, storage: .referenced) // changed candidate metadata
            let stale = try await migration.apply(plan)
            #expect(stale.items.first?.status == .recordChanged && stale.copiesRemoved == 0)
            try Data("corrupt copy".utf8).write(to: copy)
            #expect(try await migration.inspect(sourceFolders: [file.deletingLastPathComponent()]).report.items.first?.status == .contentMismatch)
            try FileManager.default.removeItem(at: copy)
            try FileManager.default.createSymbolicLink(at: copy, withDestinationURL: file)
            #expect(try await migration.inspect(sourceFolders: [file.deletingLastPathComponent()]).report.eligibleDocuments == 0)
            await #expect(throws: LocalOriginalError.unavailable) { try await store.stage(file: copy, storage: .referenced) }
        }
    }
    @Test func activeOCRBlocksMigrationAndRecoveryCanRemoveLeftoverVerifiedCopy() async throws {
        try await fixture { _, store, file in
            let result = try await LocalImportService(store: store, ocr: ReferenceOCR()).importFile(file)
            let migration = LocalOriginalMigrationService(store: store)
            let plan = try await migration.inspect(sourceFolders: [file.deletingLastPathComponent()])
            let lease = try await store.acquireWorker()
            await #expect(throws: LocalImportError.workerBusy) { try await migration.apply(plan) }
            lease.release()
            let copy = try await store.original(for: result.documentID), bytes = try Data(contentsOf: copy)
            _ = try await migration.apply(plan)
            // Simulate a crash after reference snapshots commit but before unlink.
            try bytes.write(to: copy)
            let recovery = try await migration.inspect(sourceFolders: [])
            #expect(recovery.report.eligibleDocuments == 1)
            #expect(try await migration.apply(recovery).copiesRemoved == 1)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
    @Test func referenceMetadataNeverCrossesMCPBoundary() async throws {
        try await fixture { root, store, file in
            let result = try await LocalImportService(store: store, ocr: ReferenceOCR()).importFile(file, storage: .referenced)
            let url = root.appendingPathComponent("profile.json")
            var profile = MCPAccessProfile(vaultPath: store.snapshotURL.path)
            profile.enabled = true; profile.acknowledgedCloudDisclosure = true; profile.allowedDocumentIDs = [result.documentID]
            try FileMCPProfileSource(url: url).save(profile)
            let runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: url))
            let hit = try #require(try await runtime.search(query: "Fahrradwartung").hits.first)
            let output = try await runtime.read(document: hit.document)
            let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            #expect(!json.contains(root.path) && !json.contains("bookmark") && !json.contains("lastKnownPath"))
            try Data("new bytes".utf8).write(to: file)
            _ = try await store.checkOriginals()
            let fresh = try #require(try await runtime.search(query: "Fahrradwartung").hits.first)
            let historical = try await runtime.read(document: fresh.document)
            #expect(historical.sourceCoverage == "original-changed-stored-ocr-is-historical")
            try FileManager.default.removeItem(at: file)
            _ = try await store.checkOriginals()
            let missingHit = try #require(try await runtime.search(query: "Fahrradwartung").hits.first)
            #expect(try await runtime.read(document: missingHit.document).sourceCoverage == "original-unavailable-stored-ocr-retained")
        }
    }
}
private struct ReferenceOCR: LocalDocumentOCR {
    var mutate = false
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        if mutate { try Data("mutated by synthetic test".utf8).write(to: file) }
        return .init(pages: [.init(info: .init(page: 1, method: .embeddedText), text: "Fahrradwartung 49,99 EUR.")])
    }
}
private func fixture(_ body: (URL, LocalDocumentStore, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-reference-test-\(UUID())")
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = source.appendingPathComponent("synthetic.pdf")
    try Data("synthetic source bytes".utf8).write(to: file)
    try await body(root, LocalDocumentStore(root: root.appendingPathComponent("vault")), file)
}
