import Foundation
import CoreGraphics

enum OCRRegionRecovery {
    /// Enlarge only marked small text crops. Normalized coordinates still refer
    /// to the original crop; actual resized work is charged to the page budget.
    static func retrySize(width: Int, height: Int, glyphHeight: CGFloat, enabled: Bool) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, width <= 1_000_000 / height,
              glyphHeight.isFinite, glyphHeight > 0 else { return nil }
        let pixels = width * height
        let desired = enabled && glyphHeight < 24 ? min(3, 32 / glyphHeight) : 1
        let scale = max(1, min(desired, sqrt(CGFloat(1_000_000) / CGFloat(pixels)),
                               max(1, 4096 / CGFloat(max(width, height)))))
        return (max(width, Int((CGFloat(width) * scale).rounded(.down))),
                max(height, Int((CGFloat(height) * scale).rounded(.down))))
    }

    /// One native crop can confirm up to four neighbouring missing lines.
    /// Four crop attempts and the existing pixel budget still bound each page.
    static func windows(_ regions: [LocalOCRVisualRegion], grouped: Bool) -> [(bounds: CGRect, glyphHeight: CGFloat)] {
        let sorted = regions.filter(\.needsReview).sorted {
            $0.bounds.maxY == $1.bounds.maxY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.maxY > $1.bounds.maxY
        }
        var groups: [[CGRect]] = []
        for region in sorted {
            let box = region.bounds
            if grouped, var last = groups.last, let previous = last.last, last.count < 4 {
                let union = last.reduce(box) { $0.union($1) }
                let overlap = min(previous.maxX, box.maxX) - max(previous.minX, box.minX)
                let gap = previous.minY - box.maxY
                if gap >= 0, gap <= max(previous.height, box.height) * 2,
                   overlap >= min(previous.width, box.width) * 0.5, union.height <= 0.2 {
                    last.append(box); groups[groups.count - 1] = last; continue
                }
            }
            groups.append([box])
        }
        return groups.map { boxes in
            let heights = boxes.map(\.height).sorted()
            return (boxes.reduce(CGRect.null) { $0.union($1) }, heights[heights.count / 2])
        }
    }

    struct Candidate {
        let text: String
        let bounds: CGRect
        let confidence: Float
    }
    enum Decision: Equatable { case append, unconfirmed, overlap, conflict }

    static func canonical(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func sameObservation(_ first: Candidate, _ second: Candidate) -> Bool {
        let intersection = first.bounds.intersection(second.bounds)
        let area = max(first.bounds.width * first.bounds.height, second.bounds.width * second.bounds.height)
        return canonical(first.text) == canonical(second.text) && !intersection.isNull && area > 0
            && intersection.width * intersection.height >= area * 0.7
    }

    static func decide(_ first: Candidate, confirmedBy second: Candidate, region: CGRect,
                       existingText: String, existingLines: [LocalOCRLine]) -> Decision {
        guard first.confidence >= 0.85, second.confidence >= 0.85, sameObservation(first, second),
              first.text.rangeOfCharacter(from: .alphanumerics) != nil,
              !OCRLineRecovery.hasConfusableIdentifier(first.text) else { return .unconfirmed }
        let intersection = region.intersection(first.bounds)
        let area = first.bounds.width * first.bounds.height
        guard area > 0, !intersection.isNull, region.contains(CGPoint(x: first.bounds.midX, y: first.bounds.midY)),
              intersection.width * intersection.height >= area * 0.7 else { return .unconfirmed }
        if existingLines.contains(where: { line in
            let overlap = line.bounds.intersection(first.bounds)
            let minimum = min(area, line.bounds.width * line.bounds.height)
            return !overlap.isNull && overlap.width * overlap.height > minimum * 0.1
        }) { return .overlap }
        if existingText.split(whereSeparator: \.isNewline).contains(where: {
            OCRLineRecovery.hasConflictingLabel(first.text, existing: String($0))
        }) { return .conflict }
        return .append
    }
}
