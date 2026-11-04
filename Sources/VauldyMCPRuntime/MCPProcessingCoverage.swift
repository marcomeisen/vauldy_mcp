import Foundation
import VauldyCore

/// Counts only explicitly granted records. Completeness concerns source processing,
/// never OCR accuracy, organization classification or factual AI analysis.
public struct MCPProcessingCoverage: Encodable, Sendable {
    public let scope = "source-processing-only; analysis-is-reported-separately"
    public let authorizedDocumentCount: Int
    public let searchableDocumentCount: Int
    public let completeSourceDocumentCount: Int
    public let pendingDocumentCount: Int
    public let failedDocumentCount: Int
    public let reviewDocumentCount: Int
    public let unknownCoverageDocumentCount: Int
    public let missingGrantedDocumentCount: Int
    public var processingComplete: Bool {
        missingGrantedDocumentCount == 0 && completeSourceDocumentCount == authorizedDocumentCount
    }
    var warnings: [String] { processingComplete ? [] : ["SOURCE_PROCESSING_GAPS"] }

    init(documents: [VaultDocument], grantedCount: Int) {
        self.init(statuses: documents.map { MCPSourceState($0).processingStatus },
                  searchableCount: documents.filter(\.isSearchable).count, grantedCount: grantedCount)
    }

    init(statuses: [String], searchableCount: Int, grantedCount: Int) {
        authorizedDocumentCount = statuses.count
        searchableDocumentCount = searchableCount
        completeSourceDocumentCount = statuses.count { $0 == "source-ready" }
        pendingDocumentCount = statuses.count { $0 == "pending" }
        failedDocumentCount = statuses.count { $0 == "failed" }
        reviewDocumentCount = statuses.count { $0 == "needs-review" }
        unknownCoverageDocumentCount = statuses.count { $0 == "unknown" }
        missingGrantedDocumentCount = max(0, grantedCount - statuses.count)
    }
}

struct MCPSourceState {
    let sourceCoverage: String
    let processingStatus: String

    func projection(for document: VaultDocument) -> VaultIndexProjection {
        .init(processingStatus: processingStatus, sourceCoverage: sourceCoverage,
              analysisStatus: document.baseAnalysisStatus, searchable: document.isSearchable)
    }

    init(_ document: VaultDocument) {
        let sections = VaultPageMarkedText.sections(in: document.ocrText)
        var complete = false
        if let count = document.pageCount, (1...10_000).contains(count), sections.compactMap(\.page) == Array(1...count) {
            if let info = document.localImport {
                complete = info.state == .completed && info.pages.map(\.page) == Array(1...count)
                    && info.pages.allSatisfy { page in
                        page.method != .unreadable && !page.needsReview
                            && (page.method == .blank || sections.contains { $0.page == page.page && !$0.text.isEmpty })
                    }
            } else { complete = sections.allSatisfy { !$0.text.isEmpty } }
        }
        if document.localImport?.originalState == .changed || document.localImport?.originalState == .unavailable { complete = false }
        switch document.localImport?.originalState {
        case .changed: sourceCoverage = "original-changed-stored-ocr-is-historical"
        case .unavailable: sourceCoverage = "original-unavailable-stored-ocr-retained"
        default: sourceCoverage = complete ? (document.localImport == nil ? "all-declared-pages-have-ocr-text" : "all-declared-pages-processed") : "incomplete-or-unknown"
        }
        if let info = document.localImport {
            switch info.state {
            case .queued, .recognizing: processingStatus = "pending"
            case .failed, .cancelled, .interrupted: processingStatus = "failed"
            case .partial: processingStatus = "needs-review"
            case .completed: processingStatus = complete ? "source-ready" : "needs-review"
            }
        } else if document.status == "failed" || document.status == "cancelled" {
            processingStatus = "failed"
        } else if document.status == "partiallyAnalyzed" {
            processingStatus = "needs-review"
        } else if !document.isSearchable {
            processingStatus = "pending"
        } else { processingStatus = complete ? "source-ready" : "unknown" }
    }
}
