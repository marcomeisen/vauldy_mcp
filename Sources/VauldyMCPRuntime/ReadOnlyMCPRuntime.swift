import Foundation
import CryptoKit
import VauldyCore
import VauldyPrivacy

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
        let ids: [UUID]
        var issuedOffsets: Set<Int> = [0]
    }
    private var listSessions: [String: ListSession] = [:]
    private var listOrder: [String] = []
    private var currentProfile: MCPAccessProfile?
    private var handlesByID: [UUID: String] = [:]
    private let profiles: any MCPProfileSource
    private let searchIndex = LocalVault()
    private struct PreparedDocument {
        let fingerprint: Data
        let profile: MCPAccessProfile
        let sections: [VaultPageMarkedText.Section]
        let summary: String
        let session: IdentifierPrivacySession
        var bytes: Int { sections.reduce(summary.utf8.count) { $0 + $1.text.utf8.count } }
    }
    private(set) var privacyBuildCount = 0
    private var protectedDocuments: [UUID: PreparedDocument] = [:]
    private var protectedOrder: [UUID] = []
    private var leases: [String: Lease] = [:]
    private let loadVault: @Sendable (String) throws -> [VaultDocument]

    public init(profiles: any MCPProfileSource,
                loadVault: @escaping @Sendable (String) throws -> [VaultDocument] = {
                    try FileVaultSnapshotSource(fileURL: URL(fileURLWithPath: $0)).loadDocuments()
                }) {
        self.profiles = profiles
        self.loadVault = loadVault
    }

    public func status() throws -> MCPVaultStatus {
        let profile = try profiles.load()
        guard profile.enabled else {
            clearAccessCaches()
            return MCPVaultStatus(access: "disabled", available: false, grantedDocumentCount: 0, searchableDocumentCount: 0,
                                  coverage: MCPProcessingCoverage(documents: [], grantedCount: 0), warnings: [], processingComplete: false, analysisCoverage: MCPAnalysisCoverage([]))
        }
        let documents = try authorizedDocuments(profile)
        let coverage = MCPProcessingCoverage(documents: documents, grantedCount: profile.allowedDocumentIDs.count)
        try recheck(profile)
        return MCPVaultStatus(access: "explicit-document-grants", available: true,
                              grantedDocumentCount: documents.count,
                              searchableDocumentCount: documents.filter(\.isSearchable).count,
                              coverage: coverage, warnings: coverage.warnings + MCPAnalysisCoverage(documents).warnings, processingComplete: coverage.processingComplete,
                              analysisCoverage: MCPAnalysisCoverage(documents))
    }

    public func search(query: String, limit: Int = 5) async throws -> MCPSearchResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 2_000, (1...10).contains(limit) else { throw MCPAccessError.invalidArguments }
        let profile = try profiles.load()
        let documents = try authorizedDocuments(profile)
        let raw = try await searchIndex.search(documents: documents, query: query, limit: limit)
        var output: [MCPSearchHit] = []
        for hit in raw.hits {
            guard let document = documents.first(where: { $0.id == hit.documentId }) else { continue }
            output.append(try resultItem(document, profile: profile, query: query, preferredPage: hit.page))
        }
        let coverage = MCPProcessingCoverage(documents: documents, grantedCount: profile.allowedDocumentIDs.count)
        let count = raw.totalCount ?? output.count
        try Task.checkCancellation()
        try recheck(profile)
        return MCPSearchResult(hits: output, limit: limit, totalCount: count, truncated: count > output.count,
                               processingComplete: coverage.processingComplete, coverage: coverage,
                               warnings: ["RANKED_RESULTS_NOT_EXHAUSTIVE"] + (count > output.count ? ["RESULTS_TRUNCATED"] : []) + coverage.warnings + MCPAnalysisCoverage(documents).warnings)
    }

    /// Complete enumeration of a deterministic text-filtered authorized set. A changed
    /// authorized snapshot expires continuation rather than skipping or duplicating records.
    public func list(query: String? = nil, pageSize: Int? = nil, cursor: String? = nil) throws -> MCPDocumentListResult {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.map({ !$0.isEmpty && $0.utf8.count <= 2_000 && $0.rangeOfCharacter(from: .alphanumerics) != nil }) ?? true,
              pageSize.map({ (1...25).contains($0) }) ?? true,
              cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try profiles.load()
        let documents = try authorizedDocuments(profile)
        let generation = try snapshotFingerprint(documents)
        let key: String
        let offset: Int
        var session: ListSession
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let value = Int(parts[1]), value >= 0,
                  let existing = listSessions[String(parts[0])] else { throw MCPAccessError.stale }
            key = String(parts[0]); offset = value; session = existing
            guard session.fingerprint == generation else { throw MCPAccessError.stale }
            guard session.issuedOffsets.contains(offset),
                  query == nil || query == session.query,
                  pageSize == nil || pageSize == session.pageSize else { throw MCPAccessError.invalidArguments }
        } else {
            key = UUID().uuidString.lowercased(); offset = 0
            session = ListSession(fingerprint: generation, query: query, pageSize: pageSize ?? 20,
                                  ids: documents.filter { VaultDocumentFilter.matches($0, query: query) }
                                    .map(\.id).sorted { $0.uuidString < $1.uuidString })
            if listOrder.count >= 4 { listSessions.removeValue(forKey: listOrder.removeFirst()) }
            listOrder.append(key)
        }
        let end = min(offset + session.pageSize, session.ids.count)
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        let items = try session.ids[offset..<end].map { id in
            guard let document = byID[id] else { throw MCPAccessError.stale }
            return try resultItem(document, profile: profile, query: session.query, preferredPage: nil)
        }
        let more = end < session.ids.count
        if more { session.issuedOffsets.insert(end) }
        listSessions[key] = session
        let coverage = MCPProcessingCoverage(documents: documents, grantedCount: profile.allowedDocumentIDs.count)
        try Task.checkCancellation()
        try recheck(profile)
        return MCPDocumentListResult(snapshot: key, items: items, totalCount: session.ids.count, hasMore: more,
                                     nextCursor: more ? "\(key):\(end)" : nil, retrievalComplete: !more,
                                     processingComplete: coverage.processingComplete, coverage: coverage,
                                     warnings: ["ORGANIZATION_RELATIONSHIPS_NOT_RESOLVED"]
                                        + (session.query == nil ? [] : ["TEXT_FILTER_NOT_ISSUER_ASSIGNMENT"]) + coverage.warnings + MCPAnalysisCoverage(documents).warnings)
    }

    public func read(document handle: String, cursor: String? = nil) throws -> MCPDocumentResult {
        guard handle.count <= 64, cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try profiles.load()
        let documents = try authorizedDocuments(profile)
        guard let lease = leases[handle], lease.profile == profile,
              let document = documents.first(where: { $0.id == lease.id && $0.isSearchable }),
              try fingerprint(document) == lease.fingerprint else { throw MCPAccessError.stale }
        let offset: Int
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == handle, let value = Int(parts[1]), value >= 0 else {
                throw MCPAccessError.invalidArguments
            }
            offset = value
        } else { offset = 0 }
        let sections = VaultPageMarkedText.sections(in: document.ocrText)
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
        let pages = sections.compactMap(\.page)
        let expected = document.pageCount
        let state = MCPSourceState(document)
        try Task.checkCancellation()
        try recheck(profile)
        return MCPDocumentResult(document: handle, title: "Freigegebenes Dokument",
                                 segments: Array(segments[offset..<end]), expectedPageCount: expected,
                                 availablePages: Array(Set(pages)).sorted(),
                                 sourceCoverage: state.sourceCoverage,
                                 nextCursor: end < segments.count ? "\(handle):\(end)" : nil,
                                 containsEntireAvailableText: offset == 0 && end == segments.count,
                                 pageStatus: document.localImport?.pages.map {
                                     MCPPageStatus(page: $0.page, method: $0.method.rawValue, needsReview: $0.needsReview)
                                 } ?? [], analysisStatus: document.baseAnalysisStatus)
    }

    /// One logical record per metadata page. Continuation is bound to the same
    /// content fingerprint and permission lease as full-text reading.
    public func readMetadata(document handle: String, cursor: String? = nil) throws -> MCPMetadataResult {
        guard handle.count <= 64, cursor.map({ $0.count <= 90 }) ?? true else { throw MCPAccessError.invalidArguments }
        let profile = try profiles.load()
        let documents = try authorizedDocuments(profile)
        guard let lease = leases[handle], lease.profile == profile,
              let document = documents.first(where: { $0.id == lease.id }),
              try fingerprint(document) == lease.fingerprint else { throw MCPAccessError.stale }
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
        try recheck(profile)
        return MCPMetadataResult(document: handle, analysisStatus: document.baseAnalysisStatus, engine: analysis?.engine.rawValue,
                                 analyzedPages: analysis?.analyzedPages ?? [], logicalDocumentCount: records.count, documents: output,
                                 hasMore: end < records.count, nextCursor: end < records.count ? "\(handle):m:\(end)" : nil,
                                 warnings: MCPAnalysisWarnings.safe(analysis?.issues ?? [document.baseAnalysis == nil ? "NOT_ANALYZED" : "STALE_ANALYSIS"]))
    }

    private func authorizedDocuments(_ profile: MCPAccessProfile) throws -> [VaultDocument] {
        try profile.validate()
        guard profile.enabled, profile.acknowledgedCloudDisclosure else {
            clearAccessCaches()
            throw MCPAccessError.notAuthorized
        }
        if currentProfile != profile { clearAccessCaches(); currentProfile = profile }
        do {
            let all = try loadVault(profile.vaultPath)
            guard all.count <= 20_000, Set(all.map(\.id)).count == all.count else { throw MCPAccessError.unavailable }
            let allowed = all.filter { profile.allowedDocumentIDs.contains($0.id) }
            let ids = Set(allowed.map(\.id))
            protectedDocuments = protectedDocuments.filter { ids.contains($0.key) && $0.value.profile == profile }
            protectedOrder = protectedOrder.filter { protectedDocuments[$0] != nil }
            return allowed
        } catch { throw MCPAccessError.unavailable }
    }

    private func recheck(_ profile: MCPAccessProfile) throws {
        guard try profiles.load() == profile else {
            clearAccessCaches()
            throw MCPAccessError.stale
        }
    }

    private func fingerprint(_ document: VaultDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(document)))
    }

    private func lease(for document: VaultDocument, profile: MCPAccessProfile) throws -> String {
        let hash = try fingerprint(document)
        if let handle = handlesByID[document.id], let existing = leases[handle],
           existing.fingerprint == hash, existing.profile == profile { return handle }
        if let old = handlesByID.removeValue(forKey: document.id) { leases.removeValue(forKey: old) }
        let handle = UUID().uuidString.lowercased()
        leases[handle] = Lease(id: document.id, fingerprint: hash, profile: profile)
        handlesByID[document.id] = handle
        return handle
    }

    private func preparedDocument(_ document: VaultDocument, profile: MCPAccessProfile) throws -> PreparedDocument {
        let hash = try fingerprint(document)
        if let existing = protectedDocuments[document.id], existing.fingerprint == hash, existing.profile == profile { return existing }
        protectedDocuments.removeValue(forKey: document.id); protectedOrder.removeAll { $0 == document.id }
        let session = try privacySession(document)
        privacyBuildCount += 1
        let sections = try VaultPageMarkedText.sections(in: document.ocrText).map {
            VaultPageMarkedText.Section(page: $0.page, text: try protect($0.text, using: session))
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
        leases.removeAll(); handlesByID.removeAll(); protectedDocuments.removeAll(); protectedOrder.removeAll()
        listSessions.removeAll(); listOrder.removeAll(); currentProfile = nil
    }

    private func snapshotFingerprint(_ documents: [VaultDocument]) throws -> Data {
        var hash = SHA256()
        for document in documents.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            hash.update(data: try fingerprint(document))
        }
        return Data(hash.finalize())
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
        let sourceSections = VaultPageMarkedText.sections(in: document.ocrText).map(\.text)
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
