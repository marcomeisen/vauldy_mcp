import CoreGraphics
import Foundation
import Vision

/// A line decoder can read a group of similar glyphs as a single numeric token.
/// Re-read each ambiguous glyph beside the original field label in two views.
enum OCRPolicyIdentifierRepair {
    private struct Field {
        let label: String
        let code: [Character]
        let groupLength: Int
    }

    private static func field(_ line: String) -> Field? {
        guard let colon = line.firstIndex(of: ":"),
              line[..<colon].range(of: #"^Policen[ -]?(?:nummer|nr\.?)$"#,
                                  options: [.caseInsensitive, .regularExpression]) != nil else { return nil }
        let code = Array(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        guard let dash = code.firstIndex(of: "-"), (4...8).contains(dash),
              (2...12).contains(code.count - dash - 1), code.prefix(dash).allSatisfy({ "01".contains($0) }),
              code.dropFirst(dash + 1).allSatisfy({ "0123456789".contains($0) }) else { return nil }
        let label = String(line.dropLast(code.count))
        guard label.last?.isWhitespace == true else { return nil }
        return Field(label: label, code: code, groupLength: dash)
    }

    static func permits(_ old: String, _ new: String) -> Bool {
        guard old != new, let field = field(old), new.hasPrefix(field.label) else { return false }
        let candidate = Array(new.dropFirst(field.label.count))
        guard candidate.count == field.code.count else { return false }
        return field.code.indices.allSatisfy { index in
            let previous = field.code[index], next = candidate[index]
            return previous == next || (index < field.groupLength
                && ((previous == "1" && next == "I") || (previous == "0" && next == "O")))
        }
    }

    struct Views {
        let images: [CGImage]
        let rowHeight: CGFloat
        let widths: [Int]
    }

    static func views(_ image: CGImage, bounds: CGRect, line: String) -> Views? {
        guard let field = field(line) else { return nil }
        let box = CGRect(x: bounds.minX * CGFloat(image.width), y: (1 - bounds.maxY) * CGFloat(image.height),
                         width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height))
            .insetBy(dx: -1, dy: 0).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard (10...32).contains(box.height), (40...400).contains(box.width),
              let raw = image.cropping(to: box) else { return nil }
        let width = raw.width, height = raw.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(raw, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, let ink = pixels.min(), let paper = pixels.max(), Int(paper) - Int(ink) >= 48 else { return nil }
        let threshold = Int(ink) + (Int(paper) - Int(ink)) * 55 / 100
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0...width {
            let occupied = x < width && (0..<height).contains { pixels[$0 * width + x] < threshold }
            if occupied { if start == nil { start = x } }
            else if let first = start { runs.append(first..<x); start = nil }
        }
        guard runs.count > field.code.count else { return nil }
        let glyphs = Array(runs.suffix(field.code.count))
        let colon = runs[runs.count - field.code.count - 1]
        guard let first = glyphs.first, let last = glyphs.last,
              colon.count <= 3, (3...height).contains(first.lowerBound - colon.upperBound),
              width - last.upperBound <= 6 else { return nil }
        // The colon has two separated dots, while the code's dash is a short
        // horizontal stroke. Both must align with the proposed segmentation.
        func occupiedRows(_ range: Range<Int>) -> [Int] {
            (0..<height).filter { y in range.contains { pixels[y * width + $0] < threshold } }
        }
        let dots = occupiedRows(colon)
        let dash = occupiedRows(glyphs[field.groupLength])
        guard zip(dots, dots.dropFirst()).contains(where: { $1 - $0 > 1 }),
              !dash.isEmpty, dash.count <= height / 3, glyphs[field.groupLength].count >= 2,
              let label = raw.cropping(to: CGRect(x: 0, y: 0, width: colon.upperBound + 2, height: height)) else { return nil }

        let selected = glyphs.prefix(field.groupLength)
        let glyphWidth = (selected.map(\.count).max() ?? 0) + 5
        var images: [CGImage] = []
        for scale in [3, 4] {
            let margin = 32
            let gap = 7
            let rowHeight = height * scale
            let stride = rowHeight + margin
            let canvasWidth = (label.width + gap + glyphWidth) * scale + 2 * margin
            let canvasHeight = field.groupLength * stride + margin
            guard canvasWidth <= 2048, canvasHeight <= 2048, canvasWidth * canvasHeight <= 1_000_000,
                  let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
            context.interpolationQuality = .high
            for (index, range) in selected.enumerated() {
                // Include the antialiased edge, excluding the dark columns of adjacent glyphs.
                guard range.lowerBound > 0, range.upperBound < width,
                      let glyph = raw.cropping(to: CGRect(x: range.lowerBound - 1, y: 0,
                                                         width: range.count + 2, height: height)) else { return nil }
                let bottom = canvasHeight - margin - rowHeight - index * stride
                context.draw(label, in: CGRect(x: margin, y: bottom, width: label.width * scale, height: rowHeight))
                context.draw(glyph, in: CGRect(x: margin + (label.width + gap) * scale, y: bottom,
                                               width: glyph.width * scale, height: rowHeight))
            }
            guard let view = context.makeImage() else { return nil }
            images.append(view)
        }
        return Views(images: images, rowHeight: CGFloat(height), widths: glyphs.map(\.count))
    }

    static func reading(_ line: String, views: Views,
                        observations: [[VNRecognizedTextObservation]]) -> (String, Float)? {
        guard let field = field(line), observations.count == views.images.count else { return nil }
        var confirmations: [[Character]] = []
        var confidence: Float = 1
        for (viewIndex, matches) in observations.enumerated() {
            guard matches.count == field.groupLength else { return nil }
            var characters = [Character?](repeating: nil, count: field.groupLength)
            let scale = viewIndex + 3
            let rowHeight = views.rowHeight * CGFloat(scale)
            let canvasHeight = CGFloat(views.images[viewIndex].height)
            for observation in matches {
                let y = (1 - observation.boundingBox.midY) * canvasHeight
                guard y >= 32 else { return nil }
                let row = Int((y - 32) / (rowHeight + 32))
                guard characters.indices.contains(row), characters[row] == nil,
                      y < 32 + CGFloat(row) * (rowHeight + 32) + rowHeight,
                      let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.95,
                      candidate.string.hasPrefix(field.label) else { return nil }
                let tail = candidate.string.dropFirst(field.label.count)
                guard tail.count == 1, let glyph = tail.first, "01IO".contains(glyph) else { return nil }
                characters[row] = glyph
                confidence = min(confidence, candidate.confidence)
            }
            confirmations.append(characters.compactMap { $0 })
        }
        guard let first = confirmations.first, first.count == field.groupLength,
              confirmations.allSatisfy({ $0 == first }) else { return nil }
        let proposed = field.label + String(first + field.code.dropFirst(field.groupLength))
        guard permits(line, proposed) else { return nil }

        // Compare to digits on the same line. An indistinguishable font or
        // merged strokes provide insufficient evidence for a substitution.
        let zeroWidths = first.indices.filter { first[$0] == "0" }.map { views.widths[$0] }
        let oneWidths = field.code.indices.dropFirst(field.groupLength + 1)
            .filter { field.code[$0] == "1" }.map { views.widths[$0] }
        for index in first.indices where first[index] != field.code[index] {
            if first[index] == "O" {
                guard let zero = zeroWidths.max(), 4 * views.widths[index] >= 5 * zero else { return nil }
            } else {
                guard let one = oneWidths.min(), 2 * views.widths[index] <= one else { return nil }
            }
        }
        return (proposed, confidence)
    }
}
