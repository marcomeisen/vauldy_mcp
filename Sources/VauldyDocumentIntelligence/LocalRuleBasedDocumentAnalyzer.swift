import Foundation

/// Offline extractive baseline. It never calls a model or resolves an organization
/// externally. Unclear structure remains reviewable rather than receiving invented fields.
public struct LocalRuleBasedDocumentAnalyzer: DocumentBaseAnalyzing {
    static let issuerLabels = ["Aussteller", "Absender", "Herausgeber", "Rechnungssteller"]
    static let recipientLabels = ["Empfänger", "Empfaenger", "Adressat", "Patient", "Versicherungsnehmer"]
    static let dateLabels = ["Dokumentdatum", "Rechnungsdatum", "Ausstellungsdatum", "Ausgestellt am", "Berichtsdatum", "Bescheiddatum", "Erstellt am", "Datum"]
    static let yearLabels = ["Abrechnungsjahr", "Veranlagungsjahr", "Steuerjahr", "Berichtsjahr", "Bezugsjahr"]
    public init() {}

    public func analyze(pages: [BaseAnalysisPage]) async throws -> DocumentBaseAnalysis {
        try Task.checkCancellation()
        guard pages.count <= 200, pages.reduce(0, { $0 + $1.text.utf8.count }) <= 900_000 else {
            return .init(status: .failed, analyzedPages: [], documents: [], issues: ["ANALYSIS_INPUT_LIMIT"])
        }
        var groups: [[BaseAnalysisPage]] = []
        var signature: String?
        for page in pages {
            try Task.checkCancellation()
            let lines = sourceLines(page)
            let issuer = lines.compactMap { Self.labelValue(in: $0.text, labels: Self.issuerLabels) }.first
            let reference = lines.compactMap { Self.labelValue(in: $0.text, labels: ["Rechnungsnummer", "Dokumentnummer", "Vertragsnummer", "Aktenzeichen"]) }.first
            let date = lines.compactMap { Self.issueDate(in: $0.text) }.first
            let heading = lines.first { Self.headingKind($0.text) != nil }
            let nextSignature = issuer.map { Self.fold($0) + "|" + (reference ?? "") + "|" + (date ?? "") }
            if groups.isEmpty || (heading != nil && nextSignature != nil && signature != nil && nextSignature != signature) {
                groups.append([page]); signature = nextSignature
            } else {
                groups[groups.count - 1].append(page)
                if signature == nil { signature = nextSignature }
            }
        }
        let proposals = try groups.map { group in
            try Task.checkCancellation()
            return overview(group)
        }
        return BaseAnalysisPipeline.finalize(proposals, pages: pages)
    }

    private struct Line { let page: Int; let text: String }
    private func sourceLines(_ page: BaseAnalysisPage) -> [Line] {
        page.text.components(separatedBy: .newlines).map { .init(page: page.number, text: $0) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func overview(_ pages: [BaseAnalysisPage]) -> BaseDocumentOverview {
        let lines = pages.flatMap(sourceLines)
        var issues: [String] = []
        func unique(_ role: BaseFieldRole, extract: (String) -> String?) -> BaseEvidenceField? {
            let values = lines.compactMap { line in extract(line.text).map {
                BaseEvidenceField(role: role, value: $0, page: line.page, quote: line.text)
            } }
            guard Set(values.map { Self.fold($0.value) }).count <= 1 else {
                issues.append("CONFLICTING_\(role.rawValue.uppercased())"); return nil
            }
            return values.first
        }
        let issuer = unique(.issuer) { Self.labelValue(in: $0, labels: Self.issuerLabels) }
        let recipient = unique(.recipient) { Self.labelValue(in: $0, labels: Self.recipientLabels) }
        let date = unique(.issueDate, extract: Self.issueDate)
        if lines.contains(where: { Self.labelValue(in: $0.text, labels: Self.dateLabels) != nil && Self.issueDate(in: $0.text) == nil }) {
            issues.append("DOCUMENT_DATE_UNRESOLVED")
        }
        var subject = unique(.subject) { Self.labelValue(in: $0, labels: ["Betreff", "Gegenstand", "Leistung"]) }
        let headings = lines.compactMap { line in Self.headingKind(line.text).map { (line, $0) } }
        let kind = headings.first?.1 ?? .unknown
        if Set(headings.map(\.1)).count > 1 { issues.append("DOCUMENT_STRUCTURE_AMBIGUOUS") }
        if subject == nil, let heading = headings.first {
            let patterns = [#"^(?:Beispiel)?Rechnung\s+(?:für\s+)?"#, #"^(?:Vertrag|Mitteilung|Elterninformation)\s+(?:über\s+|zum\s+)?"#]
            for pattern in patterns {
                let candidate = heading.0.text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                if candidate != heading.0.text && candidate.split(whereSeparator: \.isWhitespace).count >= 1,
                   candidate.range(of: #"^(?:Nr\.?|Nummer|\d)"#, options: [.regularExpression, .caseInsensitive]) == nil {
                    subject = .init(role: .subject, value: candidate, page: heading.0.page, quote: heading.0.text, origin: .documentHeading)
                    break
                }
            }
        }
        let referenceYear = unique(.titleYear) { line in
            guard let value = Self.labelValue(in: line, labels: Self.yearLabels), value.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil else { return nil }
            return value
        }
        let usesIssueYear: Bool = ![BaseDocumentKind.bankStatement, .utilityStatement, .taxCertificate, .employmentDocument].contains(kind)
        let year = referenceYear ?? (usesIssueYear ? date.map {
            BaseEvidenceField(role: .titleYear, value: String($0.value.prefix(4)), page: $0.page, quote: $0.quote)
        } : nil)
        // Whole literal source passages keep negation, amounts, periods and conditions.
        // Metadata, salutations, tables and instruction-shaped text are not overviews.
        let summary = overviewPassage(pages)
        if lines.contains(where: { Self.isInstruction($0.text) }) { issues.append("UNTRUSTED_INSTRUCTION_TEXT") }
        let kindEvidence = headings.first.map { BaseEvidenceField(role: .documentType, value: $0.1.rawValue,
            page: $0.0.page, quote: $0.0.text, origin: .documentHeading) }
        return .init(pages: pages.map(\.number), kind: kind, kindEvidence: kindEvidence, issuer: issuer, recipient: recipient, issueDate: date,
                     subject: subject, titleYear: year, overview: summary, issues: issues)
    }

    static func labelValue(in line: String, labels: [String]) -> String? {
        for label in labels {
            let pattern = #"^\s*(?:[-•*]\s*)?"# + NSRegularExpression.escapedPattern(for: label) + #"\s*(?::\s*|\s+)(\S.*)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            let value = String(line[range]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty && value.count <= 240 { return value }
        }
        return nil
    }

    static func issueDate(in line: String) -> String? {
        guard let value = labelValue(in: line, labels: dateLabels),
              let regex = try? NSRegularExpression(pattern: #"^(?:(\d{4})-(\d{2})-(\d{2})|(\d{1,2})\.(\d{1,2})\.(\d{4}))\.?$"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func number(_ index: Int) -> Int? { Range(match.range(at: index), in: value).flatMap { Int(value[$0]) } }
        guard let year = number(1) ?? number(6), let month = number(2) ?? number(5), let day = number(3) ?? number(4),
              (1900...2099).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == year && checked.month == month && checked.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func headingKind(_ line: String) -> BaseDocumentKind? {
        guard DocumentTitlePolicy.isTitlePhrase(line.trimmingCharacters(in: .whitespaces)), labelValue(in: line, labels: issuerLabels + recipientLabels + dateLabels + ["Betreff", "Gegenstand"]) == nil else { return nil }
        let value = fold(line.trimmingCharacters(in: .whitespaces))
        let rules: [(BaseDocumentKind, [String])] = [
            (.utilityStatement, ["nebenkostenabrechnung", "betriebskostenabrechnung"]),
            (.taxCertificate, ["steuerbescheinigung", "lohnsteuerbescheinigung"]),
            (.bankStatement, ["kontoauszug", "depotauszug", "jahreskontoauszug"]),
            (.laboratoryReport, ["laborbefund", "laborbericht"]),
            (.prescription, ["verordnung", "rezept"]),
            (.medicalReport, ["befundbericht", "arztbrief", "entlassungsbericht"]),
            (.authorityDecision, ["steuerbescheid", "bewilligungsbescheid", "bescheid"]),
            (.vehicleReport, ["hu-bericht", "hauptuntersuchungsbericht", "fahrzeugbericht"]),
            (.employmentDocument, ["gehaltsabrechnung", "lohnabrechnung", "arbeitszeugnis"]),
            (.schoolNotice, ["elterninformation", "schulmitteilung", "schulbescheinigung"]),
            (.insuranceNotice, ["versicherungsschein", "versicherungsnachtrag", "beitragsrechnung", "versicherungsmitteilung"]),
            (.receipt, ["kassenbeleg", "kassenbon"]),
            (.invoice, ["rechnung", "beispielrechnung"]),
            (.contract, ["vertrag", "vertragsanderung", "mietvertrag", "arbeitsvertrag", "kaufvertrag"]),
            (.correspondence, ["mitteilung", "anschreiben"])
        ]
        for (kind, words) in rules where words.contains(where: { word in
            value == word || value.hasPrefix(word + " ") || value.hasPrefix(word + ":")
        }) { return kind }
        return nil
    }

    static func isInstruction(_ text: String) -> Bool {
        let value = fold(text)
        return ["ignore previous instructions", "ignore all instructions", "ignoriere alle anweisungen", "system prompt", "system:", "assistant:", "developer:"].contains(where: value.contains)
    }
    private func overviewPassage(_ pages: [BaseAnalysisPage]) -> BaseEvidenceField? {
        let labels = Self.issuerLabels + Self.recipientLabels + Self.dateLabels + Self.yearLabels
            + ["Betreff", "Gegenstand", "Leistung", "Geburtsdatum", "Geboren am", "Rechnungsnummer", "Vertragsnummer", "Aktenzeichen", "Abrechnungszeitraum", "Name", "E-Mail", "Email", "IBAN", "Telefon", "Adresse"]
        for page in pages {
            var buffer: [String] = []
            func passage() -> BaseEvidenceField? {
                let quote = buffer.joined(separator: "\n")
                let value = quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard quote.count <= 900, Self.isOverview(value) else { return nil }
                return .init(role: .overview, value: value, page: page.number, quote: quote, origin: .extractive)
            }
            for raw in page.text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || Self.labelValue(in: raw, labels: labels) != nil || Self.headingKind(raw) != nil
                    || ["sehr geehrt", "mit freundlichen", "vielen dank"].contains(where: Self.fold(line).hasPrefix)
                    || line.contains("|") || line.contains("\t") || Self.isInstruction(line) {
                    if let result = passage() { return result }
                    buffer.removeAll(); continue
                }
                buffer.append(raw)
            }
            if let result = passage() { return result }
        }
        return nil
    }
    static func isOverview(_ text: String) -> Bool {
        let value = fold(text)
        guard (35...650).contains(text.count), text.split(whereSeparator: \.isWhitespace).count >= 6,
              text.hasSuffix(".") || text.hasSuffix("!"), !isInstruction(text),
              labelValue(in: text, labels: issuerLabels + recipientLabels + dateLabels + yearLabels + ["Betreff", "Gegenstand", "Leistung"]) == nil else { return false }
        return !["sehr geehrte", "mit freundlichen", "vielen dank", "fur ruckfragen", "dieses dokument", "das dokument behandelt", "datenschutz", "rechtsbehelfsbelehrung"].contains(where: value.hasPrefix)
    }
    private static func fold(_ text: String) -> String { BaseAnalysisPipeline.folded(text) }
}
