import Foundation
import CoreGraphics

/// Measures a separated final superscript beside a baseline unit glyph.
/// The original superscript pixels, not a supplied digit, are enlarged for OCR.
enum OCRMetreGlyphs {
    static func normalize(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= 100_000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard pixels.withUnsafeMutableBytes({ bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }) else { return nil }
        var runs: [CGRect] = [], start: Int?
        for x in 0...w {
            let ink = x < w && (0..<h).contains { pixels[$0 * w + x] < 210 }
            if ink { if start == nil { start = x } }
            else if let left = start {
                var top = h, bottom = -1
                for y in 0..<h {
                    for xx in left..<x where pixels[y * w + xx] < 210 { top = min(top, y); bottom = max(bottom, y) }
                }
                runs.append(CGRect(x: left, y: top, width: x - left, height: bottom - top + 1)); start = nil
            }
        }
        guard (4...24).contains(runs.count) else { return nil }
        let raised = runs.last!, unit = runs[runs.count - 2], prefix = runs.dropLast(2)
        let base = prefix.map(\.height).max() ?? 0
        let digits = prefix.filter { $0.height >= base * 0.8 }
        guard base >= 10, digits.count >= 2 else { return nil }
        let baseline = digits.map(\.maxY).sorted()[digits.count / 2]
        guard digits.allSatisfy({ abs($0.maxY - baseline) <= base * 0.15 }),
              raised.height >= base * 0.35, raised.height <= base * 0.72,
              raised.maxY <= baseline - base * 0.2, raised.minY <= baseline - base * 0.75,
              unit.height >= base * 0.55, unit.height <= base * 0.85,
              abs(unit.maxY - baseline) <= base * 0.15, unit.width >= base * 0.6,
              raised.minX - unit.maxX <= base * 0.5 else { return nil }
        let bounds = raised.insetBy(dx: -1, dy: -1).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let glyph = image.cropping(to: bounds),
              let prefixImage = image.cropping(to: CGRect(x: 0, y: 0, width: bounds.minX, height: CGFloat(h))) else { return nil }
        let glyphWidth = ceil(bounds.width * (base + 2) / bounds.height)
        let width = max(w, Int(bounds.minX + glyphWidth + 8))
        guard let context = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: h))
        context.draw(prefixImage, in: CGRect(x: 0, y: 0, width: prefixImage.width, height: h))
        context.draw(glyph, in: CGRect(x: bounds.minX, y: CGFloat(h) - baseline - 1, width: glyphWidth, height: base + 2))
        return context.makeImage()
    }
    static func restore(_ text: String) -> String? {
        guard text.range(of: #"^[+-]?[0-9][0-9.,]*\s*m\s*[0-9]$"#, options: .regularExpression) != nil,
              let m = text.lastIndex(of: "m"), let digit = text.last?.wholeNumberValue else { return nil }
        return text[..<m].trimmingCharacters(in: .whitespaces) + " m" + String(Array("⁰¹²³⁴⁵⁶⁷⁸⁹")[digit])
    }
}
