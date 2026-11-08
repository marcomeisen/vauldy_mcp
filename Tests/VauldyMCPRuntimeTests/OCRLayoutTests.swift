import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import VauldyDemoDocuments
@testable import VauldyCore

@Suite("Source-bound OCR line geometry")
struct OCRLayoutTests {
    private let top = "OBEN HAUSRAT SICHERHEIT 49,99 EUR"
    private let bottom = "UNTEN WARTUNG SERVICE 82,47 EUR"

    @Test func legacyPagesDecodeAndBindingsRejectStaleOrInvalidGeometry() throws {
        let old = Data(#"{"info":{"page":1,"method":"vision","elapsedMilliseconds":0,"needsReview":false},"text":"Altbestand"}"#.utf8)
        let decoded = try JSONDecoder().decode(LocalOCRPage.self, from: old)
        #expect(decoded.geometry == nil && decoded.info.layout == nil)
        var page = LocalOCRPage(info: .init(page: 1, method: .vision), text: "Hausrat 🚲\nBeitrag 49,99 EUR")
        page.geometry = .vision(texts: ["Hausrat 🚲", "Beitrag 49,99 EUR"],
            bounds: [CGRect(x: 0.1, y: 0.7, width: 0.6, height: 0.05), CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.05)],
            confidences: [0.9, 0.9])
        page.geometry?.configuration = "synthetic-config"
        let hash = String(repeating: "a", count: 64)
        let bound = try #require(LocalOCRPageLayout(sourceHash: hash, page: page))
        #expect(bound.matches(sourceHash: hash, page: 1, text: page.text, configuration: "synthetic-config"))
        #expect(!bound.matches(sourceHash: "other", page: 1, text: page.text, configuration: "synthetic-config"))
        #expect(!bound.matches(sourceHash: hash, page: 2, text: page.text, configuration: "synthetic-config"))
        #expect(!bound.matches(sourceHash: hash, page: 1, text: page.text + "!", configuration: "synthetic-config"))
        #expect(!bound.matches(sourceHash: hash, page: 1, text: page.text, configuration: "other"))
        #expect(try JSONDecoder().decode(LocalOCRPageLayout.self, from: JSONEncoder().encode(bound)) == bound)
        page.geometry?.lines[0].bounds.origin.x = -0.2
        #expect(LocalOCRPageLayout(sourceHash: hash, page: page) == nil)
        page.geometry?.lines[0].bounds.origin.x = 0.1
        page.geometry?.lines[0].location = 9 // Inside the emoji's surrogate pair.
        page.geometry?.lines[0].length = 1
        #expect(LocalOCRPageLayout(sourceHash: hash, page: page) == nil)
    }

    @Test(arguments: [false, true], [0, 90, 180, 270])
    func pdfCoordinatesSurviveCropRotationAndRasterization(raster: Bool, rotation: Int) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("page.pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(url: file as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        if raster { context.draw(try image(width: 600, height: 800, upper: 550, lower: 170), in: media) }
        else { draw(top, at: CGPoint(x: 90, y: 550), in: context); draw(bottom, at: CGPoint(x: 90, y: 170), in: context) }
        context.endPDFPage(); context.closePDF()
        let pdf = try #require(PDFDocument(url: file)), source = try #require(pdf.page(at: 0))
        source.setBounds(CGRect(x: 40, y: 60, width: 500, height: 650), for: .cropBox)
        source.rotation = rotation
        #expect(pdf.write(to: file))
        let bytes = try Data(contentsOf: file)
        let page = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        let geometry = try #require(page.geometry)
        #expect(geometry.coordinateSpace == .pdfCropBottomLeft && geometry.rotationDegrees == rotation)
        try check(page, word: "OBEN", expectedY: 0.77)
        try check(page, word: "UNTEN", expectedY: 0.19)
        #expect(LocalOCRPageLayout(sourceHash: LocalOriginalAccess.hash(bytes), page: page) != nil)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test(arguments: [900, 3600]) func imageCoordinatesSurviveWhiteMarginsAndTiles(height: Int) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("page.png")
        let upper = height - 220, lower = 150
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: 600, height: height, upper: upper, lower: lower), nil)
        #expect(CGImageDestinationFinalize(destination))
        let page = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        #expect(page.geometry?.coordinateSpace == .uprightImageBottomLeft)
        try check(page, word: "OBEN", expectedY: Double(upper + 10) / Double(height))
        try check(page, word: "UNTEN", expectedY: Double(lower + 10) / Double(height))
    }

    @Test func storedLayoutIsSourceBoundAndHiddenWhenTextOrOriginalChanges() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mixed.pdf")
        try ExampleDocument.writePDF(to: file, blankLastPage: true)
        let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
        let imported = try await LocalImportService(store: store).importFile(file)
        var document = try #require(try await LocalDocumentStore(root: store.root).document(id: imported.documentID))
        let review = try #require(LocalDocumentReview(document))
        let hash = try #require(document.localImport?.contentHash)
        for index in [0, 1] {
            let page = review.pages[index], text = try #require(page.text), layout = try #require(page.layout)
            #expect(layout.matches(sourceHash: hash, page: index + 1, text: text, configuration: LocalOCRPageCache.configuration))
        }
        #expect(review.pages[2].layout == nil)
        document.ocrText += "\nNeue ungebundene Zeile"
        document.localImport?.originalState = .changed
        #expect(LocalDocumentReview(document)?.pages.allSatisfy { $0.layout == nil } == true)
        _ = try await LocalImportService(store: store).retry(documentID: imported.documentID)
        let repeated = try #require(try await store.document(id: imported.documentID))
        let repeatedReview = try #require(LocalDocumentReview(repeated))
        #expect(repeated.localImport?.pages.allSatisfy { $0.metrics?.cacheHit == true } == true)
        #expect(repeatedReview.pages[0].layout == review.pages[0].layout)
        #expect(repeatedReview.pages[1].layout == review.pages[1].layout)
    }

    @Test func hybridPageCombinesEmbeddedAndRasterLineOffsets() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hybrid.pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(url: file as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        draw(top, at: CGPoint(x: 90, y: 680), in: context)
        draw("Synthetischer Beleg zur Seitenpruefung", at: CGPoint(x: 90, y: 640), in: context)
        let raster = try #require(CGContext(data: nil, width: 450, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        raster.setFillColor(gray: 1, alpha: 1); raster.fill(CGRect(x: 0, y: 0, width: 450, height: 120))
        draw(bottom, at: CGPoint(x: 10, y: 45), in: raster)
        context.draw(try #require(raster.makeImage()), in: CGRect(x: 80, y: 150, width: 450, height: 120))
        context.endPDFPage(); context.closePDF()
        let page = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        #expect(page.info.method == .embeddedTextAndVision)
        try check(page, word: "OBEN", expectedY: 0.86)
        try check(page, word: "UNTEN", expectedY: 0.25)
        let geometry = try #require(page.geometry)
        #expect(geometry.lines.contains { $0.method == .embeddedText })
        #expect(geometry.lines.contains { $0.method == .vision })
        #expect(LocalOCRPageLayout(sourceHash: String(repeating: "b", count: 64), page: page) != nil)
    }

    @Test func tallPDFRegionsKeepPhysicalPageCoordinates() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tall.pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 3600)
        let consumer = try #require(CGDataConsumer(url: file as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.draw(try image(width: 600, height: 3600, upper: 3380, lower: 150), in: media)
        context.endPDFPage(); context.closePDF()
        let page = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        #expect((page.info.metrics?.recognitionRegions ?? 0) > 1)
        try check(page, word: "OBEN", expectedY: 3390.0 / 3600)
        try check(page, word: "UNTEN", expectedY: 160.0 / 3600)
    }

    @Test func rewrittenSourcePageMarkersCannotKeepOldOffsets() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.pdf")
        try ExampleDocument.writePDF(to: file)
        let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
        let imported = try await LocalImportService(store: store, ocr: MarkerOCR()).importFile(file)
        let document = try #require(try await store.document(id: imported.documentID))
        #expect(document.ocrText.contains("[Seitenhinweis im Originaltext]"))
        #expect(document.localImport?.pages.first?.layout == nil)
    }

    private struct MarkerOCR: LocalDocumentOCR {
        func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
            let lines = ["Hausrat 49,99 EUR", "--- Seite 2 ---"]
            var page = LocalOCRPage(info: .init(page: 1, method: .vision), text: lines.joined(separator: "\n"))
            page.geometry = .vision(texts: lines, bounds: [CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.1),
                CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.1)], confidences: [1, 1])
            page.geometry?.configuration = LocalOCRPageCache.configuration
            return .init(pages: [page])
        }
    }

    private func check(_ page: LocalOCRPage, word: String, expectedY: Double) throws {
        let geometry = try #require(page.geometry)
        let line = try #require(geometry.lines.first { line in
            let value = (page.text as NSString).substring(with: NSRange(location: line.location, length: line.length))
            return value.contains(word)
        })
        #expect(abs(Double(line.bounds.midY) - expectedY) < 0.05,
                Comment(rawValue: "\(word) bounds=\(line.bounds) expectedY=\(expectedY)"))
        #expect(line.bounds.minX >= 0 && line.bounds.maxX <= 1 && line.bounds.width > 0.3)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func image(width: Int, height: Int, upper: Int, lower: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(top, at: CGPoint(x: 90, y: upper), in: context)
        draw(bottom, at: CGPoint(x: 90, y: lower), in: context)
        return try #require(context.makeImage())
    }

    private func draw(_ text: String, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 23, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
