import CoreGraphics
import Foundation

/// Pixel-only proposals: neither words nor expected document values enter this stage.
/// Original images are never rewritten; all work is bounded to the native image limit.
enum OCRFaintRasterRegions {
    private static func grey(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 3072, h <= 3072 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        return ok ? pixels : nil
    }

    static func proposals(in image: CGImage, checkCancellation: () throws -> Void) throws -> [CGRect] {
        guard let pixels = grey(image) else { return [] }
        let w = image.width, h = image.height
        guard w >= 40, h >= 40 else { return [] }
        func median(_ values: [Double]) -> Double { let s = values.sorted(); return s[s.count / 2] }
        var means = [Double](repeating: 255, count: h)
        for y in 0..<h {
            if y % 32 == 0 { try checkCancellation() }
            means[y] = Double(pixels[(y * w)..<((y + 1) * w)].reduce(0) { $0 + Int($1) }) / Double(w)
        }
        var activity = [Bool](repeating: false, count: h)
        for y in 0..<h {
            let local = Array(means[max(0, y - 18)..<min(h, y + 19)])
            let background = median(local)
            let noise = median(local.map { abs($0 - background) })
            activity[y] = means[y] > 190 && background - means[y] > max(0.35, noise * 4)
        }
        var result: [CGRect] = [], y = 0
        while y < h {
            try checkCancellation()
            guard activity[y] else { y += 1; continue }
            let top = y; var bottom = y; y += 1
            while y < h && y - bottom <= 2 {
                if activity[y] { bottom = y }; y += 1
            }
            let height = bottom - top + 1
            guard (3...24).contains(height) else { continue }
            let backgroundRows = (max(0, top - 18)..<min(h, bottom + 19)).filter {
                !activity[$0] && ($0 < top - 4 || $0 > bottom + 4)
            }
            guard backgroundRows.count >= 4 else { continue }
            var contrast = [Double](repeating: 0, count: w)
            for x in 0..<w {
                let paper = Double(backgroundRows.reduce(0) { $0 + Int(pixels[$1 * w + x]) }) / Double(backgroundRows.count)
                let ink = Double((top...bottom).reduce(0) { $0 + Int(pixels[$1 * w + x]) }) / Double(height)
                contrast[x] = paper - ink
            }
            let smoothed = (0..<w).map { x in
                (contrast[max(0, x - 1)] + contrast[x] * 2 + contrast[min(w - 1, x + 1)]) / 4
            }
            let centre = median(smoothed), noise = median(smoothed.map { abs($0 - centre) })
            let threshold = max(1.5, centre + noise * 2.5)
            var runs: [(Int, Int)] = [], start: Int?
            for x in 0..<w {
                if smoothed[x] > threshold { if start == nil { start = x } }
                else if let first = start { if x - first >= 2 { runs.append((first, x - 1)) }; start = nil }
            }
            if let first = start, w - first >= 2 { runs.append((first, w - 1)) }
            var groups: [[(Int, Int)]] = []
            for run in runs {
                if let previous = groups.last?.last, run.0 - previous.1 <= max(12, height * 3) {
                    groups[groups.count - 1].append(run)
                } else { groups.append([run]) }
            }
            for group in groups where group.count >= 6 {
                guard let first = group.first, let last = group.last, last.1 - first.0 >= 20 else { continue }
                let box = CGRect(x: first.0, y: top, width: last.1 - first.0 + 1, height: height)
                result.append(box)
                if result.count == 64 { return result }
            }
        }
        return result
    }

    static func readSize(width: Int, height: Int, glyphHeight: CGFloat) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, width <= 4096, height <= 4096, width <= 1_000_000 / height,
              glyphHeight.isFinite, glyphHeight > 0 else { return nil }
        let scale = max(1, min(6, 48 / glyphHeight, sqrt(CGFloat(1_000_000) / CGFloat(width * height)),
                               4096 / CGFloat(max(width, height))))
        return (max(width, Int((CGFloat(width) * scale).rounded(.down))),
                max(height, Int((CGFloat(height) * scale).rounded(.down))))
    }

    static func enhance(_ image: CGImage, confirmation: Bool, checkCancellation: () throws -> Void) throws -> CGImage? {
        guard image.width <= 1_000_000 / max(1, image.height), let input = grey(image) else { return nil }
        let w = image.width, h = image.height
        var reference: [Int] = []
        for y in 0..<h {
            if y % 32 == 0 { try checkCancellation() }
            for x in 0..<w where y < 2 || y >= h - 2 || x < 2 || x >= w - 2 { reference.append(Int(input[y*w+x])) }
        }
        reference.sort()
        let floor = reference[max(0, Int(Double(reference.count) * 0.01) - 1)]
        let median = reference[reference.count / 2]
        guard median - floor >= 4 else { return nil }
        let strong = floor - 1
        let weak = floor + max(2, Int(Double(median - floor) * (confirmation ? 0.45 : 0.55)))
        var supported = [Bool](repeating: false, count: input.count)
        for y in 0..<h {
            if y % 32 == 0 { try checkCancellation() }
            for x in 0..<w {
                let value = Int(input[y*w+x])
                if value < strong { supported[y*w+x] = true; continue }
                guard value < weak else { continue }
                supported[y*w+x] = (-1...1).contains { dy in (-1...1).contains { dx in
                    Int(input[max(0,min(h-1,y+dy))*w+max(0,min(w-1,x+dx))]) < strong
                } }
            }
        }
        var pixels = [UInt8](repeating: 255, count: input.count), foreground = 0
        for index in input.indices where supported[index] {
            foreground += 1
            pixels[index] = UInt8(max(0, min(255, 255 + (Double(input[index]) - Double(weak)) * (confirmation ? 14 : 16))).rounded())
        }
        guard foreground >= max(12, w / 8), foreground * 2 < input.count else { return nil }
        let initial = pixels
        if h > 2 {
            for y in 1..<(h-1) {
                for x in 0..<w where initial[y*w+x] > 192 && initial[(y-1)*w+x] < 192 && initial[(y+1)*w+x] < 192 {
                    pixels[y*w+x] = max(initial[(y-1)*w+x], initial[(y+1)*w+x])
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }
}
