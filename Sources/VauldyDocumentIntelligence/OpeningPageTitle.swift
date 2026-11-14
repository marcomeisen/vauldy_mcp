import Foundation
import CoreGraphics

/// Title-only evidence. Input lines belong to one hash-checked physical page.
enum OpeningPageTitle {
    typealias Line = TitleLayoutPage.Line

    private struct Subject {
        let value: String
        let lines: [Line]
        let issuer: String?
        let period: String?

        init(_ value: String, _ lines: [Line], issuer: String? = nil, period: String? = nil) {
            self.value = value
            self.lines = lines
            self.issuer = issuer
            self.period = period
        }
    }

    static func resolve(_ lines: [Line], analysis: BaseDocumentOverview?) -> String? {
        let trusted = lines.filter { ($0.confidence ?? 1) >= 0.82 && !LocalRuleBasedDocumentAnalyzer.isInstruction($0.text) }
        let greetings = trusted.filter { key($0.text).hasPrefix("sehr geehrt") || key($0.text).hasPrefix("guten tag") }
        let opening = trusted.filter { $0.bounds.midY >= 0.48 && $0.bounds.height <= 0.085 }
        let candidates = opening.filter { line in
            let sameRow = opening.filter {
                abs($0.bounds.midY - line.bounds.midY) < 0.5 * min($0.bounds.height, line.bounds.height)
                    && ($0.bounds.minX > line.bounds.maxX + 0.01 || $0.bounds.maxX + 0.01 < line.bounds.minX)
            }
            // A line before an aligned greeting belongs to the opening letter, even at body size.
            let aboveGreeting = greetings.contains {
                let gap = line.bounds.midY - $0.bounds.midY
                return (0.015...0.16).contains(gap) && abs(line.bounds.minX - $0.bounds.minX) <= 0.08
            }
            return aboveGreeting || (sameRow.count < 2 && line.bounds.midY >= 0.60 && !greetings.contains {
                abs(line.bounds.minX - $0.bounds.minX) < 0.08 && $0.bounds.midY > line.bounds.midY
            })
        }
        let explicit = candidates.compactMap(explicitSubject)
        let typed = candidates.compactMap { typedSubject($0, in: opening) }
        let subjects = !explicit.isEmpty ? explicit : typed
        let subject: Subject
        if let first = subjects.first {
            guard Set(subjects.map { key($0.value) }).count == 1 else { return nil }
            subject = first
        } else if let contextual = contextualSubject(in: trusted, opening: opening, greetings: greetings) {
            subject = contextual
        } else { return nil }

        let confirmed = analysis?.issuer.flatMap { field in
            field.page == 1 && DocumentTitlePolicy.isTitlePhrase(field.value)
                && LayoutDocumentTitle.isCleanTitleText(field.value) ? field.value : nil
        }
        let issuer = confirmed ?? subject.issuer ?? sender(in: opening, above: subject.lines[0], recipient: analysis?.recipient?.value)
        return [subject.value, issuer, subject.period].compactMap { $0 }.joined(separator: " – ")
    }

    private static func explicitSubject(_ line: Line) -> Subject? {
        let text = normalized(line.text)
        guard let prefix = text.range(of: #"^(?:Betreff|Thema)\s*(?::\s*|\s+)"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let value = String(text[prefix.upperBound...])
        if key(value).range(of: #"^so starten sie mit ihrem neuen gerat\b"#, options: .regularExpression) != nil {
            return Subject("Einrichtung eines neuen Geräts", [line])
        }
        guard LayoutDocumentTitle.isHeadingText(value) else { return nil }
        return Subject(value, [line])
    }

    private static func typedSubject(_ line: Line, in opening: [Line]) -> Subject? {
        let text = normalized(line.text)
        let folded = key(text)
        if folded.range(of: #"^(?:[1-9]\.\s*)?(?:mahnung|zahlungserinnerung)$"#, options: .regularExpression) != nil {
            return Subject(text, [line])
        }
        if folded == "bescheid" {
            return taxSubject(line, in: opening)
        }
        let exact: [String: String] = [
            "dynamische anpassung ihres versicherungsschutzes": "Dynamische Anpassung des Versicherungsschutzes",
            "ihre renteninformation": "Renteninformation",
            "renteninformation": "Renteninformation",
            "quittung": "Quittung",
            "willkommen in unserem netz": "Willkommensschreiben",
            "kraftfahrzeugsteuerbescheid": "Kraftfahrzeugsteuerbescheid",
            "kostenzusage": "Kostenzusage",
            "vorsorgevollmacht": "Vorsorgevollmacht",
            "patientenverfugung": "Patientenverfügung",
        ]
        if let value = exact[folded] {
            if folded == "quittung" {
                let merchant = opening.compactMap { row -> String? in
                    let raw = normalized(row.text)
                    guard key(raw).hasPrefix("kasse: ") else { return nil }
                    let name = String(raw.dropFirst(7))
                    return DocumentTitlePolicy.isTitlePhrase(name) && LayoutDocumentTitle.isCleanTitleText(name)
                        && opening.contains { $0.bounds.midY > line.bounds.midY && key($0.text) == key(name) } ? name : nil
                }
                return Subject(value, [line], issuer: unique(merchant))
            }
            if folded == "willkommen in unserem netz",
               opening.contains(where: { key($0.text) == "einspeiserabwicklung" || key($0.text).contains("ihrer einspeiseanlage") }) {
                return Subject("Willkommensschreiben zur Einspeiseanlage", [line])
            }
            return Subject(value, [line])
        }
        if line.bounds.midY >= 0.59,
           folded.range(of: #"^antrag fur ihre (?:dynamische )?private unfallversicherung$"#, options: .regularExpression) != nil {
            return Subject("Antrag auf private Unfallversicherung", [line])
        }
        if folded.range(of: #"^verbindliche (?:[\p{L}]+-)?(?:fahrzeug)?bestellung$"#, options: .regularExpression) != nil,
           DocumentTitlePolicy.isTitlePhrase(text) {
            return Subject(text, [line])
        }
        return nil
    }

    private static func taxSubject(_ heading: Line, in opening: [Line]) -> Subject? {
        let following = opening.filter {
            let gap = heading.bounds.midY - $0.bounds.midY
            return gap > 0 && gap <= 0.08 && abs(heading.bounds.midX - $0.bounds.midX) <= 0.13
        }
        let years = following.compactMap { row in
            captures(#"^fur ((?:19|20)\d{2}) uber$"#, in: key(row.text)).first
        }
        guard let year = unique(years), let tax = following.first(where: {
            key($0.text).range(of: #"^einkommensteuer(?:, solidaritatszuschlag)?$"#, options: .regularExpression) != nil
        }) else { return nil }
        return Subject("Einkommensteuerbescheid \(year)", [heading, tax])
    }

    private static func contextualSubject(in lines: [Line], opening: [Line], greetings: [Line]) -> Subject? {
        // These independent cues distinguish a statement from a brochure or a table heading.
        let summary = lines.first { key($0.text) == "portfolio summary" }
        let value = lines.contains { key($0.text) == "net portfolio value" }
        let statement = lines.contains { key($0.text).contains("questions on your statement") }
        if let summary, value, statement {
            let periods = lines.prefix(120).compactMap { quarter(key($0.text)) }
            if periods.isEmpty || unique(periods) != nil {
                // A plan statement can corroborate a short brand with its printed legal name.
                let brands = lines.filter { $0.bounds.minX <= 0.30 }.compactMap { line -> String? in
                    let title = captures(#"^([A-Z]{3,24})(?:\s+[A-Z]|\s*\()?$"#, in: normalized(line.text)).first
                    guard let title, lines.contains(where: {
                        let detail = key($0.text)
                        return detail.hasPrefix(key(title) + " ") &&
                            detail.range(of: #"\b(?:incorporated|corporation|limited|llc)\b"#, options: .regularExpression) != nil
                    }) else { return nil }
                    return title.capitalized
                }
                return Subject("Depotauszug", [summary], issuer: unique(brands), period: unique(periods))
            }
        }
        // A confirmed change in the opening paragraph is stronger than the policy attached later.
        for greeting in greetings {
            let following = lines.filter {
                let gap = greeting.bounds.midY - $0.bounds.midY
                return (0.005...0.19).contains(gap) && abs(greeting.bounds.minX - $0.bounds.minX) < 0.08
            }
            if let topic = following.first(where: { key($0.text).contains("rentenversicherung mit dynamik") }),
               following.contains(where: { key($0.text).contains("bestatigen wir ihnen die neuen leistungen")
                   && key($0.text).contains("erhohungsbeitrag") }) {
                return Subject("Dynamikmitteilung zur Rentenversicherung", [topic])
            }
        }
        return nil
    }

    private static func quarter(_ text: String) -> String? {
        let fields = captures(#"^(january|april|july|october) 0?1, ((?:19|20)\d{2})\s*[-–]\s*(march 31|june 30|september 30|december 31), ((?:19|20)\d{2})$"#, in: text)
        guard fields.count == 4, fields[1] == fields[3] else { return nil }
        let ends = ["january": ("march 31", 1), "april": ("june 30", 2),
                    "july": ("september 30", 3), "october": ("december 31", 4)]
        guard let (end, number) = ends[fields[0]], fields[2] == end else { return nil }
        return "Q\(number) \(fields[1])"
    }

    private static func sender(in opening: [Line], above subject: Line, recipient: String?) -> String? {
        let before = opening.filter { $0.bounds.midY > subject.bounds.midY + 0.01 }
        let postal = before.compactMap { row -> String? in
            let text = normalized(row.text)
            guard let separator = text.range(of: #"\s*(?:,|•|·)\s*(?:Postfach\b|\d{5}\s+\p{L})"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let name = String(text[..<separator.lowerBound])
            guard organization(name), key(name) != recipient.map(key) else { return nil }
            // A sender strip is small and above the aligned recipient block.
            return row.bounds.height <= 0.016 ? name : nil
        }
        let headers = before.filter { $0.bounds.midY >= 0.86 }
        let names = headers.compactMap { row -> String? in
            let name = normalized(row.text)
            return organization(name) && key(name) != recipient.map(key) ? name : nil
        }
        var splitNames: [String] = []
        for a in headers {
            for b in headers where a.bounds.midY - b.bounds.midY > 0 && a.bounds.midY - b.bounds.midY <= 0.035
                && abs(a.bounds.minX - b.bounds.minX) <= 0.03 {
                let first = normalized(a.text), second = normalized(b.text)
                if first.range(of: #"^[A-ZÄÖÜ]{2,8}$"#, options: .regularExpression) != nil,
                   second.range(of: #"^\p{L}+(?:-|\s)(?:AG|GmbH)$"#, options: .regularExpression) != nil {
                    splitNames.append(first + " " + second.replacingOccurrences(of: "-", with: " "))
                } else if first.range(of: #"^[A-ZÄÖÜ]{2,8}\s+\p{L}+$"#, options: .regularExpression) != nil,
                          key(second).range(of: #"^versicherungsverein\b"#, options: .regularExpression) != nil {
                    splitNames.append(first + " " + second)
                }
            }
        }
        if !splitNames.isEmpty {
            let standalone = names.filter { name in
                !splitNames.contains { key($0).replacingOccurrences(of: "-", with: " ")
                    .contains(key(name).replacingOccurrences(of: "-", with: " ")) }
            }
            if let name = unique(splitNames + standalone),
               postal.isEmpty || postal.allSatisfy({ key(name).contains(key($0)) || (key(name).split(separator: " ").first == key($0).split(separator: " ").first
                   && key($0).hasSuffix(" versicherung")) }) {
                return name
            }
        }
        if !postal.isEmpty { return unique(postal) }
        if let name = unique(names) { return name }
        if !names.isEmpty { return nil }
        // A distinctive brand needs corroboration via a matching sender strip or its domain.
        let brands = headers.compactMap { line -> String? in
            let raw = normalized(line.text)
            let token = key(raw).filter(\.isLetter)
            guard (5...28).contains(token.count), raw.split(separator: " ").count <= 3,
                  before.contains(where: { key($0.text).contains("www." + token + ".") }),
                  DocumentTitlePolicy.isTitlePhrase(raw) else { return nil }
            return raw
        }
        return unique(brands)
    }

    private static func organization(_ text: String) -> Bool {
        let value = key(text)
        guard text.count <= 80, LayoutDocumentTitle.isCleanTitleText(text),
              !text.contains(where: { ",:;?@".contains($0) }),
              !value.contains("empfanger"), !value.contains("ansprechpartner"),
              !value.contains("betreut sie"),
              value.range(of: #"\b(?:ist|sind|wird|werden|durch|gemass|kundenservice|im auftrag)\b"#,
                          options: .regularExpression) == nil else { return false }
        return value.range(of: #"^(?:finanzamt|hauptzollamt|deutsche rentenversicherung)\s+\p{L}|(?:\b(?:ag|gmbh|kg|eg|ug|kgaa|se|aktiengesellschaft)|\ba\.\s*g\.)$"#, options: .regularExpression) != nil
            && text.first?.isUppercase == true
    }

    private static func unique(_ values: [String]) -> String? {
        guard Set(values.map(key)).count == 1 else { return nil }
        return values.first
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<result.numberOfRanges).compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
    }

    private static func normalized(_ text: String) -> String { DocumentTitlePolicy.normalized(text) }
    private static func key(_ text: String) -> String { BaseAnalysisPipeline.folded(normalized(text)) }
}
