import Foundation
import VauldyDocumentIntelligence

public struct LocalImportService: Sendable {
    public let store: LocalDocumentStore
    private let ocr: any LocalDocumentOCR
    private let analyzer: any DocumentBaseAnalyzing
    public init(store: LocalDocumentStore, ocr: (any LocalDocumentOCR)? = nil, analyzer: any DocumentBaseAnalyzing = LocalRuleBasedDocumentAnalyzer()) {
        self.store = store; self.ocr = ocr ?? NativeLocalDocumentOCR(cacheRoot: store.root.appendingPathComponent("ocr-cache")); self.analyzer = analyzer
    }
    public func importFile(_ url: URL, storage: LocalOriginalStorage = .managedCopy,
                           progress: @escaping @Sendable (LocalImportProgress) -> Void = { _ in }) async throws -> LocalImportOutcome {
        try Task.checkCancellation()
        try await store.recoverInterrupted()
        progress(.init(stage: "Original lokal sichern"))
        let staged = try await store.stage(file: url, storage: storage)
        if staged.duplicate {
            return LocalImportOutcome(documentID: staged.document.id, state: staged.document.localImport?.state ?? .failed,
                                      reusedOriginal: true, pageCount: staged.document.pageCount, analysisStatus: staged.document.baseAnalysisStatus)
        }
        return try await recognize(staged.document.id, progress: progress)
    }
    public func retry(documentID: UUID,
                      progress: @escaping @Sendable (LocalImportProgress) -> Void = { _ in }) async throws -> LocalImportOutcome {
        try Task.checkCancellation()
        try await store.recoverInterrupted()
        return try await recognize(documentID, progress: progress)
    }
    private func recognize(_ id: UUID, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalImportOutcome {
        let lease = try await store.acquireWorker()
        defer { lease.release() }
        let attempt = UUID()
        let clock = LocalStopwatch()
        let access = try await store.start(id, attempt: attempt)
        defer { access.close() }
        let original = access.url
        let validation = clock.milliseconds
        let ocrClock = LocalStopwatch()
        do {
            let result = try await ocr.recognize(file: original) { update in
                var update = update; update.documentID = id; progress(update)
            }
            try Task.checkCancellation()
            var metrics = LocalImportMetrics(validationMilliseconds: validation, ocrMilliseconds: ocrClock.milliseconds, totalMilliseconds: clock.milliseconds)
            let analysisClock = LocalStopwatch()
            let analysis: DocumentBaseAnalysis
            do {
                progress(.init(documentID: id, completedPages: result.pages.count, totalPages: result.pages.count, stage: "Lokale Basisanalyse"))
                analysis = try await analyzer.analyze(pages: result.pages.map { .init(number: $0.info.page, text: $0.text,
                    needsReview: $0.info.needsReview, unreadable: $0.info.method == .unreadable) })
            } catch is CancellationError { throw CancellationError() }
            catch { analysis = .failed(pages: result.pages.map(\.info.page)) }
            try Task.checkCancellation()
            metrics.analysisMilliseconds = analysisClock.milliseconds
            let storageClock = LocalStopwatch()
            let document = try await store.finish(id, attempt: attempt, result: result, metrics: metrics, analysis: analysis)
            metrics.storageMilliseconds = storageClock.milliseconds; metrics.totalMilliseconds = clock.milliseconds
            var outcome = LocalImportOutcome(documentID: id, state: document.localImport?.state ?? .failed,
                                            reusedOriginal: false, pageCount: document.pageCount)
            outcome.metrics = metrics
            outcome.analysisStatus = document.baseAnalysisStatus
            return outcome
        } catch {
            let failure = error is CancellationError ? LocalImportError.cancelled : (error as? LocalImportError ?? .invalidDocument)
            _ = try await store.fail(id, attempt: attempt, error: failure, originalState: (error as? LocalOriginalError)?.state)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? LocalOriginalError { throw error }
            throw failure
        }
    }
}
