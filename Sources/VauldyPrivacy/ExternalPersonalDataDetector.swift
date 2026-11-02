import Foundation

nonisolated enum ExternalAIPrivacyError: LocalizedError, Equatable {
    case personalDataRemaining

    var errorDescription: String? {
        "Die Anfrage wurde nicht gesendet, weil persönliche Angaben nicht sicher entfernt werden konnten."
    }
}

/// Local identifier detection. This is pseudonymization, not a claim that arbitrary
/// prose (including health/financial facts) has become anonymous.
nonisolated enum ExternalPersonalDataDetector {
    private struct Rule {
        let kind: String
        let expression: NSRegularExpression
        let capture: Int
    }

    private static let placeholderPattern = #"\[V_[A-F0-9]{32}_[A-Z]+_\d+\]"#
    private static let rules: Result<[Rule], Error> = Result {
        let definitions: [(String, String, Int)] = [
            ("EMAIL", #"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}.\-]+\.[\p{L}]{2,}"#, 0),
            ("IBAN", #"\b[A-Z]{2}[ \t]?\d{2}(?:[ \t\r\n]?[A-Z0-9]){11,30}\b"#, 0),
            ("KONTAKT", #"(?:https?://|www\.)[^\s<>\[\]\"“”]+"#, 0),
            ("DATEIPFAD", #"(?:file://|/Users/|/home/|[A-Z]:\\)[^\r\n<>\"“”]+"#, 0),
            ("KENNUNG", #"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b"#, 0),
            ("KENNUNG", #"(?<![\p{L}\p{N}])(?:\d[ \t]?){10}\d(?![\p{L}\p{N}])"#, 0),
            ("KENNUNG", #"\b[A-Z]\d{9}\b|(?<![\p{L}\p{N}])\d{7,}(?![\p{L}\p{N}])"#, 0),
            ("TELEFON", #"(?<![\p{L}\p{N}])(?:\+|00|0(?=[1-9])|\(\d{2,5}\))[\d \t()/.-]{6,}\d(?![\p{L}\p{N}])"#, 0),
            ("TELEFON", #"\b(?:tel\.?|telefon|mobil|fax|phone|telephone)[ \t:]+(?:\n[ \t]*)?([+\d(][\d \t()/.-]{5,}\d)"#, 1),
            ("GEBURTSDATUM", #"\b(?:geburtsdatum|geboren[ \t]+am|geb\.?[ \t]*(?:am|-[ \t]*dat\.?)?|date[ \t]+of[ \t]+birth|dob)[ \t:\n]*((?:[0-3]?\d[.\-/][01]?\d[.\-/](?:19|20)\d{2})|(?:(?:19|20)\d{2}-[01]\d-[0-3]\d))"#, 1),
            ("GEBURTSDATUM", #"\*[ \t]*([0-3]?\d[.\-/][01]?\d[.\-/](?:19|20)\d{2})"#, 1),
            // Capture whole labelled values: OCR frequently inserts spaces/slashes in IDs.
            ("KENNUNG", #"\b(?:aktenzeichen|geschäftszeichen|kunden[ -]?(?:nummer|nr\.?)|vertrags[ -]?(?:nummer|nr\.?)|versicherungs[ -]?(?:nummer|nr\.?)|versichertennummer|rechnungs[ -]?(?:nummer|nr\.?)|steuer[ -]?(?:identifikationsnummer|nummer|nr\.?|id)|identifikationsnummer|id[ -]?nr\.?|personalnummer|mitgliedsnummer|patienten[ -]?(?:nummer|nr\.?)|ausweis[ -]?(?:nummer|nr\.?)|passnummer|reisepassnummer|sozialversicherungsnummer|rentenversicherungsnummer|kontonummer|konto[ -]?nr\.?|account[ \t]+number|customer[ \t]+(?:id|number)|passport[ \t]+number|social[ \t]+security[ \t]+number)[ \t:#-]*(?:\n[ \t]*)?([^\r\n;,\[\]]{3,100})"#, 1),
            ("ADRESSE", #"\b([\p{L}][\p{L}.'’\- ]{1,60}(?:straße|strasse|str\.|weg|allee|platz|gasse|ring|ufer|chaussee)[ \t]+\d+[ \t]?[a-z]?(?:[ \t]*[-/]\d+[a-z]?)?)\b"#, 1),
            ("ADRESSE", #"\b((?:D[ -]?)?\d{5}[ \t]+[\p{L}][\p{L}.'’\- ]{1,50})"#, 1),
            ("ADRESSE", #"\b\d{1,5}[ \t]+(?:[\p{L}.'’\-]+[ \t]+){1,5}(?:street|st\.?|road|rd\.?|avenue|ave\.?|lane|drive)\b"#, 0),
            ("ADRESSE", #"\b(?:adresse|anschrift|wohnort|address)[ \t:]+([^\r\n;,\[\]]{3,100})"#, 1),
            ("PERSON", #"\b(?>vorname|nachname|familienname|patient(?:in)?|versicherte(?:r|[ \t]+person)?|name|antragsteller(?:in)?|rechnungsempfänger(?:in)?|kontoinhaber(?:in)?|empfänger(?:in)?|kunde|kundin|first[ \t]+name|last[ \t]+name|recipient)[ \t:]+([^\r\n;,\[\]]{2,100})"#, 1),
            ("PERSON", #"\b(?:herrn?|frau|mr\.?|mrs\.?|ms\.?)[ \t]+([\p{L}][\p{L}.'’\-]+(?:[ \t]+[\p{L}][\p{L}.'’\-]+){0,4})"#, 1),
            // Explicit contexts work even without optional NaturalLanguage assets.
            ("PERSON", #"\b(?:über|für|von|befund(?:bericht)?|arztbrief)[ \t]+((?-i:[\p{Lu}][\p{Ll}'’\-]+(?:[ \t]+[\p{Lu}][\p{Ll}'’\-]+){1,3}))\b"#, 1)
        ]
        return try definitions.map {
            Rule(kind: $0.0, expression: try NSRegularExpression(pattern: $0.1, options: [.caseInsensitive]), capture: $0.2)
        }
    }

    static func removingPlaceholders(from text: String) -> String {
        text.replacingOccurrences(of: placeholderPattern, with: "", options: .regularExpression)
    }

    static func identifiers(in text: String) throws -> [(kind: String, value: String)] {
        // Keep token width: removing tokens would join previously separate words.
        let scanned = text.replacingOccurrences(of: placeholderPattern, with: "[]", options: .regularExpression)
        let range = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)
        var values: [(String, String)] = []
        for rule in try rules.get() {
            for match in rule.expression.matches(in: scanned, range: range) {
                guard let range = Range(match.range(at: rule.capture), in: scanned) else { continue }
                let value = String(scanned[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
                if rule.kind == "TELEFON" {
                    guard value.filter(\.isNumber).count >= 7,
                          !isDate(value) else { continue }
                }
                values.append((rule.kind, value))
            }
        }
        return values
    }

    private static func isDate(_ value: String) -> Bool {
        value.range(of: #"^(?:[0-3]?\d[.\-/][01]?\d[.\-/](?:19|20)\d{2}|(?:19|20)\d{2}-[01]\d-[0-3]\d)$"#, options: .regularExpression) != nil
    }
}
