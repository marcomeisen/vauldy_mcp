import Foundation
import VauldyCore

/// Select only after whole-context protection. All returned characters come from
/// one contiguous protected passage; neither boundary cuts an identifier token.
enum MCPSourceExcerpt {
    static func terms(in protectedQuery: String) -> [String] {
        // Names/identifiers must match the complete request-specific placeholder,
        // not a shared namespace or kind occurring in every masked name.
        guard let regex = try? NSRegularExpression(pattern: #"\[V_[A-F0-9]{32}_[A-Z_]+_\d+\]"#) else { return [] }
        let range = NSRange(protectedQuery.startIndex..., in: protectedQuery)
        let placeholders = regex.matches(in: protectedQuery, range: range).compactMap { match in
            Range(match.range, in: protectedQuery).map { String(protectedQuery[$0]) }
        }
        let rest = regex.stringByReplacingMatches(in: protectedQuery, range: range, withTemplate: " ")
        return placeholders + LocalVault.queryTerms(rest)
    }

    /// All matched windows in source order. Only overlapping source ranges are merged.
    /// Matching runs after document-wide protection; pseudonyms remain atomic.
    static func passages(sections: [VaultPageMarkedText.Section], terms: [String]) throws -> [VaultPageMarkedText.Section] {
        var result: [VaultPageMarkedText.Section] = []
        var matchCount = 0
        for section in sections {
            let text = section.text
            let projection = VaultSearchText(text)
            var matches: [Range<String.Index>] = []
            for term in terms where !term.isEmpty {
                let found = projection.ranges(of: term, limit: 20_001 - matchCount)
                matchCount += found.count
                guard matchCount <= 20_000 else { throw MCPAccessError.tooLarge }
                matches += found
            }
            var windows: [Range<String.Index>] = []
            for match in matches.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                var lower = text.index(match.lowerBound, offsetBy: -180, limitedBy: text.startIndex) ?? text.startIndex
                var upper = text.index(match.upperBound, offsetBy: 520, limitedBy: text.endIndex) ?? text.endIndex
                if let open = text[..<lower].lastIndex(of: "["), text[open...].hasPrefix("[V_"), !text[open..<lower].contains("]") { lower = open }
                if let open = text[lower..<upper].lastIndex(of: "["), text[open...].hasPrefix("[V_"),
                   !text[open..<upper].contains("]"), let close = text[upper...].firstIndex(of: "]") { upper = text.index(after: close) }
                if let last = windows.last, lower <= last.upperBound {
                    windows[windows.count - 1] = last.lowerBound..<max(last.upperBound, upper)
                } else { windows.append(lower..<upper) }
            }
            result += windows.map { .init(page: section.page, text: String(text[$0])) }
            guard result.count <= 2_000 else { throw MCPAccessError.tooLarge }
        }
        return result
    }

    static func select(sections: [VaultPageMarkedText.Section], summary: String,
                       terms: [String], preferredPage: Int?, limit: Int = 700) -> VaultPageMarkedText.Section {
        let readable = sections.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let chosen = preferredPage.flatMap { page in readable.first { $0.page == page } }
            ?? readable.first { section in
                let projection = VaultSearchText(section.text)
                return terms.contains { !projection.ranges(of: $0, limit: 1).isEmpty }
            }
            ?? readable.first
        let text = chosen?.text ?? summary
        guard !text.isEmpty else { return .init(page: nil, text: "Kein lesbarer Text verfügbar.") }
        let projection = VaultSearchText(text)
        let match = terms.compactMap { projection.ranges(of: $0, limit: 1).first }
            .min { $0.lowerBound < $1.lowerBound }
        var start = match.map { text.index($0.lowerBound, offsetBy: -180, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
        if let open = text[..<start].lastIndex(of: "["), text[open...].hasPrefix("[V_"),
           !text[open..<start].contains("]") { start = open }
        var end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        if let open = text[start..<end].lastIndex(of: "["), text[open...].hasPrefix("[V_"),
           !text[open..<end].contains("]"), let close = text[end...].firstIndex(of: "]") { end = text.index(after: close) }
        return .init(page: chosen?.page, text: String(text[start..<end]))
    }
}
