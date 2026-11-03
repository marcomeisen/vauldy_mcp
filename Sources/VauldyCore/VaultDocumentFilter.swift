import Foundation

public enum VaultTextMatchMode: String, Codable, Sendable {
    case allTokens = "all-tokens"
    case anyTermSubstring = "any-term-substring"
}

/// Deterministic AND of whole normalized tokens across the retained record.
/// This is a text filter, not an inferred issuer/organization relationship.
public enum VaultDocumentFilter {
    public static func matches(_ document: VaultDocument, query: String?, mode: VaultTextMatchMode = .allTokens) -> Bool {
        guard let query else { return true }
        let requested = Set(tokens(query))
        let fields = [document.title, document.sourceName, document.ocrText, document.summary, document.category]
            + document.entities.flatMap { [$0.value, $0.normalizedValue ?? ""] }
            + document.contentFacts.flatMap { [$0.label, $0.value, $0.normalizedValue ?? ""] }
            + document.deadlines.flatMap { [$0.title, $0.sourceSnippet] }
        if mode == .anyTermSubstring {
            return fields.contains { field in
                let text = normalized(field)
                return requested.contains { text.contains($0) }
            }
        }
        let available = Set(fields.flatMap(tokens))
        return !requested.isEmpty && requested.isSubset(of: available)
    }

    public static func validCandidateQuery(_ query: String) -> Bool {
        let values = tokens(query)
        return !values.isEmpty && values.count <= 24 && values.allSatisfy { $0.count >= 3 }
    }
    private static func tokens(_ value: String) -> [String] {
        normalized(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
    }
}
