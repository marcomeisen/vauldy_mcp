import Foundation
import VauldyCore

/// Trusted local owner-process attestation, never accepted by an MCP/HTTP tool.
/// Original bookmarks belong to that host. The credential-owning agent validates
/// the bound snapshot, recipient and explicit selection without exporting bookmarks.
public struct MCPNativeOriginalVerification: Codable, Sendable {
    public let snapshotDigest: String
    public let checkedAt: Date
    public let verifiedIDs: [UUID]
    public init(snapshotDigest: String, checkedAt: Date, verifiedIDs: [UUID]) {
        self.snapshotDigest = snapshotDigest; self.checkedAt = checkedAt; self.verifiedIDs = verifiedIDs
    }
}

/// Local maintenance DTOs only. Never serialize raw titles/IDs through MCP tools.
public struct MCPInventoryQualityReport: Sendable {
    public struct Row: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let original: LocalOriginalState?
        public let processing: String
        public let coverage: String
        public let analysis: String
        public let readable: Bool
        public let expectedPages: Int?
        public let processedPages: Int
        public let unfilledBaseFields: [String]
        public var eligible: Bool { original == .available && readable }
        public var ready: Bool { eligible && processing == "source-ready" && analysis == "completed" }
    }
    public let createdAt: Date
    public let snapshotDigest: String
    public let rows: [Row]
    public var nativeVerification: MCPNativeOriginalVerification {
        .init(snapshotDigest: snapshotDigest, checkedAt: createdAt,
              verifiedIDs: rows.filter { $0.original == .available }.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }
    public var eligibleIDs: Set<UUID> { Set(rows.filter(\.eligible).map(\.id)) }
    public var readyIDs: Set<UUID> { Set(rows.filter(\.ready).map(\.id)) }
    public var reviewIDs: Set<UUID> { eligibleIDs.subtracting(readyIDs) }
    public func validateSelection(_ ids: Set<UUID>, acknowledgedReview: Bool) throws {
        guard ids.isSubset(of: eligibleIDs), acknowledgedReview || ids.isDisjoint(with: reviewIDs) else { throw MCPAccessError.notAuthorized }
    }
}

public struct MCPInventoryQualityService: Sendable {
    public let store: LocalDocumentStore
    public init(store: LocalDocumentStore) { self.store = store }
    public func report(using verification: MCPNativeOriginalVerification? = nil, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> MCPInventoryQualityReport {
        _ = try await store.documents()
        let digest = try LocalInventoryFingerprint.snapshot(store.snapshotURL)
        let documents = try await store.documents()
        let verified = verification.map { Set($0.verifiedIDs) }
        if let verification, let verified {
            let age = Date().timeIntervalSince(verification.checkedAt)
            guard verification.snapshotDigest == digest, (-5...120).contains(age), verification.verifiedIDs.count <= 20_000,
                  verified.count == verification.verifiedIDs.count, verified.isSubset(of: Set(documents.map(\.id))) else { throw LocalInventoryError.changed }
        }
        var rows: [MCPInventoryQualityReport.Row] = []
        for (index, document) in documents.enumerated() {
            try Task.checkCancellation()
            let original: LocalOriginalState?
            if let verified { original = verified.contains(document.id) ? .available : document.localImport?.originalState == .changed ? .changed : .unavailable }
            else { original = try await store.verifiedOriginalState(for: document) }
            var current = document; current.localImport?.originalState = original
            let state = MCPSourceState(current)
            let overviews = current.currentBaseAnalysis?.documents ?? []
            var missing: [String] = []
            if overviews.isEmpty || overviews.contains(where: { $0.kind == .unknown }) { missing.append("Dokumenttyp") }
            if overviews.isEmpty || overviews.contains(where: { $0.issuer == nil }) { missing.append("Aussteller") }
            if overviews.isEmpty || overviews.contains(where: { $0.issueDate == nil }) { missing.append("Dokumentdatum") }
            if overviews.isEmpty || overviews.contains(where: { $0.subject == nil }) { missing.append("Gegenstand") }
            if overviews.isEmpty || overviews.contains(where: { $0.overview == nil }) { missing.append("Übersicht") }
            rows.append(.init(id: document.id, title: document.title, original: original, processing: state.processingStatus,
                              coverage: state.sourceCoverage, analysis: current.baseAnalysisStatus,
                              readable: document.isSearchable && !document.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              expectedPages: document.pageCount, processedPages: Set(document.localImport?.pages.filter { $0.method != .unreadable }.map(\.page) ?? []).count,
                              unfilledBaseFields: missing))
            progress(index + 1, documents.count)
        }
        guard try LocalInventoryFingerprint.snapshot(store.snapshotURL) == digest else { throw LocalInventoryError.changed }
        return .init(createdAt: Date(), snapshotDigest: digest, rows: rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }
}
