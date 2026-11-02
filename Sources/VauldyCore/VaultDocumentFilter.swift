import Foundation

/// Deterministic AND of whole normalized tokens across the retained record.
/// This is a text filter, not an inferred issuer/organization relationship.
public enum VaultDocumentFilter {
    public static func matches(_ document: VaultDocument, query: String?) -> Bool {
        guard let query else { return true }
        let requested = Set(tokens(query))
        let fields = [document.title, document.sourceName, document.ocrText, document.summary, document.category]
            + document.entities.flatMap { [$0.value, $0.normalizedValue ?? ""] }
            + document.contentFacts.flatMap { [$0.label, $0.value, $0.normalizedValue ?? ""] }
            + document.deadlines.flatMap { [$0.title, $0.sourceSnippet] }
        let available = Set(fields.flatMap(tokens))
        return !requested.isEmpty && requested.isSubset(of: available)
    }

    private static func tokens(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
