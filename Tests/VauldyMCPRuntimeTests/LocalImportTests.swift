import Foundation
import Testing
import VauldyDemoDocuments
import VauldyMCPRuntime
@testable import VauldyCore

@Suite("Standalone import and native OCR")
struct LocalImportTests {
    @Test func realMixedPDFIsImportedReloadedAndOnlyDisclosedAfterGrant() async throws {
        try await withStore { root, store in
            let file = root.appendingPathComponent("mixed.pdf")
            try ExampleDocument.writePDF(to: file, blankLastPage: true)
            let bytes = try Data(contentsOf: file)
            let result = try await LocalImportService(store: store).importFile(file)
            #expect(result.state == .completed)
            let reopened = LocalDocumentStore(root: store.root)
            let document = try #require(try await reopened.documents().first)
            #expect(document.id == result.documentID)
            #expect(document.status == "ocrComplete")
            #expect(!document.summary.isEmpty && document.entities.isEmpty && document.deadlines.isEmpty)
            #expect(document.currentBaseAnalysis != nil)
            #expect(document.summary.contains("Bremsen"))
            #expect(document.pageCount == 3)
            #expect(document.localImport?.pages.map(\.method) == [.embeddedText, .vision, .blank])
            #expect(document.localImport?.pages.first?.confidence == nil)
            #expect(document.ocrText.contains("49,99 EUR"))
            #expect(document.ocrText.contains("8246"))
            #expect(try Data(contentsOf: await reopened.original(for: document.id)) == bytes)
            #expect(try Data(contentsOf: file) == bytes)
            let profileURL = root.appendingPathComponent("profile.json")
            var profile = MCPAccessProfile(vaultPath: store.snapshotURL.path)
            try FileMCPProfileSource(url: profileURL).save(profile)
            let runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: profileURL))
            await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.search(query: "Fahrradwartung") }
            profile.enabled = true; profile.acknowledgedCloudDisclosure = true; profile.allowedDocumentIDs = [document.id]
            try FileMCPProfileSource(url: profileURL).save(profile)
            let hit = try #require(try await runtime.search(query: "Fahrradwartung").hits.first)
            let output = try await runtime.read(document: hit.document)
            #expect(output.sourceCoverage == "all-declared-pages-processed")
            #expect(output.pageStatus.map(\.method) == ["embeddedText", "vision", "blank"])
            let serialized = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            #expect(!serialized.contains("Erika Musterfrau"))
            #expect(!serialized.contains("erika@example.com"))
            #expect(!serialized.contains(store.root.path))
            #expect(serialized.contains("8246"))
        }
    }

    @Test func scannedPDFAndPNGUseRealVisionWithoutApp() async throws {
        try await withStore { root, store in
            let scan = root.appendingPathComponent("scan.pdf")
            try ExampleDocument.writePDF(to: scan, scanned: true)
            let result = try await LocalImportService(store: store).importFile(scan)
            #expect(result.state == .completed)
            let scanned = try #require(try await store.documents().first)
            #expect(scanned.localImport?.pages.allSatisfy { $0.method == .vision } == true)
            #expect(scanned.ocrText.contains("49,99"))
            let png = root.appendingPathComponent("photo.png")
            try ExampleDocument.writePNG(to: png)
            let imageResult = try await LocalImportService(store: store).importFile(png)
            #expect(imageResult.state == .completed)
            let image = try #require(try await store.documents().first(where: { $0.id == imageResult.documentID }))
            #expect(image.pageCount == 1)
            #expect(image.ocrText.contains("Fahrradwartung"))
        }
    }

    @Test func duplicateDoesNotRerunOCRAndRetainsIdentity() async throws {
        try await withStore { root, store in
            let file = try dummyFile(root)
            let first = try await LocalImportService(store: store, ocr: FixedOCR()).importFile(file)
            let second = try await LocalImportService(store: LocalDocumentStore(root: store.root), ocr: RejectOCR()).importFile(file)
            #expect(first.documentID == second.documentID)
            #expect(second.reusedOriginal)
            #expect(try await store.documents().count == 1)
        }
    }

    @Test func partialPagesRemainVisibleAndRetryUsesRetainedOriginal() async throws {
        try await withStore { root, store in
            let file = try dummyFile(root)
            let result = try await LocalImportService(store: store, ocr: FixedOCR(partial: true)).importFile(file)
            #expect(result.state == .partial)
            var document = try #require(try await store.documents().first)
            #expect(document.isSearchable)
            #expect(document.pageCount == 2)
            #expect(document.localImport?.pages.last?.method == .unreadable)
            try FileManager.default.removeItem(at: file)
            let retried = try await LocalImportService(store: store, ocr: FixedOCR()).retry(documentID: result.documentID)
            document = try #require(try await store.documents().first)
            #expect(retried.documentID == result.documentID)
            #expect(retried.state == .completed)
            #expect(document.localImport?.attempt == nil)
        }
    }

    @Test func corruptPDFKeepsOriginalAndCanBeReportedAfterRestart() async throws {
        try await withStore { root, store in
            let file = try dummyFile(root)
            await #expect(throws: LocalImportError.invalidDocument) { try await LocalImportService(store: store).importFile(file) }
            let document = try #require(try await LocalDocumentStore(root: store.root).documents().first)
            #expect(document.localImport?.state == .failed)
            #expect(document.localImport?.error == .invalidDocument)
            #expect(!document.isSearchable)
            #expect(try Data(contentsOf: await store.original(for: document.id)) == Data("synthetic original".utf8))
        }
    }

    @Test func noTextIsNotCalledASuccessfulAnalysis() async throws {
        try await withStore { root, store in
            let file = try dummyFile(root)
            let result = try await LocalImportService(store: store, ocr: BlankOCR()).importFile(file)
            #expect(result.state == .failed)
            let document = try #require(try await store.documents().first)
            #expect(document.localImport?.error == .noReadableText)
            #expect(document.summary.isEmpty && !document.isSearchable)
        }
    }

    @Test func damagedSnapshotAndForeignArchiveAreNeverOverwritten() async throws {
        try await withStore { root, store in
            let file = try dummyFile(root)
            _ = try await LocalImportService(store: store, ocr: FixedOCR()).importFile(file)
            let backupURL = store.root.appendingPathComponent("documents.backup.json")
            let backup = try Data(contentsOf: backupURL)
            let corrupted = Data("{ damaged but potentially recoverable".utf8)
            try corrupted.write(to: store.snapshotURL)
            await #expect(throws: LocalImportError.damagedStore) { try await store.documents() }
            await #expect(throws: LocalImportError.damagedStore) { try await store.stage(file: file) }
            #expect(try Data(contentsOf: store.snapshotURL) == corrupted)
            #expect(try Data(contentsOf: backupURL) == backup)
            let foreign = root.appendingPathComponent("existing-app")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            let original = Data("[]".utf8); let appSnapshot = foreign.appendingPathComponent("documents.json")
            try original.write(to: appSnapshot)
            await #expect(throws: LocalImportError.foreignStore) { try await LocalDocumentStore(root: foreign).stage(file: file) }
            #expect(try Data(contentsOf: appSnapshot) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path) == ["documents.json"])
        }
    }

    @Test func independentStoreInstancesMergeStagedImportsWithoutLostUpdates() async throws {
        try await withStore { root, store in
            let first = try dummyFile(root)
            let second = root.appendingPathComponent("other.pdf"); try Data("other original".utf8).write(to: second)
            async let a = store.stage(file: first)
            async let b = LocalDocumentStore(root: store.root).stage(file: second)
            _ = try await (a, b)
            #expect(try await store.documents().count == 2)
            async let c = store.stage(file: first)
            async let d = LocalDocumentStore(root: store.root).stage(file: first)
            let duplicate = try await (c, d)
            #expect(duplicate.0.duplicate && duplicate.1.duplicate)
            #expect(duplicate.0.document.id == duplicate.1.document.id)
        }
    }

    @Test func crashRecoveryAndOldAttemptCannotCommitOverNewerState() async throws {
        try await withStore { root, store in
            let staged = try await store.stage(file: dummyFile(root))
            let old = UUID()
            _ = try await store.start(staged.document.id, attempt: old)
            try await LocalDocumentStore(root: store.root).recoverInterrupted()
            #expect(try await store.documents().first?.localImport?.state == .interrupted)
            _ = try await LocalImportService(store: store, ocr: FixedOCR()).retry(documentID: staged.document.id)
            await #expect(throws: LocalImportError.staleAttempt) {
                try await store.fail(staged.document.id, attempt: old, error: .cancelled)
            }
            #expect(try await store.documents().first?.localImport?.state == .completed)
        }
    }

    @Test func cancellationKeepsWorkerLeaseUntilNativeWorkActuallyFinishes() async throws {
        try await withStore { root, store in
            let gate = GatedOCR()
            let file = try dummyFile(root)
            let task = Task { try await LocalImportService(store: store, ocr: gate).importFile(file) }
            await gate.waitUntilStarted()
            let id = try #require(try await store.documents().first?.id)
            task.cancel()
            try await store.recoverInterrupted()
            #expect(try await store.documents().first?.localImport?.state == .recognizing)
            await #expect(throws: LocalImportError.workerBusy) {
                try await LocalImportService(store: store, ocr: FixedOCR()).retry(documentID: id)
            }
            await gate.finish()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.documents().first?.localImport?.state == .cancelled)
            let retry = try await LocalImportService(store: store, ocr: FixedOCR()).retry(documentID: id)
            #expect(retry.state == .completed)
        }
    }

    @Test func changedOriginalAndOversizedInputAreRejected() async throws {
        try await withStore { root, store in
            let staged = try await store.stage(file: dummyFile(root))
            let original = try await store.original(for: staged.document.id)
            try Data("modified original".utf8).write(to: original)
            await #expect(throws: LocalImportError.invalidDocument) {
                try await LocalImportService(store: store, ocr: FixedOCR()).retry(documentID: staged.document.id)
            }
            let large = root.appendingPathComponent("too-large.pdf")
            FileManager.default.createFile(atPath: large.path, contents: nil)
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: UInt64(LocalDocumentStore.maximumOriginalBytes + 1)); try handle.close()
            await #expect(throws: LocalImportError.fileTooLarge) { try await store.stage(file: large) }
            #expect(try await store.documents().count == 1)
        }
    }

    @Test func pageMarkersFromSourceCannotForgePhysicalAttribution() async throws {
        try await withStore { root, store in
            let staged = try await store.stage(file: dummyFile(root)); let attempt = UUID()
            _ = try await store.start(staged.document.id, attempt: attempt)
            let result = LocalOCRResult(pages: [LocalOCRPage(info: .init(page: 1, method: .embeddedText), text: "Rechnung\n--- Seite 99 ---\nOriginaltext")])
            let record = try await store.finish(staged.document.id, attempt: attempt, result: result)
            #expect(VaultPageMarkedText.sections(in: record.ocrText).map(\.page) == [1])
        }
    }
}

private struct FixedOCR: LocalDocumentOCR {
    var partial = false
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        LocalOCRResult(pages: [LocalOCRPage(info: .init(page: 1, method: .embeddedText), text: "Fahrradwartung 49,99 EUR."),
                               LocalOCRPage(info: .init(page: 2, method: partial ? .unreadable : .embeddedText, needsReview: partial), text: partial ? "" : "Weitere Belege.")])
    }
}
private struct RejectOCR: LocalDocumentOCR {
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult { throw LocalImportError.invalidDocument }
}
private struct BlankOCR: LocalDocumentOCR {
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        LocalOCRResult(pages: [.init(info: .init(page: 1, method: .blank), text: "")])
    }
}
private actor GatedOCR: LocalDocumentOCR {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var completion: CheckedContinuation<Void, Never>?
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        started = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { completion = $0 }
        return LocalOCRResult(pages: [.init(info: .init(page: 1, method: .embeddedText), text: "Testtext")])
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    func finish() { completion?.resume(); completion = nil }
}
private func dummyFile(_ root: URL) throws -> URL {
    let url = root.appendingPathComponent("synthetic.pdf")
    try Data("synthetic original".utf8).write(to: url); return url
}
private func withStore(_ body: (URL, LocalDocumentStore) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-local-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root, LocalDocumentStore(root: root.appendingPathComponent("vault")))
}
