import CoreGraphics

/// Remove only an outer, exactly white border. Every nonwhite pixel remains in
/// the OCR input; text, tables, annotations and page identity are never inferred.
/// Vision can omit lines when a small text block occupies a mostly empty page.
enum OCRWhiteMargins {
    static func contentBounds(in image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 3072, height <= 3072 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(full)
            context.interpolationQuality = .none
            context.draw(image, in: full)
            let data = bytes.bindMemory(to: UInt8.self)
            var left = width, right = -1, top = height, bottom = -1
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    guard data[index] < 255 || data[index + 1] < 255 || data[index + 2] < 255 else { continue }
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard right >= left, bottom >= top else { return nil }
            let padding = max(12, min(64, min(width, height) / 50))
            return CGRect(x: max(0, left - padding), y: max(0, top - padding),
                width: min(width - 1, right + padding) - max(0, left - padding) + 1,
                height: min(height - 1, bottom + padding) - max(0, top - padding) + 1)
        }
    }

    static func cropped(_ image: CGImage) -> CGImage {
        guard let bounds = contentBounds(in: image),
              bounds.width < CGFloat(image.width) || bounds.height < CGFloat(image.height) else { return image }
        return image.cropping(to: bounds) ?? image
    }
}
