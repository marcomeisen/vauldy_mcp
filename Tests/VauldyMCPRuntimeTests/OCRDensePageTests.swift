import Foundation
import CoreGraphics
import Testing
@testable import VauldyCore

@Suite("Bounded dense OCR coverage")
struct OCRDensePageTests {
    @Test func batchesKeepLateGapsAndExactTotalsWithoutExpandingStoredGeometry() throws {
        let chars = (0..<180).map { row in (0..<12).map { column in
            CGRect(x: 0.01 + Double(column) * 0.02, y: 0.01 + Double(row) * 0.005, width: 0.01, height: 0.003)
        } }
        let lines = LocalOCRGeometry.vision(texts: Array(repeating: "Known", count: 179),
            bounds: chars.dropLast().map { $0.reduce(CGRect.null) { $0.union($1) } },
            confidences: Array(repeating: 1, count: 179)).lines
        #expect(LocalOCRVisualCoverage.compare(characters: chars, lines: lines).status == .limited)
        let current = try LocalOCRVisualCoverage.segmented(characters: chars, lines: lines)
        #expect(current.status == .checked && current.needsReview && current.regions.count == 128)
        #expect(current.comparedRegions == 180 && current.detectedTotal == 2160 && current.missingTotal == 12)
        #expect(current.regions.first?.bounds == chars.last?.reduce(CGRect.null) { $0.union($1) })
        var page = LocalOCRPage(info: .init(page: 1, method: .vision), text: Array(repeating: "Known", count: 179).joined(separator: "\n"))
        page.geometry = .vision(texts: Array(repeating: "Known", count: 179), bounds: lines.map(\.bounds), confidences: Array(repeating: 1, count: 179))
        page.geometry?.configuration = "synthetic-dense"
        page.geometry?.coverage = current
        #expect(LocalOCRPageLayout(sourceHash: String(repeating: "a", count: 64), page: page) != nil)
        page.geometry?.coverage?.totalCoveredCharacters = current.detectedTotal + 1
        #expect(LocalOCRPageLayout(sourceHash: String(repeating: "a", count: 64), page: page) == nil)
        page.geometry?.coverage = current
        page.geometry?.coverage?.totalDetectedCharacters = nil
        #expect(LocalOCRPageLayout(sourceHash: String(repeating: "a", count: 64), page: page) == nil)
        #expect(throws: CancellationError.self) {
            try LocalOCRVisualCoverage.segmented(characters: chars, lines: lines) { throw CancellationError() }
        }
        let limited = try LocalOCRVisualCoverage.segmented(characters: Array(repeating: chars[0], count: 1025), lines: [])
        #expect(limited.status == .limited && limited.regions.count == 128)
    }

    @Test func denseNativePageRecoversFiveFieldsBeyondTheFormerCoverageCutoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-dense-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fields = ["Rate Alpha: 11,10 EUR", "Rate Beta: 22,20 EUR", "Rate Gamma: 33,30 EUR", "Rate Delta: 44,40 EUR", "Rate Epsilon: 55,50 EUR"]
        let bytes = try PDFVectorTextOCRTests().fixture(fields: fields, freePaths: true,
            embeddedFields: ["Selbstbehalt: 110,00 EUR"], fontSize: 8, denseRows: 140, fieldSpacing: 14, bodyY: 100)
        let file = root.appendingPathComponent("dense.pdf"); try bytes.write(to: file)
        let previous = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, denseCoverage: false).recognize(file: file) { _ in }.pages.first)
        let current = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        #expect(previous.geometry?.coverage?.status == .limited)
        #expect(!fields.contains(where: previous.text.contains))
        for field in fields { #expect(current.text.contains(field), Comment(rawValue: field)) }
        #expect(current.text.hasPrefix(previous.text))
        #expect(current.geometry?.coverage?.status == .checked && current.geometry?.coverage?.needsReview == false)
        #expect((current.geometry?.coverage?.comparedRegions ?? 0) > 128)
        #expect((current.info.metrics?.regionRetries ?? 0) <= 4)
        #expect((current.info.metrics?.regionRetryPixels ?? 0) <= 8_000_000)
        #expect(LocalOCRPageLayout(sourceHash: LocalOriginalAccess.hash(bytes), page: current) != nil)
        #expect(try Data(contentsOf: file) == bytes)
        print("DENSE-PAGE before=\(fields.filter { previous.text.contains($0) }.count)/5 after=\(fields.filter { current.text.contains($0) }.count)/5 regions=\(current.geometry?.coverage?.comparedRegions ?? 0) retries=\(current.info.metrics?.regionRetries ?? 0)")
        if let path = ProcessInfo.processInfo.environment["VAULDY_OCR_DENSE_FIXTURES"] {
            let output = URL(fileURLWithPath: path);try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try bytes.write(to: output.appendingPathComponent("dense.pdf"))
            try JSONEncoder().encode(current).write(to: output.appendingPathComponent("dense-current.json"))
        }
    }
}
