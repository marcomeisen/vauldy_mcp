import Foundation
import VauldyDocumentIntelligence

public struct VaultEntity: Codable, Equatable, Sendable {
    public var type: String
    public var value: String
    public var normalizedValue: String?
    public var confidence: Double
    public var sourceSnippet: String

    public init(
        type: String,
        value: String,
        normalizedValue: String? = nil,
        confidence: Double,
        sourceSnippet: String
    ) {
        self.type = type
        self.value = value
        self.normalizedValue = normalizedValue
        self.confidence = confidence
        self.sourceSnippet = sourceSnippet
    }
}

public struct VaultFact: Codable, Equatable, Sendable {
    public var kind: String
    public var label: String
    public var value: String
    public var normalizedValue: String?
    public var confidence: Double
    public var sourceSnippet: String

    public init(
        kind: String,
        label: String,
        value: String,
        normalizedValue: String? = nil,
        confidence: Double,
        sourceSnippet: String
    ) {
        self.kind = kind
        self.label = label
        self.value = value
        self.normalizedValue = normalizedValue
        self.confidence = confidence
        self.sourceSnippet = sourceSnippet
    }
}

public struct VaultDeadline: Codable, Equatable, Sendable {
    public var title: String
    public var date: Date
    public var type: String
    public var confidence: Double
    public var sourceSnippet: String

    public init(
        title: String,
        date: Date,
        type: String,
        confidence: Double,
        sourceSnippet: String
    ) {
        self.title = title
        self.date = date
        self.type = type
        self.confidence = confidence
        self.sourceSnippet = sourceSnippet
    }
}

public struct VaultDocument: Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var sourceName: String
    public let importedAt: Date
    public var category: String
    public var status: String
    public var ocrText: String
    public var ocrConfidence: Double
    public var summary: String
    public var categoryConfidence: Double
    public var entities: [VaultEntity]
    public var deadlines: [VaultDeadline]
    public var contentFacts: [VaultFact]
    public var pageCount: Int?
    public var localImport: LocalImportMetadata?
    public var baseAnalysis: DocumentBaseAnalysis?
    public var baseAnalysisSourceHash: String?

    public init(
        id: UUID = UUID(),
        title: String,
        sourceName: String,
        importedAt: Date = Date(),
        category: String = "other",
        status: String = "indexed",
        ocrText: String = "",
        ocrConfidence: Double = 0,
        summary: String = "",
        categoryConfidence: Double = 0,
        entities: [VaultEntity] = [],
        deadlines: [VaultDeadline] = [],
        contentFacts: [VaultFact] = [],
        pageCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.importedAt = importedAt
        self.category = category
        self.status = status
        self.ocrText = ocrText
        self.ocrConfidence = ocrConfidence
        self.summary = summary
        self.categoryConfidence = categoryConfidence
        self.entities = entities
        self.deadlines = deadlines
        self.contentFacts = contentFacts
        self.pageCount = pageCount
    }

    public var isSearchable: Bool {
        status == "indexed" || status == "partiallyAnalyzed" || status == "ocrComplete"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceName
        case importedAt
        case category
        case status
        case ocrText
        case ocrConfidence
        case summary
        case categoryConfidence
        case entities
        case deadlines
        case contentFacts
        case pageCount
        case localImport
        case baseAnalysis
        case baseAnalysisSourceHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Ohne Titel"
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? .distantPast
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "other"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "imported"
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText) ?? ""
        ocrConfidence = try container.decodeIfPresent(Double.self, forKey: .ocrConfidence) ?? 0
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        categoryConfidence = try container.decodeIfPresent(Double.self, forKey: .categoryConfidence) ?? 0
        entities = try container.decodeIfPresent([VaultEntity].self, forKey: .entities) ?? []
        deadlines = try container.decodeIfPresent([VaultDeadline].self, forKey: .deadlines) ?? []
        contentFacts = try container.decodeIfPresent([VaultFact].self, forKey: .contentFacts) ?? []
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
        localImport = try container.decodeIfPresent(LocalImportMetadata.self, forKey: .localImport)
        baseAnalysis = try container.decodeIfPresent(DocumentBaseAnalysis.self, forKey: .baseAnalysis)
        baseAnalysisSourceHash = try container.decodeIfPresent(String.self, forKey: .baseAnalysisSourceHash)
    }
}

public struct VaultStatus: Codable, Equatable, Sendable {
    public var available: Bool
    public var documentCount: Int
    public var searchableDocumentCount: Int
    public var categories: [String: Int]
    public var processingLocation: String
    public var externalProcessing: Bool
    public var accessMode: String

    public init(
        available: Bool,
        documentCount: Int,
        searchableDocumentCount: Int,
        categories: [String: Int],
        processingLocation: String = "local",
        externalProcessing: Bool = false,
        accessMode: String = "read-only"
    ) {
        self.available = available
        self.documentCount = documentCount
        self.searchableDocumentCount = searchableDocumentCount
        self.categories = categories
        self.processingLocation = processingLocation
        self.externalProcessing = externalProcessing
        self.accessMode = accessMode
    }
}

public struct VaultEvidence: Codable, Equatable, Sendable {
    public var documentId: UUID
    public var title: String
    public var page: Int?
    public var reference: String
    public var excerpt: String

    public init(documentId: UUID, title: String, page: Int?, reference: String, excerpt: String) {
        self.documentId = documentId
        self.title = title
        self.page = page
        self.reference = reference
        self.excerpt = excerpt
    }
}

public struct VaultSearchHit: Codable, Equatable, Sendable {
    public var documentId: UUID
    public var title: String
    public var category: String
    public var importedAt: String
    public var excerpt: String
    public var page: Int?
    public var reference: String
    public var relevance: Double

    public init(
        documentId: UUID,
        title: String,
        category: String,
        importedAt: Date,
        excerpt: String,
        page: Int?,
        reference: String,
        relevance: Double
    ) {
        self.documentId = documentId
        self.title = title
        self.category = category
        self.importedAt = ISO8601DateFormatter().string(from: importedAt)
        self.excerpt = excerpt
        self.page = page
        self.reference = reference
        self.relevance = relevance
    }
}

public struct VaultSearchResult: Codable, Equatable, Sendable {
    public var query: String
    public var hits: [VaultSearchHit]
    public var totalCount: Int?
    public var disclosureLevel: String
    public var processingLocation: String
    public var externalProcessing: Bool

    public init(query: String, hits: [VaultSearchHit], totalCount: Int? = nil) {
        self.query = query
        self.hits = hits
        self.totalCount = totalCount ?? hits.count
        disclosureLevel = "D2"
        processingLocation = "local"
        externalProcessing = false
    }
}

public struct VaultPrivateAnswer: Codable, Equatable, Sendable {
    public var runId: UUID
    public var answer: String
    public var confidence: Double
    public var evidence: [VaultEvidence]
    public var processingLocation: String
    public var engine: String
    public var externalProcessing: Bool
    public var disclosureLevel: String

    public init(
        runId: UUID = UUID(),
        answer: String,
        confidence: Double,
        evidence: [VaultEvidence],
        processingLocation: String = "local",
        engine: String = "deterministic-grounded",
        externalProcessing: Bool = false,
        disclosureLevel: String = "D1"
    ) {
        self.runId = runId
        self.answer = answer
        self.confidence = confidence
        self.evidence = evidence
        self.processingLocation = processingLocation
        self.engine = engine
        self.externalProcessing = externalProcessing
        self.disclosureLevel = disclosureLevel
    }
}
