import Foundation

public actor LocalVault {
    public nonisolated static func queryTerms(_ query: String) -> [String] { meaningfulTerms(in: query) }
    private let source: any VaultSnapshotSource
    private(set) var indexBuildCount = 0
    private var indexed: [UUID: IndexedDocument] = [:]
    private struct IndexedDocument {
        let document: VaultDocument
        let fields: [(tokens: [String], normalized: String, weight: Int)]
        var bytes: Int { fields.reduce(0) { $0 + $1.normalized.utf8.count } }
    }

    public init(source: any VaultSnapshotSource = LocalVaultSnapshotSource(fileURL: FileVaultSnapshotSource.defaultVaultURL())) {
        self.source = source
    }

    public func status() throws -> VaultStatus {
        guard source.isAvailable() else {
            return VaultStatus(
                available: false,
                documentCount: 0,
                searchableDocumentCount: 0,
                categories: [:]
            )
        }

        let documents = try source.loadDocuments()
        let searchable = documents.filter(\.isSearchable)
        let categories = Dictionary(grouping: searchable, by: \.category)
            .mapValues(\.count)
        return VaultStatus(
            available: true,
            documentCount: documents.count,
            searchableDocumentCount: searchable.count,
            categories: categories
        )
    }

    public func search(
        query: String,
        category: String? = nil,
        limit: Int = 5
    ) throws -> VaultSearchResult {
        try search(documents: source.loadDocuments(), query: query, category: category, limit: limit)
    }

    public func search(documents input: [VaultDocument], query: String, category: String? = nil, limit: Int = 5) throws -> VaultSearchResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return VaultSearchResult(query: query, hits: [])
        }

        let documents = input
            .filter(\.isSearchable)
            .filter { document in
                guard let category, !category.isEmpty else { return true }
                return document.category.caseInsensitiveCompare(category) == .orderedSame
            }
        let terms = Self.meaningfulTerms(in: trimmedQuery)
        let phrase = Self.normalized(trimmedQuery)

        let ids = Set(documents.map(\.id))
        indexed = indexed.filter { ids.contains($0.key) }
        // Bound derived memory; records over the index budget still participate through uncached scoring.
        var indexBytes = indexed.values.reduce(0) { $0 + $1.bytes }
        for document in documents where indexed[document.id]?.document != document {
            indexBytes -= indexed.removeValue(forKey: document.id)?.bytes ?? 0
            let size = Self.searchFields(document).reduce(0) { $0 + $1.0.utf8.count }
            if indexBytes + size <= 16_000_000 {
                indexBuildCount += 1
                indexed[document.id] = IndexedDocument(document: document, fields: Self.searchFields(document).map {
                    (tokens: VaultSearchText.sourceTokens($0.0), normalized: Self.normalized($0.0), weight: $0.1)
                })
                indexBytes += size
            }
        }
        let ranked = documents.compactMap { document -> RankedDocument? in
            let score = Self.score(document: document, prepared: indexed[document.id]?.fields, terms: terms, phrase: phrase)
            guard score > 0 else { return nil }
            let excerpt = Self.bestExcerpt(from: document, terms: terms)
            return RankedDocument(document: document, score: score, excerpt: excerpt)
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.document.importedAt > rhs.document.importedAt
                : lhs.score > rhs.score
        }

        let hits = ranked.prefix(max(1, min(limit, 10))).map { ranked in
            let reference = VaultPageMarkedText.reference(
                documentId: ranked.document.id,
                page: ranked.excerpt.page
            )
            return VaultSearchHit(
                documentId: ranked.document.id,
                title: ranked.document.title,
                category: ranked.document.category,
                importedAt: ranked.document.importedAt,
                excerpt: ranked.excerpt.text,
                page: ranked.excerpt.page,
                reference: reference,
                relevance: Self.normalizedRelevance(ranked.score)
            )
        }
        return VaultSearchResult(query: trimmedQuery, hits: hits, totalCount: ranked.count)
    }

    public func answerPrivately(question: String, limit: Int = 3) throws -> VaultPrivateAnswer {
        let searchResult = try search(query: question, limit: limit)
        guard !searchResult.hits.isEmpty else {
            return VaultPrivateAnswer(
                answer: """
                ## Antwort
                Ich finde dazu in den lokal durchsuchten Dokumenten keine passende Quelle.

                ## Naechste Schritte
                - Frage mit einem konkreten Namen, Datum, Betrag, Absender oder Dokumenttitel.
                """,
                confidence: 0,
                evidence: []
            )
        }

        let documentsById = Dictionary(
            uniqueKeysWithValues: try source.loadDocuments().map { ($0.id, $0) }
        )
        let intent = Self.intent(for: question)
        var answerLines: [String] = []
        var evidence: [VaultEvidence] = []
        var claimConfidences: [Double] = []

        for hit in searchResult.hits {
            guard let document = documentsById[hit.documentId] else { continue }
            let claim = Self.claim(
                for: document,
                intent: intent,
                fallback: hit.excerpt,
                retrievalRelevance: hit.relevance
            )
            answerLines.append("**\(document.title):** \(claim.text) \(hit.reference)")
            claimConfidences.append(claim.confidence)
            evidence.append(
                VaultEvidence(
                    documentId: document.id,
                    title: document.title,
                    page: hit.page,
                    reference: hit.reference,
                    excerpt: Self.compact(hit.excerpt, limit: 360)
                )
            )
        }

        guard !evidence.isEmpty else {
            return VaultPrivateAnswer(
                answer: """
                ## Antwort
                Der lokale Vault wurde während der Suche aktualisiert. Bitte wiederhole die Frage.
                """,
                confidence: 0,
                evidence: []
            )
        }

        let evidenceLines = evidence.map {
            "- **\($0.title):** \($0.excerpt) \($0.reference)"
        }
        let confidence = claimConfidences.reduce(0, +) / Double(claimConfidences.count)

        return VaultPrivateAnswer(
            answer: """
            ## Antwort
            \(answerLines.joined(separator: "\n\n"))

            ## Belege
            \(evidenceLines.joined(separator: "\n"))
            """,
            confidence: confidence,
            evidence: evidence
        )
    }
}

private extension LocalVault {
    struct RankedDocument {
        var document: VaultDocument
        var score: Int
        var excerpt: VaultPageMarkedText.Section
    }

    enum QuestionIntent {
        case amount
        case deadline
        case general
    }

    struct GroundedClaim {
        var text: String
        var confidence: Double
    }

    static let stopwords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines", "einem", "einen",
        "und", "oder", "aber", "auch", "ist", "sind", "war", "wird", "werden", "kann", "soll", "muss",
        "ich", "mir", "mich", "mein", "meine", "für", "von", "vom", "zum", "zur", "mit", "bei", "nach",
        "über", "unter", "vor", "aus", "auf", "was", "wer", "wie", "wo", "wann", "warum", "welche",
        "nenne", "gib", "zeige", "liste", "sage", "finde", "suche", "bitte", "diese", "dieser", "dieses",
        "the", "and", "or", "for", "with", "from", "are", "what", "who", "how", "where", "when", "why",
        "which", "list", "show", "give", "find", "search", "please", "that", "this", "these", "about"
    ]

    static func searchFields(_ document: VaultDocument) -> [(String, Int)] {
        [
            (document.title, 5),
            (document.entities.map { "\($0.type) \($0.value) \($0.normalizedValue ?? "")" }.joined(separator: " "), 4),
            (document.contentFacts.map { "\($0.label) \($0.value) \($0.normalizedValue ?? "")" }.joined(separator: " "), 4),
            (document.summary, 3),
            (document.deadlines.map { "\($0.title) \($0.type) \($0.sourceSnippet)" }.joined(separator: " "), 3),
            (document.category, 3),
            (document.sourceName, 2),
            (document.ocrText, 1)
        ]

    }
    static func score(document: VaultDocument, prepared: [(tokens: [String], normalized: String, weight: Int)]?, terms: [String], phrase: String) -> Int {
        let fields = prepared ?? searchFields(document).map { (tokens: VaultSearchText.sourceTokens($0.0), normalized: normalized($0.0), weight: $0.1) }
        var result = 0
        for (tokens, normalizedValue, weight) in fields {
            for term in terms {
                let count = tokens.reduce(0) { partial, token in
                    partial + (token.contains(term) ? 1 : 0)
                }
                result += min(count, 5) * weight
            }
            if phrase.count > 3, normalizedValue.contains(phrase) {
                result += weight * 3
            }
        }
        return result
    }

    static func meaningfulTerms(in query: String) -> [String] {
        let allTerms = tokenize(query)
        let meaningful = allTerms.filter { $0.count > 2 && !stopwords.contains($0) }
        return meaningful.isEmpty ? allTerms : meaningful
    }

    static func tokenize(_ value: String) -> [String] {
        normalized(value)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func normalized(_ value: String) -> String {
        VaultSearchText.normalized(value)
    }

    static func bestExcerpt(from document: VaultDocument, terms: [String]) -> VaultPageMarkedText.Section {
        let sections = VaultPageMarkedText.sections(in: document.ocrText)
        let ranked = sections.map { section in
            let tokens = VaultSearchText.sourceTokens(section.text)
            let score = terms.reduce(0) { partial, term in
                partial + tokens.reduce(0) { $0 + ($1.contains(term) ? 1 : 0) }
            }
            return (section, score)
        }
        if let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return VaultPageMarkedText.Section(
                page: best.0.page,
                text: excerptWindow(in: best.0.text, terms: terms)
            )
        }

        let fallback = document.summary.isEmpty ? document.ocrText : document.summary
        return VaultPageMarkedText.Section(page: nil, text: compact(fallback, limit: 600))
    }

    static func excerptWindow(in text: String, terms: [String]) -> String {
        let projection = VaultSearchText(text)
        let match = terms.compactMap { projection.ranges(of: $0, limit: 1).first }
            .min { $0.lowerBound < $1.lowerBound }
        let start = match.map { text.index($0.lowerBound, offsetBy: -180, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
        let end = text.index(start, offsetBy: 600, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }

    static func intent(for question: String) -> QuestionIntent {
        let folded = normalized(question)
        if ["betrag", "kosten", "preis", "summe", "euro", "eur", "zahlen"].contains(where: folded.contains) {
            return .amount
        }
        if ["frist", "fallig", "datum", "termin", "ablauf", "kundigung", "ende"].contains(where: folded.contains) {
            return .deadline
        }
        return .general
    }

    static func claim(
        for document: VaultDocument,
        intent: QuestionIntent,
        fallback: String,
        retrievalRelevance: Double
    ) -> GroundedClaim {
        switch intent {
        case .amount:
            if let amount = document.entities.first(where: { $0.type == "amount" }) {
                return GroundedClaim(
                    text: "Der belegte Betrag ist \(amount.value).",
                    confidence: amount.confidence
                )
            }
            if let amount = document.contentFacts.first(where: {
                normalized($0.kind).contains("amount") || normalized($0.label).contains("betrag")
            }) {
                return GroundedClaim(
                    text: "Der belegte Betrag ist \(amount.value).",
                    confidence: amount.confidence
                )
            }
        case .deadline:
            if let deadline = document.deadlines.sorted(by: { $0.date < $1.date }).first {
                return GroundedClaim(
                    text: "\(deadline.title) ist am \(dateString(deadline.date)).",
                    confidence: deadline.confidence
                )
            }
        case .general:
            break
        }

        let summary = document.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return GroundedClaim(
                text: compact(summary, limit: 520),
                confidence: max(retrievalRelevance, document.categoryConfidence)
            )
        }
        return GroundedClaim(
            text: compact(fallback, limit: 520),
            confidence: retrievalRelevance
        )
    }

    static func normalizedRelevance(_ score: Int) -> Double {
        let value = 1 - exp(-Double(score) / 20)
        return min(max(value, 0), 1)
    }

    static func compact(_ value: String, limit: Int) -> String {
        let cleaned = value
            .replacingOccurrences(of: #"---\s*Seite\s*\d+\s*---"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

extension LocalVault {
    package nonisolated static func rankedCandidates(
        query: String, limit: Int, visit: ((VaultDocument) throws -> Void) throws -> Void
    ) throws -> (hits: [(document: VaultDocument, page: Int?)], count: Int) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = meaningfulTerms(in: query)
        let phrase = normalized(query)
        var best: [(document: VaultDocument, score: Int)] = []
        var count = 0
        try visit { document in
            guard document.isSearchable else { return }
            let value = score(document: document, prepared: nil, terms: terms, phrase: phrase)
            guard value > 0 else { return }
            count += 1
            let position = best.firstIndex {
                value > $0.score || (value == $0.score && document.importedAt > $0.document.importedAt)
            } ?? best.count
            if position < limit {
                best.insert((document, value), at: position)
                if best.count > limit { best.removeLast() }
            }
        }
        return (best.map { ($0.document, bestExcerpt(from: $0.document, terms: terms).page) }, count)
    }

    static func rankedSearchFields(_ document: VaultDocument) -> [(String, Int)] {
        searchFields(document)
    }

    package nonisolated static func compactRankTerm(_ query: String) -> String? {
        let phrase = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return meaningfulTerms(in: query) == [phrase] ? phrase : nil
    }

    package nonisolated static func rankedIDs(
        term: String, limit: Int, scores: [VaultRankScore],
        visitUncovered: ((VaultDocument) throws -> Void) throws -> Void
    ) throws -> (ids: [UUID], count: Int) {
        var ranked = scores
        try visitUncovered { document in
            guard document.isSearchable else { return }
            let value = score(document: document, prepared: nil, terms: [term], phrase: term)
            if value > 0 { ranked.append(.init(id: document.id, score: value, date: document.importedAt)) }
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        return (ranked.prefix(limit).map(\.id), ranked.count)
    }

    package nonisolated static func rankedEvidencePage(_ document: VaultDocument, query: String) -> Int? {
        bestExcerpt(from: document, terms: meaningfulTerms(in: query)).page
    }
}

struct VaultSearchVocabulary {
    let counts: [String: Int]
    var words: Dictionary<String, Int>.Keys { counts.keys }
    let foldedChunks: Set<String>
    let normalizedChunks: Set<String>

    init(_ field: String) {
        if let ascii = Self.asciiVocabulary(field) {
            counts = ascii.counts
            foldedChunks = ascii.chunks
            normalizedChunks = ascii.chunks
            return
        }
        let folded = VaultSearchText.folded(field)
        let normalized = VaultSearchText.normalized(field)
        let separators = CharacterSet.alphanumerics.inverted
        let original = folded.components(separatedBy: separators).filter { !$0.isEmpty }
        let known = Set(original)
        let aliases = normalized.components(separatedBy: separators).filter { !$0.isEmpty && !known.contains($0) }
        var frequencies: [String: Int] = [:]
        for word in original + aliases { frequencies[word] = min(5, frequencies[word, default: 0] + 1) }
        counts = frequencies
        foldedChunks = Self.chunks(folded)
        normalizedChunks = Self.chunks(normalized)
    }

    // Search terms do not span whitespace. Keep punctuation and combining characters
    // inside chunks so the lookup still uses Swift's original substring semantics.
    private static func chunks(_ field: String) -> Set<String> {
        Set(field.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static func asciiVocabulary(_ field: String) -> (counts: [String: Int], chunks: Set<String>)? {
        let bytes = Array(field.utf8)
        guard bytes.allSatisfy({ $0 < 128 }) else { return nil }
        for offset in bytes.indices where bytes[offset] == 45 {
            // These are the only possible ASCII spellings of an OCR line-break alias.
            var after = offset + 1
            while after < bytes.count, bytes[after] == 9 || bytes[after] == 32 { after += 1 }
            if after < bytes.count, bytes[after] == 10 || bytes[after] == 13 { return nil }
        }
        let lower = Array(field.lowercased().utf8)
        var counts: [String: Int] = [:]
        var chunks: Set<String> = []
        func countWord(_ slice: ArraySlice<UInt8>) {
            let word = String(decoding: slice, as: UTF8.self)
            counts[word] = min(5, counts[word, default: 0] + 1)
        }
        var wordStart = 0, chunkStart = 0
        for (offset, byte) in lower.enumerated() {
            if !(48...57).contains(byte), !(97...122).contains(byte) {
                if wordStart < offset { countWord(lower[wordStart..<offset]) }
                wordStart = offset + 1
            }
            if byte == 32 || (9...13).contains(byte) {
                if chunkStart < offset { chunks.insert(String(decoding: lower[chunkStart..<offset], as: UTF8.self)) }
                chunkStart = offset + 1
            }
        }
        if wordStart < lower.count { countWord(lower[wordStart...]) }
        if chunkStart < lower.count { chunks.insert(String(decoding: lower[chunkStart...], as: UTF8.self)) }
        return (counts, chunks)
    }
}

package struct VaultRankScore: Sendable {
    let id: UUID
    let score: Int
    let date: Date
}

/// The original rank formula for a single normalized word. Whitespace cannot be
/// part of that word, so checking it in any chunk preserves the phrase bonus.
struct VaultRankProjection: Codable, Sendable {
    struct Field: Codable, Sendable {
        let weight: Int
        let counts: [String: Int]
        let normalizedChunks: Set<String>
    }
    let importedAt: Date
    let searchable: Bool
    let fields: [Field]

    func score(term: String) -> Int {
        fields.reduce(0) { score, field in
            var matches = 0
            for (token, count) in field.counts where token.contains(term) {
                matches += count
                if matches >= 5 { break }
            }
            let bonus = term.count > 3 && field.normalizedChunks.contains { $0.contains(term) } ? 3 : 0
            return score + (min(matches, 5) + bonus) * field.weight
        }
    }

    var isValid: Bool {
        fields.count == 8 && fields.allSatisfy { field in
            (1...5).contains(field.weight) && field.counts.values.allSatisfy { (1...5).contains($0) }
        }
    }
}
