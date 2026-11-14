import CoreGraphics
import Foundation
import Vision

/// Removes inter-cell whitespace, never ink. Each pixel segment keeps its
/// source transform; contextual OCR characters must map back into one cell.
enum OCRTableContext {
    struct Cell {
        let column: Int
        let source: CGRect
        let target: CGRect
        let raisedMicroUnit: Bool
        let raisedMetreUnit: Bool
    }
    struct View {
        let image: CGImage
        let cells: [Cell]
    }
    struct Reading {
        var text: String
        var confidence: Float
    }

    static func rowBounds(_ grid: OCRRuledTable.Grid, row: Int, image: CGImage) -> CGRect {
        normalized(CGRect(x: grid.columns[0] + 3, y: grid.rows[row] + 3,
            width: grid.columns.last! - grid.columns[0] - 6,
            height: grid.rows[row + 1] - grid.rows[row] - 6), image: image)
    }

    static func cellBounds(_ grid: OCRRuledTable.Grid, row: Int, column: Int, image: CGImage) -> CGRect {
        normalized(CGRect(x: grid.columns[column] + 3, y: grid.rows[row] + 3,
            width: grid.columns[column + 1] - grid.columns[column] - 6,
            height: grid.rows[row + 1] - grid.rows[row] - 6), image: image)
    }

    static func normalized(_ pixels: CGRect, image: CGImage) -> CGRect {
        CGRect(x: pixels.minX / CGFloat(image.width), y: 1 - pixels.maxY / CGFloat(image.height),
               width: pixels.width / CGFloat(image.width), height: pixels.height / CGFloat(image.height))
    }

    static func make(_ image: CGImage, grid: OCRRuledTable.Grid, row: Int, scale: Int,
                     unitColumns: Set<Int> = [], cellGap: Int? = nil,
                     check: () throws -> Void) throws -> View? {
        guard (1...3).contains(scale), row >= 0, row + 1 < grid.rows.count else { return nil }
        let top = grid.rows[row] + 3, height = grid.rows[row + 1] - top - 3
        guard height > 0, height <= 256 else { return nil }
        var pieces: [(column: Int, image: CGImage, source: CGRect, raised: Bool, metre: Bool)] = []
        for column in 0..<(grid.columns.count - 1) {
            try check()
            let left = grid.columns[column] + 3, originalWidth = grid.columns[column + 1] - left - 3
            guard originalWidth > 0, var raw = image.cropping(to: CGRect(x: left, y: top, width: originalWidth, height: height)) else { return nil }
            let typography = unitColumns.contains(column) ? OCRUnitGlyphs.normalize(raw) : nil
            let metre = unitColumns.contains(column) && typography == nil ? OCRMetreGlyphs.normalize(raw) : nil
            if let typography { raw = typography.image }
            else if let metre { raw = metre }
            let width = raw.width
            var pixels = [UInt8](repeating: 255, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.draw(raw, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            guard drawn else { return nil }
            var minX = width, maxX = -1, ink = 0
            for y in 0..<height {
                for x in 0..<width where pixels[y * width + x] < 210 {
                    minX = min(minX, x); maxX = max(maxX, x); ink += 1
                }
            }
            guard ink >= 4, maxX >= minX else { continue }
            let x = max(0, minX - 2), size = min(width, maxX + 3) - x
            guard let piece = raw.cropping(to: CGRect(x: x, y: 0, width: size, height: height)) else { return nil }
            let source = typography == nil && metre == nil ? CGRect(x: left + x, y: top, width: size, height: height)
                : CGRect(x: left, y: top, width: originalWidth, height: height)
            pieces.append((column, piece, normalized(source, image: image), typography != nil, metre != nil))
        }
        guard pieces.count >= 2 else { return nil }
        let gap = min(32, max(8, cellGap ?? height / 8)), padding = 32
        let width = (pieces.reduce(0) { $0 + $1.image.width } + gap * (pieces.count - 1)) * scale + padding * 2
        let outputHeight = height * scale + padding * 2
        guard width <= 4096, width * outputHeight <= 1_000_000,
              let context = CGContext(data: nil, width: width, height: outputHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: outputHeight))
        var cells: [Cell] = [], x = padding
        for piece in pieces {
            let bounds = CGRect(x: x, y: padding, width: piece.image.width * scale, height: height * scale)
            context.draw(piece.image, in: bounds)
            cells.append(.init(column: piece.column, source: piece.source,
                target: CGRect(x: bounds.minX / CGFloat(width), y: bounds.minY / CGFloat(outputHeight),
                               width: bounds.width / CGFloat(width), height: bounds.height / CGFloat(outputHeight)),
                raisedMicroUnit: piece.raised, raisedMetreUnit: piece.metre))
            x += (piece.image.width + gap) * scale
        }
        guard let output = context.makeImage() else { return nil }
        return View(image: output, cells: cells)
    }

    static func readings(_ observations: [VNRecognizedTextObservation], in view: View) -> [Int: Reading] {
        var result: [Int: Reading] = [:], invalid = Set<Int>()
        for observation in observations {
            guard let text = observation.topCandidates(1).first else { continue }
            // Vision has no reliable boxes for spaces. Assign ink characters,
            // then retain their literal intervening text, including spaces.
            var assignments: [(index: String.Index, column: Int)] = []
            for index in text.string.indices where !text.string[index].isWhitespace {
                guard let box = try? text.boundingBox(for: index..<text.string.index(after: index))?.boundingBox else { continue }
                let matches = view.cells.filter { $0.target.contains(CGPoint(x: box.midX, y: box.midY)) }
                guard matches.count == 1, let cell = matches.first else { return [:] }
                assignments.append((index, cell.column))
            }
            guard assignments.count == text.string.filter({ !$0.isWhitespace }).count else { return [:] }
            for column in Set(assignments.map(\.column)) {
                let assigned = assignments.filter { $0.column == column }
                let start = assigned.first!.index, end = assigned.last!.index
                guard assignments.allSatisfy({ $0.index < start || $0.index > end || $0.column == column }) else { return [:] }
                var value = String(text.string[start...end])
                guard !value.isEmpty else { continue }
                if view.cells.first(where: { $0.column == column })?.raisedMicroUnit == true {
                    guard let restored = OCRUnitGlyphs.restore(value) else { invalid.insert(column); continue }
                    value = restored
                }
                if view.cells.first(where: { $0.column == column })?.raisedMetreUnit == true {
                    guard let restored = OCRMetreGlyphs.restore(value) else { invalid.insert(column); continue }
                    value = restored
                }
                if result[column] != nil { invalid.insert(column) }
                result[column] = Reading(text: value, confidence: text.confidence)
            }
        }
        for column in invalid { result.removeValue(forKey: column) }
        return result
    }
}
