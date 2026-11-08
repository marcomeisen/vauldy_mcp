import Foundation
import CryptoKit

public enum MCPInventoryOrder: String, Sendable {
    case importedDescending = "imported-desc"
    case importedAscending = "imported-asc"
}

/// Authorized metadata only. Stable references never replace current access handles.
public struct MCPDocumentInventory: Encodable, Sendable {
    public struct Item: Encodable, Sendable {
        public let document: String
        public let documentID: String
        public let importedAt: String?
        public let contentHash: String?
        public let originalState: String
        public let processingStatus: String
        public let sourceCoverage: String
    }
    public let contractVersion = 1
    public let scope = "currently-authorized-documents"
    public let identityScope = "stored-document; independent-of-access-handles"
    public let identityAlgorithm = "sha256-domain-separated-document-uuid-v1"
    public let contentHashScope = "sha256-of-last-imported-original; not-current-file-or-ocr-text"
    public let order: String
    public let snapshot: String
    public let items: [Item]
    public let totalCount: Int
    public let nextCursor: String?
    public let retrievalComplete: Bool
    public let coverage: MCPProcessingCoverage
    public let warnings = ["AUTHORIZED_INVENTORY_ONLY", "MISSING_ROW_DOES_NOT_PROVE_DELETION", "UNKNOWN_IMPORT_DATES_SORT_LAST", "CHANGED_OR_UNAVAILABLE_ORIGINAL_HASH_IS_HISTORICAL"]
    public let disclosure = MCPDisclosure()
}

package enum MCPDocumentIdentity {
    /// Domain separation keeps the raw archive UUID out of transport metadata.
    /// This correlatable pseudonym is not a secret or an authorization capability.
    /// Deliberately correlatable across grants to the same stored document, as requested.
    package static func reference(_ id: UUID) -> String {
        let data = Data(("vauldy.document-reference.v1\0" + id.uuidString.lowercased()).utf8)
        return "doc_" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    package static func timestamp(_ date: Date?) -> String? {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite,
              date != .distantPast, date != .distantFuture else { return nil }
        return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
