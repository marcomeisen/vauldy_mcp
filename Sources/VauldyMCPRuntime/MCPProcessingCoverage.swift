import Foundation
import VauldyCore
import VauldyDocumentCore

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

typealias MCPSourceState = VaultSourceState
