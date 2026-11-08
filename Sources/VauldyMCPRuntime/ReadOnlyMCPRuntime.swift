import Foundation
import CryptoKit
import VauldyCore
import VauldyDocumentCore
import VauldyDocumentIntelligence
import VauldyPrivacy

public struct MCPIndexFeatures: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let largerSnapshotCache = Self(rawValue: 1 << 0)
    public static let compactProjection = Self(rawValue: 1 << 1)
    public static let memoryTokenIndex = Self(rawValue: 1 << 2)
    public static let persistentTokenIndex = Self(rawValue: 1 << 3)
}

/// The only content boundary used by MCP. Raw domain records never become tool results.
public actor ReadOnlyMCPRuntime {
    private struct Lease {
        let databaseGeneration: String?
        let id: UUID
        let fingerprint: Data
        let profile: MCPAccessProfile
    }
    private struct ListSession {
        let fingerprint: Data
        let query: String?
        let pageSize: Int
        let matchMode: VaultTextMatchMode
        let includeExcerpts: Bool
        let overviewScope: String?
        let ids: [UUID]
        var issuedOffsets: Set<Int> = [0]
    }
    private struct CompactProjection {
        struct Row {
            let fingerprint: Data
            let metadata: VaultIndexProjection
        }
        let generation: Data
        let rows: [UUID: Row]
        let ids: [UUID]
        let coverage: MCPProcessingCoverage
        let analysis: MCPAnalysisCoverage
    }
    private struct PassageSession {
        let document: String
        let fingerprint: Data
        let query: String
        var issuedOffsets: Set<Int> = [0]
    }
    private var passageSessions: [String: PassageSession] = [:]
    private var passageOrder: [String] = []
    private struct FieldSession {
        let documents: [String]
        let fields: [MCPExtractionField]
        let profile: MCPAccessProfile
        let fingerprints: [Data]
        var issuedOffsets: Set<Int> = [0]
    }
    private var fieldSessions: [String: FieldSession] = [:]
    private var fieldOrder: [String] = []
    private var listSessions: [String: ListSession] = [:]
    private var listOrder: [String] = []
    private struct InventorySession {
        let fingerprint: Data
        let pageSize: Int
        let order: MCPInventoryOrder
        let ids: [UUID]
        var issuedOffsets: Set<Int> = [0]
    }
    private var inventorySessions: [String: InventorySession] = [:]
    private var inventoryOrder: [String] = []
    private var inventoryReferences: [UUID: String] = [:]
    private var currentProfile: MCPAccessProfile?
    private var handlesByID: [UUID: String] = [:]
    private let profiles: any MCPProfileSource
    private let searchIndex = LocalVault()
    private struct PreparedDocument {
        let fingerprint: Data
        let profile: MCPAccessProfile
        let sections: [VauldyDocumentCore.VaultPageMarkedText.Section]
        let summary: String
        let session: IdentifierPrivacySession
        var bytes: Int { sections.reduce(summary.utf8.count) { $0 + $1.text.utf8.count } }
    }
    private(set) var privacyBuildCount = 0
    private var protectedDocuments: [UUID: PreparedDocument] = [:]
    private var protectedOrder: [UUID] = []
    private var leases: [String: Lease] = [:]
    private let loadVault: (@Sendable (String) throws -> [VaultDocument])?
    private var fileSnapshots: MCPVaultSnapshotCache
    private let indexFeatures: MCPIndexFeatures
    private var persistentIndex: PersistentMCPIndex?
    private var compactProjection: CompactProjection?
    private var tokenIndex: SQLiteVaultTokenIndex?
    private var tokenIndexGeneration: Data?
    private var sourceVersion: MCPFileVersion?
    private var authorizedCache: [VaultDocument]?
    private var fingerprintCache: [UUID: Data] = [:]
    private var generationCache: Data?
    private var accessEpoch: UInt64 = 0
    var snapshotDecodeCount: Int { fileSnapshots.decodeCount }
    var hasSQLiteTokenIndex: Bool { tokenIndex != nil }

    public init(profiles: any MCPProfileSource, experimentalSQLiteIndex: Bool = false,
                indexFeatures: MCPIndexFeatures = [],
                loadVault: (@Sendable (String) throws -> [VaultDocument])? = nil) {
        self.profiles = profiles
        self.loadVault = loadVault
        let features = experimentalSQLiteIndex ? indexFeatures.union([.largerSnapshotCache, .memoryTokenIndex]) : indexFeatures
        self.indexFeatures = features
        fileSnapshots = MCPVaultSnapshotCache(maximumBytes: (features.contains(.largerSnapshotCache) ? 96 : 64) * 1_024 * 1_024)
        if features.contains(.persistentTokenIndex), loadVault == nil, let fileProfile = profiles as? FileMCPProfileSource {
            persistentIndex = PersistentMCPIndex(profileURL: fileProfile.url)
        }
    }

    private func loadProfile() throws -> MCPAccessProfile {
        do {
            let profile = try profiles.load()
            if !profile.enabled { purgeRevokedIndex() }
            return profile
        } catch {
            purgeRevokedIndex()
            clearAccessCaches()
            throw error
        }
    }

    private func purgeRevokedIndex() {
        if let fileProfile = profiles as? FileMCPProfileSource {
            PersistentMCPIndex(profileURL: fileProfile.url).purgeIfPresent()
        }
    }

    public func status() throws -> MCPVaultStatus {
        let profile = try loadProfile()
        guard profile.enabled else {
            clearAccessCaches()
            return MCPVaultStatus(access: "disabled", available: false, grantedDocumentCount: 0, searchableDocumentCount: 0,
                                  coverage: MCPProcessingCoverage(documents: [], grantedCount: 0), warnings: [], processingComplete: false, analysisCoverage: MCPAnalysisCoverage([]))
        }
        if let projection = try sqliteProjection(profile) {
            try recheck(profile, epoch: accessEpoch)
            return vaultStatus(coverage: projection.coverage, analysis: projection.analysis)
        }
        let documents = try authorizedDocuments(profile)
        let epoch = accessEpoch
        let coverage = MCPProcessingCoverage(documents: documents, grantedCount: profile.allowedDocumentIDs.count)
        try recheck(profile, epoch: epoch)
        return vaultStatus(coverage: coverage, analysis: MCPAnalysisCoverage(documents))
    }

    private func vaultStatus(coverage: MCPProcessingCoverage, analysis: MCPAnalysisCoverage) -> MCPVaultStatus {
        MCPVaultStatus(access: "explicit-document-grants", available: true,
                       grantedDocumentCount: coverage.authorizedDocumentCount,
                       searchableDocumentCount: coverage.searchableDocumentCount,
                       coverage: coverage, warnings: coverage.warnings + analysis.warnings,
                       processingComplete: coverage.processingComplete, analysisCoverage: analysis)
    }

    public func search(query: String, limit: Int = 5) async throws -> MCPSearchResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 2_000, (1...10).contains(limit) else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
        if let projection = try sqliteProjection(profile) {
            var terms = LocalVault.queryTerms(query)
            let phrase = VaultSearchText.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
            if phrase.count > 3, let first = phrase.split(whereSeparator: \.isWhitespace).first {
                terms.append(String(first))
            }
            if let selection = try indexedSelection(.ranked(terms), profile: profile, projection: projection) {
                let epoch = accessEpoch
                let candidates = selection.matches.union(selection.uncovered)
                let ranked = try rankSQLite(query: query, limit: limit, profile: profile,
                                            ids: projection.ids.filter { candidates.contains($0) })
                try Task.checkCancellation()
                try recheck(profile, epoch: epoch)
                return searchResult(ranked.hits, limit: limit, count: ranked.count,
                                    coverage: projection.coverage, analysis: projection.analysis)
            }
        }
        let documents = try authorizedDocuments(profile)
        let epoch = accessEpoch
        let raw = try await searchIndex.search(documents: documents, query: query, limit: limit)
        guard epoch == accessEpoch else { throw MCPAccessError.stale }
        var output: [MCPSearchHit] = []
        for hit in raw.hits {
            guard let document = documents.first(where: { $0.id == hit.documentId }) else { continue }
            output.append(try resultItem(document, profile: profile, query: query, preferredPage: hit.page))
        }
        let coverage = MCPProcessingCoverage(documents: documents, grantedCount: profile.allowedDocumentIDs.count)
        let count = raw.totalCount ?? output.count
        try Task.checkCancellation()
        try recheck(profile, epoch: epoch)
        return searchResult(output, limit: limit, count: count, coverage: coverage, analysis: MCPAnalysisCoverage(documents))
    }

    private func rankSQLite(query: String, limit: Int, profile: MCPAccessProfile,
                            ids: [UUID]) throws -> (hits: [MCPSearchHit], count: Int) {
        if let term = LocalVault.compactRankTerm(query), !ids.isEmpty {
            let source = LocalVaultSnapshotSource(fileURL: URL(fileURLWithPath: profile.vaultPath))
            let projected: (scores: [VaultRankScore], uncovered: [UUID])
            do { projected = try source.database().rankScores(ids: ids, term: term) }
            catch is CancellationError { throw CancellationError() }
            catch { throw MCPAccessError.unavailable }
            if projected.uncovered.count < ids.count {
                let ranked = try LocalVault.rankedIDs(term: term, limit: limit, scores: projected.scores) { visit in
                    try visitSQLiteDocuments(profile, ids: projected.uncovered, visit: visit)
                }
                var hits: [MCPSearchHit] = []
                try visitSQLiteDocuments(profile, ids: ranked.ids) { document in
                    hits.append(try resultItem(document, profile: profile, query: query,
                                               preferredPage: LocalVault.rankedEvidencePage(document, query: query)))
                }
                return (hits, ranked.count)
            }
        }
        let ranked = try LocalVault.rankedCandidates(query: query, limit: limit) { visit in
            try visitSQLiteDocuments(profile, ids: ids, visit: visit)
        }
        return (try ranked.hits.map {
            try resultItem($0.document, profile: profile, query: query, preferredPage: $0.page)
        }, ranked.count)
    }

    private func searchResult(_ hits: [MCPSearchHit], limit: Int, count: Int,
                              coverage: MCPProcessingCoverage, analysis: MCPAnalysisCoverage) -> MCPSearchResult {
        MCPSearchResult(hits: hits, limit: limit, totalCount: count, truncated: count > hits.count,
                               processingComplete: coverage.processingComplete, coverage: coverage,
                               warnings: ["RANKED_RESULTS_NOT_EXHAUSTIVE"] + (count > hits.count ? ["RESULTS_TRUNCATED"] : []) + coverage.warnings + analysis.warnings)
    }

    /// Complete enumeration of a deterministic text-filtered authorized set. A changed
    /// authorized snapshot expires continuation rather than skipping or duplicating records.
    public func list(query: String? = nil, pageSize: Int? = nil, cursor: String? = nil,
                     matchMode: VaultTextMatchMode? = nil, includeExcerpts: Bool? = nil) throws -> MCPDocumentListResult {
        try list(query: query, pageSize: pageSize, cursor: cursor, matchMode: matchMode,
                 includeExcerpts: includeExcerpts, overviewScope: nil).page
    }

    private func list(query: String?, pageSize: Int?, cursor: String?, matchMode: VaultTextMatchMode?,
                      includeExcerpts: Bool?, overviewScope: String?) throws
        -> (page: MCPDocumentListResult, documents: [VaultDocument], profile: MCPAccessProfile, epoch: UInt64) {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.map({ !$0.isEmpty && $0.utf8.count <= 2_000 && $0.rangeOfCharacter(from: .alphanumerics) != nil }) ?? true,
              pageSize.map({ (1...100).contains($0) }) ?? true,
              cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
        if let cursor, let projection = compactProjection, currentProfile == profile,
           let version = sourceVersion, overviewScope == nil || version.databaseGeneration != nil,
           (try? MCPFileVersion(URL(fileURLWithPath: profile.vaultPath))) == version {
            let (key, offset, session) = try listCursor(cursor, generation: projection.generation, query: query,
                                                       pageSize: pageSize, matchMode: matchMode, includeExcerpts: includeExcerpts,
                                                       overviewScope: overviewScope)
            if !session.includeExcerpts || version.databaseGeneration != nil {
                let page = try listPage(key: key, offset: offset, session: session, profile: currentProfile ?? profile,
                                        epoch: accessEpoch, documents: [], projection: projection)
                return (page, [], profile, accessEpoch)
            }
        }

        let excerpts = includeExcerpts ?? true, mode = matchMode ?? .allTokens
        if cursor == nil {
            guard (pageSize ?? 20) <= (excerpts ? 25 : 100),
                  mode != .anyTermSubstring || query.map({ VaultDocumentFilter.validCandidateQuery($0) }) ?? true
            else { throw MCPAccessError.invalidArguments }
            if let query, let projection = try sqliteProjection(profile) {
                let terms = VaultDocumentFilter.tokens(query)
                let predicate: SQLiteDocumentStore.SearchPredicate = mode == .allTokens ? .exact(terms) : .substring(terms)
                if let selection = try indexedSelection(predicate, profile: profile, projection: projection) {
                    var matches = selection.matches
                    try visitSQLiteDocuments(profile, ids: selection.uncovered.sorted { $0.uuidString < $1.uuidString }) {
                        if VaultDocumentFilter.matches($0, query: query, mode: mode) { matches.insert($0.id) }
                    }
                    let session = ListSession(fingerprint: projection.generation, query: query, pageSize: pageSize ?? 20,
                                              matchMode: mode, includeExcerpts: excerpts, overviewScope: overviewScope,
                                              ids: projection.ids.filter { matches.contains($0) })
                    let page = try startList(session, profile: currentProfile ?? profile, epoch: accessEpoch,
                                             documents: [], projection: projection)
                    return (page, [], profile, accessEpoch)
                }
            }
        }
        if cursor == nil, overviewScope == nil, query == nil, !excerpts,
           let projection = try sqliteProjection(profile) {
            let session = ListSession(fingerprint: projection.generation, query: nil, pageSize: pageSize ?? 20,
                                      matchMode: mode, includeExcerpts: false, overviewScope: nil, ids: projection.ids)
            let page = try startList(session, profile: currentProfile ?? profile, epoch: accessEpoch,
                                     documents: [], projection: projection)
            return (page, [], profile, accessEpoch)
        }
        if cursor != nil, try pinSQLiteSource(profile) != nil,
           let cursor, listSessions[String(cursor.prefix { $0 != ":" })] == nil {
            throw MCPAccessError.stale
        }
        let documents = try authorizedDocuments(profile)
        let epoch = accessEpoch
        let generation = try snapshotFingerprint(documents)
        if let cursor {
            let (key, offset, session) = try listCursor(cursor, generation: generation, query: query,
                                                       pageSize: pageSize, matchMode: matchMode, includeExcerpts: includeExcerpts,
                                                       overviewScope: overviewScope)
            let page = try listPage(key: key, offset: offset, session: session, profile: profile, epoch: epoch,
                                    documents: documents, projection: nil)
            return (page, documents, profile, epoch)
        }

        let exactQuery = mode == .allTokens ? query : nil
        let usesProjection = overviewScope == nil && !excerpts && sourceVersion != nil
            && (indexFeatures.contains(.compactProjection) || persistentIndex != nil)
        let needsProjection = usesProjection && compactProjection?.generation != generation
        let persisted = (exactQuery != nil || needsProjection)
            ? try diskCandidates(documents, query: exactQuery, profile: profile, generation: generation) : nil
        if needsProjection {
            compactProjection = try makeProjection(documents, profile: profile, generation: generation,
                                                   persisted: persisted?.projections)
        }
        let candidates: Set<UUID>?
        if let persisted {
            candidates = persisted.candidates
        } else if let exactQuery, indexFeatures.contains(.memoryTokenIndex) {
            candidates = try indexedCandidates(documents, query: exactQuery, generation: generation)
        } else {
            candidates = nil
        }
        // SQLite candidates are intersected with the current grant and verified with the original text filter.
        let ids = documents.filter {
            (candidates?.contains($0.id) ?? true) && VaultDocumentFilter.matches($0, query: query, mode: mode)
        }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let session = ListSession(fingerprint: generation, query: query, pageSize: pageSize ?? 20,
                                  matchMode: mode, includeExcerpts: excerpts, overviewScope: overviewScope, ids: ids)
        let page = try startList(session, profile: profile, epoch: epoch,
                                 documents: documents, projection: usesProjection ? compactProjection : nil)
        return (page, documents, profile, epoch)
    }

    private func startList(_ session: ListSession, profile: MCPAccessProfile, epoch: UInt64,
                           documents: [VaultDocument], projection: CompactProjection?) throws -> MCPDocumentListResult {
        let key = UUID().uuidString.lowercased()
        if listOrder.count >= 4 { listSessions.removeValue(forKey: listOrder.removeFirst()) }
        listOrder.append(key)
        return try listPage(key: key, offset: 0, session: session, profile: profile, epoch: epoch,
                            documents: documents, projection: projection)
    }

    public func topicOverview(query: String?, topic: String?, cursor: String?) throws -> MCPTopicOverview {
        let filter: String
        switch (query, topic) {
        case (nil, "insurance"):
            filter = "versicher polic"
        case (let query?, nil) where query.utf8.count <= 240 && VaultDocumentFilter.validCandidateQuery(query):
            filter = query
        default:
            throw MCPAccessError.invalidArguments
        }
        let (page, documents, profile, epoch) = try list(query: filter, pageSize: 25, cursor: cursor,
            matchMode: .anyTermSubstring, includeExcerpts: false, overviewScope: topic ?? "keywords")
        let rows = try page.items.map { item in
            try Task.checkCancellation()
            let (document, _) = try documents.isEmpty
                ? resolveSingle(item.document, profile: profile)
                : resolve(item.document, in: documents, profile: profile)
            return try topicRow(item: item, document: document, profile: profile, filter: filter,
                                insurance: topic == "insurance")
        }
        try Task.checkCancellation()
        try recheck(profile, epoch: epoch)
        return .init(rows: rows, candidateCount: page.totalCount, nextCursor: page.nextCursor,
                     retrievalComplete: page.retrievalComplete, processingComplete: page.processingComplete,
                     coverage: page.coverage, warnings: page.coverage.warnings + [
                        "TEXT_FILTER_ONLY", "ACTIVE_CONTRACT_STATUS_NOT_CHECKED"
                     ])
    }

    public func extractFields(documents handles: [String]?, fields names: [String]?, cursor: String?) throws -> MCPFieldExtractionResult {
        guard handles.map({ (1...10).contains($0.count) && Set($0).count == $0.count && $0.allSatisfy { $0.count <= 64 } }) ?? true,
              names.map({ (1...8).contains($0.count) && Set($0).count == $0.count && $0.allSatisfy { MCPExtractionField(rawValue: $0).map(MCPExtractionField.exposed.contains) == true } }) ?? true,
              cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile(), documents = try authorizedDocuments(profile), epoch = accessEpoch
        let key: String, offset: Int
        var selection: FieldSession
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1] == "f", let value = Int(parts[2]),
                  let session = fieldSessions[String(parts[0])], session.profile == profile else { throw MCPAccessError.stale }
            guard session.issuedOffsets.contains(value), handles == nil || handles == session.documents,
                  names == nil || names == session.fields.map(\.rawValue) else { throw MCPAccessError.invalidArguments }
            selection = session; key = String(parts[0]); offset = value
        } else {
            guard let handles else { throw MCPAccessError.invalidArguments }
            let fields = names?.compactMap(MCPExtractionField.init(rawValue:)) ?? MCPExtractionField.defaults
            let fingerprints = try handles.map { handle in
                let (_, lease) = try resolve(handle, in: documents, profile: profile)
                return lease.fingerprint
            }
            selection = .init(documents: handles, fields: fields, profile: profile, fingerprints: fingerprints)
            key = UUID().uuidString.lowercased(); offset = 0
        }
        var results: [MCPExtractedField] = []
        for (index, handle) in selection.documents.enumerated() {
            try Task.checkCancellation()
            let (document, lease) = try resolve(handle, in: documents, profile: profile)
            guard lease.fingerprint == selection.fingerprints[index] else { throw MCPAccessError.stale }
            let coverage = MCPSourceState(document).sourceCoverage
            if !document.isSearchable || document.localImport?.originalState == .changed {
                results += selection.fields.map {
                    .init(document: handle, field: $0.rawValue, status: "source-unavailable",
                          evidence: [], evidenceCount: 0, evidenceOffset: 0, evidenceComplete: true,
                          sourceCoverage: coverage, warnings: ["NO_CURRENT_SEARCHABLE_SOURCE"])
                }
            } else {
                let prepared = try preparedDocument(document, profile: profile)
                results += try MCPFieldExtraction.extract(sections: prepared.sections, handle: handle,
                                                         fields: selection.fields, sourceCoverage: coverage)
            }
            guard results.count <= 2_048 else { throw MCPAccessError.tooLarge }
        }
        guard offset < results.count else { throw MCPAccessError.invalidArguments }
        let end = min(offset + 8, results.count)
        if end < results.count { selection.issuedOffsets.insert(end) }
        try Task.checkCancellation()
        try recheck(profile, epoch: epoch)
        if fieldSessions[key] == nil {
            if fieldOrder.count >= 4 { fieldSessions.removeValue(forKey: fieldOrder.removeFirst()) }
            fieldOrder.append(key)
        }
        fieldSessions[key] = selection
        return .init(results: Array(results[offset..<end]),
                     nextCursor: end < results.count ? "\(key):f:\(end)" : nil, retrievalComplete: end == results.count)
    }

    public func compareContractVersions(before: String, after: String) throws -> MCPContractComparisonResult {
        guard before != after, (1...64).contains(before.utf8.count), (1...64).contains(after.utf8.count) else {
            throw MCPAccessError.invalidArguments
        }
        let profile = try loadProfile(), documents = try authorizedDocuments(profile), epoch = accessEpoch
        let (left, _) = try resolve(before, in: documents, profile: profile)
        let (right, _) = try resolve(after, in: documents, profile: profile)
        guard left.ocrText.utf8.count <= 1_000_000, right.ocrText.utf8.count <= 1_000_000 else {
            throw MCPAccessError.tooLarge
        }
        let leftState = MCPSourceState(left), rightState = MCPSourceState(right)
        func response(rows: [MCPContractComparisonResult.Row] = [], unresolved: String? = nil) throws -> MCPContractComparisonResult {
            try Task.checkCancellation()
            try recheck(profile, epoch: epoch)
            return .init(status: unresolved == nil ? "compared" : "unresolved-pair",
                before: .init(document: before, sourceCoverage: leftState.sourceCoverage,
                              identitySource: unresolved == nil ? reference(before, page: 1) : nil),
                after: .init(document: after, sourceCoverage: rightState.sourceCoverage,
                             identitySource: unresolved == nil ? reference(after, page: 1) : nil),
                rows: rows, warnings: MCPContractComparison.limitations + (unresolved.map { [$0] } ?? []))
        }
        guard left.isSearchable, right.isSearchable,
              leftState.processingStatus == "source-ready", rightState.processingStatus == "source-ready" else {
            return try response(unresolved: "SOURCE_NOT_READY")
        }
        let leftScope = contractScope(left), rightScope = contractScope(right)
        guard leftScope.allowed, rightScope.allowed else { return try response(unresolved: "DOCUMENT_SCOPE_UNRESOLVED") }

        // Validate whole-document privacy first. Matching itself stays local and emits no identifier values.
        let leftText = try preparedDocument(left, profile: profile)
        let rightText = try preparedDocument(right, profile: profile)
        guard let identity = try MCPContractComparison.identity(in: MCPSourceState.sourceSections(left),
                                                                 hasVerifiedHeading: leftScope.verifiedHeading),
              try MCPContractComparison.identity(in: MCPSourceState.sourceSections(right),
                                                 hasVerifiedHeading: rightScope.verifiedHeading) == identity else {
            return try response(unresolved: "IDENTITY_NOT_UNIQUE_OR_MATCHING")
        }
        let fields = MCPContractComparison.fields
        let previous = try MCPFieldExtraction.extract(sections: leftText.sections, handle: before, fields: fields,
                                                      sourceCoverage: leftState.sourceCoverage, exactValues: true)
        let current = try MCPFieldExtraction.extract(sections: rightText.sections, handle: after, fields: fields,
                                                     sourceCoverage: rightState.sourceCoverage, exactValues: true)
        return try response(rows: MCPContractComparison.compare(previous, current, identity: identity))
    }

    public func deadlineOverview(documents handles: [String]) throws -> MCPDeadlineOverview {
        guard (1...5).contains(handles.count), Set(handles).count == handles.count,
              handles.allSatisfy({ (1...64).contains($0.utf8.count) }) else {
            throw MCPAccessError.invalidArguments
        }
        let profile = try loadProfile()
        let selected: [VaultDocument]
        if try pinSQLiteSource(profile) != nil {
            selected = try handles.map { try resolveSingle($0, profile: profile).0 }
        } else {
            let documents = try authorizedDocuments(profile)
            selected = try handles.map { try resolve($0, in: documents, profile: profile).0 }
        }
        let epoch = accessEpoch
        let rows = try zip(handles, selected).map { handle, document in
            try Task.checkCancellation()
            let state = MCPSourceState(document)
            guard document.isSearchable, document.localImport?.originalState != .changed else {
                return MCPDeadlineOverview.row(document: handle, sourceCoverage: state.sourceCoverage, extracted: [],
                                               sourceReady: false, singleContract: false, sections: [])
            }
            let prepared = try preparedDocument(document, profile: profile)
            let extracted = try MCPFieldExtraction.extract(sections: prepared.sections, handle: handle,
                fields: MCPDeadlineOverview.fields, sourceCoverage: state.sourceCoverage, exactValues: true)
            return MCPDeadlineOverview.row(document: handle, sourceCoverage: state.sourceCoverage, extracted: extracted,
                sourceReady: state.processingStatus == "source-ready", singleContract: contractScope(document).allowed,
                sections: MCPSourceState.sourceSections(document))
        }
        try Task.checkCancellation()
        try recheck(profile, epoch: epoch)
        return .init(rows: rows)
    }

    private func contractScope(_ document: VaultDocument) -> (allowed: Bool, verifiedHeading: Bool) {
        let analysis = document.currentBaseAnalysis
        if document.pageCount != 1 || document.baseAnalysis != nil {
            guard let analysis, analysis.status == .completed || analysis.status == .needsReview,
                  analysis.documents.count == 1,
                  let count = document.pageCount, (1...200).contains(count),
                  analysis.documents[0].pages == Array(1...count) else { return (false, false) }
        }
        let card = analysis?.documents.first
        let verifiedHeading = card?.kindEvidence?.page == 1 && (card?.kind == .contract || card?.kind == .insuranceNotice)
        return (true, verifiedHeading)
    }

    private func topicRow(item: MCPSearchHit, document: VaultDocument, profile: MCPAccessProfile,
                          filter: String, insurance: Bool) throws -> MCPTopicOverview.Row {
        func unresolved(_ status: String) -> MCPTopicOverview.Row {
            .init(document: item.document, status: status, evidence: nil, issuer: nil, subject: nil,
                  processingStatus: item.processingStatus)
        }
        guard document.isSearchable, document.localImport?.originalState != .changed else {
            return unresolved("no-current-searchable-source")
        }
        do {
            let prepared = try preparedDocument(document, profile: profile)
            let pages = prepared.sections.filter { $0.page != nil }
            let policyHeadings: Set<String> = ["versicherungsschein", "versicherungsvertrag", "versicherungspolice"]
            func policyHeading(in text: String) -> String? {
                text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { policyHeadings.contains($0.lowercased()) }
            }
            let policyPage = insurance ? pages.first { policyHeading(in: $0.text) != nil } : nil
            let terms = MCPSourceExcerpt.terms(in: prepared.session.protect(filter))
            let matchingPage = policyPage ?? pages.first { page in
                let projection = VaultSearchText(page.text)
                return terms.contains { !projection.ranges(of: $0, limit: 1).isEmpty }
            }
            guard let matchingPage, let page = matchingPage.page else { return unresolved("no-physical-page-evidence") }
            let quote = policyPage.flatMap { policyHeading(in: $0.text) }
                ?? MCPSourceExcerpt.select(sections: [matchingPage], summary: "",
                                           terms: terms, preferredPage: page, limit: 240).text
            guard quote.utf8.count <= 520 else { return unresolved("evidence-withheld") }
            let card = document.currentBaseAnalysis?.documents.first { $0.pages.contains(page) }
            func field(_ value: BaseEvidenceField?) throws -> MCPAnalysisField? {
                guard let value else { return nil }
                let protectedValue = try protect(value.value, using: prepared.session)
                let protectedQuote = try protect(value.quote, using: prepared.session)
                guard protectedValue.utf8.count <= 120, protectedQuote.utf8.count <= 160 else { return nil }
                return .init(role: value.role.rawValue, value: protectedValue, page: value.page,
                             quote: protectedQuote, source: reference(item.document, page: value.page))
            }
            return .init(document: item.document, status: policyPage != nil ? "policy-heading" : "topic-mention",
                         evidence: .init(page: page, quote: quote, source: reference(item.document, page: page)),
                         issuer: try field(card?.issuer), subject: try field(card?.subject),
                         processingStatus: item.processingStatus)
        } catch MCPAccessError.privacy, MCPAccessError.tooLarge {
            return unresolved("evidence-withheld")
        }
    }

    private func listCursor(_ cursor: String, generation: Data, query: String?, pageSize: Int?,
                            matchMode: VaultTextMatchMode?, includeExcerpts: Bool?,
                            overviewScope: String?) throws -> (String, Int, ListSession) {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let offset = Int(parts[1]), offset >= 0,
              let session = listSessions[String(parts[0])], session.overviewScope == overviewScope else {
            throw MCPAccessError.stale
        }
        let key = String(parts[0])
        guard session.fingerprint == generation else {
            listSessions.removeValue(forKey: key)
            listOrder.removeAll { $0 == key }
            throw MCPAccessError.stale
        }
        guard session.issuedOffsets.contains(offset),
              query == nil || query == session.query,
              pageSize == nil || pageSize == session.pageSize,
              matchMode == nil || matchMode == session.matchMode,
              includeExcerpts == nil || includeExcerpts == session.includeExcerpts else { throw MCPAccessError.invalidArguments }
        return (key, offset, session)
    }

    private func listPage(key: String, offset: Int, session: ListSession, profile: MCPAccessProfile, epoch: UInt64,
                          documents: [VaultDocument], projection: CompactProjection?) throws -> MCPDocumentListResult {
        var session = session
        let end = min(offset + session.pageSize, session.ids.count)
        let items: [MCPSearchHit]
        let coverage: MCPProcessingCoverage
        let analysisWarnings: [String]
        if let projection {
            if session.includeExcerpts {
                var excerpts: [MCPSearchHit] = []
                try visitSQLiteDocuments(profile, ids: Array(session.ids[offset..<end])) {
                    excerpts.append(try resultItem($0, profile: profile, query: session.query, preferredPage: nil))
                }
                items = excerpts
            } else {
                items = try session.ids[offset..<end].map { id in
                    guard let row = projection.rows[id], profile.allowedDocumentIDs.contains(id) else { throw MCPAccessError.stale }
                    return compactItem(id: id, fingerprint: row.fingerprint, metadata: row.metadata, profile: profile)
                }
            }
            coverage = projection.coverage
            analysisWarnings = projection.analysis.warnings
        } else {
            let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
            items = try session.ids[offset..<end].map { id in
                guard let document = byID[id] else { throw MCPAccessError.stale }
                if !session.includeExcerpts {
                    return compactItem(id: id, fingerprint: try fingerprint(document),
                                       metadata: MCPSourceState(document).projection(for: document), profile: profile)
                }
                return try resultItem(document, profile: profile, query: session.query, preferredPage: nil)
            }
            coverage = MCPProcessingCoverage(documents: documents, grantedCount: profile.allowedDocumentIDs.count)
            analysisWarnings = MCPAnalysisCoverage(documents).warnings
        }
        let more = end < session.ids.count
        if more { session.issuedOffsets.insert(end) }
        listSessions[key] = session
        try Task.checkCancellation()
        try recheck(profile, epoch: epoch)
        return MCPDocumentListResult(filter: session.matchMode == .allTokens ? "all-normalized-text-tokens; not an issuer filter" : "any-normalized-term-substring; candidates, not a classification or issuer filter",
                                     snapshot: key, items: items, totalCount: session.ids.count, hasMore: more,
                                     nextCursor: more ? "\(key):\(end)" : nil, retrievalComplete: !more,
                                     processingComplete: coverage.processingComplete, coverage: coverage,
                                     warnings: ["ORGANIZATION_RELATIONSHIPS_NOT_RESOLVED"]
                                        + (session.matchMode == .anyTermSubstring ? ["BROAD_TEXT_CANDIDATES_NOT_CLASSIFICATION"] : [])
                                        + (session.includeExcerpts ? [] : ["EXCERPTS_OMITTED"])
                                        + (session.query == nil ? [] : ["TEXT_FILTER_NOT_ISSUER_ASSIGNMENT"]) + coverage.warnings + analysisWarnings)
    }

    private func compactItem(id: UUID, fingerprint: Data, metadata: VaultIndexProjection, profile: MCPAccessProfile) -> MCPSearchHit {
        let handle = lease(id: id, fingerprint: fingerprint, profile: profile)
        return MCPSearchHit(document: handle, title: "Freigegebenes Dokument", page: nil, excerpt: "",
                            source: reference(handle, page: nil), processingStatus: metadata.processingStatus,
                            sourceCoverage: metadata.sourceCoverage, analysisStatus: metadata.analysisStatus)
    }

    private func inventoryReference(_ id: UUID) -> String {
        if let existing = inventoryReferences[id] { return existing }
        if inventoryReferences.count >= 20_000 { inventoryReferences.removeAll(keepingCapacity: true) }
        let value = MCPDocumentIdentity.reference(id)
        inventoryReferences[id] = value
        return value
    }

    private func makeProjection(_ documents: [VaultDocument], profile: MCPAccessProfile, generation: Data,
                                persisted: [UUID: VaultIndexProjection]?) throws -> CompactProjection {
        var rows: [UUID: CompactProjection.Row] = [:]
        for document in documents {
            try Task.checkCancellation()
            let metadata = persisted?[document.id] ?? MCPSourceState(document).projection(for: document)
            rows[document.id] = .init(fingerprint: try fingerprint(document), metadata: metadata)
        }
        return makeProjection(rows, profile: profile, generation: generation,
                              ids: rows.keys.sorted { $0.uuidString < $1.uuidString })
    }

    private func makeProjection(_ rows: [UUID: CompactProjection.Row], profile: MCPAccessProfile,
                                generation: Data, ids: [UUID]) -> CompactProjection {
        let coverage = MCPProcessingCoverage(statuses: rows.values.map { $0.metadata.processingStatus },
                                             searchableCount: rows.values.count { $0.metadata.searchable },
                                             grantedCount: profile.allowedDocumentIDs.count)
        return CompactProjection(generation: generation, rows: rows, ids: ids, coverage: coverage,
                                 analysis: MCPAnalysisCoverage(states: rows.values.map { $0.metadata.analysisStatus }))
    }

    public func documentInventory(pageSize: Int? = nil, cursor: String? = nil,
                                  order: MCPInventoryOrder? = nil) throws -> MCPDocumentInventory {
        guard pageSize.map({ (1...100).contains($0) }) ?? true,
              cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
        let projection: CompactProjection
        if let stored = try sqliteProjection(profile) {
            var rows = stored.rows
            let legacy = stored.ids.filter { rows[$0]?.metadata.inventoryVersion != 1 }
            // Old compact projections remain readable. Backfill only in memory, one record at a time.
            if !legacy.isEmpty {
                try visitSQLiteDocuments(profile, ids: legacy) { document in
                    rows[document.id] = .init(fingerprint: try fingerprint(document),
                                              metadata: MCPSourceState(document).projection(for: document))
                }
            }
            projection = makeProjection(rows, profile: profile, generation: stored.generation, ids: stored.ids)
        } else {
            let documents = try authorizedDocuments(profile)
            let generation = try snapshotFingerprint(documents)
            if let cached = compactProjection, cached.generation == generation,
               cached.rows.values.allSatisfy({ $0.metadata.inventoryVersion == 1 }) { projection = cached }
            else { projection = try makeProjection(documents, profile: profile, generation: generation, persisted: nil) }
        }
        compactProjection = projection
        let epoch = accessEpoch
        let key: String, offset: Int
        var session: InventorySession
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "inventory", let index = Int(parts[2]),
                  let previous = inventorySessions[String(parts[1])], index >= 0,
                  previous.fingerprint == projection.generation else { throw MCPAccessError.stale }
            guard previous.issuedOffsets.contains(index), pageSize == nil || pageSize == previous.pageSize,
                  order == nil || order == previous.order else { throw MCPAccessError.invalidArguments }
            key = String(parts[1]); offset = index; session = previous
        } else {
            let selectedOrder = order ?? .importedDescending
            let ids = projection.ids.sorted { left, right in
                let l = projection.rows[left]?.metadata.importedAt, r = projection.rows[right]?.metadata.importedAt
                if let l, let r, l != r { return selectedOrder == .importedDescending ? l > r : l < r }
                if (l == nil) != (r == nil) { return l != nil }
                return inventoryReference(left) < inventoryReference(right)
            }
            key = UUID().uuidString.lowercased(); offset = 0
            session = .init(fingerprint: projection.generation, pageSize: pageSize ?? 20, order: selectedOrder, ids: ids)
            inventoryOrder.append(key)
            while inventoryOrder.count > 8 { inventorySessions.removeValue(forKey: inventoryOrder.removeFirst()) }
        }
        let end = min(offset + session.pageSize, session.ids.count)
        let items = try session.ids[offset..<end].map { id -> MCPDocumentInventory.Item in
            guard let row = projection.rows[id], profile.allowedDocumentIDs.contains(id) else { throw MCPAccessError.stale }
            let handle = lease(id: id, fingerprint: row.fingerprint, profile: profile)
            return .init(document: handle, documentID: inventoryReference(id),
                         importedAt: MCPDocumentIdentity.timestamp(row.metadata.importedAt), contentHash: row.metadata.contentHash,
                         originalState: row.metadata.originalState ?? "unknown", processingStatus: row.metadata.processingStatus,
                         sourceCoverage: row.metadata.sourceCoverage)
        }
        let more = end < session.ids.count
        if more { session.issuedOffsets.insert(end) }
        inventorySessions[key] = session
        try Task.checkCancellation()
        try recheck(profile, epoch: epoch)
        return .init(order: session.order.rawValue, snapshot: key, items: items, totalCount: session.ids.count,
                     nextCursor: more ? "inventory:\(key):\(end)" : nil, retrievalComplete: !more, coverage: projection.coverage)
    }

    public func read(document handle: String, cursor: String? = nil) throws -> MCPDocumentResult {
        guard handle.count <= 64, cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
        let (document, _) = try resolveSingle(handle, profile: profile)
        let epoch = accessEpoch
        guard document.isSearchable else { throw MCPAccessError.stale }
        let offset: Int
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == handle, let value = Int(parts[1]), value >= 0 else {
                throw MCPAccessError.invalidArguments
            }
            offset = value
        } else { offset = 0 }
        let prepared = try preparedDocument(document, profile: profile)
        var segments: [MCPDocumentSegment] = []
        for section in prepared.sections {
            for (index, chunk) in chunks(section.text, limit: 6_000).enumerated() {
                segments.append(MCPDocumentSegment(page: section.page, part: index + 1, text: chunk,
                                                   source: reference(handle, page: section.page)))
            }
        }
        guard !segments.isEmpty else { throw MCPAccessError.unavailable }
        guard offset < segments.count else { throw MCPAccessError.invalidArguments }
        let end = min(offset + 3, segments.count)
        let pages = prepared.sections.compactMap(\.page)
        let expected = document.pageCount.flatMap { $0 > 0 ? $0 : nil }
        let state = MCPSourceState(document)
        try Task.checkCancellation()
        try recheck(profile, epoch: epoch)
        return MCPDocumentResult(document: handle, title: "Freigegebenes Dokument",
                                 segments: Array(segments[offset..<end]), expectedPageCount: expected,
                                 availablePages: Array(Set(pages)).sorted(),
                                 sourceCoverage: state.sourceCoverage,
                                 nextCursor: end < segments.count ? "\(handle):\(end)" : nil,
                                 containsEntireAvailableText: offset == 0 && end == segments.count,
                                 pageStatus: document.localImport?.pages.compactMap {
                                     guard MCPSourceState.physicalPage($0.page, declaredCount: document.pageCount) else { return nil }
                                     return MCPPageStatus(page: $0.page, method: $0.method.rawValue, needsReview: $0.needsReview)
                                 } ?? [], analysisStatus: document.baseAnalysisStatus)
    }

    /// Search within one granted document without transferring unrelated source pages.
    /// Results are literal protected windows, not summaries or a full-document claim.
    public func passages(document handle: String, query: String? = nil, cursor: String? = nil) throws -> MCPPassagesResult {
        guard handle.count <= 64, cursor.map({ $0.count <= 90 }) ?? true,
              query.map({ $0.utf8.count <= 2_000 && VaultDocumentFilter.validCandidateQuery($0) }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
        let (document, lease) = try resolveSingle(handle, profile: profile)
        let epoch = accessEpoch
        guard document.isSearchable else { throw MCPAccessError.stale }
        let key: String, offset: Int
        var selection: PassageSession
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1] == "p", let value = Int(parts[2]), value >= 0,
                  let previous = passageSessions[String(parts[0])], previous.document == handle,
                  previous.fingerprint == lease.fingerprint else { throw MCPAccessError.stale }
            guard previous.issuedOffsets.contains(value), query == nil || query == previous.query else { throw MCPAccessError.invalidArguments }
            key = String(parts[0]); offset = value; selection = previous
        } else {
            guard let query else { throw MCPAccessError.invalidArguments }
            key = UUID().uuidString.lowercased(); offset = 0
            selection = .init(document: handle, fingerprint: lease.fingerprint, query: query)
            if passageOrder.count >= 16 { passageSessions.removeValue(forKey: passageOrder.removeFirst()) }
            passageOrder.append(key)
        }
        let prepared = try preparedDocument(document, profile: profile)
        let terms = MCPSourceExcerpt.terms(in: prepared.session.protect(selection.query))
        let windows = try MCPSourceExcerpt.passages(sections: prepared.sections, terms: terms)
        var segments: [MCPDocumentSegment] = []
        for window in windows {
            for text in chunks(window.text, limit: 1_000) {
                segments.append(.init(page: window.page, part: segments.count + 1, text: text, source: reference(handle, page: window.page)))
            }
        }
        guard offset <= segments.count else { throw MCPAccessError.invalidArguments }
        let end = min(offset + 8, segments.count)
        if end < segments.count { selection.issuedOffsets.insert(end) }
        passageSessions[key] = selection
        try recheck(profile, epoch: epoch)
        return .init(document: handle, segments: Array(segments[offset..<end]), matchingPassageCount: segments.count,
                     nextCursor: end < segments.count ? "\(key):p:\(end)" : nil, retrievalComplete: end == segments.count,
                     sourceCoverage: MCPSourceState(document).sourceCoverage, analysisStatus: document.baseAnalysisStatus)
    }

    /// One logical record per metadata page. Continuation is bound to the same
    /// content fingerprint and permission lease as full-text reading.
    public func readMetadata(document handle: String, cursor: String? = nil) throws -> MCPMetadataResult {
        guard handle.count <= 64, cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
        let (document, _) = try resolveSingle(handle, profile: profile)
        let epoch = accessEpoch
        let analysis = document.currentBaseAnalysis
        let records = analysis?.documents ?? []
        let offset: Int
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == handle, parts[1] == "m", let value = Int(parts[2]),
                  value >= 0, value < records.count else { throw MCPAccessError.invalidArguments }
            offset = value
        } else { offset = 0 }
        let end = min(offset + 1, records.count)
        let session = try preparedDocument(document, profile: profile).session
        let output = try records[offset..<end].map { card in
            MCPLogicalDocument(pages: card.pages, documentType: card.kind.rawValue,
                               title: try protect(card.title, using: session),
                               overview: try card.overview.map { try protect($0.value, using: session) },
                               fields: try card.fields.map { field in
                MCPAnalysisField(role: field.role.rawValue, value: try protect(field.value, using: session), page: field.page,
                                 quote: try protect(field.quote, using: session), source: reference(handle, page: field.page))
            }, warnings: MCPAnalysisWarnings.safe(card.issues))
        }
        try Task.checkCancellation()
        try recheck(profile, epoch: epoch)
        return MCPMetadataResult(document: handle, analysisStatus: document.baseAnalysisStatus, engine: analysis?.engine.rawValue,
                                 analyzedPages: analysis?.analyzedPages ?? [], logicalDocumentCount: records.count, documents: output,
                                 hasMore: end < records.count, nextCursor: end < records.count ? "\(handle):m:\(end)" : nil,
                                 warnings: MCPAnalysisWarnings.safe(analysis?.issues ?? [document.baseAnalysis == nil ? "NOT_ANALYZED" : "STALE_ANALYSIS"]))
    }

    private func diskCandidates(_ documents: [VaultDocument], query: String?, profile: MCPAccessProfile,
                                generation: Data) throws -> PersistentMCPIndex.Result? {
        guard var index = persistentIndex, let version = sourceVersion else { return nil }
        let source = profiles
        do {
            let records = try documents.map { (document: $0, fingerprint: try fingerprint($0)) }
            let result = try index.query(query, profile: profile, generation: generation, records: records) {
                guard (try? source.load()) == profile,
                      (try? MCPFileVersion(URL(fileURLWithPath: profile.vaultPath))) == version else {
                    throw MCPAccessError.stale
                }
            }
            persistentIndex = index
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch MCPAccessError.stale {
            clearAccessCaches()
            throw MCPAccessError.stale
        } catch {
            return nil
        }
    }

    private func indexedCandidates(_ documents: [VaultDocument], query: String,
                                   generation: Data) throws -> Set<UUID>? {
        do {
            if tokenIndexGeneration != generation {
                let index = try tokenIndex ?? SQLiteVaultTokenIndex()
                let records = try documents.map { (document: $0, fingerprint: try fingerprint($0)) }
                try index.reconcile(records)
                tokenIndex = index
                tokenIndexGeneration = generation
            }
            return try tokenIndex?.matchingIDs(for: query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // FTS5 availability and resource limits must not affect contract completeness.
            tokenIndex = nil
            tokenIndexGeneration = generation
            return nil
        }
    }

    private func pinSQLiteSource(_ profile: MCPAccessProfile) throws -> LocalVaultSnapshotSource? {
        let source = LocalVaultSnapshotSource(fileURL: URL(fileURLWithPath: profile.vaultPath))
        guard loadVault == nil, source.isSQLite else { return nil }
        try profile.validate()
        guard profile.enabled else {
            clearAccessCaches()
            throw MCPAccessError.notAuthorized
        }
        guard let version = try? MCPFileVersion(source.fileURL) else {
            clearAccessCaches()
            throw MCPAccessError.unavailable
        }
        if currentProfile != profile || sourceVersion != version {
            clearAccessCaches()
            currentProfile = profile
            sourceVersion = version
        }
        return source
    }

    private func sqliteProjection(_ profile: MCPAccessProfile) throws -> CompactProjection? {
        guard let source = try pinSQLiteSource(profile), let token = sourceVersion?.databaseGeneration else { return nil }
        if let compactProjection { return compactProjection }
        let stored: [UUID: SQLiteDocumentStore.Projection]
        do {
            guard let rows = try source.database().projections(ids: profile.allowedDocumentIDs) else { return nil }
            stored = rows
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            clearAccessCaches()
            throw MCPAccessError.unavailable
        }
        let ids = stored.keys.sorted { $0.uuidString < $1.uuidString }
        var hash = SHA256()
        hash.update(data: Data(token.utf8))
        let rows = stored.mapValues { CompactProjection.Row(fingerprint: $0.fingerprint, metadata: $0.metadata) }
        for id in ids {
            if let row = rows[id] { hash.update(data: row.fingerprint) }
        }
        let projection = makeProjection(rows, profile: profile, generation: Data(hash.finalize()), ids: ids)
        try recheck(profile, epoch: accessEpoch)
        compactProjection = projection
        return projection
    }

    private func indexedSelection(_ predicate: SQLiteDocumentStore.SearchPredicate, profile: MCPAccessProfile,
                                  projection: CompactProjection) throws -> (matches: Set<UUID>, uncovered: Set<UUID>)? {
        let source = LocalVaultSnapshotSource(fileURL: URL(fileURLWithPath: profile.vaultPath))
        do {
            return try source.database().searchSelection(predicate, allowed: Set(projection.ids))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            clearAccessCaches()
            throw MCPAccessError.unavailable
        }
    }

    private func visitSQLiteDocuments(_ profile: MCPAccessProfile, ids: [UUID],
                                      visit: (VaultDocument) throws -> Void) throws {
        guard !ids.isEmpty else { return }
        let source = LocalVaultSnapshotSource(fileURL: URL(fileURLWithPath: profile.vaultPath))
        let database: SQLiteDocumentStore
        do { database = try source.database() }
        catch { throw MCPAccessError.unavailable }
        for id in ids {
            try Task.checkCancellation()
            guard profile.allowedDocumentIDs.contains(id) else { throw MCPAccessError.stale }
            let document: VaultDocument?
            do { document = try database.document(id: id) }
            catch { throw MCPAccessError.unavailable }
            guard let document else { throw MCPAccessError.stale }
            try visit(document)
        }
    }

    private func resolveSingle(_ handle: String, profile: MCPAccessProfile) throws -> (VaultDocument, Lease) {
        guard let source = try pinSQLiteSource(profile) else {
            return try resolve(handle, in: authorizedDocuments(profile), profile: profile)
        }
        guard let lease = leases[handle], lease.profile == profile,
              lease.databaseGeneration == sourceVersion?.databaseGeneration,
              profile.allowedDocumentIDs.contains(lease.id) else { throw MCPAccessError.stale }
        let document: VaultDocument?
        do { document = try source.database().document(id: lease.id) }
        catch { clearAccessCaches(); throw MCPAccessError.unavailable }
        guard let document else { throw MCPAccessError.stale }
        return try resolve(handle, in: [document], profile: profile)
    }

    private func authorizedDocuments(_ profile: MCPAccessProfile) throws -> [VaultDocument] {
        try profile.validate()
        guard profile.enabled, profile.acknowledgedCloudDisclosure else {
            clearAccessCaches()
            throw MCPAccessError.notAuthorized
        }
        if currentProfile != profile { clearAccessCaches(); currentProfile = profile }
        do {
            let all: [VaultDocument]
            let version: MCPFileVersion?
            if let loadVault { all = try loadVault(profile.vaultPath); version = nil }
            else {
                let loaded = try fileSnapshots.load(profile.vaultPath, allowedIDs: profile.allowedDocumentIDs)
                if sourceVersion == loaded.version, let authorizedCache { return authorizedCache }
                all = loaded.documents; version = loaded.version
            }
            guard Set(all.map(\.id)).count == all.count else { throw MCPAccessError.unavailable }
            let allowed = all.filter { profile.allowedDocumentIDs.contains($0.id) }
            if version == nil || sourceVersion != version {
                fingerprintCache.removeAll(); generationCache = nil; compactProjection = nil; accessEpoch &+= 1
            }
            sourceVersion = version
            authorizedCache = version != nil && fileSnapshots.retainsDocuments ? allowed : nil
            let ids = Set(allowed.map(\.id))
            protectedDocuments = protectedDocuments.filter { ids.contains($0.key) && $0.value.profile == profile }
            protectedOrder = protectedOrder.filter { protectedDocuments[$0] != nil }
            return allowed
        } catch VaultSnapshotError.tooLarge {
            clearAccessCaches(); throw MCPAccessError.tooLarge
        } catch { clearAccessCaches(); throw MCPAccessError.unavailable }
    }

    private func recheck(_ profile: MCPAccessProfile, epoch: UInt64) throws {
        guard epoch == accessEpoch, try loadProfile() == profile,
              sourceVersion == nil || (try? MCPFileVersion(URL(fileURLWithPath: profile.vaultPath))) == sourceVersion else {
            clearAccessCaches()
            throw MCPAccessError.stale
        }
    }

    private func fingerprint(_ document: VaultDocument) throws -> Data {
        if let existing = fingerprintCache[document.id] { return existing }
        let value = try SQLiteDocumentStore.documentFingerprint(document)
        fingerprintCache[document.id] = value
        return value
    }

    private func lease(for document: VaultDocument, profile: MCPAccessProfile) throws -> String {
        try lease(id: document.id, fingerprint: fingerprint(document), profile: profile)
    }

    private func resolve(_ handle: String, in documents: [VaultDocument],
                         profile: MCPAccessProfile) throws -> (VaultDocument, Lease) {
        guard let lease = leases[handle], lease.profile == profile, lease.databaseGeneration == sourceVersion?.databaseGeneration else { throw MCPAccessError.stale }
        guard let document = documents.first(where: { $0.id == lease.id }),
              try fingerprint(document) == lease.fingerprint else {
            leases.removeValue(forKey: handle)
            handlesByID.removeValue(forKey: lease.id)
            throw MCPAccessError.stale
        }
        return (document, lease)
    }

    private func lease(id: UUID, fingerprint: Data, profile: MCPAccessProfile) -> String {
        if let handle = handlesByID[id], let existing = leases[handle],
           existing.fingerprint == fingerprint, existing.profile == profile,
           existing.databaseGeneration == sourceVersion?.databaseGeneration { return handle }
        if let old = handlesByID.removeValue(forKey: id) { leases.removeValue(forKey: old) }
        let handle = UUID().uuidString.lowercased()
        leases[handle] = Lease(databaseGeneration: sourceVersion?.databaseGeneration, id: id, fingerprint: fingerprint, profile: profile)
        handlesByID[id] = handle
        return handle
    }

    private func preparedDocument(_ document: VaultDocument, profile: MCPAccessProfile) throws -> PreparedDocument {
        let hash = try fingerprint(document)
        if let existing = protectedDocuments[document.id], existing.fingerprint == hash, existing.profile == profile { return existing }
        protectedDocuments.removeValue(forKey: document.id); protectedOrder.removeAll { $0 == document.id }
        let session = try privacySession(document)
        privacyBuildCount += 1
        let sections = try MCPSourceState.sourceSections(document).map {
            VauldyDocumentCore.VaultPageMarkedText.Section(page: $0.page, text: try protect($0.text, using: session))
        }
        let result = PreparedDocument(fingerprint: hash, profile: profile, sections: sections,
                                      summary: try protect(document.summary, using: session), session: session)
        while protectedDocuments.count >= 8 || protectedDocuments.values.reduce(0, { $0 + $1.bytes }) + result.bytes > 8_000_000 {
            guard let first = protectedOrder.first else { break }
            protectedDocuments.removeValue(forKey: first); protectedOrder.removeFirst()
        }
        if result.bytes <= 8_000_000 { protectedDocuments[document.id] = result; protectedOrder.append(document.id) }
        return result
    }

    private func clearAccessCaches() {
        accessEpoch &+= 1
        leases.removeAll(); handlesByID.removeAll(); protectedDocuments.removeAll(); protectedOrder.removeAll()
        listSessions.removeAll(); listOrder.removeAll(); passageSessions.removeAll(); passageOrder.removeAll(); currentProfile = nil
        inventorySessions.removeAll(); inventoryOrder.removeAll()
        inventoryReferences.removeAll()
        fieldSessions.removeAll(); fieldOrder.removeAll()
        fileSnapshots.clear(); sourceVersion = nil; authorizedCache = nil
        tokenIndex = nil; tokenIndexGeneration = nil; compactProjection = nil
        fingerprintCache.removeAll(); generationCache = nil
    }

    private func snapshotFingerprint(_ documents: [VaultDocument]) throws -> Data {
        if let generationCache { return generationCache }
        var hash = SHA256()
        if let generation = sourceVersion?.databaseGeneration { hash.update(data: Data(generation.utf8)) }
        for document in documents.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            hash.update(data: try fingerprint(document))
        }
        let value = Data(hash.finalize()); generationCache = value
        return value
    }

    private func resultItem(_ document: VaultDocument, profile: MCPAccessProfile, query: String?, preferredPage: Int?) throws -> MCPSearchHit {
        let prepared = try preparedDocument(document, profile: profile)
        let terms = MCPSourceExcerpt.terms(in: prepared.session.protect(query ?? ""))
        let excerpt = MCPSourceExcerpt.select(sections: prepared.sections, summary: prepared.summary,
                                             terms: terms, preferredPage: preferredPage)
        let handle = try lease(for: document, profile: profile)
        let state = MCPSourceState(document)
        return MCPSearchHit(document: handle, title: "Freigegebenes Dokument", page: excerpt.page,
                            excerpt: excerpt.text, source: reference(handle, page: excerpt.page),
                            processingStatus: state.processingStatus, sourceCoverage: state.sourceCoverage, analysisStatus: document.baseAnalysisStatus)
    }

    private func privacySession(_ document: VaultDocument) throws -> IdentifierPrivacySession {
        let entityNames = document.entities.filter {
            ["person", "recipient", "patient", "customer"].contains($0.type.lowercased())
        }.map { "Name: \($0.value)" }
        let metadataNames = document.currentBaseAnalysis?.documents.compactMap { $0.recipient?.value }.map { "Name: \($0)" } ?? []
        let metadata = document.currentBaseAnalysis?.documents.flatMap { card in
            [card.title] + card.fields.flatMap { [$0.value, $0.quote] }
        } ?? []
        let sourceSections = VauldyDocumentCore.VaultPageMarkedText.sections(in: document.ocrText).map(\.text)
        let contents = [document.title, document.sourceName, document.summary] + sourceSections + metadata + metadataNames
            + document.entities.map { "\($0.type): \($0.value)\n\($0.sourceSnippet)" } + entityNames
            + document.contentFacts.map { "\($0.label): \($0.value)\n\($0.sourceSnippet)" }
            + document.deadlines.map { "\($0.title)\n\($0.sourceSnippet)" }
        guard contents.reduce(0, { $0 + $1.utf8.count }) <= 1_000_000 else { throw MCPAccessError.tooLarge }
        do { return try IdentifierPrivacySession(contents: contents) }
        catch { throw MCPAccessError.privacy }
    }

    private func protect(_ value: String, using session: IdentifierPrivacySession) throws -> String {
        do { return try session.protectForSending(value) }
        catch { throw MCPAccessError.privacy }
    }

    private func reference(_ handle: String, page: Int?) -> String {
        page.map { "[Quelle:\(handle):S.\($0)]" } ?? "[Quelle:\(handle)]"
    }

    /// Bound response sizes without splitting a pseudonym or silently dropping remaining text.
    private func chunks(_ text: String, limit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var remaining = text[...]
        while !remaining.isEmpty {
            var end = remaining.index(remaining.startIndex, offsetBy: min(limit, remaining.count))
            let prefix = remaining[..<end]
            if let open = prefix.lastIndex(of: "["), !prefix[open...].contains("]"),
               prefix[open...].hasPrefix("[V_"), open != remaining.startIndex { end = open }
            result.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        return result
    }
}
