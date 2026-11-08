import Foundation
import VauldyDocumentCore

public struct MCPContractComparisonResult: Encodable, Sendable {
    public struct Side: Encodable, Sendable {
        let document: String
        let sourceCoverage: String
        let identitySource: String?
    }
    public struct Row: Encodable, Sendable {
        let field: String
        let aspect: String
        let status: String
        let before: MCPFieldEvidence?
        let after: MCPFieldEvidence?
        let beforeEvidenceCount: Int
        let afterEvidenceCount: Int
        let warnings: [String]
    }
    let contractVersion = 1
    let scope = "explicit-field-text-comparison"
    let status: String
    let before: Side
    let after: Side
    public let rows: [Row]
    let warnings: [String]
    let disclosure = MCPDisclosure()
}

enum MCPContractComparison {
    static let fields = MCPExtractionField.defaults + [.startDate, .endDate]
    static let limitations = ["EXPLICIT_LABELS_ONLY", "VERSION_ORDER_AND_LEGAL_EFFECT_NOT_VERIFIED"]
    private static let numberLabels: Set<String> = ["vertragsnummer", "vertragsnr.", "policennummer", "versicherungsscheinnummer"]
    private static let issuerLabels: Set<String> = ["aussteller", "versicherer", "leasinggeber"]

    /// This type is deliberately not Encodable. The values are used only for local matching.
    struct Identity: Equatable {
        fileprivate let namespace: String
        fileprivate let number: String
        fileprivate let issuer: String
    }

    static func identity(in sections: [VaultPageMarkedText.Section], hasVerifiedHeading: Bool) throws -> Identity? {
        var numbers: [Int: [(String, String)]] = [:]
        var issuers: [Int: [String]] = [:]
        var firstHeading = hasVerifiedHeading
        var headings: Set<String> = []
        for section in sections {
            guard let page = section.page else { return nil }
            var pageHeadingCount = 0
            let lines = section.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            for (index, raw) in lines.enumerated() {
                try Task.checkCancellation()
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if MCPFieldExtraction.isContractHeading(line) {
                    pageHeadingCount += 1
                    headings.insert(line.lowercased())
                    if page == 1 { firstHeading = true }
                }
                guard let colon = line.firstIndex(of: ":") else {
                    if numberLabels.contains(line.lowercased()) || issuerLabels.contains(line.lowercased()) { return nil }
                    continue
                }
                let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard numberLabels.contains(label) || issuerLabels.contains(label) else { continue }
                if index + 1 < lines.count {
                    let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    guard next.isEmpty || next.range(of: #"^\p{L}[\p{L} .-]{0,39}:"#,
                                                     options: .regularExpression) != nil else { return nil }
                }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if numberLabels.contains(label) {
                    guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9./-]{3,63}$"#, options: .regularExpression) != nil,
                          value.utf8.contains(where: { (48...57).contains($0) }) else { return nil }
                    let namespace = label == "vertragsnr." ? "vertragsnummer" : label
                    numbers[page, default: []].append((namespace, value))
                } else {
                    guard !value.isEmpty, value.utf8.count <= 240, !value.contains("[V_") else { return nil }
                    issuers[page, default: []].append(value)
                }
            }
            guard pageHeadingCount <= 1, headings.count <= 1 else { return nil }
        }
        guard firstHeading, let number = numbers[1]?.first, let issuer = issuers[1]?.first,
              numbers.values.joined().allSatisfy({ $0 == number }),
              issuers.values.joined().allSatisfy({ $0 == issuer }) else { return nil }
        return .init(namespace: number.0, number: number.1, issuer: issuer)
    }

    static func compare(_ before: [MCPExtractedField], _ after: [MCPExtractedField],
                        identity: Identity) -> [MCPContractComparisonResult.Row] {
        fields.flatMap { field in
            let b = before.filter { $0.field == field.rawValue }, a = after.filter { $0.field == field.rawValue }
            let left = Dictionary(grouping: b.flatMap(\.evidence)) { MCPFieldExtraction.aspect(for: $0.label) }
            let right = Dictionary(grouping: a.flatMap(\.evidence)) { MCPFieldExtraction.aspect(for: $0.label) }
            let aspects = Set(left.keys).union(right.keys)
            let warnings = Set((a + b).flatMap(\.warnings))
            return (aspects.isEmpty ? ["unclassified"] : aspects.sorted()).map { aspect in
                let l = left[aspect] ?? [], r = right[aspect] ?? []
                var issues = warnings
                if l.count > 1 || r.count > 1 { issues.insert("CONFLICTING_VALUES") }
                if (l + r).contains(where: { $0.value.contains("[V_") }) { issues.insert("REDACTED_VALUE") }
                if aspect == "unspecified", let l = l.first, let r = r.first,
                   l.label.caseInsensitiveCompare(r.label) != .orderedSame {
                    issues.insert("COST_ROLE_NOT_COMPARABLE")
                }
                // Never disclose the matching number, even if a field's quote includes an unlabelled copy.
                func bounded(_ evidence: MCPFieldEvidence?) -> MCPFieldEvidence? {
                    guard let evidence, evidence.quote.utf8.count <= 500, evidence.value.utf8.count <= 300,
                          !evidence.quote.localizedCaseInsensitiveContains(identity.number),
                          !evidence.value.localizedCaseInsensitiveContains(identity.number) else { return nil }
                    return evidence
                }
                let before = l.count == 1 ? bounded(l.first) : nil
                let after = r.count == 1 ? bounded(r.first) : nil
                if (l.count == 1 && before == nil) || (r.count == 1 && after == nil) { issues.insert("EVIDENCE_WITHHELD") }
                let status: String
                if !issues.isEmpty { status = "unresolved" }
                else if let before, let after { status = before.value == after.value ? "same-text" : "different-text" }
                else if before != nil { status = "before-only" }
                else if after != nil { status = "after-only" }
                else { status = "not-evidenced" }
                return MCPContractComparisonResult.Row(
                    field: field.rawValue, aspect: aspect, status: status, before: before, after: after,
                    beforeEvidenceCount: l.count, afterEvidenceCount: r.count, warnings: issues.sorted())
            }
        }
    }
}
