import Foundation
import CoreGraphics
import CoreText
import Vision
import Testing
@testable import VauldyCore

@Suite("Source-bound numeric punctuation and raised metre units")
struct OCRNumericRecoveryTests {
    struct Corpus: Decodable {
        struct Case: Decodable {
            struct Page: Decodable {
                struct Field: Decodable { let text: String }
                struct Table: Decodable { struct Cell: Decodable { let text: String }; let cells: [Cell] }
                let fields: [Field]; let tables: [Table]
            }
            let id: String; let file: String; let sha256: String
            let pages: [Page]; let baseline: [LocalOCRPage]
        }
        let cases: [Case]
    }
    @Test func frozenPDFsKeepEveryPriorFieldAndCellAndRepairNumericSpelling() async throws {
        let manifest = try #require(Bundle.module.url(forResource: "ocr-numeric-recovery-corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: manifest))
        for item in corpus.cases {
            let file = try #require(Bundle.module.url(forResource: String(item.file.dropLast(4)), withExtension: "pdf"))
            let bytes = try Data(contentsOf: file)
            #expect(LocalOriginalAccess.hash(bytes) == item.sha256)
            let pages = try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages
            #expect(pages.count == item.baseline.count)
            for (index, page) in pages.enumerated() {
                let before = item.baseline[index], truth = item.pages[index]
                let fresh = EvidencePreservingLocalOCR.preserving(previous: before, candidate: page)
                #expect(fresh.text == page.text, Comment(rawValue: item.id + " fresh " + String(index + 1)))
                #expect(EvidencePreservingLocalOCR.preserving(previous: fresh, candidate: page).text == page.text)
                for field in truth.fields where before.text.contains(field.text) {
                    #expect(page.text.contains(field.text), Comment(rawValue: field.text))
                }
                let cells = truth.tables.flatMap(\.cells).map(\.text).filter { !$0.isEmpty }
                for cell in Set(cells) {
                    let expected = cells.filter { $0 == cell }.count
                    #expect(occurrences(cell, in: page.text) >= expected, Comment(rawValue: item.id + " " + cell))
                }
                let history = page.geometry?.lines.flatMap { $0.priorReadings ?? [] } ?? []
                var remaining = page.text.components(separatedBy: .newlines) + history
                for line in before.text.components(separatedBy: .newlines) {
                    if let found = remaining.firstIndex(of: line) { remaining.remove(at: found) }
                    else { Issue.record(Comment(rawValue: "Lost literal evidence: " + line)) }
                }
                #expect((page.info.metrics?.fieldRetries ?? 0) <= 8)
                #expect((page.info.metrics?.fieldRetryPixels ?? 0) <= 8_000_000)
                #expect(LocalOCRPageLayout(sourceHash: item.sha256, page: fresh) != nil)
                if let root = ProcessInfo.processInfo.environment["VAULDY_OCR_NUMERIC_RESULTS"] {
                    let folder = URL(fileURLWithPath: root); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try JSONEncoder().encode(fresh).write(to: folder.appendingPathComponent("\(item.id)-p\(index+1).fresh.json"))
                }
            }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
    @Test func onlyMalformedSeparatorsAndEquivalentMoneyPresentationMayChange() {
        for (old, new) in [("1,500,00€", "1.500,00 €"), ("1.635.3", "1.635,3"), ("45,00€", "45,00 €"),
                           ("- 1.284,37 €", "-1.284,37 €"), ("€ 2,50", "2,50 €"), ("86,240 m", "86,240 m³"), ("117,960 m3", "117,960 m³")] {
            #expect(OCRNumericRefinement.needsRetry(old))
            #expect(OCRNumericRefinement.permits(old, new))
        }
        for (old, new) in [("1.234,56 €", "1,234.56 €"), ("1,234.56 €", "1.234,56 €"), ("1.234", "1,234"),
                           ("82.47 EUR", "82,47 EUR"), ("1,500,00€", "1.500,01 €"), ("- 1.284,37 €", "1.284,37 €"),
                           ("12€34", "1234 €"), ("2,50€", "2,50"), ("86,240 m2", "86,240 m³"), ("86,240 m³", "86,240 m²"),
                           ("86,240 m", "86,241 m³"), ("1.635.3", "1635,3")] {
            #expect(!OCRNumericRefinement.permits(old, new), Comment(rawValue: old + " -> " + new))
        }
        #expect(OCRNumericRefinement.money("€2,50") == "€ 2,50")
        #expect(OCRNumericRefinement.money("- 2,50€") == "-2,50 €")
        #expect(!OCRNumericRefinement.needsRetry("12,34 m³"))
    }
    @Test func sourceExponentsAreReadAndBaselineDigitsAreNotRaised() throws {
        for digit in ["²", "³"] {
            let original = try image("12,345 m" + digit)
            let normal = try #require(OCRMetreGlyphs.normalize(original))
            #expect(normal.width >= original.width)
            let table = try metreTable("12,345 m" + digit)
            let grid = OCRRuledTable.Grid(rows: [10, 75, 140], columns: [10, 220, 440, 710])
            for gap in [8, 10] {
                let view = try #require(try OCRTableContext.make(table, grid: grid, row: 1, scale: 3,
                    unitColumns: [1], cellGap: gap, check: {}))
                #expect(view.cells.first(where: { $0.column == 1 })?.raisedMetreUnit == true)
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["de-DE", "en-US"]; request.usesLanguageCorrection = false
                request.automaticallyDetectsLanguage = true; request.minimumTextHeight = 0
                try VNImageRequestHandler(cgImage: view.image).perform([request])
                let readings = OCRTableContext.readings(request.results ?? [], in: view)
                #expect((readings[1]?.confidence ?? 0) >= 0.95)
                #expect(readings[1]?.text == "12,345 m" + digit)
            }
        }
        for value in ["12,345 m", "12,345 m3", "12,345 m2", "", "12345"] {
            #expect(OCRMetreGlyphs.normalize(try image(value)) == nil)
        }
    }
    @Test func whitespacePresentationRetainsUncertaintyAndCannotSmuggleNumericChanges() {
        func page(_ text: String, confidence: Double, prior: [String]? = nil) -> LocalOCRPage {
            var page = LocalOCRPage(info: .init(page: 1, method: .vision, confidence: confidence, needsReview: true), text: text)
            page.geometry = .vision(texts: [text], bounds: [CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.1)], confidences: [confidence])
            page.geometry?.configuration = LocalOCRPageCache.configuration
            page.geometry?.lines[0].priorReadings = prior
            return page
        }
        let old = page("-12,34€", confidence: 0.3)
        let formatted = page("-12,34 €", confidence: 0.3, prior: [old.text])
        let kept = EvidencePreservingLocalOCR.preserving(previous: old, candidate: formatted)
        #expect(kept.text == formatted.text && kept.geometry?.lines[0].confidence == 0.3 && kept.info.needsReview)
        for text in ["12,34 €", "-12.34 €", "-12,35 €", "€ -12,34"] {
            #expect(EvidencePreservingLocalOCR.preserving(previous: old,
                candidate: page(text, confidence: 0.3, prior: [old.text])).text == old.text)
        }
        #expect(EvidencePreservingLocalOCR.preserving(previous: old,
            candidate: page(formatted.text, confidence: 0.3)).text == old.text)
        #expect(!OCRNumericRefinement.isPresentationChange("€ 2,50", "2,50 €"))
    }
    private func metreTable(_ value: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 720, height: 150, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 720, height: 150))
        context.setStrokeColor(gray: 0, alpha: 1); context.setLineWidth(1)
        for x in [10, 220, 440, 710] { context.move(to: CGPoint(x: x, y: 10)); context.addLine(to: CGPoint(x: x, y: 140)) }
        for y in [10, 75, 140] { context.move(to: CGPoint(x: 10, y: y)); context.addLine(to: CGPoint(x: 710, y: y)) }
        context.strokePath()
        let font = CTFontCreateWithName("ArialMT" as CFString, 26, nil)
        for (text, x) in [("Messung", 25), (value, 235), ("Kontrolle", 455)] {
            let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: x, y: 32); CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        return try #require(context.makeImage())
    }
    private func occurrences(_ needle: String, in text: String) -> Int {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let pattern = #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: needle) + #"(?!\w)"#
        return (try! NSRegularExpression(pattern: pattern)).numberOfMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
    }
    private func image(_ text: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 300, height: 80, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 300, height: 80))
        let font = CTFontCreateWithName("ArialMT" as CFString, 26, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 25, y: 30); CTLineDraw(CTLineCreateWithAttributedString(string), context)
        return try #require(context.makeImage())
    }
}
