import Foundation

/// Eligibility only: these rules never manufacture a reading. A replacement
/// must first be read twice from source pixels and retain the previous text.
enum OCRFieldRefinement {
    private static let vehicle = try! NSRegularExpression(
        pattern: #"^(?:Fahrgestellnummer|Fahrzeugidentifizierungsnummer|Fahrzeug-Identifizierungsnummer|FIN|VIN)\s*:\s*([A-Z0-9]+)$"#)

    static func vehicleValue(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = vehicle.firstMatch(in: text, range: range),
              let value = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[value])
    }

    static func needsVehicleRetry(_ text: String) -> Bool {
        // Labels also occur on historic and synthetic identifiers of other
        // lengths. Length is a work bound, never a guessed VIN correction.
        vehicleValue(text).map { (10...32).contains($0.count) } ?? false
    }

    static func permitsVehicleRepair(_ original: String, _ candidate: String) -> Bool {
        guard let old = vehicleValue(original), let new = vehicleValue(candidate),
              (10...32).contains(old.count), new.count == old.count + 1,
              original.dropLast(old.count) == candidate.dropLast(new.count),
              old.filter(\.isNumber) == new.filter(\.isNumber),
              !new.contains(where: { "IOQ".contains($0) }) else { return false }
        // Only a missed letter may be restored. No substitution, digit edit,
        // checksum guess, manufacturer lookup or expected identifier is used.
        return new.indices.contains { index in
            guard new[index].isLetter else { return false }
            var shortened = new; shortened.remove(at: index)
            return shortened == old
        }
    }

    static func isUnit(_ text: String) -> Bool {
        text.range(of: #"^(?:(?:[kcmµμnpu]?g|[kcmµμnpu]?mol|[kcmµμnpu]?U)/(?:[dmµμn]?l|[dmµμn]?L)|10[⁰¹²³⁴⁵⁶⁷⁸⁹]+/[µμ]l)$"#,
                   options: .regularExpression) != nil
    }

    static func needsUnitRetry(_ text: String) -> Bool {
        !isUnit(text) && text.count <= 14 && text.contains("/")
            && text.range(of: #"^(?:[kcmµμnpu]?g|[kcmµμnpu]?mol|[kcmµμnpu]?U|10[⁰¹²³⁴⁵⁶⁷⁸⁹]*)/[dmuµμn]?[lLI1]$"#,
                          options: .regularExpression) != nil
    }

    static func permitsUnitRepair(_ original: String, _ candidate: String) -> Bool {
        guard needsUnitRetry(original), isUnit(candidate) else { return false }
        let exponent = original.filter { "⁰¹²³⁴⁵⁶⁷⁸⁹".contains($0) }
        guard exponent.isEmpty || exponent == candidate.filter({ "⁰¹²³⁴⁵⁶⁷⁸⁹".contains($0) }) else { return false }
        func glyphs(_ text: String) -> String {
            String(text.filter { !"⁰¹²³⁴⁵⁶⁷⁸⁹".contains($0) })
                .replacingOccurrences(of: "µ", with: "u").replacingOccurrences(of: "μ", with: "u")
                .replacingOccurrences(of: "I", with: "l")
                .replacingOccurrences(of: "/1", with: "/l").replacingOccurrences(of: "u1", with: "ul")
        }
        return glyphs(original) == glyphs(candidate)
    }

    static func permits(_ original: String, _ candidate: String) -> Bool {
        permitsVehicleRepair(original, candidate) || permitsUnitRepair(original, candidate) || OCRNumericRefinement.permits(original, candidate)
    }
}
