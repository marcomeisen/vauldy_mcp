import Foundation

/// Eligibility only. A valid decimal spelling must never be changed by locale
/// normalization: the caller needs two agreeing reads of unrectified source pixels.
enum OCRDecimalSourceRepair {
    static func eligible(_ text: String) -> Bool {
        text.range(of: #"^[\p{L}][\p{L} ()/-]{1,60}:\s*[+-]?[0-9]{1,8}[.,][0-9]{2}\s*(?:EUR|€)$"#,
                   options: .regularExpression) != nil
    }

    static func permits(_ old: String, _ new: String) -> Bool {
        guard eligible(old), eligible(new), old.count == new.count else { return false }
        let differences = zip(old, new).filter { $0 != $1 }
        return differences.count == 1 && differences.allSatisfy {
            ($0 == "." && $1 == ",") || ($0 == "," && $1 == ".")
        }
    }
}
