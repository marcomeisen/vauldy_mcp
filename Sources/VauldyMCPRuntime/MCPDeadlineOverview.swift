import Foundation
import VauldyDocumentCore

public struct MCPDeadlineOverview: Encodable, Sendable {
    struct Entry: Encodable, Sendable {
        let role: String
        let status: String
        let date: String?
        let evidence: [MCPFieldEvidence]
        let evidenceCount: Int
        let warnings: [String]
    }

    struct Calculation: Encodable, Sendable {
        let date: String
        let method: String
        let ruleSource: String
        let endDateSource: String
    }

    public struct Row: Encodable, Sendable {
        let document: String
        let sourceCoverage: String
        let entries: [Entry]
        let calculationStatus: String
        let calculation: Calculation?
        let warnings: [String]
    }

    let contractVersion = 1
    let scope = "selected-documents-explicit-deadlines"
    public let rows: [Row]
    let warnings = ["EXPLICIT_LABELS_ONLY", "CALCULATED_DATES_ARE_ARITHMETIC", "LEGAL_EFFECT_AND_CONTRACT_STATUS_NOT_VERIFIED"]
    let disclosure = MCPDisclosure()

    static let fields: [MCPExtractionField] = [.endDate, .noticePeriod, .cancellationDue, .paymentDue, .appointment]
    private static let conditionalContext = #"\b(?:\w*verlänger\w*|\w*verlaenger\w*|abweich\w*|sonderkündig\w*|werktag\w*|arbeitstag\w*|zugang\w*|ausnahme\w*|vorbehaltlich|wenn|sofern|falls|außer|es sei denn|nur bei|nur für)\b"#

    static func row(document: String, sourceCoverage: String, extracted: [MCPExtractedField],
                    sourceReady: Bool, singleContract: Bool, sections: [VaultPageMarkedText.Section]) -> Row {
        let grouped = Dictionary(grouping: extracted, by: \.field)
        let entries = fields.map { field in
            entry(field, chunks: grouped[field.rawValue] ?? [], sourceReady: sourceReady)
        }
        let fixed = entries[2]
        if fixed.status == "explicit-date" {
            return .init(document: document, sourceCoverage: sourceCoverage, entries: entries,
                         calculationStatus: "stated-date", calculation: nil, warnings: [])
        }

        func unresolved(_ warning: String) -> Row {
            .init(document: document, sourceCoverage: sourceCoverage, entries: entries,
                  calculationStatus: "unresolved", calculation: nil, warnings: [warning])
        }

        guard sourceReady else { return unresolved("SOURCE_NOT_READY") }
        guard fixed.status == "not-evidenced" else { return unresolved("CANCELLATION_DATE_UNRESOLVED") }
        let end = entries[0], notice = entries[1]
        guard let anchor = end.date.flatMap(MCPCalendarDay.init), let anchorEvidence = end.evidence.first,
              notice.status == "stated-rule", let rule = notice.evidence.first,
              MCPFieldExtraction.aspect(for: rule.label) == "notice" else {
            return unresolved("RULE_OR_END_DATE_UNRESOLVED")
        }
        guard singleContract, rule.page == anchorEvidence.page,
              sections.first(where: { $0.page == rule.page })?.text.split(whereSeparator: \.isNewline)
                .filter({ MCPFieldExtraction.isContractHeading(String($0).trimmingCharacters(in: .whitespaces)) }).count == 1 else {
            return unresolved("RULE_AND_END_DATE_SCOPE_UNRESOLVED")
        }
        guard !sections.contains(where: { $0.text.range(of: conditionalContext, options: [.regularExpression, .caseInsensitive]) != nil })
        else { return unresolved("CONDITIONAL_CONTEXT") }
        guard let offset = MCPNoticeOffset(rule.value) else { return unresolved("RULE_NOT_SUPPORTED") }
        guard let date = anchor.subtract(offset) else { return unresolved("CALENDAR_DATE_UNRESOLVED") }
        return .init(document: document, sourceCoverage: sourceCoverage, entries: entries,
                     calculationStatus: "calculated",
                     calculation: .init(date: date, method: offset.method, ruleSource: rule.source, endDateSource: anchorEvidence.source),
                     warnings: [])
    }

    private static func entry(_ field: MCPExtractionField, chunks: [MCPExtractedField], sourceReady: Bool) -> Entry {
        let values = chunks.flatMap(\.evidence)
        var warnings = Set(chunks.flatMap(\.warnings))
        if !sourceReady { warnings.insert("SOURCE_NOT_READY") }
        if values.count > 1 { warnings.insert("MULTIPLE_FIELD_VALUES") }
        if values.contains(where: { $0.value.contains("[V_") }) { warnings.insert("REDACTED_VALUE") }
        let evidence = Array(values.prefix(2).filter { $0.quote.utf8.count <= 320 && $0.value.utf8.count <= 160 })
        if evidence.count < min(2, values.count) { warnings.insert("EVIDENCE_WITHHELD") }
        let date: String?
        let status: String
        if !warnings.isEmpty {
            date = nil
            status = "unresolved"
        } else if let value = evidence.first?.value {
            if field == .noticePeriod {
                date = nil
                status = "stated-rule"
            } else {
                date = MCPCalendarDay(value)?.iso
                status = date == nil ? "unresolved" : "explicit-date"
                if date == nil { warnings.insert("DATE_NOT_SUPPORTED") }
            }
        } else {
            date = nil
            status = "not-evidenced"
        }
        return .init(role: field.rawValue, status: status, date: date, evidence: evidence,
                     evidenceCount: values.count, warnings: warnings.sorted())
    }
}

private struct MCPNoticeOffset {
    let component: Calendar.Component
    let amount: Int
    let method: String

    init?(_ text: String) {
        let words = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .split(whereSeparator: \.isWhitespace)
        guard words.count == 4 || (words.count == 5 && words[3] == "dem"),
              words[0].utf8.count <= 3, words[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(words[0]), count > 0, words[2] == "vor", words.last == "vertragsende" else { return nil }
        switch words[1] {
        case "kalendertag", "kalendertage":
            component = .day; amount = count; method = "subtract-calendar-days"
        case "woche", "wochen":
            component = .day; amount = 7 * count; method = "subtract-calendar-weeks"
        case "monat", "monate":
            component = .month; amount = count; method = "subtract-calendar-months-same-day"
        default: return nil
        }
    }
}

private struct MCPCalendarDay {
    let value: Date
    let parts: DateComponents
    private static let calendar: Calendar = {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }()

    init?(_ text: String) {
        let pattern = #"^(?:[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}|[0-9]{4}-[0-9]{2}-[0-9]{2})\.?$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let iso = text.contains("-")
        let numbers = text.split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        let year = numbers[iso ? 0 : 2], month = numbers[1], day = numbers[iso ? 2 : 0]
        let expected = DateComponents(year: year, month: month, day: day)
        guard (1900...9999).contains(year), let date = Self.calendar.date(from: expected) else { return nil }
        let parsed = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard parsed == expected else { return nil }
        value = date
        parts = parsed
    }

    var iso: String { Self.format(parts) }

    func subtract(_ offset: MCPNoticeOffset) -> String? {
        guard let date = Self.calendar.date(byAdding: offset.component, value: -offset.amount, to: value) else { return nil }
        let shifted = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = shifted.year, (1900...9999).contains(year),
              offset.component != .month || shifted.day == parts.day else { return nil }
        return Self.format(shifted)
    }

    private static func format(_ date: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)
    }
}
