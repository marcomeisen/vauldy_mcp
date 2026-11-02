import Foundation

/// One acceptance boundary for extracted proposals, persistence and corpus checks.
/// Missing optional metadata is allowed; unsupported populated metadata is rejected.
public enum BaseAnalysisPipeline {
    public static func finalize(_ proposed: [BaseDocumentOverview], pages: [BaseAnalysisPage]) -> DocumentBaseAnalysis {
        let numbers = pages.map(\.number)
        guard !pages.isEmpty, pages.count <= 200, numbers == Array(1...pages.count),
              pages.reduce(0, { $0 + $1.text.utf8.count }) <= 900_000 else {
            return .init(status: .failed, analyzedPages: [], documents: [], issues: ["INVALID_SOURCE_COVERAGE"])
        }
        guard pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return .init(status: .unavailable, analyzedPages: numbers, documents: [], issues: ["NO_READABLE_TEXT"])
        }
        let byPage = Dictionary(uniqueKeysWithValues: pages.map { ($0.number, $0) })
        let owners = proposed.flatMap(\.pages)
        guard owners.sorted() == numbers else {
            return .init(status: .failed, analyzedPages: numbers, documents: [], issues: ["INVALID_DOCUMENT_OWNERSHIP"])
        }
        var global: [String] = []
        if pages.contains(where: { $0.needsReview || $0.unreadable }) { global.append("SOURCE_NEEDS_REVIEW") }
        if proposed.count > 1 { global.append("MULTIPLE_LOGICAL_DOCUMENTS") }
        let documents = proposed.map { original in
            var card = original
            func checked(_ field: BaseEvidenceField?, role: BaseFieldRole) -> BaseEvidenceField? {
                guard let field else { return nil }
                guard field.role == role, card.pages.contains(field.page), let source = byPage[field.page],
                      !field.value.isEmpty, field.value.count <= (role == .overview ? 650 : 240),
                      !field.quote.isEmpty, field.quote.count <= 900,
                      source.text.contains(field.quote), supports(field, in: source.text) else {
                    card.issues.append("UNSUPPORTED_\(role.rawValue.uppercased())")
                    return nil
                }
                return field
            }
            card.kindEvidence = checked(card.kindEvidence, role: .documentType)
            if card.kindEvidence?.value != card.kind.rawValue { card.kind = .unknown }
            card.issuer = checked(card.issuer, role: .issuer)
            card.recipient = checked(card.recipient, role: .recipient)
            card.issueDate = checked(card.issueDate, role: .issueDate)
            card.subject = checked(card.subject, role: .subject)
            card.titleYear = checked(card.titleYear, role: .titleYear)
            card.overview = checked(card.overview, role: .overview)
            if card.kind == .unknown { card.issues.append("DOCUMENT_TYPE_UNRESOLVED") }
            if card.overview == nil { card.issues.append("OVERVIEW_UNAVAILABLE") }
            if card.subject == nil { card.issues.append("SUBJECT_UNRESOLVED") }
            let subject = card.subject?.value
            var parts = [card.issuer?.value, subject].compactMap { $0 }
            if subject?.localizedCaseInsensitiveContains(card.kind.title) != true { parts.append(card.kind.title) }
            if let year = card.titleYear?.value, !parts.joined(separator: " ").contains(year) { parts.append(year) }
            card.title = parts.joined(separator: " ")
            card.issues = Array(Set(card.issues)).sorted()
            return card
        }
        global = Array(Set(global + documents.flatMap(\.issues))).sorted()
        return .init(status: global.isEmpty ? .completed : .needsReview, analyzedPages: numbers, documents: documents, issues: global)
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
    }
    static func supports(_ field: BaseEvidenceField, in source: String) -> Bool {
        switch field.role {
        case .documentType:
            return LocalRuleBasedDocumentAnalyzer.headingKind(field.quote)?.rawValue == field.value
        case .issueDate:
            return LocalRuleBasedDocumentAnalyzer.issueDate(in: field.quote) == field.value
        case .titleYear:
            return field.value.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil
                && (LocalRuleBasedDocumentAnalyzer.labelValue(in: field.quote, labels: LocalRuleBasedDocumentAnalyzer.yearLabels) == field.value
                    || LocalRuleBasedDocumentAnalyzer.issueDate(in: field.quote)?.hasPrefix(field.value + "-") == true)
        case .issuer:
            return field.origin == .explicitLabel && LocalRuleBasedDocumentAnalyzer.labelValue(in: field.quote, labels: LocalRuleBasedDocumentAnalyzer.issuerLabels) == field.value
        case .recipient:
            return field.origin == .explicitLabel && LocalRuleBasedDocumentAnalyzer.labelValue(in: field.quote, labels: LocalRuleBasedDocumentAnalyzer.recipientLabels) == field.value
        case .overview:
            return field.value == field.quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                && LocalRuleBasedDocumentAnalyzer.isOverview(field.value)
        case .subject:
            return field.quote.contains(field.value) && !field.value.isEmpty
        }
    }
}
