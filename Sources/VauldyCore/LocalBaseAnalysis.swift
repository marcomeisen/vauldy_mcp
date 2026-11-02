import Foundation
import CryptoKit
import VauldyDocumentIntelligence

extension VaultDocument {
    public var baseAnalysisPages: [BaseAnalysisPage] {
        let sections = VaultPageMarkedText.sections(in: ocrText)
        // An unmarked legacy source cannot prove physical page identity.
        guard let count = pageCount, (1...200).contains(count), sections.compactMap(\.page) == Array(1...count),
              !sections.contains(where: { $0.page == nil && !$0.text.isEmpty }) else { return [] }
        return sections.map { section in
            let info = localImport?.pages.first { $0.page == section.page }
            return .init(number: section.page ?? 0, text: section.text,
                         needsReview: info?.needsReview ?? false, unreadable: info?.method == .unreadable)
        }
    }
    public var baseAnalysisStatus: String {
        guard baseAnalysis != nil else { return "not-analyzed" }
        return currentBaseAnalysis?.status.rawValue ?? "stale"
    }
    public var currentBaseAnalysis: DocumentBaseAnalysis? {
        guard let analysis = baseAnalysis, analysis.version == 1, baseAnalysisSourceHash == analysisFingerprint else { return nil }
        if analysis.status == .failed || analysis.status == .unavailable { return analysis }
        return BaseAnalysisPipeline.finalize(analysis.documents, pages: baseAnalysisPages)
    }
    var analysisFingerprint: String {
        struct Source: Encodable { let text: String; let count: Int?; let review: [Bool]; let unreadable: [Bool] }
        let source = Source(text: ocrText, count: pageCount, review: baseAnalysisPages.map(\.needsReview), unreadable: baseAnalysisPages.map(\.unreadable))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? encoder.encode(source)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    mutating func applyBaseAnalysis(_ proposal: DocumentBaseAnalysis) {
        let prior = baseAnalysis
        let analysis: DocumentBaseAnalysis
        if proposal.status == .failed || proposal.status == .unavailable { analysis = proposal }
        else { analysis = BaseAnalysisPipeline.finalize(proposal.documents, pages: baseAnalysisPages) }
        let filenameTitle = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        if title == filenameTitle || title == prior?.displayTitle {
            if !analysis.documents.isEmpty { title = analysis.displayTitle }
        }
        if summary.isEmpty || summary == prior?.summary { summary = analysis.summary }
        let priorCategory = prior?.documents.first?.kind.category
        if category == "other" || category == priorCategory {
            let categories = Set(analysis.documents.map { $0.kind.category })
            category = categories.count == 1 ? (categories.first ?? "other") : "other"
        }
        baseAnalysis = analysis
        baseAnalysisSourceHash = analysisFingerprint
    }
}

/// Explicit local reanalysis of retained OCR. No original changes, OCR restart,
/// provider switching or automatic document disclosure.
public struct LocalBaseAnalysisService: Sendable {
    private let store: LocalDocumentStore
    private let analyzer: any DocumentBaseAnalyzing
    public init(store: LocalDocumentStore, analyzer: any DocumentBaseAnalyzing = LocalRuleBasedDocumentAnalyzer()) {
        self.store = store; self.analyzer = analyzer
    }
    public func analyze(documentID: UUID) async throws -> VaultDocument {
        guard let source = try await store.documents().first(where: { $0.id == documentID }) else { throw LocalImportError.unreadableFile }
        guard source.localImport?.state != .recognizing && source.localImport?.state != .queued else { throw LocalImportError.workerBusy }
        let result: DocumentBaseAnalysis
        do { result = try await analyzer.analyze(pages: source.baseAnalysisPages) }
        catch is CancellationError { throw CancellationError() }
        catch { result = .failed(pages: source.baseAnalysisPages.map(\.number)) }
        try Task.checkCancellation()
        return try await store.saveBaseAnalysis(result, expected: source)
    }
}
