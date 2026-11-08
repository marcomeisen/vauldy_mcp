import Foundation

/// Derived search spelling only. Source strings and returned evidence are never rewritten.
/// Ambiguous hard line breaks are aliases, not corrected document facts.
public struct VaultSearchText {
    public let source: String
    public let text: String
    private struct Removal {
        let projectedOffset: Int
        let removedThrough: Int
    }
    private let removals: [Removal]
    private static let markers = CharacterSet(charactersIn: "-‐\u{00AD}\u{200B}\u{2060}\u{FEFF}")

    // Restrict aliases to German/English word-like fragments. Do not join codes containing
    // digits, all-capital fragments, punctuation, paragraphs or physical page markers.
    private static let word = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}_/@.\-])[A-ZÄÖÜ]?[a-zäöüß]{2,}(?:(?:[-‐][\t ]*(?:\r\n|[\n\r\u2028])[\t ]*|[\u00AD\u200B\u2060\uFEFF]+(?:[\t ]*(?:\r\n|[\n\r\u2028])[\t ]*)?)[a-zäöüß]{2,})+(?![\p{L}\p{N}_/@.\-])"#)
    private static let separator = try! NSRegularExpression(pattern:
        #"[-‐][\t ]*(?:\r\n|[\n\r\u2028])[\t ]*|[\u00AD\u200B\u2060\uFEFF]+(?:[\t ]*(?:\r\n|[\n\r\u2028])[\t ]*)?"#)
    private static let identifierLabel = try! NSRegularExpression(pattern:
        #"(?i)(?:nummer|\bnr\.?|\bid|iban|bic|aktenzeichen|kennzeichen|code|referenz)\s*[:.]?\s*$"#)

    public init(_ source: String) {
        self.source = source
        guard source.rangeOfCharacter(from: Self.markers) != nil else {
            text = source; removals = []; return
        }
        let original = source as NSString
        var deleted: [NSRange] = []
        for word in Self.word.matches(in: source, range: NSRange(location: 0, length: original.length)) {
            let preceding = original.substring(with: NSRange(location: max(0, word.range.location - 100),
                                                             length: min(100, word.range.location)))
            if Self.identifierLabel.firstMatch(in: preceding, range: NSRange(preceding.startIndex..., in: preceding)) != nil { continue }
            deleted += Self.separator.matches(in: source, range: word.range).map(\.range)
        }
        var pieces: [String] = [], mapping: [Removal] = [], offset = 0, removed = 0
        for range in deleted {
            pieces.append(original.substring(with: NSRange(location: offset, length: range.location - offset)))
            let projectedOffset = range.location - removed
            removed += range.length
            mapping.append(Removal(projectedOffset: projectedOffset, removedThrough: removed))
            offset = NSMaxRange(range)
        }
        pieces.append(original.substring(from: offset))
        text = pieces.joined(); removals = mapping
    }

    public static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
    }

    public static func normalized(_ value: String) -> String { folded(Self(value).text) }

    public static func tokens(_ value: String) -> [String] {
        normalized(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Keep the original token vocabulary, adding only new normalized aliases.
    public static func sourceTokens(_ value: String) -> [String] {
        let original = folded(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let known = Set(original)
        return original + tokens(value).filter { !known.contains($0) }
    }

    /// Map a projected match back to a contiguous, unmodified source range.
    /// Foundation performs case/diacritic matching, so Unicode folding cannot invalidate offsets.
    public func ranges(of term: String, limit: Int = 20_001) -> [Range<String.Index>] {
        guard !term.isEmpty, limit > 0 else { return [] }
        var result: [Range<String.Index>] = []
        let normalizedTerm = Self(term).text
        // Original matches preserve the pre-existing vocabulary and literal hyphen queries.
        for (value, projected) in [(source, false), (text, true)] {
            if projected && removals.isEmpty && normalizedTerm == term { continue }
            let needle = projected ? normalizedTerm : term
            var offset = value.startIndex
            var count = 0
            while offset < value.endIndex, let match = value.range(of: needle,
                options: [.caseInsensitive, .diacriticInsensitive], range: offset..<value.endIndex) {
                let range: Range<String.Index>?
                if projected {
                    let ns = NSRange(match, in: value)
                    let lower = ns.location + removed(before: ns.location, inclusive: true)
                    let upper = NSMaxRange(ns) + removed(before: NSMaxRange(ns), inclusive: false)
                    range = Range(NSRange(location: lower, length: upper - lower), in: source)
                } else { range = match }
                if let range { result.append(range) }
                count += 1
                if count >= limit { break }
                offset = match.upperBound
            }
        }
        return Array(Set(result).sorted { $0.lowerBound < $1.lowerBound }.prefix(limit))
    }

    private func removed(before offset: Int, inclusive: Bool) -> Int {
        var lower = 0, upper = removals.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if removals[mid].projectedOffset < offset || (inclusive && removals[mid].projectedOffset == offset) {
                lower = mid + 1
            } else { upper = mid }
        }
        return lower == 0 ? 0 : removals[lower - 1].removedThrough
    }
}
