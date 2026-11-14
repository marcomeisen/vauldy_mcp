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
        if localImport?.originalState == .changed { return "stale" }
        guard baseAnalysis != nil else { return "not-analyzed" }
        return currentBaseAnalysis?.status.rawValue ?? "stale"
    }
    public var currentBaseAnalysis: DocumentBaseAnalysis? {
        guard localImport?.originalState != .changed, let analysis = baseAnalysis, analysis.version == 1, baseAnalysisSourceHash == analysisFingerprint else { return nil }
        if analysis.status == .failed || analysis.status == .unavailable { return analysis }
        return BaseAnalysisPipeline.finalize(analysis.documents, pages: baseAnalysisPages)
    }
    var analysisFingerprint: String {
        struct Source: Encodable { let text: String; let count: Int?; let review: [Bool]; let unreadable: [Bool] }
        let source = Source(text: ocrText, count: pageCount, review: baseAnalysisPages.map(\.needsReview), unreadable: baseAnalysisPages.map(\.unreadable))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? encoder.encode(source)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    func resolvedTitle(using analysis: DocumentBaseAnalysis) -> (value: String, headingPage: Int?, usesLayout: Bool) {
        let pages = baseAnalysisPages
        guard !pages.isEmpty, !analysis.documents.isEmpty else { return (DocumentTitlePolicy.fallback, nil, false) }
        if analysis.documents.count > 1 { return (analysis.displayTitle, nil, false) }
        let card = analysis.documents[0]
        guard let metadata = localImport else { return (DocumentTitlePolicy.withoutLayout(card), nil, false) }
        let info = Dictionary(metadata.pages.map { ($0.page, $0) }, uniquingKeysWith: { first, _ in first })
        func layout(for page: BaseAnalysisPage) -> TitleLayoutPage? {
            guard !page.unreadable, let layout = info[page.number]?.layout,
                  layout.geometry.rotationDegrees == 0, !layout.geometry.lines.isEmpty,
                  layout.matches(sourceHash: metadata.contentHash, page: page.number, text: page.text,
                                 configuration: layout.geometry.configuration) else { return nil }
            let source = page.text as NSString
            let lines: [TitleLayoutPage.Line] = layout.geometry.lines.compactMap { line in
                let text = source.substring(with: NSRange(location: line.location, length: line.length))
                guard !text.contains(where: \.isNewline) else { return nil }
                return .init(text: text, bounds: line.bounds, confidence: line.confidence)
            }
            return lines.isEmpty ? nil : .init(number: page.number, lines: lines)
        }
        guard let first = pages.first.flatMap(layout) else { return (DocumentTitlePolicy.withoutLayout(card), nil, false) }
        let result = LayoutDocumentTitle.resolve(first: first, later: pages.dropFirst().prefix(5).compactMap(layout), analysis: card)
        if result.page == nil, result.value == DocumentTitlePolicy.fallback,
           let retained = DocumentTitlePolicy.retainedTypeTitle(generatedTitle ?? title, analysis: card) {
            return (retained, nil, false)
        }
        return (result.value, result.page, true)
    }

    mutating func applyBaseAnalysis(_ proposal: DocumentBaseAnalysis) {
        let prior = baseAnalysis
        let analysis: DocumentBaseAnalysis
        if proposal.status == .failed || proposal.status == .unavailable { analysis = proposal }
        else { analysis = BaseAnalysisPipeline.finalize(proposal.documents, pages: baseAnalysisPages) }
        setGeneratedTitle(resolvedTitle(using: analysis).value)
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
    /// Refresh only title metadata. Stored analysis, evidence, OCR and grants are untouched.
    public func regenerateTitle(documentID: UUID) async throws -> VaultDocument {
        guard let source = try await store.document(id: documentID) else { throw LocalImportError.unreadableFile }
        guard source.localImport?.state != .recognizing && source.localImport?.state != .queued else { throw LocalImportError.workerBusy }
        guard source.localImport?.originalState != .changed else { throw LocalImportError.staleAttempt }
        let title = try await determineTitle(of: source)
        return try await store.saveGeneratedTitle(title.value, expected: source)
    }

    package struct TitlePreview: Encodable, Sendable {
        package let documentID: UUID
        package let sourceName: String
        package let pages: Int?
        package let before: String
        package let after: String
        package let automaticTitle: String?
        package let method: String
        package let headingPage: Int?
        package let manualOverride: Bool
    }

    /// The preview uses the same proposal and legacy/manual rules as the write path.
    /// It opens the record snapshot read-only, without the import worker or writer lock.
    package func previewTitles() async throws -> [TitlePreview] {
        let sources = try LocalVaultSnapshotSource(fileURL: store.snapshotURL).loadDocuments()
        var results: [TitlePreview] = []
        for source in sources.sorted(by: { ($0.importedAt, $0.id.uuidString) > ($1.importedAt, $1.id.uuidString) }) {
            try Task.checkCancellation()
            var proposed = source
            var headingPage: Int?
            let method: String
            if source.localImport?.state == .queued || source.localImport?.state == .recognizing {
                method = "busy"
            } else if source.localImport?.originalState == .changed {
                method = "sourceChanged"
            } else {
                do {
                    let title = try await determineTitle(of: source)
                    proposed.setGeneratedTitle(title.value)
                    headingPage = title.headingPage
                    method = title.usesLayout ? "layout" : "text"
                } catch LocalImportError.invalidDocument {
                    method = "analysisUnavailable"
                }
            }
            results.append(.init(documentID: source.id, sourceName: source.sourceName, pages: source.pageCount,
                                 before: source.title, after: proposed.title,
                                 automaticTitle: proposed.generatedTitle, method: method,
                                 headingPage: headingPage, manualOverride: proposed.manualTitle != nil))
        }
        return results
    }

    private func determineTitle(of source: VaultDocument) async throws -> (value: String, headingPage: Int?, usesLayout: Bool) {
        let pages = source.baseAnalysisPages
        guard !pages.isEmpty else { return (DocumentTitlePolicy.fallback, nil, false) }
        let proposal = try await analyzer.analyze(pages: pages)
        try Task.checkCancellation()
        let result = BaseAnalysisPipeline.finalize(proposal.documents, pages: pages)
        guard result.status != .failed else { throw LocalImportError.invalidDocument }
        return source.resolvedTitle(using: result)
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
