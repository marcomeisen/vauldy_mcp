import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Shared local pseudonymization. The mapping never crosses a transport boundary.
nonisolated public struct IdentifierPrivacySession: Sendable {
    private struct Replacement: Hashable, Sendable {
        let original: String
        let token: String
        let wholeWord: Bool
    }

    private var replacements: [Replacement] = []

    public init(contents: [String]) throws {
        var valuesByKind: [(kind: String, value: String)] = []
        for content in contents where !content.isEmpty {
            valuesByKind.append(contentsOf: try ExternalPersonalDataDetector.identifiers(in: content))
            valuesByKind.append(contentsOf: Self.detectNamedEntities(in: content))
        }

        // A document containing an old/example placeholder must never be able to
        // impersonate a token from this request and recover another person's data.
        let namespace = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var counters: [String: Int] = [:]
        var tokensByKey: [String: String] = [:]
        for candidate in valuesByKind.sorted(by: { $0.value.count > $1.value.count }) {
            let value = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isUseful(value) else { continue }
            let key = value.folding(options: [.caseInsensitive], locale: .current)
            guard tokensByKey[key] == nil else { continue }
            counters[candidate.kind, default: 0] += 1
            let token = "[V_\(namespace)_\(candidate.kind)_\(counters[candidate.kind, default: 1])]"
            tokensByKey[key] = token
            replacements.append(Replacement(original: value, token: token,
                wholeWord: ["PERSON", "ORGANISATION", "ORT"].contains(candidate.kind)))
        }
    }

    /// Validate the actual outgoing value, rather than trusting a settings flag.
    /// Detection/validation failures stop the request before credentials or network use.
    public func protectForSending(_ value: String) throws -> String {
        let protected = protect(value)
        guard try ExternalPersonalDataDetector.identifiers(in: protected).isEmpty else {
            throw ExternalAIPrivacyError.personalDataRemaining
        }
        return protected
    }

    public func protect(_ value: String) -> String {
        // Use neutral sentinels first so a short candidate such as "IBAN" cannot
        // rewrite the token generated for a complete IBAN value.
        var protected = value
        for (index, replacement) in replacements.enumerated() {
            for range in Self.ranges(of: replacement, in: protected).reversed() {
                guard let swiftRange = Range(range, in: protected) else { continue }
                protected.replaceSubrange(swiftRange, with: "\u{E000}\(index)\u{E001}")
            }
        }
        for (index, replacement) in replacements.enumerated() {
            protected = protected.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: replacement.token)
        }
        return protected
    }

    /// Local geometry projection needs the complete detected span, including
    /// identifiers that OCR split across lines. No mapping values leave this type.
    public func redactionRanges(in value: String) -> [NSRange] {
        replacements.flatMap { Self.ranges(of: $0, in: value) }
    }

    private static func ranges(of replacement: Replacement, in text: String) -> [NSRange] {
        let literal = NSRegularExpression.escapedPattern(for: replacement.original)
        // An entity such as "Kinder" is not a match inside "Kindernothilfe".
        // Structured identifiers retain literal matching, including split lines.
        let pattern = replacement.wholeWord ? "(?<![\\p{L}\\p{N}_])\(literal)(?![\\p{L}\\p{N}_])" : literal
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    public func restore(_ value: String) -> String {
        replacements.reduce(value) { partial, replacement in
            partial.replacingOccurrences(of: replacement.token, with: replacement.original)
        }
    }

    private static func detectNamedEntities(in text: String) -> [(kind: String, value: String)] {
        #if canImport(NaturalLanguage)
        let tagger = NLTagger(tagSchemes: [.nameType])
        // Page citation syntax is protocol, not a place such as "S.2".
        // Its document UUID is still protected by the deterministic detector.
        let withoutCitations = text.replacingOccurrences(of: #"\[Ref:[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}:S\.\d+\]"#,
            with: " ", options: [.regularExpression, .caseInsensitive])
        let text = ExternalPersonalDataDetector.removingPlaceholders(from: withoutCitations)
        tagger.string = text
        var values: [(String, String)] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            let kind: String?
            switch tag {
            case .personalName: kind = "PERSON"
            case .organizationName: kind = "ORGANISATION"
            case .placeName: kind = "ORT"
            default: kind = nil
            }
            if let kind {
                let value = String(text[range])
                // These are request protocol labels, never identifier candidates
                // from NLTagger. Explicit personal-name fields still protect them.
                if !["ref", "referenz", "dokument-id"].contains(value.lowercased()) {
                    values.append((kind, value))
                }
            }
            return true
        }
        return values
        #else
        return []
        #endif
    }

    private static func isUseful(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters.union(.decimalDigits)) != nil else { return false }
        return true
    }
}
