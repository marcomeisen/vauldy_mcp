import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import VauldyCore

@Suite("PDF vector text coverage")
struct PDFVectorTextOCRTests {
    private static let samples = [
        ["Beitrag: 49,99 EUR", "Beginn: 27.01.2026", "Versicherungsart: Hausrat"],
        ["Rechnungsbetrag: 82,47 EUR", "Zahlbar bis: 19.08.2027", "Leistung: Wartung"]
    ]
    private static let header = "Synthetischer Beleg fuer die lokale Dokumentenpruefung"

    @Test(arguments: [0, 1]) func vectorBodyIsRecoveredInsteadOfCertifyingOnlyTheHeader(sample: Int) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vector-\(sample).pdf")
        let fields = Self.samples[sample]
        try fixture(fields: fields).write(to: file)
        let bytes = try Data(contentsOf: file)
        let document = try #require(PDFDocument(url: file))
        let source = try #require(document.page(at: 0))
        let embedded = source.string ?? ""
        #expect(NativeLocalDocumentOCR.isUsableEmbeddedText(embedded))
        #expect(!fields.contains(where: embedded.contains))
        let previous = try await read(NativeLocalDocumentOCR(baseline: true), file)
        let current = try await read(NativeLocalDocumentOCR(), file)
        #expect(previous.info.method == .embeddedText && !previous.info.needsReview)
        #expect(!fields.contains(where: previous.text.contains))
        #expect(current.info.method == .vision && !current.info.needsReview)
        for field in fields { #expect(current.text.contains(field), Comment(rawValue: field)) }
        #expect(current.text.contains(Self.header))
        #expect(current.info.page == 1 && current.info.metrics?.recognitionRegions == 1)
        #expect(try Data(contentsOf: file) == bytes)
        print("OCR-VECTOR sample=\(sample) exact=0/\(fields.filter { current.text.contains($0) }.count)/\(fields.count) "
              + "previous-ms=\(previous.info.elapsedMilliseconds) current-ms=\(current.info.elapsedMilliseconds)")
        try exportFixture(bytes, name: "vector-\(sample).pdf")
    }

    @Test func nestedFormUsesItsOwnFontResources() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("form.pdf")
        try fixture(fields: Self.samples[1], form: true).write(to: file)
        let source = try #require(PDFDocument(url: file)?.page(at: 0)?.pageRef)
        let inspection = PDFContentInspection.inspect(source)
        #expect(inspection.uncertain && inspection.imageRects.isEmpty)
        let current = try await read(NativeLocalDocumentOCR(), file)
        #expect(current.info.method == .vision)
        for field in Self.samples[1] { #expect(current.text.contains(field)) }
    }

    @Test func unusedVectorFontKeepsTheEmbeddedTextFastPath() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ordinary.pdf")
        try fixture(fields: Self.samples[0], embeddedBody: true).write(to: file)
        let source = try #require(PDFDocument(url: file)?.page(at: 0)?.pageRef)
        let inspection = PDFContentInspection.inspect(source)
        #expect(!inspection.uncertain && inspection.imageRects.isEmpty)
        let current = try await read(NativeLocalDocumentOCR(), file)
        #expect(current.info.method == .embeddedText && current.info.confidence == nil)
        #expect(current.info.metrics?.recognitionRegions == 0)
        for field in Self.samples[0] { #expect(current.text.contains(field)) }
    }

    @Test func oldHeaderOnlyCheckpointCannotHideTheBody() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cached.pdf"), cache = root.appendingPathComponent("cache")
        try fixture(fields: Self.samples[0]).write(to: file)
        let previous = try LocalOCRPageCache(root: cache, file: file,
            configuration: "ocr-v6-checked-pdf-text-layer-" + ProcessInfo.processInfo.operatingSystemVersionString)
        try previous.save(.init(info: .init(page: 1, method: .embeddedText), text: Self.header))
        let engine = NativeLocalDocumentOCR(cacheRoot: cache)
        let first = try await read(engine, file), second = try await read(engine, file)
        #expect(first.info.method == .vision && first.info.metrics?.cacheHit == false)
        for field in Self.samples[0] { #expect(first.text.contains(field)) }
        #expect(second.info.metrics?.cacheHit == true && second.text == first.text)
    }

    private func read(_ engine: NativeLocalDocumentOCR, _ file: URL) async throws -> LocalOCRPage {
        try #require(try await engine.recognize(file: file) { _ in }.pages.first)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-vector-text-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func exportFixture(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["VAULDY_OCR_VECTOR_FIXTURES"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name))
    }

    /// A selected Type 3 glyph paints a complete body as real vector outlines.
    /// The text extractor sees an unrelated A alongside a valid embedded header.
    func fixture(fields: [String], form: Bool = false, embeddedBody: Bool = false,
                 freePaths: Bool = false, embeddedFields: [String] = [], fontSize: CGFloat = 22,
                 denseRows: Int = 0, fieldSpacing: CGFloat = 44, bodyY: CGFloat = 580) throws -> Data {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var outlines = "0 0 d0\n"
        for (index, field) in fields.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: field,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                for position in 0..<count {
                    var transform = CGAffineTransform(translationX: positions[position].x,
                        y: positions[position].y - CGFloat(index) * fieldSpacing)
                    if let path = CTFontCreatePathForGlyph(font, glyphs[position], &transform) {
                        outlines += pathCommands(path)
                    }
                }
            }
            outlines += "f\n"
        }
        let dense = (0..<denseRows).map { index in
            "BT /F1 6 Tf \(index % 2 == 0 ? 40 : 330) \(680 - (index / 2) * 8) Td (Eintrag \(index): Synthetische Daten) Tj ET\n"
        }.joined()
        let header = "BT /F1 17 Tf 40 730 Td (\(Self.header)) Tj ET\n" + embeddedFields.enumerated().map {
            "BT /F1 20 Tf 40 \(690 - $0.offset * 35) Td (\($0.element)) Tj ET\n"
        }.joined() + dense
        let vector = "BT /F2 1 Tf 40 \(bodyY) Td (A) Tj ET"
        let ordinary = fields.enumerated().map {
            "BT /F1 22 Tf 40 \(580 - $0.offset * 44) Td (\($0.element)) Tj ET"
        }.joined(separator: "\n")
        let body: String
        if embeddedBody { body = ordinary }
        else if freePaths { body = "q 1 0 0 1 40 \(bodyY) cm\n" + outlines.dropFirst("0 0 d0\n".count) + "Q" }
        else if form { body = "/Body Do" }
        else { body = vector }
        let resources = "<< /Font << /F1 4 0 R /F2 6 0 R >> /XObject << /Body 8 0 R >> >>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources \(resources) /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream(header + body),
            "<< /Type /Font /Subtype /Type3 /FontBBox [0 -120 550 40] /FontMatrix [1 0 0 1 0 0] /CharProcs << /A 7 0 R >> /Encoding << /Type /Encoding /Differences [65 /A] >> /FirstChar 65 /LastChar 65 /Widths [0] /Resources << >> >>",
            stream(outlines),
            stream(vector, dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources \(resources)")
        ]
        var pdf = "%PDF-1.4\n", offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private func stream(_ content: String, dictionary: String = "") -> String {
        "<< /Length \(content.utf8.count) \(dictionary) >>\nstream\n\(content)\nendstream"
    }

    private func pathCommands(_ path: CGPath) -> String {
        var result = ""
        var current = CGPoint.zero, start = CGPoint.zero
        func point(_ point: CGPoint) -> String { String(format: "%.4f %.4f", point.x, point.y) }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]; start = current
                result += point(current) + " m\n"
            case .addLineToPoint:
                current = element.points[0]
                result += point(current) + " l\n"
            case .addQuadCurveToPoint:
                let control = element.points[0], end = element.points[1]
                let first = CGPoint(x: current.x + (control.x - current.x) * 2 / 3,
                                    y: current.y + (control.y - current.y) * 2 / 3)
                let second = CGPoint(x: end.x + (control.x - end.x) * 2 / 3,
                                     y: end.y + (control.y - end.y) * 2 / 3)
                result += [first, second, end].map(point).joined(separator: " ") + " c\n"
                current = end
            case .addCurveToPoint:
                result += (0..<3).map { point(element.points[$0]) }.joined(separator: " ") + " c\n"
                current = element.points[2]
            case .closeSubpath:
                result += "h\n"; current = start
            @unknown default: preconditionFailure("Unsupported future path element")
            }
        }
        return result
    }
}
