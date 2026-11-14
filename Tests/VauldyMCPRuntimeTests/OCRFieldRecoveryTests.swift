import Foundation
import CoreGraphics
import CoreText
import Vision
import Testing
@testable import VauldyCore

@Suite("Source-bound identifiers, table values and units")
struct OCRFieldRecoveryTests {
    struct Corpus: Decodable {
        struct Case: Decodable {
            struct Page: Decodable {
                struct Field: Decodable { let text: String }
                let fields: [Field]
                let text: String
            }
            let id: String; let file: String; let sha256: String
            let pages: [Page]; let baseline: [LocalOCRPage]
        }
        let cases: [Case]
    }

    @Test func frozenPDFsRepairEveryReportedExampleWithoutLosingPriorFieldsOrEvidence() async throws {
        let url = try #require(Bundle.module.url(forResource: "ocr-field-recovery-corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        for item in corpus.cases {
            let file = try #require(Bundle.module.url(forResource: String(item.file.dropLast(4)), withExtension: "pdf"))
            let bytes = try Data(contentsOf: file)
            #expect(LocalOriginalAccess.hash(bytes) == item.sha256)
            let pages = try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages
            #expect(pages.count == item.baseline.count && pages.count == item.pages.count)
            for (index, page) in pages.enumerated() {
                let old = item.baseline[index], truth = item.pages[index]
                let fresh = EvidencePreservingLocalOCR.preserving(previous: old, candidate: page)
                let previousFields = truth.fields.filter { old.text.contains($0.text) }
                #expect(previousFields.allSatisfy { page.text.contains($0.text) && fresh.text.contains($0.text) })
                #expect(fresh.text == page.text)
                let history = Set(fresh.geometry?.lines.flatMap { $0.priorReadings ?? [] } ?? [])
                let current = Set(fresh.text.components(separatedBy: .newlines))
                #expect(old.text.components(separatedBy: .newlines).allSatisfy { current.contains($0) || history.contains($0) })
                #expect((page.info.metrics?.fieldRetries ?? 0) <= 8)
                #expect((page.info.metrics?.fieldRetryPixels ?? 0) <= 8_000_000)
                let layout = try #require(LocalOCRPageLayout(sourceHash: item.sha256, page: fresh))
                #expect(layout.matches(sourceHash: item.sha256, page: index + 1, text: fresh.text,
                                       configuration: LocalOCRPageCache.configuration))
            }
            if item.id == "doc-001" {
                #expect(pages[1].text.contains("Fahrgestellnummer: TESTWVWZZZ26K08417"))
                #expect(pages[1].geometry?.lines.contains { $0.priorReadings?.contains("Fahrgestellnummer: TESTWWZZZ26K08417") == true } == true)
            } else if item.id == "doc-004" {
                for row in ["Wohnung 3 beide Schließzylinder", "Keller 1 gekennzeichnet", "Briefkasten 0 Nachlieferung vereinbart"] {
                    #expect(pages[2].text.contains(row), Comment(rawValue: row))
                }
                #expect(pages[2].info.metrics?.recoveredTableRows == 3)
            } else if item.id == "doc-009" {
                let lines = pages[1].text.components(separatedBy: .newlines)
                for unit in ["g/dl", "10³/µl", "mg/l"] { #expect(lines.contains(unit), Comment(rawValue: unit)) }
                #expect(lines.filter { $0 == "mg/dl" }.count == 2)
                #expect(pages[1].info.metrics?.fieldRepairs == 3)
            }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func validValuesAndDigitChangesCannotBeOverwritten() {
        let old = "Fahrgestellnummer: TESTWWZZZ26K08417", correct = "Fahrgestellnummer: TESTWVWZZZ26K08417"
        #expect(OCRFieldRefinement.permitsVehicleRepair(old, correct))
        #expect(!OCRFieldRefinement.permitsVehicleRepair(correct, "Fahrgestellnummer: TESTWVWZZZ26K08418"))
        #expect(!OCRFieldRefinement.permitsVehicleRepair(old, "Fahrgestellnummer: TESTWWZZZ026K08417"))
        #expect(!OCRFieldRefinement.permitsVehicleRepair(old, "Fahrgestellnummer: TESTWIWZZZ26K08417"))
        #expect(!OCRFieldRefinement.permitsVehicleRepair(old, "Auftragsnummer: TESTWVWZZZ26K08417"))
        #expect(OCRFieldRefinement.permitsUnitRepair("g/dI", "g/dl"))
        #expect(OCRFieldRefinement.permitsUnitRepair("mg/1", "mg/l"))
        #expect(OCRFieldRefinement.permitsUnitRepair("10/u1", "10³/µl"))
        for unit in ["g/dl", "mg/l", "mg/dl", "10²/µl", "10³/µl", "10⁶/µl"] {
            #expect(!OCRFieldRefinement.needsUnitRetry(unit))
            #expect(!OCRFieldRefinement.permitsUnitRepair(unit, "mg/l"))
        }
        #expect(!OCRFieldRefinement.permitsUnitRepair("mg/1", "g/l"))
        #expect(!OCRFieldRefinement.permitsUnitRepair("10/u1", "100³/µl"))
        #expect(!OCRFieldRefinement.permitsUnitRepair("10²/u1", "10³/µl"))
        #expect(!OCRFieldRefinement.permits("Beitrag: 82.47 EUR", "Beitrag: 82,47 EUR"))
        #expect(!OCRFieldRefinement.permits("Rechnungsnummer: 4711", "Rechnungsnummer: 4717"))
    }

    @Test func typographyRestoresOnlyReadDigitsAndRequiresRaisedGlyphAndDescender() throws {
        for (read, expected) in [("102/ul", "10²/µl"), ("103/ul", "10³/µl"), ("106/ul", "10⁶/µl")] {
            #expect(OCRUnitGlyphs.restore(read) == expected)
        }
        #expect(OCRUnitGlyphs.restore("10/ul") == nil)
        #expect(OCRUnitGlyphs.restore("103/pl") == nil)
        for text in ["103/ul", "10³/ul", "103/µl", "", "123456"] {
            #expect(OCRUnitGlyphs.normalize(try textImage(text)) == nil, Comment(rawValue: text))
        }
    }

    @Test func emptyOrUnruledImagesDoNotBecomeTablesAndCancellationPropagates() throws {
        for text in ["", "Fahrgestellnummer: WXYZ", "1 2 3 4", "g/dl"] {
            let image = try textImage(text)
            #expect(try OCRRuledTable.detect(image, check: {}).isEmpty)
            #expect(throws: CancellationError.self) { try OCRRuledTable.detect(image, check: { throw CancellationError() }) }
        }
    }

    @Test func differentSourceExponentsAndEmptyCellsAreNotGuessed() throws {
        for (digit, expected) in [("2", "10²/µl"), ("6", "10⁶/µl")] {
            let image = try unitTable(digit: digit, raised: true, denominator: "µl")
            let grids = try OCRRuledTable.detect(image, check: {})
            let grid = try #require(grids.first)
            for scale in [2, 3] {
                let view = try #require(try OCRTableContext.make(image, grid: grid, row: 1, scale: scale,
                    unitColumns: [1], check: {}))
                #expect(view.cells.first(where: { $0.column == 1 })?.raisedMicroUnit == true)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.recognitionLanguages = ["de-DE", "en-US"]
                request.usesLanguageCorrection = false; request.minimumTextHeight = 0
                try VNImageRequestHandler(cgImage: view.image).perform([request])
                let values = OCRTableContext.readings(request.results ?? [], in: view)
                #expect(values[1]?.text == expected)
                #expect((values[1]?.confidence ?? 0) >= 0.95)
                #expect(values[0]?.text == "Messung")
                #expect(values[2]?.text == "Kontrolle")
            }
        }
        for (digit, raised, denominator) in [("3", false, "ul"), ("3", true, "ul"), ("3", false, "µl"), ("", false, ""), ("3", true, "pl")] {
            let image = try unitTable(digit: digit, raised: raised, denominator: denominator)
            let grids = try OCRRuledTable.detect(image, check: {})
            let grid = try #require(grids.first)
            let view = try #require(try OCRTableContext.make(image, grid: grid, row: 1, scale: 2,
                unitColumns: [1], check: {}))
            if denominator != "pl" { #expect(view.cells.allSatisfy { !$0.raisedMicroUnit }) }
            if digit.isEmpty { #expect(!view.cells.contains { $0.column == 1 }) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = false; request.minimumTextHeight = 0
            try VNImageRequestHandler(cgImage: view.image).perform([request])
            let values = OCRTableContext.readings(request.results ?? [], in: view)
            #expect(values[1]?.text != "10³/µl")
            if digit.isEmpty { #expect(values[1] == nil) }
        }
    }

    private func unitTable(digit: String, raised: Bool, denominator: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 720, height: 150, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 720, height: 150))
        context.setStrokeColor(gray: 0, alpha: 1); context.setLineWidth(1)
        for x in [10, 220, 440, 710] { context.move(to: CGPoint(x: x, y: 10)); context.addLine(to: CGPoint(x: x, y: 140)) }
        for y in [10, 75, 140] { context.move(to: CGPoint(x: 10, y: y)); context.addLine(to: CGPoint(x: 710, y: y)) }
        context.strokePath()
        func draw(_ text: String, x: CGFloat, y: CGFloat = 32, size: CGFloat = 26) -> CGFloat {
            let font = CTFontCreateWithName("ArialMT" as CFString, size, nil)
            let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            let line = CTLineCreateWithAttributedString(string)
            context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, context)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        _ = draw("Messung", x: 25); _ = draw("Kontrolle", x: 455)
        if !digit.isEmpty {
            var x: CGFloat = 235
            x += draw("10", x: x)
            x += draw(digit, x: x, y: raised ? 42 : 32, size: raised ? 14 : 26)
            // Independent CoreText runs have no inter-run kerning. Keep the
            // slash separated, as required by the measured-glyph recovery.
            x += 2
            _ = draw("/" + denominator, x: x)
        }
        return try #require(context.makeImage())
    }

    private func textImage(_ text: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 800, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 800, height: 100))
        let font = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 32, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 20, y: 40)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        return try #require(context.makeImage())
    }
}
