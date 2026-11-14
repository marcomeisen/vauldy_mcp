import CoreGraphics
import Foundation

/// A geometry-only measurement for a raised glyph and a micro-sign descender.
/// It normalizes their placement for OCR, never supplies the exponent's value.
enum OCRUnitGlyphs {
  struct Result { let image: CGImage }
  static func normalize(_ image: CGImage) -> Result? {
    let w = image.width
    let h = image.height
    guard w > 0, h > 0, w * h <= 100_000 else { return nil }
    var pixels = [UInt8](repeating: 255, count: w * h)
    guard
      pixels.withUnsafeMutableBytes({ b -> Bool in
        guard
          let c = CGContext(
            data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
      })
    else { return nil }
    var runs: [CGRect] = []
    var start: Int?
    for x in 0...w {
      let ink = x < w && (0..<h).contains { pixels[$0 * w + x] < 210 }
      if ink {
        if start == nil { start = x }
      } else if let s = start {
        var top = h
        var bottom = -1
        for y in 0..<h {
          for xx in s..<x where pixels[y * w + xx] < 210 {
            top = min(top, y)
            bottom = max(bottom, y)
          }
        }
        runs.append(CGRect(x: s, y: top, width: x - s, height: bottom - top + 1))
        start = nil
      }
    }
    guard runs.count == 6 else { return nil }
    let a = runs[0]
    let b = runs[1]
    let sup = runs[2]
    let slash = runs[3]
    let micro = runs[4]
    let last = runs[5]
    let base = (a.height + b.height) / 2
    let baseline = (a.maxY + b.maxY) / 2
    guard base >= 10, abs(a.height - b.height) < base * 0.2, abs(a.maxY - b.maxY) < base * 0.15,
      sup.height >= base * 0.35, sup.height <= base * 0.72,
      sup.minY <= min(a.minY, b.minY) + base * 0.15, sup.maxY <= baseline - base * 0.2,
      slash.height >= base * 0.8, last.height >= base * 0.8,
      abs(last.maxY - baseline) < base * 0.15,
      micro.minY > min(a.minY, b.minY) + base * 0.15, micro.maxY >= baseline + base * 0.2,
      micro.maxY <= baseline + base * 0.6
    else { return nil }
    let enlarged = Int(ceil(sup.width * base / sup.height))
    let extra = enlarged - Int(sup.width)
    guard
      let c = CGContext(
        data: nil, width: w + extra + 8, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    c.setFillColor(gray: 1, alpha: 1)
    c.fill(CGRect(x: 0, y: 0, width: w + extra + 8, height: h))
    for (i, run) in runs.enumerated() {
      let bounds = run.insetBy(dx: -1, dy: -1).intersection(CGRect(x: 0, y: 0, width: w, height: h))
      guard let glyph = image.cropping(to: bounds) else { return nil }
      if i == 2 {
        c.draw(
          glyph,
          in: CGRect(
            x: bounds.minX, y: CGFloat(h) - baseline - 1, width: CGFloat(enlarged + 2),
            height: base + 2))
      } else {
        c.draw(
          glyph,
          in: CGRect(
            x: bounds.minX + (i > 2 ? CGFloat(extra + 2) : 0), y: CGFloat(h) - bounds.maxY,
            width: bounds.width, height: bounds.height))
      }
    }
    guard let output = c.makeImage() else { return nil }
    return .init(image: output)
  }
  static func restore(_ text: String) -> String? {
    guard let match = text.range(of: #"^10[0-9]/[uµμ]l$"#, options: .regularExpression) else {
      return nil
    }
    let value = String(text[match])
    let digit = Array(value)[2]
    guard let index = digit.wholeNumberValue else { return nil }
    return "10" + String(Array("⁰¹²³⁴⁵⁶⁷⁸⁹")[index]) + "/µl"
  }
}
