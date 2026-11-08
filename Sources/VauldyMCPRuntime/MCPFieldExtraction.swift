import Foundation
import VauldyDocumentCore

public struct MCPFieldEvidence: Encodable, Sendable {
    public let label: String
    public let value: String
    public let page: Int
    public let quote: String
    public let source: String
}

public struct MCPExtractedField: Encodable, Sendable {
    public let document: String
    public let field: String
    public let status: String
    public let evidence: [MCPFieldEvidence]
    public let evidenceCount: Int
    public let evidenceOffset: Int
    public let evidenceComplete: Bool
    public let sourceCoverage: String
    public let warnings: [String]
}

public struct MCPFieldExtractionResult: Encodable, Sendable {
    public let contractVersion = 1
    public let scope = "explicit-labels-and-contract-headings"
    public let results: [MCPExtractedField]
    public let nextCursor: String?
    public let retrievalComplete: Bool
    public let warnings = ["LITERAL_FIELDS_ONLY", "CONTRACT_STATUS_NOT_VERIFIED", "LOGICAL_DOCUMENT_ASSIGNMENT_NOT_INFERRED"]
    public let disclosure = MCPDisclosure()
}

enum MCPExtractionField: String, CaseIterable {
    case contractType, cost, term, noticePeriod, contractNumber, issuer, startDate, endDate
    case paymentDue, cancellationDue, appointment
    static let defaults: [Self] = [.contractType, .cost, .term, .noticePeriod]
    static let exposed: Set<Self> = Set(defaults + [.contractNumber, .issuer, .startDate, .endDate])
}

/// Runs exclusively on text already protected in the whole-document privacy context.
/// Labels identify roles. Mentions, filenames and document instructions provide no field authority.
enum MCPFieldExtraction {
    private struct Rule {
        let field: MCPExtractionField
        let aspect: String
    }
    private static let rules: [String: Rule] = {
        let groups: [(MCPExtractionField, String, [String])] = [
            (.contractType, "type", ["Vertragsart", "Vertragstyp"]),
            (.cost, "monthly", ["Monatliche Rate", "Monatliche Leasingrate", "Leasingrate", "Finanzierungsrate", "Monatsrate", "Monatsbeitrag"]),
            (.cost, "annual", ["Jahresbeitrag"]),
            (.cost, "total", ["Gesamtkosten", "Gesamtbetrag"]),
            (.cost, "final", ["Schlussrate"]),
            (.cost, "unspecified", ["Kosten", "Beitrag", "Versicherungsbeitrag"]),
            (.term, "duration", ["Laufzeit", "Vertragslaufzeit", "Vertragsdauer"]),
            (.term, "minimum", ["Mindestlaufzeit"]),
            (.noticePeriod, "notice", ["Kündigungsfrist"]),
            (.noticePeriod, "ordinary", ["Ordentliche Kündigung"]),
            (.noticePeriod, "early", ["Vorzeitige Kündigung"]),
            (.noticePeriod, "conditions", ["Kündigung", "Kündigungsbedingungen"]),
            (.contractNumber, "number", ["Vertragsnummer", "Policennummer", "Versicherungsscheinnummer"]),
            (.issuer, "issuer", ["Aussteller", "Absender", "Versicherer", "Leasinggeber"]),
            (.startDate, "start", ["Vertragsbeginn", "Versicherungsbeginn"]),
            (.endDate, "end", ["Vertragsende", "Laufzeitende"])
        ]
        var output: [String: Rule] = [:]
        for (field, aspect, labels) in groups {
            for label in labels { output[fold(label)] = Rule(field: field, aspect: aspect) }
        }
        return output
    }()
    private static let deadlineRules = rules.merging([
        "zahlbar bis": Rule(field: .paymentDue, aspect: "due"),
        "zahlungsfrist": Rule(field: .paymentDue, aspect: "due"),
        "zahlung fallig am": Rule(field: .paymentDue, aspect: "due"),
        "kundigung bis": Rule(field: .cancellationDue, aspect: "due"),
        "kundigungsstichtag": Rule(field: .cancellationDue, aspect: "due"),
        "kundigung spatestens am": Rule(field: .cancellationDue, aspect: "due"),
        "termin": Rule(field: .appointment, aspect: "appointment"),
        "termin am": Rule(field: .appointment, aspect: "appointment")
    ]) { previous, _ in previous }
    private static let headings: Set<String> = [
        "leasingvertrag", "finanzierungsvertrag", "darlehensvertrag", "versicherungsvertrag",
        "versicherungsschein", "mietvertrag", "kaufvertrag", "dienstleistungsvertrag", "arbeitsvertrag"
    ]

    static func extract(sections: [VaultPageMarkedText.Section], handle: String,
                        fields: [MCPExtractionField], sourceCoverage: String,
                        exactValues: Bool = false) throws -> [MCPExtractedField] {
        let rules = fields.allSatisfy(MCPExtractionField.exposed.contains) ? Self.rules : deadlineRules
        struct Value {
            let aspect: String
            let evidence: MCPFieldEvidence
        }
        var values: [MCPExtractionField: [Value]] = [:]
        var seen: [MCPExtractionField: Set<String>] = [:]
        var incomplete: Set<MCPExtractionField> = []
        var unlocated = false
        for section in sections {
            try Task.checkCancellation()
            guard let page = section.page else {
                unlocated = unlocated || !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                continue
            }
            let lines = section.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            for (index, raw) in lines.enumerated() {
                try Task.checkCancellation()
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let rule: Rule
                let label: String
                var value: String
                var quote = line
                if let colon = line.firstIndex(of: ":"), let matched = rules[fold(String(line[..<colon]))] {
                    rule = matched
                    label = String(line[..<colon])
                    value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                } else if let matched = rules[fold(line)] {
                    rule = matched; label = line; value = ""
                } else if headings.contains(fold(line)) {
                    rule = Rule(field: .contractType, aspect: "type"); label = "Dokumentüberschrift"; value = line
                } else { continue }
                guard fields.contains(rule.field) else { continue }
                if value.isEmpty {
                    guard index + 1 < lines.count else { incomplete.insert(rule.field); continue }
                    let next = lines[index + 1]
                    value = next.trimmingCharacters(in: .whitespacesAndNewlines)
                    let prefix = value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                    guard !value.isEmpty, rules[fold(prefix)] == nil, !headings.contains(fold(value)) else {
                        incomplete.insert(rule.field); continue
                    }
                    quote = String(section.text[raw.startIndex..<next.endIndex])
                    // A following line can start a longer clause. Keep the bounded evidence explicit.
                    if index + 2 < lines.count && !lines[index + 2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        incomplete.insert(rule.field)
                    }
                }
                guard value.utf8.count <= 1_200, quote.utf8.count <= 1_600, label.utf8.count <= 100 else {
                    incomplete.insert(rule.field); continue
                }
                // An inline value may continue as an unlabelled clause on the next line.
                if !quote.contains(where: \.isNewline), index + 1 < lines.count {
                    let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let prefix = next.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                    if !next.isEmpty, rules[fold(prefix)] == nil, !headings.contains(fold(next)) {
                        incomplete.insert(rule.field)
                    }
                }
                let key = rule.aspect + "\n" + (exactValues ? value : fold(value))
                guard seen[rule.field, default: []].insert(key).inserted else { continue }
                let evidence = MCPFieldEvidence(label: label, value: value, page: page, quote: quote,
                                                source: "[Quelle:\(handle):S.\(page)]")
                values[rule.field, default: []].append(Value(aspect: rule.aspect, evidence: evidence))
                guard seen.values.reduce(0, { $0 + $1.count }) <= 512 else { throw MCPAccessError.tooLarge }
            }
        }
        return fields.flatMap { field -> [MCPExtractedField] in
            let found = values[field] ?? []
            let groups = Dictionary(grouping: found, by: \.aspect)
            let status: String
            if groups.values.contains(where: { $0.count > 1 }) { status = "conflicting" }
            else if found.count > 1 { status = "multiple-values" }
            else if let first = found.first { status = first.evidence.value.contains("[V_") ? "redacted" : "evidenced" }
            else { status = "not-evidenced" }
            var warnings: [String] = []
            if incomplete.contains(field) { warnings.append("FIELD_EXTRACTION_INCOMPLETE") }
            if unlocated { warnings.append("UNLOCATED_SOURCE_TEXT") }
            let offsets = stride(from: 0, to: max(1, found.count), by: 2)
            return offsets.map { offset in
                let end = min(offset + 2, found.count)
                return MCPExtractedField(document: handle, field: field.rawValue, status: status,
                    evidence: found[offset..<end].map(\.evidence), evidenceCount: found.count,
                    evidenceOffset: offset, evidenceComplete: end == found.count,
                    sourceCoverage: sourceCoverage, warnings: warnings)
            }
        }
    }

    static func aspect(for label: String) -> String {
        label == "Dokumentüberschrift" ? "type" : (rules[fold(label)]?.aspect ?? "unclassified")
    }

    static func isContractHeading(_ line: String) -> Bool { headings.contains(fold(line)) }

    private static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
