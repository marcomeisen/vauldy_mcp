import Foundation
import CoreGraphics

/// Geometry is provided only after the store checks the source, page and exact text.
package struct TitleLayoutPage: Sendable {
    package struct Line: Sendable {
        package let text: String
        package let bounds: CGRect
        package let confidence: Double?

        package init(text: String, bounds: CGRect, confidence: Double?) {
            self.text = text
            self.bounds = bounds
            self.confidence = confidence
        }
    }

    package let number: Int
    package let lines: [Line]

    package init(number: Int, lines: [Line]) {
        self.number = number
        self.lines = lines
    }
}

package struct LayoutDocumentTitle: Sendable {
    package let value: String
    package let page: Int?

    private struct Candidate {
        let index: Int
        let text: String
        let kind: BaseDocumentKind?
        let score: Int
    }

    /// Only use the opening page. Later pages may contain terms, annexes or other documents.
    package static func resolve(first page: TitleLayoutPage, later: [TitleLayoutPage],
                                analysis: BaseDocumentOverview?) -> Self {
        let lines = page.lines.sorted {
            if $0.bounds.maxY == $1.bounds.maxY { return $0.bounds.minX < $1.bounds.minX }
            return $0.bounds.maxY > $1.bounds.maxY
        }
        let heights = lines.filter { $0.text.count >= 24 && $0.bounds.midY < 0.78 && $0.bounds.midY > 0.10 }
            .map(\.bounds.height).sorted()
        let typicalHeight = heights.count >= 3 ? heights[heights.count / 2] : nil
        let laterMargins = Set(later.flatMap(\.lines).filter { $0.bounds.midY > 0.87 || $0.bounds.midY < 0.12 }
            .map { key($0.text) })
        let candidates = lines.indices.compactMap { index -> Candidate? in
            let line = lines[index]
            let text = headingText(line.text)
            guard line.bounds.midY >= 0.48, (line.confidence ?? 1) >= 0.72,
                  isHeadingText(text), !isTableCell(at: index, in: lines) else { return nil }
            let kind = titleKind(text)
            if line.bounds.midY > 0.87 && laterMargins.contains(key(line.text)) { return nil }
            let prominent = typicalHeight.map { line.bounds.height >= 1.20 * $0 } ?? false
            let isolated = hasSpace(around: index, in: lines)
            let centered = abs(line.bounds.midX - 0.5) <= 0.12
            let early = line.bounds.midY >= 0.73
            if kind == nil {
                guard prominent, isolated, early, centered, text.split(separator: " ").count >= 2,
                      (line.confidence ?? 1) >= 0.85 else { return nil }
            } else {
                let shortLabel = !text.contains(" ") || key(text).range(of: #"^\S+ (?:19|20)\d{2}$"#, options: .regularExpression) != nil
                guard prominent || isolated || (line.bounds.midY >= 0.60 && shortLabel) else { return nil }
            }
            let score = (kind == nil ? 0 : 4) + (prominent ? 3 : 0) + (isolated ? 2 : 0)
                + (early ? 1 : 0) + (centered ? 1 : 0)
            return Candidate(index: index, text: text, kind: kind, score: score)
        }.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }

        guard let winner = candidates.first else {
            return fallback(first: page, later: later, repeatedMargins: laterMargins, analysis: analysis)
        }
        let conflicts = candidates.dropFirst().contains {
            $0.score >= winner.score - 2 && $0.kind != nil && winner.kind != nil && $0.kind != winner.kind
        }
        let issuer = confirmedIssuer(analysis) ?? letterhead(above: winner.index, in: lines, recipient: analysis?.recipient?.value)
        if conflicts {
            return .init(value: compose("Dokument", issuer: confirmedIssuer(analysis)), page: nil)
        }
        var heading = winner.text
        if let continuation = continuation(after: winner.index, in: lines), titleKind(continuation) == nil,
           heading.count + continuation.count < 100 {
            heading += " " + continuation
        }
        return .init(value: compose(heading, issuer: issuer, year: winner.kind == nil ? nil : analysis?.titleYear?.value),
                     page: page.number)
    }

    private static func key(_ text: String) -> String {
        BaseAnalysisPipeline.folded(DocumentTitlePolicy.normalized(text))
    }

    static func titleKind(_ text: String) -> BaseDocumentKind? {
        if let kind = LocalRuleBasedDocumentAnalyzer.headingKind(text) { return kind }
        if key(text) == "rechnung/lieferschein" { return .invoice }
        let value = key(text)
        let extra: [(String, BaseDocumentKind)] = [
            ("beitragsmitteilung", .insuranceNotice), ("beitragsanpassung", .insuranceNotice),
            ("versicherungspolice", .insuranceNotice), ("nachtrag zum versicherungsschein", .insuranceNotice),
            ("jahresabrechnung", .correspondence), ("jahresbescheinigung", .correspondence),
            ("auftragsblatt", .correspondence),
            ("jahresdepotauszug", .bankStatement), ("abrechnungsmitteilung", .correspondence),
            ("zahlungsbestatigung", .receipt), ("bestellbestatigung", .correspondence),
            ("mahnung", .correspondence), ("kundigung", .correspondence), ("zahlungsaufforderung", .correspondence),
        ]
        return extra.first { value == $0.0 || value.hasPrefix($0.0 + " ") }?.1
    }

    static func headingText(_ source: String) -> String {
        let text = DocumentTitlePolicy.normalized(source)
        guard !LocalRuleBasedDocumentAnalyzer.isInstruction(text) else { return text }
        // Drop identifiable reference suffixes and accept the literal type at the start.
        if let separator = text.firstIndex(of: ":") {
            let label = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
            let suffix = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if titleKind(label) != nil, suffix.isEmpty || DocumentTitlePolicy.isTitlePhrase(suffix) { return label }
            if let range = label.range(of: #"\s+(?:Nr\.?|Nummer)$"#, options: [.regularExpression, .caseInsensitive]) {
                let prefix = String(label[..<range.lowerBound])
                if titleKind(prefix) != nil { return prefix }
            }
        }
        if let suffix = text.range(of: #"\s+(?:Nr\.?|Nummer)\s+\d|\s+\d{7,}\b"#, options: [.regularExpression, .caseInsensitive]) {
            let prefix = String(text[..<suffix.lowerBound])
            if titleKind(prefix) != nil { return prefix }
        }
        return text
    }

    static func isHeadingText(_ text: String) -> Bool {
        guard DocumentTitlePolicy.isTitlePhrase(text), !isOrganization(text),
              !text.contains(":"), isCleanTitleText(text) else { return false }
        let value = key(text)
        return value.range(of: #"^(?:an|auf|aus|bei|bis|fur|in|mit|nach|ohne|seit|uber|unter|von|vor|zu|zum|zur|der|die|das|den|dem|des|ein|eine)\s|^(?:anlage|anhang|abschnitt|artikel|seite|stand|inhalt|inhaltsverzeichnis|bedingungen|datenschutz|impressum|sehr geehrt|mit freundlichen|summe|betrag|position|bezeichnung|menge|einzelpreis|gesamtpreis|leistungsbeschreibung)\b"#,
                           options: .regularExpression) == nil
    }

    static func isCleanTitleText(_ text: String) -> Bool {
        let folded = key(text)
        return !text.contains(where: { "*@_<>[]{}\t".contains($0) })
            && folded.range(of: #"^(?:fwd|fw|re|aw|wg)\s*:|https?\b|www\.|\b(?:iban|bic)\b|\b\d{7,}\b|\b(?:kundigen|kündigen|gelten|entspricht|betragt|lautet|erhalten|ergibt|ergeben|teilen|treten|beachten|beigefugt)\b"#,
                            options: .regularExpression) == nil
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midY - b.midY) < 0.5 * min(a.height, b.height)
    }

    private static func isTableCell(at index: Int, in lines: [TitleLayoutPage.Line]) -> Bool {
        let box = lines[index].bounds
        let nearby = lines[max(0, index - 8)..<min(lines.count, index + 9)]
        let neighbors = nearby.filter { sameRow(box, $0.bounds) && box != $0.bounds
            && (box.maxX + 0.01 < $0.bounds.minX || $0.bounds.maxX + 0.01 < box.minX) }
        // One unrelated item (e.g. a date in a letter's right column) is common.
        if neighbors.count >= 2 { return true }
        guard let peer = neighbors.first else { return false }
        return nearby.contains { row in
            let verticalDistance = abs(box.midY - row.bounds.midY)
            guard verticalDistance > box.height, verticalDistance < 0.06,
                  abs(box.minX - row.bounds.minX) < 0.035 else { return false }
            return nearby.contains { cell in
                sameRow(cell.bounds, row.bounds) && abs(peer.bounds.minX - cell.bounds.minX) < 0.035
            }
        }
    }

    private static func hasSpace(around index: Int, in lines: [TitleLayoutPage.Line]) -> Bool {
        let box = lines[index].bounds
        let others = [index - 1, index + 1].filter { lines.indices.contains($0) }
        guard !others.isEmpty else { return true }
        return others.allSatisfy { neighbor in
            let adjacent = lines[neighbor].bounds
            let gap = max(box.minY - adjacent.maxY, adjacent.minY - box.maxY)
            return gap >= 0.60 * min(box.height, adjacent.height)
        }
    }

    private static func continuation(after index: Int, in lines: [TitleLayoutPage.Line]) -> String? {
        guard lines.indices.contains(index + 1), hasSpace(after: index + 1, in: lines) else { return nil }
        let a = lines[index], b = lines[index + 1]
        let gap = a.bounds.minY - b.bounds.maxY
        let text = DocumentTitlePolicy.normalized(b.text)
        guard gap >= 0, gap <= 0.60 * a.bounds.height, b.bounds.height >= 0.85 * a.bounds.height,
              b.bounds.height <= 1.2 * a.bounds.height, (b.confidence ?? 1) >= 0.85,
              abs(a.bounds.minX - b.bounds.minX) <= 0.025 || abs(a.bounds.midX - b.bounds.midX) <= 0.04,
              text.split(separator: " ").count >= 2, isHeadingText(text),
              !isTableCell(at: index + 1, in: lines) else { return nil }
        return text
    }

    private static func hasSpace(after index: Int, in lines: [TitleLayoutPage.Line]) -> Bool {
        let next = index + 1
        guard lines.indices.contains(next) else { return true }
        let a = lines[index].bounds, b = lines[next].bounds
        return a.minY - b.maxY >= 0.8 * min(a.height, b.height)
    }

    private static func isOrganization(_ text: String) -> Bool {
        key(text).range(of: #"(?:\b(?:gmbh|ag|kg|ug|gbr|se|kgaa|eg|mbh|aor)\b|\be\.?\s*v\.?$)"#,
                        options: .regularExpression) != nil
    }

    private static func letterhead(above heading: Int, in lines: [TitleLayoutPage.Line], recipient: String?) -> String? {
        let header = lines[..<heading].prefix(12)
        let organizations = header.indices.filter { index in
            let line = header[index]
            return line.bounds.midY >= 0.86 && (line.confidence ?? 1) >= 0.90
                && isOrganization(line.text) && !line.text.contains(":") && isCleanTitleText(line.text)
        }
        guard organizations.count == 1, let index = organizations.first else { return nil }
        let line = lines[index]
        guard hasSpace(around: index, in: lines),
              header.prefix(index).allSatisfy({ row in
                  LocalRuleBasedDocumentAnalyzer.labelValue(in: row.text, labels: LocalRuleBasedDocumentAnalyzer.recipientLabels) == nil
                    && key(row.text).range(of: #"^(?:herr|frau|an|firma|z\.?\s*hd\.?|\d{5})\b"#, options: .regularExpression) == nil
              }),
              key(line.text) != recipient.map(key),
              !isTableCell(at: index, in: lines),
              DocumentTitlePolicy.isTitlePhrase(line.text) else { return nil }
        return DocumentTitlePolicy.normalized(line.text)
    }

    private static func confirmedIssuer(_ analysis: BaseDocumentOverview?) -> String? {
        guard let issuer = analysis?.issuer?.value, DocumentTitlePolicy.isTitlePhrase(issuer),
              isCleanTitleText(issuer) else { return nil }
        return issuer
    }

    private static func fallback(first page: TitleLayoutPage, later: [TitleLayoutPage],
                                 repeatedMargins: Set<String>, analysis: BaseDocumentOverview?) -> Self {
        // If the primary heading is unclear, prefer a verified type label over guessing a subject.
        // On a later page the label must be on the upper half and isolated from other columns.
        if let field = analysis?.kindEvidence, let kind = analysis?.kind, kind != .unknown,
           analysis?.issues.contains("DOCUMENT_STRUCTURE_AMBIGUOUS") != true,
           let owner = ([page] + later).first(where: { $0.number == field.page }) {
            let lines = owner.lines.sorted { $0.bounds.maxY > $1.bounds.maxY }
            let minimumY = owner.number == page.number ? 0.45 : 0.48
            if lines.indices.contains(where: { index in
                let line = lines[index]
                return key(line.text) == key(field.quote) && line.bounds.midY >= minimumY
                    && (line.confidence ?? 1) >= 0.72 && isHeadingText(headingText(line.text))
                    && !isTableCell(at: index, in: lines)
                     && (owner.number != page.number || line.bounds.midY <= 0.87 || !repeatedMargins.contains(key(line.text)))
            }) {
                let label = headingText(field.quote)
                let shortType = label.split(separator: " ", maxSplits: 1).first.map(String.init)
                let primary = shortType.flatMap { titleKind($0) == kind ? $0 : nil } ?? kind.title
                return .init(value: compose(primary, issuer: confirmedIssuer(analysis),
                                            year: analysis?.titleYear?.value), page: owner.number)
            }
        }
        return .init(value: compose("Dokument", issuer: confirmedIssuer(analysis)), page: nil)
    }

    private static func compose(_ heading: String, issuer: String?, year: String? = nil) -> String {
        var parts = [heading]
        if let issuer, !key(heading).contains(key(issuer)) { parts.append(issuer) }
        else if issuer == nil { parts.append("Aussteller unbekannt") }
        if let year, !parts.contains(where: { $0.contains(year) }) { parts.append(year) }
        return parts.joined(separator: " – ")
    }
}
