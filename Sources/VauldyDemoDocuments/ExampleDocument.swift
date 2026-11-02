import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Deliberately synthetic originals for onboarding and genuine OCR verification. No stored OCR fixtures.
public enum ExampleDocument {
    public static let pageOne = ["Beispielrechnung Fahrradwartung", "Fahrradwerkstatt Nord", "Dokumentdatum: 27.01.2026",
                                 "Fahrradwartung und Bremsenpruefung: 49,99 EUR.", "Name: Erika Musterfrau", "E-Mail: erika@example.com"]
    public static let pageTwo = ["Servicebericht zur Fahrradwartung", "Die Bremsen wurden geprueft und eingestellt.",
                                 "Zweite Seite: Werkstattbeleg 8246.", "Name: Erika Musterfrau", "E-Mail: erika@example.com"]
    public static func writePDF(to url: URL, scanned: Bool = false, blankLastPage: Bool = false) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (index, lines) in [pageOne, pageTwo].enumerated() {
            context.beginPDFPage(nil)
            if index == 1 || scanned { context.draw(try raster(lines), in: box) }
            else { draw(lines, into: context) }
            context.endPDFPage()
        }
        if blankLastPage { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
    }
    public static func writePNG(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, try raster(pageOne), nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
    private static func raster(_ lines: [String]) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 1190, height: 1684, bitsPerComponent: 8, bytesPerRow: 1190 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1190, height: 1684))
        context.scaleBy(x: 2, y: 2); draw(lines, into: context)
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
    private static func draw(_ lines: [String], into context: CGContext) {
        context.textMatrix = .identity
        let font = CTFontCreateWithName("Helvetica" as CFString, 17, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        for (index, text) in lines.enumerated() {
            context.textPosition = CGPoint(x: 40, y: 780 - index * 40)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
    }
}

extension ExampleDocument {
    /// Raster footer outside the embedded text, for checking hybrid coverage without discarding the image.
    public static func writeHybridPDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil); draw(pageOne, into: context)
        guard let imageContext = CGContext(data: nil, width: 800, height: 180, bitsPerComponent: 8, bytesPerRow: 3200,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        imageContext.setFillColor(CGColor(gray: 1, alpha: 1)); imageContext.fill(CGRect(x: 0, y: 0, width: 800, height: 180))
        imageContext.textPosition = CGPoint(x: 20, y: 80)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 38, nil)]
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Zusatzbetrag 12,34 EUR", attributes: attributes)), imageContext)
        guard let image = imageContext.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        context.draw(image, in: CGRect(x: 40, y: 100, width: 400, height: 90))
        context.endPDFPage(); context.closePDF()
    }
    public static func writeFormPDF(to url: URL) throws {
        let text = "BT /F1 14 Tf 30 160 Td (Text aus PDF-Form: Rechnung Fahrradwartung 49,99 EUR.) Tj ET"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 200] /Resources << /XObject << /Fm 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length 6 >>\nstream\n/Fm Do\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 600 200] /Resources << /Font << /F1 6 0 R >> >> /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        var data = Data("%PDF-1.4\n".utf8); var offsets: [Int] = [0]
        for (i, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(i+1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 7\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url)
    }
}

extension ExampleDocument {
    public static func writeLongReceiptPNG(to url: URL) throws {
        guard let context = CGContext(data: nil, width: 600, height: 4200, bitsPerComponent: 8, bytesPerRow: 2400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 4200))
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 28, nil)]
        for (text, y) in [("Beleganfang Fahrradwartung 49,99 EUR", 4100), ("Belegmitte Datum 27.01.2026", 2100), ("Belegende Referenz 8246 bezahlt", 100)] {
            context.textPosition = CGPoint(x: 20, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
