import Foundation

/// A second OCR observation can support a line repair, but confidence alone
/// cannot settle a disagreement about a number or an identifier.
enum OCRLineRecovery {
    private static let identifier = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:Versicherungsschein|Versicherungs|Vertrags|Policen|Police|Rechnungs|Kunden)[ -]?n(?:ummer|r)|Aktenzeichen|IBAN)\b\s*[:.]?\s*"#,
        options: .caseInsensitive
    )

    static func isIdentifier(_ text: String) -> Bool {
        label(in: text) != nil
    }

    static func hasConfusableIdentifier(_ text: String) -> Bool {
        guard let label = label(in: text) else { return false }
        // Four confusable glyphs also catch an all-digit rendering of a
        // mixed O/0 or I/1 run inside a segmented code.
        let value = text[label.upperBound...]
        return value.contains("-") && value.contains(where: \.isNumber)
            && value.range(of: #"[O0Il1]{4,}"#, options: .regularExpression) != nil
    }

    private static func label(in text: String) -> Range<String.Index>? {
        let range = NSRange(text.startIndex..., in: text)
        return identifier.firstMatch(in: text, range: range).flatMap { Range($0.range, in: text) }
    }

    enum Decision: Equatable {
        case keep, review, replace
    }

    static func priority(identifier: Bool, ambiguous: Bool, confidence: Float, index: Int) -> (Int, Int, Float, Int) {
        let uncertain = confidence < (identifier ? 0.94 : 0.75)
        return (ambiguous ? 0 : (uncertain ? 1 : 2), identifier ? 0 : 1, confidence, index)
    }

    static func decide(original: String, confidence: Float, alternatives: [String],
                       retry: String, retryConfidence: Float, identifier: Bool, smallPrint: Bool = false,
                       allowSmallGlyphRepair: Bool = false) -> Decision {
        let first = tokens(original), second = tokens(retry)
        guard !second.isEmpty else { return .keep }
        if identifier {
            return original.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                == retry.split(whereSeparator: \.isWhitespace).joined(separator: " ") ? .keep : .review
        }
        let numbers = numericParts(original)
        guard numbers == numericParts(retry) else { return .review }
        let stronger = retryConfidence >= 0.85 && retryConfidence - confidence >= 0.10
        guard first != second, stronger || (smallPrint && retryConfidence >= 0.95) else { return .keep }
        var remaining = second[...]
        for token in first {
            guard let position = remaining.firstIndex(of: token) else {
                // Require support from the first pass for a conflicting word.
                let supportedAlternative = stronger && second.count >= first.count && alternatives.contains(retry)
                // A tiny glyph can be wrong even at native confidence 1. The
                // caller must confirm this candidate on a second context crop.
                let smallGlyphRepair = allowSmallGlyphRepair && smallPrint && retryConfidence >= 0.95 && singleLetterRepair(first, second)
                return supportedAlternative || smallGlyphRepair ? .replace : .review
            }
            remaining = remaining[remaining.index(after: position)...]
        }
        return .replace
    }

    private static func singleLetterRepair(_ first: [String], _ second: [String]) -> Bool {
        guard first.count == second.count else { return false }
        let changed = zip(first, second).filter { $0 != $1 }
        guard changed.count == 1, let pair = changed.first,
              pair.0.count >= 6, pair.0.allSatisfy(\.isLetter), pair.1.allSatisfy(\.isLetter) else { return false }
        let a = Array(pair.0), b = Array(pair.1)
        guard a.count == b.count else { return false }
        return zip(a, b).filter { $0 != $1 }.count == 1
    }

    /// A contextual crop may also contain neighbours. Select only a single
    /// geometrically matching line; a merged or ambiguous match remains review.
    static func select(_ candidates: [OCRRegionRecovery.Candidate], target: CGRect,
                       joinFragments: Bool = true) -> OCRRegionRecovery.Candidate? {
        let matches = candidates.filter { candidate in
            let box = candidate.bounds, overlap = box.intersection(target)
            let area = max(box.width * box.height, target.width * target.height)
            return area > 0 && !overlap.isNull && target.contains(CGPoint(x: box.midX, y: box.midY))
                && overlap.width * overlap.height >= area * 0.7
        }
        if !matches.isEmpty { return matches.count == 1 ? matches.first : nil }
        guard joinFragments else { return nil }
        let fragments = candidates.filter { candidate in
            let box = candidate.bounds
            let overlap = min(box.maxY, target.maxY) - max(box.minY, target.minY)
            return box.height > 0 && box.height <= target.height * 1.5
                && overlap >= min(box.height, target.height) * 0.7
                && box.maxX > target.minX && box.minX < target.maxX
        }.sorted { $0.bounds.minX < $1.bounds.minX }
        guard (2...4).contains(fragments.count), let first = fragments.first else { return nil }
        var union = first.bounds
        for (previous, next) in zip(fragments, fragments.dropFirst()) {
            let gap = next.bounds.minX - previous.bounds.maxX
            guard gap >= 0, gap <= max(previous.bounds.height, next.bounds.height) * 3,
                  min(previous.bounds.height, next.bounds.height) >= max(previous.bounds.height, next.bounds.height) * 0.5 else { return nil }
            union = union.union(next.bounds)
        }
        guard union.height <= target.height * 1.5 else { return nil }
        let combined = OCRRegionRecovery.Candidate(text: fragments.map(\.text).joined(separator: " "),
            bounds: union, confidence: fragments.map(\.confidence).min() ?? 0)
        // Reuse the full-line gate without recursively joining fragments.
        return select([combined], target: target, joinFragments: false)
    }

    private static func numericParts(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && !".,-/".contains($0) }
            .filter { $0.contains(where: \.isNumber) }.map(String.init)
    }

    static func hasConflictingLabel(_ text: String, existing: String) -> Bool {
        let candidate = text.split(separator: ":", maxSplits: 1)
        let previous = existing.split(separator: ":", maxSplits: 1)
        guard candidate.count == 2, previous.count == 2,
              !tokens(String(candidate[0])).isEmpty, tokens(String(candidate[0])) == tokens(String(previous[0])) else { return false }
        let first = numericParts(String(candidate[1])), second = numericParts(String(previous[1]))
        return !first.isEmpty && !second.isEmpty && first != second
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
