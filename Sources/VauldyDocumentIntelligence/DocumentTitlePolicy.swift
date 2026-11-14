import Foundation

/// Conservative text-only title policy. Source evidence alone does not make prose a title.
/// No filename, recipient, bank account or unlabelled organization is treated as an issuer.
public enum DocumentTitlePolicy {
    public static let fallback = "Dokument – Aussteller unbekannt"

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isTitlePhrase(_ text: String) -> Bool {
        let value = normalized(text)
        guard !text.contains("\n"), !text.contains("\r"), (2...110).contains(value.count),
              value.split(separator: " ").count <= 12,
              let first = value.first, first.isLetter, first.isUppercase,
              !value.contains(where: { ",;!?|".contains($0) }),
              !LocalRuleBasedDocumentAnalyzer.isInstruction(value) else { return false }
        let folded = BaseAnalysisPipeline.folded(value)
        // Finite verbs, personal address and clause openings are stronger prose signals
        // than line position or the presence of a type word such as "Vertrag".
        let prose = #"\b(ist|sind|war|waren|wird|werden|wurde|wurden|hat|haben|hatte|hatten|muss|mussen|kann|konnen|soll|sollen|darf|durfen|sollte|sollten|mochten|bitte|sie|ihnen|wir|ich|du|euch|verpflichtet|abbuchen|weiterzuleiten)\b|^(wenn|sofern|falls|weil|dass|obwohl|hiermit|gemaß|gemass|und|oder|aber|dieser|diese|dieses)\b"#
        guard folded.range(of: prose, options: .regularExpression) == nil else { return false }
        // Allow common abbreviations and numeric punctuation, never sentence endings
        // or a sentence joined to a heading ("weiterzuleiten. Vertrag").
        let withoutAbbreviations = folded.replacingOccurrences(of: #"\b(nr|dr|prof|e|v|z|b|co)\."#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: "", options: .regularExpression)
        return !withoutAbbreviations.contains(".") && !value.contains("://")
    }

    package static func withoutLayout(_ card: BaseDocumentOverview) -> String {
        var card = card
        if let subject = card.subject?.value, !LayoutDocumentTitle.isCleanTitleText(subject) { card.subject = nil }
        if let heading = card.kindEvidence?.quote, !LayoutDocumentTitle.isCleanTitleText(heading) { card.kindEvidence = nil }
        if let issuer = card.issuer?.value, !LayoutDocumentTitle.isCleanTitleText(issuer) { card.issuer = nil }
        return title(for: card)
    }

    /// Do not degrade an existing, same-source type to a generic title just because the
    /// layout cannot rank it. Require the same heading from the fresh text analysis.
    package static func retainedTypeTitle(_ existing: String, analysis: BaseDocumentOverview) -> String? {
        guard !analysis.issues.contains("DOCUMENT_STRUCTURE_AMBIGUOUS"),
              let evidence = analysis.kindEvidence,
              let originalHeading = existing.components(separatedBy: " – ").first else { return nil }
        let supported = LayoutDocumentTitle.headingText(evidence.quote)
        let heading = LayoutDocumentTitle.headingText(originalHeading)
        guard LayoutDocumentTitle.isHeadingText(heading), LayoutDocumentTitle.titleKind(heading) == analysis.kind,
              BaseAnalysisPipeline.folded(supported) == BaseAnalysisPipeline.folded(heading) else { return nil }
        // Keep only the confirmed heading, issuer and year. Drop old unconfirmed subjects.
        var card = analysis
        card.kindEvidence = .init(role: .documentType, value: evidence.value, page: evidence.page, quote: heading, origin: .documentHeading)
        card.subject = nil
        if let issuer = card.issuer?.value, !LayoutDocumentTitle.isCleanTitleText(issuer) { card.issuer = nil }
        return title(for: card)
    }

    static func title(for card: BaseDocumentOverview) -> String {
        // Only accepted evidence enters here. Keep the specific printed heading,
        // e.g. "Versicherungsschein", instead of replacing it with a broad category.
        let ambiguous = card.issues.contains("DOCUMENT_STRUCTURE_AMBIGUOUS")
        let heading = card.kindEvidence?.quote.trimmingCharacters(in: .whitespaces)
        let primary = ambiguous ? "Dokument" : (heading.flatMap { isTitlePhrase($0) ? normalized($0) : nil } ?? card.kind.title)
        var parts = [primary]
        if !ambiguous, let subject = card.subject?.value, isTitlePhrase(subject),
           !BaseAnalysisPipeline.folded(primary).contains(BaseAnalysisPipeline.folded(subject)) {
            parts.append(normalized(subject))
        }
        if let issuer = card.issuer?.value, isTitlePhrase(issuer) { parts.append(normalized(issuer)) }
        else { parts.append("Aussteller unbekannt") }
        if !ambiguous, card.kind != .unknown, let year = card.titleYear?.value,
           !parts.joined(separator: " ").contains(year) { parts.append(year) }
        // Drop optional detail rather than truncate an arbitrary clause.
        if parts.joined(separator: " – ").count > 220, parts.count > 2 { parts.remove(at: 1) }
        return parts.joined(separator: " – ")
    }
}
