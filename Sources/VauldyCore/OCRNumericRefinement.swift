import Foundation

/// Eligibility and lossless presentation. Separator changes are accepted only
/// from two native source readings, never from a guessed locale or value.
enum OCRNumericRefinement {
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    static func number(_ text: String) -> String? {
        guard matches(text, #"^(?:[+-]?\s*[0-9][0-9.,]*\s*€?|€\s*[+-]?\s*[0-9][0-9.,]*)$"#) else { return nil }
        let compact = text.filter { !$0.isWhitespace && $0 != "€" }
        return matches(compact, #"^[+-]?[0-9][0-9.,]*$"#) ? compact : nil
    }
    static func validNumber(_ text: String) -> Bool {
        matches(text, #"^[+-]?(?:[0-9]+(?:[.,][0-9]+)?|[0-9]{1,3}(?:\.[0-9]{3})+(?:,[0-9]+)?|[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?)$"#)
    }
    static func money(_ text: String) -> String? {
        guard matches(text, #"^(?:[+-]?\s*[0-9][0-9.,]*\s*€|€\s*[+-]?\s*[0-9][0-9.,]*)$"#),
              let value = number(text), validNumber(value) else { return nil }
        return text.first == "€" ? "€ " + value : value + " €"
    }
    static func needsMetreRetry(_ text: String) -> Bool {
        matches(text, #"^[+-]?[0-9][0-9.,]*\s+m[0-9]?$"#)
    }
    static func isPresentationChange(_ old: String, _ new: String) -> Bool {
        old != new && money(old) == new
            && old.filter({ !$0.isWhitespace }) == new.filter({ !$0.isWhitespace })
    }
    static func needsRetry(_ text: String) -> Bool {
        if needsMetreRetry(text) { return true }
        guard let value = number(text) else { return false }
        return !validNumber(value) || (money(text).map { $0 != text || text.hasPrefix("€") } ?? false)
    }
    static func permits(_ old: String, _ new: String) -> Bool {
        guard old != new else { return false }
        if needsMetreRetry(old), matches(new, #"^[+-]?[0-9][0-9.,]*\s+m[⁰¹²³⁴⁵⁶⁷⁸⁹]$"#),
           let m = old.lastIndex(of: "m"), let n = new.lastIndex(of: "m"), old[..<m] == new[..<n] {
            let oldPower = old[old.index(after: m)...]
            let power = new.last!.wholeNumberValue
            return oldPower.isEmpty || Int(oldPower) == power
        }
        guard let a = number(old), let b = number(new),
              old.filter({ $0 == "€" }) == new.filter({ $0 == "€" }),
              a.filter(\.isNumber) == b.filter(\.isNumber),
              a.filter({ "+-".contains($0) }) == b.filter({ "+-".contains($0) }), validNumber(b) else { return false }
        if a == b { return money(new) == new && old.contains("€") }
        // A valid decimal/grouping spelling is not a repair target. In an
        // invalid spelling only dot/comma substitutions at fixed positions pass.
        return !validNumber(a) && a.count == b.count && zip(a, b).allSatisfy {
            $0 == $1 || (".,".contains($0) && ".,".contains($1))
        }
    }
}
