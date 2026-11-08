import CoreGraphics
import Foundation

enum OCRLineContrast {
    /// A bounded grey stretch/tone curve, never binarization. Measure only the target line;
    /// dark neighbours must not hide a faint line. One million pixels maximum.
    static func normalize(_ image: CGImage, target: CGRect, maximumGain: Double = 3) -> CGImage? {
        guard target.minX.isFinite, target.minY.isFinite, target.width.isFinite, target.height.isFinite,
              image.width > 0, image.height > 0, image.width <= 1_000_000 / image.height else { return nil }
        var pixels = [UInt8](repeating: 255, count: image.width * image.height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let box = CGRect(x: target.minX * canvas.width, y: (1 - target.maxY) * canvas.height,
            width: target.width * canvas.width, height: target.height * canvas.height).integral.intersection(canvas)
        guard !box.isNull, !box.isEmpty else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) { histogram[Int(pixels[y * image.width + x])] += 1 }
        }
        let count = histogram.reduce(0, +)
        func percentile(_ fraction: Double) -> Int {
            let threshold = max(1, Int(Double(count) * fraction)); var seen = 0
            for index in histogram.indices { seen += histogram[index]; if seen >= threshold { return index } }
            return 255
        }
        let low = percentile(0.02), high = percentile(0.98), span = high - low
        // Avoid amplifying a blank/noisy flat patch. A mixed line may contain
        // dark words and one faint word; preserve black/white endpoints while
        // darkening intermediate grey levels in that case.
        guard span >= 16 else { return nil }
        let gain = min(maximumGain, 255.0 / Double(span))
        for index in pixels.indices {
            let value = span >= 180
                ? 255 * pow(min(1, Double(pixels[index]) / Double(max(1, high))), maximumGain)
                : max(0, min(255, (Double(pixels[index]) - Double(high)) * gain + 255))
            pixels[index] = UInt8(value.rounded())
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
