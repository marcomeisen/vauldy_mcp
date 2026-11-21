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
    public struct Row: Identifiable, Codable, Sendable {
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
        package var version = Data()
        package var localFingerprint = ""
        public var requiresOriginalVerification = true
        public var originalVerificationPending = false
        public var selectable: Bool { (original == .available || !requiresOriginalVerification) && readable }
        public var eligible: Bool { selectable && !originalVerificationPending }
        public var ready: Bool { eligible && processing == "source-ready" && analysis == "completed" }
        public var selectionReady: Bool { selectable && processing == "source-ready" && analysis == "completed" }
    }
    public let createdAt: Date
    public let snapshotDigest: String
    public let rows: [Row]
    public var nativeVerification: MCPNativeOriginalVerification {
        .init(snapshotDigest: snapshotDigest, checkedAt: createdAt,
              verifiedIDs: rows.filter { $0.original == .available && !$0.originalVerificationPending }.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }
    public var eligibleIDs: Set<UUID> { Set(rows.filter(\.eligible).map(\.id)) }
    public var selectableIDs: Set<UUID> { Set(rows.filter(\.selectable).map(\.id)) }
    public var readyIDs: Set<UUID> { Set(rows.filter(\.ready).map(\.id)) }
    public var reviewIDs: Set<UUID> { eligibleIDs.subtracting(readyIDs) }
    public var selectionReviewIDs: Set<UUID> { selectableIDs.subtracting(Set(rows.filter(\.selectionReady).map(\.id))) }
    public func validateSelection(_ ids: Set<UUID>, acknowledgedReview: Bool, preserving existingIDs: Set<UUID> = []) throws {
        guard ids.isSubset(of: eligibleIDs.union(existingIDs)), acknowledgedReview || ids.subtracting(existingIDs).isDisjoint(with: reviewIDs) else { throw MCPAccessError.notAuthorized }
    }
}

public struct MCPInventoryQualityService: Sendable {
    public let store: LocalDocumentStore
    private struct CachedRow: Codable {
        let recordVersion: String
        let row: MCPInventoryQualityReport.Row
    }

    /// A disposable, local list index. Only the confirmation path verifies originals.
    package func overview() async throws -> MCPInventoryQualityReport {
        let source = LocalVaultSnapshotSource(fileURL: store.snapshotURL)
        guard source.isSQLite else { return try await report(verifyOriginalIDs: []) }
        let digest = try LocalInventoryFingerprint.snapshot(store.snapshotURL)
        let versions = try source.database().inventoryRecordVersions()
        let url = store.root.appendingPathComponent("grant-overview-v1.plist")
        var cache: [UUID: CachedRow] = [:]
        if let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 32_000_000,
           let bytes = try? Data(contentsOf: url),
           let saved = try? PropertyListDecoder().decode([UUID: CachedRow].self, from: bytes) {
            cache = saved.filter { $0.key == $0.value.row.id && versions[$0.key] == $0.value.recordVersion }
        }
        let missing = Set(versions.keys).subtracting(cache.keys)
        if !missing.isEmpty {
            let refreshed = try await report(verifyOriginalIDs: [], grantScope: missing)
            for row in refreshed.rows {
                if let version = versions[row.id] { cache[row.id] = CachedRow(recordVersion: version, row: row) }
            }
        }
        guard try LocalInventoryFingerprint.snapshot(store.snapshotURL) == digest else { throw LocalInventoryError.changed }
        if !missing.isEmpty, let bytes = try? PropertyListEncoder().encode(cache), bytes.count <= 32_000_000 {
            try? bytes.write(to: url, options: .atomic)
        }
        return .init(createdAt: Date(), snapshotDigest: digest, rows: cache.values.map(\.row))
    }

    private static func digest(_ documents: [VaultDocument]) throws -> String {
        LocalInventoryFingerprint.grantDigest(try Dictionary(uniqueKeysWithValues: documents.map { ($0.id, try SQLiteDocumentStore.documentFingerprint($0)) }))
    }

    public init(store: LocalDocumentStore) { self.store = store }
    /// Legacy imported archives have no managed-original metadata. Their text remains
    /// readable through the existing snapshot contract, with an explicit review notice.
    public static func archiveReport(at url: URL, verifyOriginalIDs: Set<UUID>? = nil, grantScope: Set<UUID>? = nil) async throws -> MCPInventoryQualityReport {
        let snapshot = try grantScope == nil ? LocalInventoryFingerprint.snapshot(url) : nil
        let documents = try grantScope.map { try LocalInventoryFingerprint.selectedDocuments(url, ids: $0) } ?? LocalVaultSnapshotSource(fileURL: url).loadDocuments()
        let digest = try snapshot ?? Self.digest(documents)
        if let verifyOriginalIDs {
            guard verifyOriginalIDs.isSubset(of: Set(documents.map(\.id))) else { throw LocalInventoryError.changed }
        }
        let archiveStore = LocalDocumentStore(root: url.deletingLastPathComponent())
        var rows: [MCPInventoryQualityReport.Row] = []
        for document in documents {
            let pending = verifyOriginalIDs.map { !$0.contains(document.id) } == true && document.localImport != nil
            let original = pending ? document.localImport?.originalState : try await archiveStore.verifiedOriginalState(for: document)
            let state = MCPSourceState(document)
            rows.append(.init(id: document.id, title: document.title, original: original,
                processing: state.processingStatus, coverage: state.sourceCoverage,
                analysis: document.baseAnalysisStatus, readable: document.isSearchable && !document.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                expectedPages: document.pageCount, processedPages: 0, unfilledBaseFields: [],
                version: try SQLiteDocumentStore.documentFingerprint(document), localFingerprint: MCPLocalDocumentChoices.fingerprint(document), requiresOriginalVerification: document.localImport != nil, originalVerificationPending: pending))
        }
        try LocalInventoryFingerprint.checkGrant(digest, url: url, ids: grantScope ?? [])
        return .init(createdAt: Date(), snapshotDigest: digest, rows: rows)
    }
    public func report(using verification: MCPNativeOriginalVerification? = nil,
                       progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> MCPInventoryQualityReport {
        try await report(using: verification, verifyOriginalIDs: nil, progress: progress)
    }
    /// An explicit scope defers original reads outside that scope. Deferred rows may be
    /// shown and selected locally, but validateSelection never accepts them as new grants.
    public func report(using verification: MCPNativeOriginalVerification? = nil, verifyOriginalIDs: Set<UUID>?,
                       grantScope: Set<UUID>? = nil,
                       onOriginalCheck: @escaping @Sendable (Int, Int, String) -> Void = { _, _, _ in },
                       progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> MCPInventoryQualityReport {
        guard verification == nil || verifyOriginalIDs == nil else { throw LocalInventoryError.changed }
        let url = store.snapshotURL
        let snapshot = try grantScope == nil ? LocalInventoryFingerprint.snapshot(url) : nil
        let documents: [VaultDocument]
        if let grantScope { documents = try LocalInventoryFingerprint.selectedDocuments(url, ids: grantScope) }
        else { documents = try await store.documents() }
        let digest = try snapshot ?? Self.digest(documents)
        if let verifyOriginalIDs {
            guard verifyOriginalIDs.isSubset(of: Set(documents.map(\.id))) else { throw LocalInventoryError.changed }
        }
        let verified = verification.map { Set($0.verifiedIDs) }
        if let verification, let verified {
            let age = Date().timeIntervalSince(verification.checkedAt)
            guard verification.snapshotDigest == digest, (-5...120).contains(age), verification.verifiedIDs.count <= 20_000,
                  verified.count == verification.verifiedIDs.count, verified.isSubset(of: Set(documents.map(\.id))) else { throw LocalInventoryError.changed }
        }
        var rows: [MCPInventoryQualityReport.Row] = []
        var checkedCount = 0
        let checkTotal = verifyOriginalIDs?.count ?? documents.count
        for document in documents {
            try Task.checkCancellation()
            let original: LocalOriginalState?
            let pending: Bool
            if let verified { original = verified.contains(document.id) ? .available : document.localImport?.originalState == .changed ? .changed : .unavailable }
            else if let verifyOriginalIDs, !verifyOriginalIDs.contains(document.id) {
                original = document.localImport?.originalState
            } else {
                onOriginalCheck(checkedCount + 1, checkTotal, document.sourceName)
                original = try await store.verifiedOriginalState(for: document)
                checkedCount += 1
                progress(checkedCount, checkTotal)
            }
            pending = verified == nil && verifyOriginalIDs.map { !$0.contains(document.id) } == true && document.localImport != nil
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
                              unfilledBaseFields: missing, version: try SQLiteDocumentStore.documentFingerprint(document), localFingerprint: MCPLocalDocumentChoices.fingerprint(document), originalVerificationPending: pending))
        }
        try LocalInventoryFingerprint.checkGrant(digest, url: url, ids: grantScope ?? [])
        return .init(createdAt: Date(), snapshotDigest: digest, rows: rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }
}
