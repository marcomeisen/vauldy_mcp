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

    static func select(sections: [VaultPageMarkedText.Section], summary: String,
                       terms: [String], preferredPage: Int?) -> VaultPageMarkedText.Section {
        let readable = sections.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let chosen = preferredPage.flatMap { page in readable.first { $0.page == page } }
            ?? readable.first { section in terms.contains { section.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            ?? readable.first
        let text = chosen?.text ?? summary
        guard !text.isEmpty else { return .init(page: nil, text: "Kein lesbarer Text verfügbar.") }
        let match = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        var start = match.map { text.index($0.lowerBound, offsetBy: -180, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
        if let open = text[..<start].lastIndex(of: "["), text[open...].hasPrefix("[V_"),
           !text[open..<start].contains("]") { start = open }
        var end = text.index(start, offsetBy: 700, limitedBy: text.endIndex) ?? text.endIndex
        if let open = text[start..<end].lastIndex(of: "["), text[open...].hasPrefix("[V_"),
           !text[open..<end].contains("]"), let close = text[end...].firstIndex(of: "]") { end = text.index(after: close) }
        return .init(page: chosen?.page, text: String(text[start..<end]))
    }
}
