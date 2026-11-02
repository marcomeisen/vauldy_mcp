import Foundation
import CoreGraphics
import CoreText

/// Test originals only. Text wraps inside physical page bounds before rasterizing.
public enum SyntheticDocumentWriter {
    public static func writePDF(pages: [String], rasterPages: Set<Int> = [], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (index, text) in pages.enumerated() {
            pdf.beginPDFPage(nil)
            if rasterPages.contains(index + 1) {
                guard let image = CGContext(data: nil, width: 1190, height: 1684, bitsPerComponent: 8,
                    bytesPerRow: 1190 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                image.setFillColor(CGColor(gray: 1, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 1190, height: 1684))
                image.scaleBy(x: 2, y: 2); draw(text, in: image)
                guard let rendered = image.makeImage() else { throw CocoaError(.fileWriteUnknown) }
                pdf.draw(rendered, in: box)
            } else { draw(text, in: pdf) }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }
    private static func draw(_ text: String, in context: CGContext) {
        context.textMatrix = .identity
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 15, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 40, y: 30, width: 515, height: 782), transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}
