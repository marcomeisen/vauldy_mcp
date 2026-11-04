import Foundation
import CryptoKit
import VauldyCore
import VauldyDocumentCore
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
        let coverage: MCPProcessingCoverage
        let analysisWarnings: [String]
    }
    private struct PassageSession {
        let document: String
        let fingerprint: Data
        let query: String
        var issuedOffsets: Set<Int> = [0]
    }
    private var passageSessions: [String: PassageSession] = [:]
    private var passageOrder: [String] = []
    private var listSessions: [String: ListSession] = [:]
    private var listOrder: [String] = []
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
        let documents = try authorizedDocuments(profile)
        let epoch = accessEpoch
        let coverage = MCPProcessingCoverage(documents: documents, grantedCount: profile.allowedDocumentIDs.count)
        try recheck(profile, epoch: epoch)
        return MCPVaultStatus(access: "explicit-document-grants", available: true,
                              grantedDocumentCount: documents.count,
                              searchableDocumentCount: documents.filter(\.isSearchable).count,
                              coverage: coverage, warnings: coverage.warnings + MCPAnalysisCoverage(documents).warnings, processingComplete: coverage.processingComplete,
                              analysisCoverage: MCPAnalysisCoverage(documents))
    }

    public func search(query: String, limit: Int = 5) async throws -> MCPSearchResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 2_000, (1...10).contains(limit) else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
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
        return MCPSearchResult(hits: output, limit: limit, totalCount: count, truncated: count > output.count,
                               processingComplete: coverage.processingComplete, coverage: coverage,
                               warnings: ["RANKED_RESULTS_NOT_EXHAUSTIVE"] + (count > output.count ? ["RESULTS_TRUNCATED"] : []) + coverage.warnings + MCPAnalysisCoverage(documents).warnings)
    }

    /// Complete enumeration of a deterministic text-filtered authorized set. A changed
    /// authorized snapshot expires continuation rather than skipping or duplicating records.
    public func list(query: String? = nil, pageSize: Int? = nil, cursor: String? = nil,
                     matchMode: VaultTextMatchMode? = nil, includeExcerpts: Bool? = nil) throws -> MCPDocumentListResult {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.map({ !$0.isEmpty && $0.utf8.count <= 2_000 && $0.rangeOfCharacter(from: .alphanumerics) != nil }) ?? true,
              pageSize.map({ (1...100).contains($0) }) ?? true,
              cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
        if let cursor, let projection = compactProjection, currentProfile == profile,
           let version = sourceVersion, (try? MCPFileVersion(URL(fileURLWithPath: profile.vaultPath))) == version {
            let (key, offset, session) = try listCursor(cursor, generation: projection.generation, query: query,
                                                       pageSize: pageSize, matchMode: matchMode, includeExcerpts: includeExcerpts)
            if !session.includeExcerpts {
                return try listPage(key: key, offset: offset, session: session, profile: profile,
                                    epoch: accessEpoch, documents: [], projection: projection)
            }
        }

        let documents = try authorizedDocuments(profile)
        let epoch = accessEpoch
        let generation = try snapshotFingerprint(documents)
        if let cursor {
            let (key, offset, session) = try listCursor(cursor, generation: generation, query: query,
                                                       pageSize: pageSize, matchMode: matchMode, includeExcerpts: includeExcerpts)
            return try listPage(key: key, offset: offset, session: session, profile: profile, epoch: epoch,
                                documents: documents, projection: nil)
        }

        let excerpts = includeExcerpts ?? true, mode = matchMode ?? .allTokens
        guard (pageSize ?? 20) <= (excerpts ? 25 : 100),
              mode != .anyTermSubstring || query.map({ VaultDocumentFilter.validCandidateQuery($0) }) ?? true
        else { throw MCPAccessError.invalidArguments }
        let exactQuery = mode == .allTokens ? query : nil
        let usesProjection = !excerpts && sourceVersion != nil
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
        let key = UUID().uuidString.lowercased()
        let session = ListSession(fingerprint: generation, query: query, pageSize: pageSize ?? 20,
                                  matchMode: mode, includeExcerpts: excerpts, ids: ids)
        if listOrder.count >= 4 { listSessions.removeValue(forKey: listOrder.removeFirst()) }
        listOrder.append(key)
        return try listPage(key: key, offset: 0, session: session, profile: profile, epoch: epoch,
                            documents: documents, projection: usesProjection ? compactProjection : nil)
    }

    private func listCursor(_ cursor: String, generation: Data, query: String?, pageSize: Int?,
                            matchMode: VaultTextMatchMode?, includeExcerpts: Bool?) throws -> (String, Int, ListSession) {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let offset = Int(parts[1]), offset >= 0,
              let session = listSessions[String(parts[0])] else {
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
            items = try session.ids[offset..<end].map { id in
                guard let row = projection.rows[id], profile.allowedDocumentIDs.contains(id) else { throw MCPAccessError.stale }
                return compactItem(id: id, fingerprint: row.fingerprint, metadata: row.metadata, profile: profile)
            }
            coverage = projection.coverage
            analysisWarnings = projection.analysisWarnings
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

    private func makeProjection(_ documents: [VaultDocument], profile: MCPAccessProfile, generation: Data,
                                persisted: [UUID: VaultIndexProjection]?) throws -> CompactProjection {
        var rows: [UUID: CompactProjection.Row] = [:]
        for document in documents {
            try Task.checkCancellation()
            let metadata = persisted?[document.id] ?? MCPSourceState(document).projection(for: document)
            rows[document.id] = .init(fingerprint: try fingerprint(document), metadata: metadata)
        }
        let coverage = MCPProcessingCoverage(statuses: rows.values.map { $0.metadata.processingStatus },
                                             searchableCount: rows.values.count { $0.metadata.searchable },
                                             grantedCount: profile.allowedDocumentIDs.count)
        return CompactProjection(generation: generation, rows: rows, coverage: coverage,
                                 analysisWarnings: MCPAnalysisCoverage(documents).warnings)
    }

    public func read(document handle: String, cursor: String? = nil) throws -> MCPDocumentResult {
        guard handle.count <= 64, cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try loadProfile()
        let documents = try authorizedDocuments(profile)
        let epoch = accessEpoch
        let (document, _) = try resolve(handle, in: documents, profile: profile)
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
        let profile = try loadProfile(), documents = try authorizedDocuments(profile), epoch = accessEpoch
        let (document, lease) = try resolve(handle, in: documents, profile: profile)
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
        let documents = try authorizedDocuments(profile)
        let epoch = accessEpoch
        let (document, _) = try resolve(handle, in: documents, profile: profile)
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
                let loaded = try fileSnapshots.load(profile.vaultPath)
                if sourceVersion == loaded.version, let authorizedCache { return authorizedCache }
                all = loaded.documents; version = loaded.version
            }
            guard all.count <= 20_000, Set(all.map(\.id)).count == all.count else { throw MCPAccessError.unavailable }
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
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = Data(SHA256.hash(data: try encoder.encode(document)))
        fingerprintCache[document.id] = value
        return value
    }

    private func lease(for document: VaultDocument, profile: MCPAccessProfile) throws -> String {
        try lease(id: document.id, fingerprint: fingerprint(document), profile: profile)
    }

    private func resolve(_ handle: String, in documents: [VaultDocument],
                         profile: MCPAccessProfile) throws -> (VaultDocument, Lease) {
        guard let lease = leases[handle], lease.profile == profile else { throw MCPAccessError.stale }
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
           existing.fingerprint == fingerprint, existing.profile == profile { return handle }
        if let old = handlesByID.removeValue(forKey: id) { leases.removeValue(forKey: old) }
        let handle = UUID().uuidString.lowercased()
        leases[handle] = Lease(id: id, fingerprint: fingerprint, profile: profile)
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
        fileSnapshots.clear(); sourceVersion = nil; authorizedCache = nil
        tokenIndex = nil; tokenIndexGeneration = nil; compactProjection = nil
        fingerprintCache.removeAll(); generationCache = nil
    }

    private func snapshotFingerprint(_ documents: [VaultDocument]) throws -> Data {
        if let generationCache { return generationCache }
        var hash = SHA256()
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
