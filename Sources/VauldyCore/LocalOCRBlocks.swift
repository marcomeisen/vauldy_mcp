import Foundation
import CoreGraphics

public struct LocalOCRTextBlock: Codable, Equatable, Sendable {
    public let lineIndices: [Int]
    public let bounds: CGRect
}

enum OCRTextBlocks {
    /// Preserve the page text and refer to its lines. Ambiguous neighbours stay separate.
    static func make(_ lines: [LocalOCRLine]) -> [LocalOCRTextBlock]? {
        guard lines.count <= 4096 else { return nil }
        let order = lines.indices.sorted {
            let a = lines[$0].bounds, b = lines[$1].bounds
            return a.maxY == b.maxY ? a.minX < b.minX : a.maxY > b.maxY
        }
        var groups: [[Int]] = []
        var active: [Int] = []
        for index in order {
            let box = lines[index].bounds
            active = active.filter { group in
                let last = lines[groups[group].last!].bounds
                return last.minY - box.maxY <= max(last.height, box.height) * 2
            }
            let matches = active.filter { group in
                let last = lines[groups[group].last!].bounds
                let height = max(last.height, box.height)
                let overlap = max(0, min(last.maxX, box.maxX) - max(last.minX, box.minX))
                let gap = last.minY - box.maxY
                return height > 0 && min(last.height, box.height) >= height * 0.6
                    && gap >= -height * 0.2 && gap <= height * 1.5
                    && abs(last.minX - box.minX) <= min(0.035, height)
                    && overlap >= min(last.width, box.width) * 0.65
            }
            if matches.count == 1, let group = matches.first { groups[group].append(index) }
            else { groups.append([index]); active.append(groups.count - 1) }
            // Bound comparisons on extremely dense layouts; separation is safer than a speculative merge.
            if active.count > 64 { active.removeFirst(active.count - 64) }
        }
        return groups.map { indices in
            LocalOCRTextBlock(lineIndices: indices,
                              bounds: indices.reduce(CGRect.null) { $0.union(lines[$1].bounds) })
        }
    }
}
