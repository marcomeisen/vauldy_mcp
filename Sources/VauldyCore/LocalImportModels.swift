import Foundation

public enum LocalImportError: String, Error, LocalizedError, Codable, Sendable {
    case unsupportedFile, unreadableFile, fileTooLarge, invalidDocument, encryptedPDF, tooManyPages
    case storageUnavailable, damagedStore, foreignStore, workerBusy, staleAttempt, interrupted, cancelled, noReadableText
    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Unterstützt werden PDF, PNG, JPEG, TIFF und HEIC."
        case .unreadableFile: "Die ausgewählte Datei ist nicht lesbar."
        case .fileTooLarge: "Die Datei oder ihr erkannter Text überschreitet die lokale Größenbegrenzung."
        case .invalidDocument: "Die Datei ist beschädigt oder hat ein nicht unterstütztes Format. Das importierte Original bleibt erhalten."
        case .encryptedPDF: "Das PDF ist gesperrt. Bitte vor dem Import lokal entsperren."
        case .tooManyPages: "Das Dokument überschreitet die Grenze von 200 Seiten."
        case .storageUnavailable: "Der lokale Bestand konnte nicht gespeichert werden."
        case .damagedStore: "Der lokale Bestand ist beschädigt. Er wird nicht überschrieben; Originale und Sicherung bleiben erhalten."
        case .foreignStore: "Dieser Ordner ist kein eigenständiger Vauldy-MCP-Bestand. Bestehende Archive werden nicht überschrieben."
        case .workerBusy: "In diesem Bestand läuft bereits eine Texterkennung. Bitte nach deren Abschluss erneut versuchen."
        case .staleAttempt: "Der Import wurde zwischenzeitlich geändert. Das alte Ergebnis wurde verworfen."
        case .interrupted: "Die Texterkennung wurde unterbrochen. Das Original kann erneut verarbeitet werden."
        case .cancelled: "Die Texterkennung wurde abgebrochen. Das Original bleibt erhalten."
        case .noReadableText: "Es konnte kein durchsuchbarer Text erkannt werden. Das Original bleibt erhalten."
        }
    }
}

public enum LocalImportState: String, Codable, Sendable {
    case queued, recognizing, completed, partial, failed, interrupted, cancelled
}
public enum LocalOCRMethod: String, Codable, Sendable { case embeddedText, embeddedTextAndVision, vision, blank, unreadable }
public struct LocalOCRPageInfo: Codable, Equatable, Sendable {
    public var page: Int
    public var method: LocalOCRMethod
    public var confidence: Double?
    public var elapsedMilliseconds: Int
    public var needsReview: Bool
    public var metrics: LocalOCRMetrics?
    public init(page: Int, method: LocalOCRMethod, confidence: Double? = nil, elapsedMilliseconds: Int = 0, needsReview: Bool = false) {
        self.page = page; self.method = method; self.confidence = confidence
        self.elapsedMilliseconds = elapsedMilliseconds; self.needsReview = needsReview
    }
}
public struct LocalImportMetadata: Codable, Equatable, Sendable {
    public var contentHash: String
    public var fileExtension: String
    public var state: LocalImportState
    public var attempt: UUID?
    public var error: LocalImportError?
    public var pages: [LocalOCRPageInfo]
    public var pipelineVersion: Int
    public var updatedAt: Date
    public var metrics: LocalImportMetrics?
    public init(contentHash: String, fileExtension: String) {
        self.contentHash = contentHash; self.fileExtension = fileExtension; state = .queued
        pages = []; pipelineVersion = 1; updatedAt = Date()
    }
}
public struct LocalOCRPage: Codable, Sendable {
    public var info: LocalOCRPageInfo
    public var text: String
    public init(info: LocalOCRPageInfo, text: String) { self.info = info; self.text = text }
}
public struct LocalOCRResult: Sendable {
    public let pages: [LocalOCRPage]
    public init(pages: [LocalOCRPage]) { self.pages = pages }
}
public struct LocalImportProgress: Codable, Equatable, Sendable {
    public var documentID: UUID?
    public var completedPages: Int
    public var totalPages: Int
    public var stage: String
    public init(documentID: UUID? = nil, completedPages: Int = 0, totalPages: Int = 0, stage: String) {
        self.documentID = documentID; self.completedPages = completedPages; self.totalPages = totalPages; self.stage = stage
    }
}
public protocol LocalDocumentOCR: Sendable {
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult
}
public struct LocalImportOutcome: Codable, Sendable {
    public let documentID: UUID
    public let state: LocalImportState
    public let reusedOriginal: Bool
    public let pageCount: Int?
    public var metrics: LocalImportMetrics? = nil
    public var analysisStatus: String? = nil
}
