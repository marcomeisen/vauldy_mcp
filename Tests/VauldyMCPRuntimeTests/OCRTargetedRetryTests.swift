import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VauldyCore

@Suite("Targeted native OCR retry")
struct OCRTargetedRetryTests {
    @Test func unusablePDFGlyphMapFallsBackToVisibleText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-ocr-layer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-layer.pdf")
        let mapping = (32...126).map { value in
            String(format: "<%02X> <%04X>", value, value == 80 ? 0xE000 : value)
        }.joined(separator: "\n")
        let cmap = """
            /CIDInit /ProcSet findresource begin
            12 dict begin begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapName /Synthetic def /CMapType 2 def
            1 begincodespacerange <00> <FF> endcodespacerange
            95 beginbfchar
            \(mapping)
            endbfchar
            endcmap CMapName currentdict /CMap defineresource pop end end
            """
        let text = "BT /F1 23 Tf 40 300 Td (Police fuer den synthetischen Hausrat) Tj 0 -45 Td (Beitrag: 49,99 EUR) Tj ET"
        func stream(_ value: String) -> String {
            "<< /Length \(value.utf8.count) >>\nstream\n\(value)\nendstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 400] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            stream(text), stream(cmap)
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, value) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(value)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: file)
        let old = try await NativeLocalDocumentOCR(baseline: true).recognize(file: file) { _ in }
        let new = try await NativeLocalDocumentOCR().recognize(file: file) { _ in }
        let prior = try #require(old.pages.first)
        let current = try #require(new.pages.first)
        #expect(prior.info.method == .embeddedText && prior.text.contains("\u{E000}"))
        #expect(current.info.method == .vision)
        #expect(current.text.contains("Police") && current.text.contains("49,99 EUR"))
        #expect(!current.text.contains("\u{E000}"))
    }

    @Test func conflictingValuesAreNeverPromotedByConfidence() {
        #expect(OCRLineRecovery.isIdentifier("Vertragsnummer: AB-O105"))
        #expect(OCRLineRecovery.isIdentifier("Versicherungsscheinnummer: AB-O105"))
        #expect(!OCRLineRecovery.isIdentifier("Beitrag: 49,99 EUR"))
        #expect(OCRLineRecovery.hasConfusableIdentifier("Policennummer: IO0O-171"))
        #expect(!OCRLineRecovery.hasConfusableIdentifier("Vertragsnummer: ZO-481017"))
        #expect(OCRLineRecovery.decide(original: "Vertragsnummer: AB-O105", confidence: 0.55,
                                      alternatives: ["Vertragsnummer: AB-0105"], retry: "Vertragsnummer: AB-0105",
                                      retryConfidence: 1, identifier: true) == .review)
        #expect(OCRLineRecovery.decide(original: "Beitrag 49,99 EUR", confidence: 0.55,
                                      alternatives: ["Beitrag 49,89 EUR"], retry: "Beitrag 49,89 EUR",
                                      retryConfidence: 1, identifier: false) == .review)
        #expect(OCRLineRecovery.decide(original: "Gültig bis 27.01.2026", confidence: 0.55,
                                      alternatives: [], retry: "Gültig bis 27.07.2026",
                                      retryConfidence: 1, identifier: false) == .review)
    }

    @Test func incompleteWordsCanBeRecoveredWithoutLosingExistingContent() {
        #expect(OCRLineRecovery.decide(original: "Schutz Hausrat", confidence: 0.55, alternatives: [],
                                      retry: "Schutz für Hausrat", retryConfidence: 0.95,
                                      identifier: false) == .replace)
        #expect(OCRLineRecovery.decide(original: "Haustat", confidence: 0.60, alternatives: ["Hausrat"],
                                      retry: "Hausrat", retryConfidence: 0.95, identifier: false) == .replace)
        #expect(OCRLineRecovery.decide(original: "Schutz Hausrat", confidence: 0.55, alternatives: [],
                                      retry: "Schutz", retryConfidence: 0.95, identifier: false) == .review)
        #expect(OCRLineRecovery.decide(original: "Schutz Hausrat", confidence: 0.70, alternatives: [],
                                      retry: "Schutz für Hausrat", retryConfidence: 0.73,
                                      identifier: false) == .keep)
    }

    @Test func priorPageMetricsStillDecode() throws {
        let old = #"{"inspectionMilliseconds":1,"renderMilliseconds":2,"recognitionMilliseconds":3,"cacheMilliseconds":0,"cacheHit":false,"renderedPixels":200,"recognitionRegions":1}"#
        let decoded = try JSONDecoder().decode(LocalOCRMetrics.self, from: Data(old.utf8))
        #expect(decoded.recognitionMilliseconds == 3)
        #expect(decoded.targetedRetries == nil && decoded.recoveredLines == nil && decoded.pdfScaleRetries == nil)
    }

    @Test func pdfScalePreservesCropRotationEdgesAndPixelBudget() throws {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 300, height: 250)
        let consumer = try #require(CGDataConsumer(data: data))
        let writer = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        writer.beginPDFPage(nil)
        // Solid edge marks are independent of OCR and must survive crop/rotation at 3x.
        writer.setFillColor(CGColor(gray: 0, alpha: 1))
        let crop = CGRect(x: 40, y: 30, width: 120, height: 90)
        for box in [CGRect(x: 42, y: 32, width: 6, height: 6), CGRect(x: 152, y: 32, width: 6, height: 6),
                    CGRect(x: 42, y: 112, width: 6, height: 6), CGRect(x: 152, y: 112, width: 6, height: 6)] {
            writer.fill(box)
        }
        writer.endPDFPage(); writer.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        let page = try #require(document.page(at: 0))
        page.setBounds(crop, for: .cropBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let reference = try #require(page.pageRef)
            let image = try NativeLocalDocumentOCR.render(reference, region: reference.getBoxRect(.cropBox), requestedScale: 3)
            #expect(image.width == (rotation % 180 == 0 ? 360 : 270))
            #expect(image.height == (rotation % 180 == 0 ? 270 : 360))
            var pixels = [UInt8](repeating: 255, count: image.width * image.height)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            for (x, y) in [(15, 15), (image.width - 15, 15), (15, image.height - 15), (image.width - 15, image.height - 15)] {
                #expect(pixels[y * image.width + x] < 30, Comment(rawValue: "rotation \(rotation)"))
            }
            let capped = try NativeLocalDocumentOCR.render(reference, region: reference.getBoxRect(.cropBox), requestedScale: 100)
            #expect(max(capped.width, capped.height) <= 3072)
        }
    }

    @Test func correctedRasterIgnoresOldCheckpointAndReusesOnlyNewSuccessfulPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-r2-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("difficult.pdf"), cacheRoot = root.appendingPathComponent("cache")
        let fields = ["Vertragsnummer: ZO-481017", "Beitrag: 49,99 EUR", "Beginn: 27.01.2026", "Versicherungsart: Hausrat"]
        try Scan(name: "raster-pdf", fields: fields, size: 13, gray: 0.72, angle: 0.03, asPDF: true).write(to: file)
        let original = try Data(contentsOf: file)
        let prior = try LocalOCRPageCache(root: cacheRoot, file: file,
            configuration: "ocr-v13-dense-and-line-recovery-" + ProcessInfo.processInfo.operatingSystemVersionString)
        try prior.save(.init(info: .init(page: 1, method: .vision), text: "OBSOLETE CHECKPOINT"))
        let engine = NativeLocalDocumentOCR(cacheRoot: cacheRoot)
        let first = try await read(engine, file), repeated = try await read(engine, file)
        #expect(matches(first.text, expected: fields.map(normalized)).count == 4)
        #expect(!first.info.needsReview && first.info.metrics?.cacheHit == false)
        #expect(repeated.info.metrics?.cacheHit == true && repeated.text == first.text)
        #expect(first.info.metrics?.lineReview != nil && repeated.info.metrics?.lineReview == first.info.metrics?.lineReview)
        #expect(try Data(contentsOf: file) == original)
        let current = try LocalOCRPageCache(root: cacheRoot, file: file)
        #expect(current.identity != prior.identity)
        try current.save(.init(info: .init(page: 2, method: .vision, needsReview: true), text: "Uncertain"))
        #expect(current.load(page: 2) == nil)
    }

    @Test func nativeComparisonOnDifficultScans() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-ocr-ab-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let regular = [
            "Vertragsnummer: ZO-481017",
            "Beitrag: 49,99 EUR",
            "Beginn: 27.01.2026",
            "Versicherungsart: Hausrat"
        ]
        let samples: [Scan] = [
            .init(name: "clean-control", fields: regular, size: 27),
            .init(name: "small-print", fields: regular, size: 13),
            .init(name: "faint-copy", fields: regular, size: 19, gray: 0.83),
            .init(name: "skewed-scan", fields: regular, size: 18, gray: 0.32, angle: 0.065),
            .init(name: "raster-pdf", fields: regular, size: 13, gray: 0.72, angle: 0.03, asPDF: true),
            .init(name: "ambiguous-identifier", fields: ["Policennummer: IO0O-171", "Beitrag: 81,19 EUR",
                  "Ende: 17.11.2027", "Versicherungsart: Haftpflicht"], size: 15, gray: 0.67, angle: -0.035),
            .init(name: "dense-amounts", fields: ["Glasbruch 18,70 EUR", "Wasserschaden 81,07 EUR",
                  "Selbstbehalt 110,00 EUR", "Rechnungsnummer: RX-8181"], size: 14, gray: 0.55, gap: 17),
            .init(name: "raster-other-values", fields: ["Vertragsnummer: VX-739245", "Beitrag: 82,47 EUR",
                  "Beginn: 19.08.2027", "Versicherungsart: Hausrat"], size: 14, gray: 0.65, angle: -0.025, asPDF: true),
            .init(name: "raster-light", fields: regular, size: 13, gray: 0.80, angle: 0.01, asPDF: true)
        ]
        // Pre-R2 production behavior, including the existing targeted line retries.
        let previous = NativeLocalDocumentOCR(targetedRetry: true, correctPDFScale: false)
        let enhanced = NativeLocalDocumentOCR()
        let warmup = root.appendingPathComponent("warmup.png")
        try samples[0].write(to: warmup)
        _ = try await previous.recognize(file: warmup, progress: { _ in })

        var totalRetries = 0
        for (index, sample) in samples.enumerated() {
            let file = root.appendingPathComponent(sample.name + (sample.asPDF ? ".pdf" : ".png"))
            try sample.write(to: file)
            let original = try Data(contentsOf: file)
            let before: LocalOCRPage
            let after: LocalOCRPage
            if index.isMultiple(of: 2) {
                before = try await read(previous, file)
                after = try await read(enhanced, file)
            } else {
                after = try await read(enhanced, file)
                before = try await read(previous, file)
            }
            let expected = sample.fields.map(normalized)
            let baselineMatches = matches(before.text, expected: expected)
            let retryMatches = matches(after.text, expected: expected)
            let attempts = after.info.metrics?.targetedRetries ?? 0
            totalRetries += attempts
            print("OCR-AB \(sample.name) exact=\(baselineMatches.count)/\(retryMatches.count)/\(expected.count) "
                  + "retry=\(attempts) scale-retry=\(after.info.metrics?.pdfScaleRetries ?? 0) recovered=\(after.info.metrics?.recoveredLines ?? 0) "
                  + "review=\(before.info.needsReview)/\(after.info.needsReview) "
                  + "recognition-ms=\(before.info.metrics?.recognitionMilliseconds ?? 0)/\(after.info.metrics?.recognitionMilliseconds ?? 0)")
            let expectedText = normalized((["Versicherungsschein"] + sample.fields).joined(separator: "\n"))
            let beforeText = normalized(before.text), afterText = normalized(after.text)
            print("OCR-ERRORS \(sample.name) chars=\(distance(Array(beforeText), Array(expectedText)))/\(distance(Array(afterText), Array(expectedText)))/\(expectedText.count) "
                  + "words=\(distance(beforeText.split(separator: " "), expectedText.split(separator: " ")))/\(distance(afterText.split(separator: " "), expectedText.split(separator: " ")))/\(expectedText.split(separator: " ").count) "
                  + "pixels=\(before.info.metrics?.renderedPixels ?? 0)/\(after.info.metrics?.renderedPixels ?? 0) "
                  + "elapsed-ms=\(before.info.elapsedMilliseconds)/\(after.info.elapsedMilliseconds)")
            #expect(baselineMatches.isSubset(of: retryMatches), Comment(rawValue: sample.name))
            if sample.asPDF {
                #expect(retryMatches.count == expected.count, Comment(rawValue: sample.name))
                #expect(after.info.metrics?.pdfScaleRetries == 1)
                if let path = ProcessInfo.processInfo.environment["VAULDY_OCR_AB_FIXTURES"] {
                    let folder = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try original.write(to: folder.appendingPathComponent(sample.name + ".pdf"), options: .atomic)
                }
            }
            #expect(after.info.page == 1 && attempts <= 4)
            #expect(try Data(contentsOf: file) == original)
            if index == 0 {
                #expect(retryMatches.count == expected.count)
                #expect(attempts == 0 && after.text == before.text && !after.info.needsReview)
                #expect(after.info.metrics?.pdfScaleRetries == nil)
            }
            if sample.name == "ambiguous-identifier" {
                #expect(attempts > 0 && after.info.needsReview)
                #expect(after.text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Policennummer") }
                        == before.text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Policennummer") })
            }
        }
        #expect(totalRetries > 0)
    }

    private func distance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        var row = Array(0...rhs.count)
        for (i, a) in lhs.enumerated() {
            var next = [i + 1]
            for (j, b) in rhs.enumerated() {
                next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (a == b ? 0 : 1)))
            }
            row = next
        }
        return row[rhs.count]
    }

    private func read(_ engine: NativeLocalDocumentOCR, _ file: URL) async throws -> LocalOCRPage {
        let result = try await engine.recognize(file: file, progress: { _ in })
        #expect(result.pages.count == 1)
        return try #require(result.pages.first)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func matches(_ text: String, expected: [String]) -> Set<String> {
        let lines = text.split(whereSeparator: \.isNewline).map { normalized(String($0)) }
        return Set(expected.filter { value in lines.contains { $0.contains(value) } })
    }
}

private struct Scan {
    let name: String
    let fields: [String]
    let size: CGFloat
    var gray: CGFloat = 0
    var angle: CGFloat = 0
    var gap: CGFloat = 44
    var asPDF = false

    func write(to file: URL) throws {
        let width = 840, height = 660
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 70, y: 510)
        context.rotate(by: angle)
        func line(_ value: String, y: CGFloat, size: CGFloat, gray: CGFloat) {
            let text = NSAttributedString(string: value, attributes: [
                .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
                .init(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)
            ])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        line("Versicherungsschein", y: 0, size: 27, gray: 0.08)
        for (index, field) in fields.enumerated() {
            line(field, y: -70 - CGFloat(index) * gap, size: size, gray: gray)
        }
        let image = try #require(context.makeImage())
        if asPDF {
            var page = CGRect(x: 0, y: 0, width: 420, height: 330)
            let consumer = try #require(CGDataConsumer(url: file as CFURL))
            let pdf = try #require(CGContext(consumer: consumer, mediaBox: &page, nil))
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: page)
            pdf.endPDFPage()
            pdf.closePDF()
            return
        }
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
