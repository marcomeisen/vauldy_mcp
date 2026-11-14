import CoreGraphics

/// Rectifies only a measured slanted line. Pixels and returned observations stay
/// bound to the original image; no text or dictionary enters this transform.
enum OCRDeskewedLineCrop {
    struct Crop {
        let image: CGImage
        let target: CGRect
        let transform: CGAffineTransform
    }

    static func make(_ image: CGImage, corners: [CGPoint], contextPadding: CGFloat) -> Crop? {
        guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite
                && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              contextPadding.isFinite, (0...1).contains(contextPadding) else { return nil }
        let points = corners.map { CGPoint(x: $0.x * CGFloat(image.width), y: $0.y * CGFloat(image.height)) }
        let top = CGPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y)
        let bottom = CGPoint(x: points[2].x - points[3].x, y: points[2].y - points[3].y)
        let angle = atan2(top.y + bottom.y, top.x + bottom.x)
        guard abs(angle) >= 0.012, abs(angle) <= 0.21,
              abs(atan2(top.y, top.x) - atan2(bottom.y, bottom.x)) < 0.025 else { return nil }
        let centre = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        let rotation = CGAffineTransform(rotationAngle: -angle)
        let rotated = points.map { CGPoint(x: $0.x - centre.x, y: $0.y - centre.y).applying(rotation) }
        let minX = rotated.map(\.x).min()!, minY = rotated.map(\.y).min()!
        let lineWidth = rotated.map(\.x).max()! - minX, lineHeight = rotated.map(\.y).max()! - minY
        guard lineWidth > 0, lineHeight > 0 else { return nil }
        let padX = max(6, lineHeight), padY = max(3, lineHeight * contextPadding)
        let width = lineWidth + 2 * padX, height = lineHeight + 2 * padY
        let scale = max(1, min(3, 64 / lineHeight, 2048 / max(width, height)))
        guard width * height * scale * scale <= 1_000_000 else { return nil }
        let outputWidth = Int(ceil(width * scale)), outputHeight = Int(ceil(height * scale))
        guard outputWidth * outputHeight <= 1_000_000, max(outputWidth, outputHeight) <= 4096 else { return nil }
        guard let context = CGContext(data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: padX - minX, y: padY - minY)
        context.rotate(by: -angle)
        context.translateBy(x: -centre.x, y: -centre.y)
        let drawing = context.ctm
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let output = context.makeImage() else { return nil }
        let target = CGRect(x: padX * scale / CGFloat(outputWidth), y: padY * scale / CGFloat(outputHeight),
                            width: lineWidth * scale / CGFloat(outputWidth), height: lineHeight * scale / CGFloat(outputHeight))
        let transform = CGAffineTransform(scaleX: CGFloat(outputWidth), y: CGFloat(outputHeight))
            .concatenating(drawing.inverted())
            .concatenating(CGAffineTransform(scaleX: 1 / CGFloat(image.width), y: 1 / CGFloat(image.height)))
        return Crop(image: output, target: target, transform: transform)
    }
}
