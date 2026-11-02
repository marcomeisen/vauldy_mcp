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
        add(valuesByKind.sorted { $0.value.count > $1.value.count }, namespace: namespace,
            counters: &counters, tokensByKey: &tokensByKey, residual: false)
        // Redacting an overlapping span can expose a shorter labelled identifier.
        // Complete the same document-wide mapping before any value is released.
        // Validation below still fails closed if bounded completion cannot cover it.
        for _ in 0..<8 {
            let residuals = try contents.flatMap { try ExternalPersonalDataDetector.identifiers(in: protect($0)) }
            if residuals.isEmpty { break }
            if !add(residuals, namespace: namespace, counters: &counters, tokensByKey: &tokensByKey, residual: true) { break }
        }
    }

    @discardableResult
    private mutating func add(_ candidates: [(kind: String, value: String)], namespace: String,
                              counters: inout [String: Int], tokensByKey: inout [String: String], residual: Bool) -> Bool {
        var changed = false
        for candidate in candidates {
            let value = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isUseful(value), !value.contains("[V_" + namespace + "_") else { continue }
            let key = value.folding(options: [.caseInsensitive], locale: .current)
            if let token = tokensByKey[key] {
                if residual && !replacements.contains(where: { !$0.wholeWord && $0.original.caseInsensitiveCompare(value) == .orderedSame }) {
                    replacements.append(Replacement(original: value, token: token, wholeWord: false)); changed = true
                }
                continue
            }
            counters[candidate.kind, default: 0] += 1
            let token = "[V_\(namespace)_\(candidate.kind)_\(counters[candidate.kind, default: 1])]"
            tokensByKey[key] = token
            replacements.append(Replacement(original: value, token: token,
                wholeWord: !residual && ["PERSON", "ORGANISATION", "ORT"].contains(candidate.kind)))
            changed = true
        }
        return changed
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
        // Match only original source coordinates. Never rescan generated tokens or
        // numeric sentinels as source identifiers, even for short labelled values.
        var selected: [(NSRange, String)] = []
        let occupied = NSMutableIndexSet()
        for replacement in replacements {
            for range in Self.ranges(of: replacement, in: value) where !occupied.intersects(in: range) {
                selected.append((range, replacement.token)); occupied.add(in: range)
            }
        }
        let protected = NSMutableString(string: value)
        for (range, token) in selected.sorted(by: { $0.0.location > $1.0.location }) {
            protected.replaceCharacters(in: range, with: token)
        }
        return protected as String
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
                // NLTagger can label currency codes as places in invoice context.
                // Explicit personal-name/identifier rules above still apply to these values.
                if !["ref", "referenz", "dokument-id", "eur", "usd", "chf", "gbp", "jpy", "cny"].contains(value.lowercased()) {
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
