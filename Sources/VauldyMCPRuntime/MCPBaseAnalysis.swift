import VauldyCore

public struct MCPAnalysisCoverage: Encodable, Sendable {
    public let completed: Int
    public let needsReview: Int
    public let unavailable: Int
    public let failed: Int
    public let notAnalyzed: Int
    public let stale: Int
    public let scope = "local-rule-based-extractive-analysis; not model-verified"
    var warnings: [String] { needsReview + unavailable + failed + notAnalyzed + stale > 0 ? ["BASE_ANALYSIS_NOT_COMPLETE"] : [] }
    init(_ documents: [VaultDocument]) {
        self.init(states: documents.map(\.baseAnalysisStatus))
    }

    init(states: [String]) {
        completed = states.filter { $0 == "completed" }.count
        needsReview = states.filter { $0 == "needsReview" }.count
        unavailable = states.filter { $0 == "unavailable" }.count
        failed = states.filter { $0 == "failed" }.count
        notAnalyzed = states.filter { $0 == "not-analyzed" }.count
        stale = states.filter { $0 == "stale" }.count
    }
}

/// Sanitized metadata only. Raw persisted models never cross the MCP boundary.
public struct MCPAnalysisField: Encodable, Sendable {
    public let role: String
    public let value: String
    public let page: Int
    public let quote: String
    public let source: String
}
public struct MCPLogicalDocument: Encodable, Sendable {
    public let pages: [Int]
    public let documentType: String
    public let title: String
    public let overview: String?
    public let fields: [MCPAnalysisField]
    public let warnings: [String]
}
public struct MCPMetadataResult: Encodable, Sendable {
    public let document: String
    public let view = "metadata"
    public let analysisStatus: String
    public let engine: String?
    public let analyzedPages: [Int]
    public let logicalDocumentCount: Int
    public let documents: [MCPLogicalDocument]
    public let hasMore: Bool
    public let nextCursor: String?
    public let warnings: [String]
    public let disclosure = MCPDisclosure()
}

enum MCPAnalysisWarnings {
    private static let allowed: Set<String> = Set(["INVALID_SOURCE_COVERAGE", "INVALID_DOCUMENT_OWNERSHIP", "NO_READABLE_TEXT",
        "SOURCE_NEEDS_REVIEW", "MULTIPLE_LOGICAL_DOCUMENTS", "DOCUMENT_TYPE_UNRESOLVED", "OVERVIEW_UNAVAILABLE",
        "SUBJECT_UNRESOLVED", "DOCUMENT_DATE_UNRESOLVED", "DOCUMENT_STRUCTURE_AMBIGUOUS", "UNTRUSTED_INSTRUCTION_TEXT",
        "ANALYSIS_FAILED", "ANALYSIS_INPUT_LIMIT", "NOT_ANALYZED", "STALE_ANALYSIS"])
        .union(["DOCUMENTTYPE", "ISSUER", "RECIPIENT", "ISSUEDATE", "SUBJECT", "TITLEYEAR", "OVERVIEW"].flatMap {
            ["UNSUPPORTED_" + $0, "CONFLICTING_" + $0]
        })
    static func safe(_ codes: [String]) -> [String] {
        Array(Set(codes.map { allowed.contains($0) ? $0 : "UNRECOGNIZED_ANALYSIS_ISSUE" })).sorted()
    }
}
