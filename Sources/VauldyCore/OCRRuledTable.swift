import CoreGraphics

/// Finds only closed, axis-aligned ruled grids from pixels. No text, labels or
/// expected values participate in detection. Coordinates are image-top pixels.
enum OCRRuledTable {
  struct Grid {
    let rows: [Int]
    let columns: [Int]
  }
  static func detect(_ image: CGImage, check: () throws -> Void) throws -> [Grid] {
    let w = image.width
    let h = image.height
    guard w > 64, h > 64, w <= 4096, h <= 4096 else { return [] }
    var pixels = [UInt8](repeating: 255, count: w * h)
    return try pixels.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return [] }
      context.setFillColor(gray: 1, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: w, height: h))
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      let p = bytes.bindMemory(to: UInt8.self)
      struct Rule {
        var startY: Int
        var endY: Int
        let left: Int
        let right: Int
      }
      var rules: [Rule] = []
      for y in 0..<h {
        if y % 64 == 0 { try check() }
        var start: Int?
        var best: (Int, Int)?
        for x in 0...w {
          if x < w && p[y * w + x] < 210 {
            if start == nil { start = x }
          } else if let s = start {
            if x - s >= max(80, w / 4), x - s > (best.map { $0.1 - $0.0 } ?? 0) {
              best = (s, x - 1)
            }
            start = nil
          }
        }
        guard let (l, r) = best else { continue }
        if let last = rules.last, last.endY == y - 1, abs(last.left - l) < 4,
          abs(last.right - r) < 4
        {
          rules[rules.count - 1].endY = y
        } else {
          rules.append(.init(startY: y, endY: y, left: l, right: r))
        }
        if rules.count > 256 { return [] }
      }
      rules = rules.filter { $0.endY - $0.startY <= max(3, h / 300) }
      var groups: [[Rule]] = []
      for rule in rules {
        if let last = groups.last?.last, abs(last.left - rule.left) <= 4,
          abs(last.right - rule.right) <= 4,
          rule.startY - last.endY <= max(128, h / 12)
        {
          groups[groups.count - 1].append(rule)
        } else {
          groups.append([rule])
        }
      }
      var grids: [Grid] = []
      for group in groups where group.count >= 3 && group.count <= 33 {
        try check()
        let rows = group.map { ($0.startY + $0.endY) / 2 }
        let first = group[0]
        let last = group[group.count - 1]
        guard zip(rows, rows.dropFirst()).allSatisfy({ $1 - $0 >= 14 }) else { continue }
        var bands: [[Int]] = []
        for x in max(0, first.left - 3)...min(w - 1, first.right + 3) {
          var dark = 0
          for y in first.startY...last.endY { if p[y * w + x] < 210 { dark += 1 } }
          if Double(dark) / Double(last.endY - first.startY + 1) >= 0.9 {
            if bands.last?.last == x - 1 {
              bands[bands.count - 1].append(x)
            } else {
              bands.append([x])
            }
          }
        }
        let columns = bands.filter { $0.count <= max(4, w / 300) }.map { $0[$0.count / 2] }
        guard (3...13).contains(columns.count), abs(columns[0] - first.left) <= 4,
          abs(columns.last! - first.right) <= 4,
          zip(columns, columns.dropFirst()).allSatisfy({ $1 - $0 >= 16 }),
          (rows.count - 1) * (columns.count - 1) <= 256
        else { continue }
        grids.append(.init(rows: rows, columns: columns))
        if grids.count == 4 { break }
      }
      return grids
    }
  }
}
