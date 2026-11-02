import Foundation
import Testing
@testable import VauldyCore

@Suite("Local worker lifecycle")
struct LocalWorkerTests {
    @Test func idleWorkerStopsAndDoesNotLoseCompletedJob() async throws {
        try await fixture { root, worker in
            let server = Task { try await worker.serve(idleSeconds: 2, ocr: WorkerFixtureOCR()) }
            try await waitForWorker(worker)
            let input = root.appendingPathComponent("input.pdf"); try Data("fixture bytes".utf8).write(to: input)
            let result = try await worker.importFile(input)
            #expect(result.state == .completed)
            try await server.value
            #expect(try await worker.status().running == false)
            #expect(try await worker.store.documents().first?.localImport?.state == .completed)
        }
    }
    @Test func queuedDocumentsUseOneWorkerAndRemainSeparate() async throws {
        try await fixture { root, worker in
            let server = Task { try await worker.serve(ocr: WorkerFixtureOCR()) }
            try await waitForWorker(worker)
            let instance = try await worker.status().instance
            let first = root.appendingPathComponent("one.pdf"), second = root.appendingPathComponent("two.pdf")
            try Data("first bytes".utf8).write(to: first); try Data("second bytes".utf8).write(to: second)
            async let a = worker.importFile(first); async let b = worker.importFile(second)
            let results = try await (a,b)
            #expect(results.0.documentID != results.1.documentID)
            #expect(results.0.state == .completed && results.1.state == .completed)
            #expect(try await worker.status().instance == instance)
            try await worker.stop(); try await server.value
        }
    }
    @Test func queuedCancellationPersistsWithoutInterruptingAnotherNativeLease() async throws {
        try await fixture { root, worker in
            let lease = try await worker.store.acquireWorker()
            defer { lease.release() }
            let server = Task { try await worker.serve(ocr: WorkerFixtureOCR()) }
            try await waitForWorker(worker)
            let file = root.appendingPathComponent("queued.pdf"); try Data("queued fixture".utf8).write(to: file)
            let client = Task { try await worker.importFile(file) }
            for _ in 0..<100 {
                if try await worker.store.documents().first?.localImport?.state == .queued { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            client.cancel()
            await #expect(throws: CancellationError.self) { try await client.value }
            #expect(try await worker.store.documents().first?.localImport?.state == .cancelled)
            await #expect(throws: LocalImportError.workerBusy) { try await worker.store.acquireWorker() }
            try await worker.stop(); try await server.value
        }
    }
    @Test func clientCancellationJoinsNativeWorkBeforeWorkerAcceptsNextJob() async throws {
        try await fixture { root, worker in
            let gate = WorkerGateOCR()
            let server = Task { try await worker.serve(ocr: gate) }
            try await waitForWorker(worker)
            let file = root.appendingPathComponent("input.pdf"); try Data("fixture bytes".utf8).write(to: file)
            let client = Task { try await worker.importFile(file) }
            await gate.started()
            client.cancel()
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await worker.store.documents().first?.localImport?.state == .recognizing)
            #expect(try await worker.status().processing == 1)
            await gate.release()
            await #expect(throws: CancellationError.self) { try await client.value }
            #expect(try await worker.store.documents().first?.localImport?.state == .cancelled)
            try await worker.stop(); try await server.value
        }
    }
}
private func fixture(_ body: (URL, LocalImportWorker) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-worker-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
    _ = try await store.documents()
    try await body(root, LocalImportWorker(store: store, executable: URL(fileURLWithPath: "/usr/bin/false")))
}
private func waitForWorker(_ worker: LocalImportWorker) async throws {
    for _ in 0..<100 { if try await worker.status().running { return }; try await Task.sleep(for: .milliseconds(20)) }
    throw LocalImportError.workerBusy
}
private struct WorkerFixtureOCR: LocalDocumentOCR {
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        try await Task.sleep(for: .milliseconds(50))
        return .init(pages: [.init(info: .init(page: 1, method: .embeddedText), text: "Synthetic worker test 49,99 EUR")])
    }
}
private actor WorkerGateOCR: LocalDocumentOCR {
    var isStarted = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var finish: CheckedContinuation<Void, Never>?
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        isStarted = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { finish = $0 }
        return .init(pages: [.init(info: .init(page: 1, method: .embeddedText), text: "Synthetic work complete")])
    }
    func started() async { if !isStarted { await withCheckedContinuation { startWaiter = $0 } } }
    func release() { finish?.resume(); finish = nil }
}
