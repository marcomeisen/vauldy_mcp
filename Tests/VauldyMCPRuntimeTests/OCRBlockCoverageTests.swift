import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import VauldyCore

@Suite("Local text blocks and visual coverage")
struct OCRBlockCoverageTests {
    @Test func columnsAndDistantParagraphsKeepSeparateBlocks() throws {
        let boxes = [CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.03), CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.03),
                     CGRect(x: 0.1, y: 0.75, width: 0.28, height: 0.03), CGRect(x: 0.6, y: 0.75, width: 0.29, height: 0.03),
                     CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.03)]
        var geometry = LocalOCRGeometry.vision(texts: ["Links oben", "Rechts oben", "Links unten", "Rechts unten", "Fusszeile"],
            bounds: boxes, confidences: Array(repeating: 1, count: boxes.count))
        geometry.formBlocks()
        let blocks = try #require(geometry.blocks)
        #expect(blocks.map(\.lineIndices) == [[0, 2], [1, 3], [4]])
        #expect(blocks[0].bounds == boxes[0].union(boxes[2]))
    }

    @Test func blockBoundsCannotHideAnUnrecognizedLine() throws {
        let lines = LocalOCRGeometry.vision(texts: ["Obere Zeile", "Untere Zeile"],
            bounds: [CGRect(x: 0.1, y: 0.7, width: 0.6, height: 0.04), CGRect(x: 0.1, y: 0.61, width: 0.6, height: 0.04)],
            confidences: [1, 1]).lines
        #expect(try #require(OCRTextBlocks.make(lines)).count == 1)
        let chars = (0..<10).map { CGRect(x: 0.1 + Double($0) * 0.02, y: 0.66, width: 0.01, height: 0.02) }
        let gap = LocalOCRVisualCoverage.compare(characters: [chars], lines: lines)
        #expect(gap.status == .checked && gap.needsReview)
        #expect(gap.regions[0].coveredCharacters == 0)
        let covered = LocalOCRVisualCoverage.compare(characters: [chars],
            lines: LocalOCRGeometry.vision(texts: ["Gefundene Zeile"],
                bounds: [CGRect(x: 0.1, y: 0.65, width: 0.3, height: 0.04)], confidences: [1]).lines)
        #expect(!covered.needsReview && covered.regions[0].coveredCharacters == 10)
        let shortGap = LocalOCRVisualCoverage.compare(characters: [chars],
            lines: LocalOCRGeometry.vision(texts: ["Teilweise"],
                bounds: [CGRect(x: 0.1, y: 0.65, width: 0.15, height: 0.04)], confidences: [1]).lines)
        #expect(shortGap.regions[0].coveredCharacters == 8 && !shortGap.needsReview)
    }

    @Test func limitsAndLegacyMetadataStayExplicit() throws {
        let old = Data(#"{"coordinateSpace":"uprightImageBottomLeft","rotationDegrees":0,"configuration":"v8","lines":[]}"#.utf8)
        let geometry = try JSONDecoder().decode(LocalOCRGeometry.self, from: old)
        #expect(geometry.blocks == nil && geometry.coverage == nil)
        let chars = (0..<5).map { CGRect(x: 0.1 + Double($0) * 0.02, y: 0.5, width: 0.01, height: 0.02) }
        let limited = LocalOCRVisualCoverage.compare(characters: Array(repeating: chars, count: 129), lines: [])
        #expect(limited.status == .limited && limited.regions.count == 128 && limited.needsReview)
        #expect(!LocalOCRVisualCoverage.compare(characters: [], lines: []).needsReview)
        #expect(LocalOCRVisualCoverage(status: .unavailable, regions: []).needsReview)
    }

    @Test(arguments: [0, 1]) func visibleVectorBodyMissingFromEmbeddedTextIsFlagged(sample: Int) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fields = sample == 0 ? ["Beitrag: 49,99 EUR", "Beginn: 27.01.2026", "Versicherungsart: Hausrat"]
            : ["Rechnungsbetrag: 82,47 EUR", "Zahlbar bis: 19.08.2027", "Leistung: Wartung"]
        let file = root.appendingPathComponent("missing-\(sample).pdf")
        let bytes = try PDFVectorTextOCRTests().fixture(fields: fields, freePaths: true)
        try bytes.write(to: file)
        let previous = try #require(try await NativeLocalDocumentOCR(baseline: true).recognize(file: file) { _ in }.pages.first)
        let current = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, regionRecovery: false).recognize(file: file) { _ in }.pages.first)
        #expect(previous.info.method == .embeddedText && !previous.info.needsReview)
        #expect(current.info.method == .embeddedText && current.info.needsReview)
        #expect(current.text == previous.text && !fields.contains(where: current.text.contains))
        let coverage = try #require(current.geometry?.coverage)
        #expect(coverage.status == .checked && coverage.regions.contains(where: \.needsReview))
        #expect(current.geometry?.blocks?.isEmpty == false)
        print("OCR-COVERAGE sample=\(sample) prior-review=\(previous.info.needsReview) review=\(current.info.needsReview) "
              + "regions=\(coverage.regions.count) gaps=\(coverage.regions.filter(\.needsReview).count) ms=\(current.info.metrics?.coverageMilliseconds ?? 0)")
        #expect(try Data(contentsOf: file) == bytes)
        if let path = ProcessInfo.processInfo.environment["VAULDY_OCR_COVERAGE_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try bytes.write(to: output.appendingPathComponent("missing-\(sample).pdf"))
        }
    }

    @Test func rectanglesAndChartBarsDoNotCreateTextGapWarnings() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("graphics.pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(url: file as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 730)
        let text = "Synthetischer Beleg fuer die lokale Dokumentenpruefung"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 17, nil)]))
        CTLineDraw(line, context)
        context.setFillColor(gray: 0.25, alpha: 1)
        for (index, height) in [40, 130, 80, 180].enumerated() {
            context.fill(CGRect(x: 80 + index * 90, y: 170, width: 45, height: height))
        }
        context.setStrokeColor(gray: 0, alpha: 1)
        context.stroke(CGRect(x: 60, y: 150, width: 450, height: 300))
        context.endPDFPage(); context.closePDF()
        let page = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        let coverage = try #require(page.geometry?.coverage)
        #expect(page.info.method == .embeddedText && !page.info.needsReview)
        #expect(coverage.status == .checked && !coverage.needsReview && !coverage.regions.isEmpty)
    }

    @Test func reviewExplainsTheGapAndDoesNotCacheAnIncompletePage() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("missing.pdf")
        try PDFVectorTextOCRTests().fixture(fields: ["Beitrag: 82,47 EUR", "Beginn: 27.01.2026"], freePaths: true,
            embeddedFields: ["Beitrag: 49,99 EUR"]).write(to: file)
        let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
        let outcome = try await LocalImportService(store: store).importFile(file)
        #expect(outcome.state == .partial)
        let document = try #require(try await store.document(id: outcome.documentID))
        let review = try #require(LocalDocumentReview(document))
        #expect(review.pages[0].needsReview && review.pages[0].reason.contains("Textbereiche"))
        #expect(review.pages[0].layout?.geometry.coverage?.needsReview == true)
        _ = try await LocalImportService(store: store).retry(documentID: document.id)
        let repeated = try #require(try await store.document(id: document.id))
        #expect(repeated.localImport?.pages[0].metrics?.cacheHit == false)
    }

    @Test func oldLineOnlyCheckpointIsNotAVisualCoverageResult() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("missing.pdf"), cache = root.appendingPathComponent("cache")
        try PDFVectorTextOCRTests().fixture(fields: ["Beitrag: 49,99 EUR", "Beginn: 27.01.2026"], freePaths: true).write(to: file)
        var previous = try #require(try await NativeLocalDocumentOCR(baseline: true).recognize(file: file) { _ in }.pages.first)
        let oldConfiguration = "ocr-v8-source-line-geometry-" + ProcessInfo.processInfo.operatingSystemVersionString
        previous.geometry?.configuration = oldConfiguration
        previous.geometry?.blocks = nil
        previous.geometry?.coverage = nil
        try LocalOCRPageCache(root: cache, file: file, configuration: oldConfiguration).save(previous)
        let current = try #require(try await NativeLocalDocumentOCR(cacheRoot: cache).recognize(file: file) { _ in }.pages.first)
        #expect(current.info.metrics?.cacheHit == false && !current.info.needsReview)
        #expect(current.geometry?.coverage?.needsReview == false)
        #expect(current.text.contains("Beitrag: 49,99 EUR") && current.text.contains("Beginn: 27.01.2026"))
    }

    @Test func corruptBlockReferencesAndCoverageCountsCannotBind() {
        var page = LocalOCRPage(info: .init(page: 1, method: .vision), text: "Synthetischer Text")
        page.geometry = .vision(texts: [page.text], bounds: [CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.04)], confidences: [1])
        page.geometry?.configuration = "synthetic"
        page.geometry?.blocks = [.init(lineIndices: [99], bounds: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.04))]
        #expect(LocalOCRPageLayout(sourceHash: String(repeating: "a", count: 64), page: page) == nil)
        page.geometry?.formBlocks()
        page.geometry?.coverage = .init(status: .checked, regions: [.init(bounds: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.04),
            detectedCharacters: 4, coveredCharacters: 5)])
        #expect(LocalOCRPageLayout(sourceHash: String(repeating: "a", count: 64), page: page) == nil)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-coverage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
