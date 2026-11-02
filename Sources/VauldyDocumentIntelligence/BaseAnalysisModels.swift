import Foundation

public enum BaseDocumentKind: String, Codable, CaseIterable, Sendable {
    case invoice, receipt, contract, bankStatement, taxCertificate, authorityDecision
    case medicalReport, laboratoryReport, prescription, insuranceNotice, utilityStatement
    case vehicleReport, employmentDocument, schoolNotice, correspondence, unknown

    public var title: String {
        switch self {
        case .invoice: "Rechnung"
        case .receipt: "Kassenbeleg"
        case .contract: "Vertrag"
        case .bankStatement: "Kontoauszug"
        case .taxCertificate: "Steuerbescheinigung"
        case .authorityDecision: "Bescheid"
        case .medicalReport: "Befundbericht"
        case .laboratoryReport: "Laborbefund"
        case .prescription: "Verordnung"
        case .insuranceNotice: "Versicherungsdokument"
        case .utilityStatement: "Nebenkostenabrechnung"
        case .vehicleReport: "Fahrzeugbericht"
        case .employmentDocument: "Arbeitgeberdokument"
        case .schoolNotice: "Schulmitteilung"
        case .correspondence: "Mitteilung"
        case .unknown: "Dokument"
        }
    }
    public var category: String {
        switch self {
        case .invoice, .receipt, .utilityStatement: "invoice"
        case .contract: "contract"
        case .medicalReport, .laboratoryReport, .prescription: "health"
        case .insuranceNotice: "insurance"
        default: "other"
        }
    }
}

public enum BaseAnalysisStatus: String, Codable, Sendable { case completed, needsReview, unavailable, failed }
public enum BaseAnalysisEngine: String, Codable, Sendable { case localRulesExtractiveV1 = "local-rules-extractive-v1" }
public enum BaseFieldRole: String, Codable, Sendable { case documentType, issuer, recipient, issueDate, subject, titleYear, overview }
public enum BaseFieldOrigin: String, Codable, Sendable { case explicitLabel, documentHeading, extractive }

public struct BaseAnalysisPage: Sendable {
    public let number: Int
    public let text: String
    public let needsReview: Bool
    public let unreadable: Bool
    public init(number: Int, text: String, needsReview: Bool = false, unreadable: Bool = false) {
        self.number = number; self.text = text; self.needsReview = needsReview; self.unreadable = unreadable
    }
}

public struct BaseEvidenceField: Codable, Equatable, Sendable {
    public let role: BaseFieldRole
    public let value: String
    public let page: Int
    public let quote: String
    public let origin: BaseFieldOrigin
    public init(role: BaseFieldRole, value: String, page: Int, quote: String, origin: BaseFieldOrigin = .explicitLabel) {
        self.role = role; self.value = value; self.page = page; self.quote = quote; self.origin = origin
    }
}

public struct BaseDocumentOverview: Codable, Equatable, Sendable {
    public var pages: [Int]
    public var kind: BaseDocumentKind
    public var kindEvidence: BaseEvidenceField?
    public var issuer: BaseEvidenceField?
    public var recipient: BaseEvidenceField?
    public var issueDate: BaseEvidenceField?
    public var subject: BaseEvidenceField?
    public var titleYear: BaseEvidenceField?
    public var overview: BaseEvidenceField?
    public var title: String
    public var issues: [String]

    public init(pages: [Int], kind: BaseDocumentKind, kindEvidence: BaseEvidenceField? = nil, issuer: BaseEvidenceField? = nil,
                recipient: BaseEvidenceField? = nil, issueDate: BaseEvidenceField? = nil,
                subject: BaseEvidenceField? = nil, titleYear: BaseEvidenceField? = nil,
                overview: BaseEvidenceField? = nil, title: String = "Dokument", issues: [String] = []) {
        self.pages = pages; self.kind = kind; self.kindEvidence = kindEvidence; self.issuer = issuer; self.recipient = recipient
        self.issueDate = issueDate; self.subject = subject; self.titleYear = titleYear
        self.overview = overview; self.title = title; self.issues = issues
    }
    public var fields: [BaseEvidenceField] { [kindEvidence, issuer, recipient, issueDate, subject, titleYear, overview].compactMap { $0 } }
}

public struct DocumentBaseAnalysis: Codable, Equatable, Sendable {
    public let version: Int
    public let engine: BaseAnalysisEngine
    public let status: BaseAnalysisStatus
    public let analyzedPages: [Int]
    public let documents: [BaseDocumentOverview]
    public let issues: [String]
    public init(version: Int = 1, engine: BaseAnalysisEngine = .localRulesExtractiveV1, status: BaseAnalysisStatus,
                analyzedPages: [Int], documents: [BaseDocumentOverview], issues: [String] = []) {
        self.version = version; self.engine = engine; self.status = status
        self.analyzedPages = analyzedPages; self.documents = documents; self.issues = issues
    }
    public var displayTitle: String { documents.count == 1 ? documents[0].title : "Dokumentenpaket" }
    public var summary: String { documents.compactMap(\.overview?.value).joined(separator: "\n\n") }
    public static func failed(pages: [Int]) -> Self {
        .init(status: .failed, analyzedPages: [], documents: [], issues: ["ANALYSIS_FAILED"])
    }
}

public protocol DocumentBaseAnalyzing: Sendable {
    func analyze(pages: [BaseAnalysisPage]) async throws -> DocumentBaseAnalysis
}
