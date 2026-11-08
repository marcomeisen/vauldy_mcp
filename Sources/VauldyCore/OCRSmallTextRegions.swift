import CoreGraphics

/// Bounded ink-band proposals for a second-scale text DETECTOR. These pixels do
/// not certify text, completeness, confidence, or any expected document value.
enum OCRSmallTextRegions {
    static func proposals(in image: CGImage, checkCancellation: () throws -> Void) throws -> [CGRect] {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 3072, height <= 3072 else { return [] }
        var pixels = [UInt8](repeating: 255, count: width * height)
        return try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = bytes.bindMemory(to: UInt8.self)
            var rows = [(left: Int, right: Int)](repeating: (width, -1), count: height)
            for y in 0..<height {
                if y % 64 == 0 { try checkCancellation() }
                for x in 0..<width where data[y * width + x] < 180 {
                    rows[y].left = min(rows[y].left, x)
                    rows[y].right = x
                }
            }
            var proposals: [CGRect] = []
            var y = 0
            while y < height {
                try checkCancellation()
                guard rows[y].right >= rows[y].left else { y += 1; continue }
                let top = y
                var bottom = y, left = rows[y].left, right = rows[y].right
                y += 1
                while y < height && y - bottom <= 2 {
                    if rows[y].right >= rows[y].left {
                        bottom = y; left = min(left, rows[y].left); right = max(right, rows[y].right)
                    }
                    y += 1
                }
                let bandHeight = bottom - top + 1, bandWidth = right - left + 1
                guard (3...24).contains(bandHeight), bandWidth >= 12 else { continue }
                // Split columns at broad white gaps before proposing crops.
                // A page-wide band would otherwise repeatedly redetect already
                // covered columns and exhaust the small-text detector budget.
                var runs: [(left: Int, right: Int)] = []
                var start: Int?
                for x in left...right {
                    let ink = (top...bottom).contains { data[$0 * width + x] < 180 }
                    if ink && start == nil { start = x }
                    if !ink, let first = start { runs.append((first, x - 1)); start = nil }
                }
                if let first = start { runs.append((first, right)) }
                var groups: [[(left: Int, right: Int)]] = []
                for run in runs {
                    if let last = groups.last?.last, run.left - last.right <= max(12, bandHeight * 3) {
                        groups[groups.count - 1].append(run)
                    } else { groups.append([run]) }
                }
                for group in groups where group.count >= 6 {
                    guard let first = group.first, let last = group.last, last.right - first.left + 1 <= 1600 else { continue }
                    proposals.append(CGRect(x: first.left, y: top, width: last.right - first.left + 1, height: bandHeight))
                    if proposals.count == 1025 { return proposals }
                }
            }
            return proposals
        }
    }
}
