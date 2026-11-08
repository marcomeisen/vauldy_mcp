import Foundation
import CoreGraphics
import PDFKit
import Testing
@testable import VauldyCore

@Suite("Tiny text import and chat evidence")
struct OCRSmallTextMCPFixturesTests {
    private let fields = ["Beitrag: 49,99 EUR", "Beginn: 27.01.2026", "Versicherungsart: Hausrat"]

    @Test func normalImportsExposeBeforeAndAfterWithoutEditingStoredOCR() async throws {
        let export = ProcessInfo.processInfo.environment["VAULDY_OCR_SMALL_FIXTURES"].map { URL(fileURLWithPath: $0) }
        let parent = export ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("chat-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if export == nil { try? FileManager.default.removeItem(at: root) } }
        var cases: [[String: String]] = []
        for size in [4, 5] {
            let file = root.appendingPathComponent("tiny-\(size).pdf")
            let bytes = try PDFVectorTextOCRTests().fixture(fields: fields, freePaths: true,
                embeddedFields: ["Selbstbehalt: 110,00 EUR"], fontSize: CGFloat(size))
            try bytes.write(to: file)
            for mode in ["v11", "current"] {
                let store = LocalDocumentStore(root: root.appendingPathComponent("\(mode)-\(size)"))
                let engine = NativeLocalDocumentOCR(targetedRetry: true, smallTextDetection: mode == "current")
                let outcome = try await LocalImportService(store: store, ocr: engine).importFile(file)
                let doc = try #require(try await store.document(id: outcome.documentID))
                #expect(doc.ocrText.contains("Selbstbehalt: 110,00 EUR"))
                let exact = fields.filter { doc.ocrText.contains($0) }.count
                #expect(exact == (mode == "current" ? 3 : (size == 4 ? 0 : 2)))
                #expect(try Data(contentsOf: file) == bytes)
                cases.append(["size": String(size), "mode": mode,
                    "vault": store.root.appendingPathComponent("documents.json").path,
                    "documentID": outcome.documentID.uuidString])
            }
        }
        if let export {
            try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted, .sortedKeys])
                .write(to: export.appendingPathComponent("wire-cases.json"))
        }
    }

    @Test func previousCompletedCheckpointCannotHideTinyText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-v12-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tiny.pdf"), cache = root.appendingPathComponent("cache")
        try PDFVectorTextOCRTests().fixture(fields: fields, freePaths: true, fontSize: 4).write(to: file)
        let previous = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, smallTextDetection: false)
            .recognize(file: file) { _ in }.pages.first)
        #expect(!previous.info.needsReview && !fields.contains(where: previous.text.contains))
        try LocalOCRPageCache(root: cache, file: file,
            configuration: "ocr-v11-small-region-recovery-" + ProcessInfo.processInfo.operatingSystemVersionString).save(previous)
        let current = try #require(try await NativeLocalDocumentOCR(cacheRoot: cache)
            .recognize(file: file) { _ in }.pages.first)
        #expect(current.info.metrics?.cacheHit == false)
        for field in fields { #expect(current.text.contains(field)) }
    }

    @Test func smallSourceRerenderKeepsNonzeroCropCoordinates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-tiny-crop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = try #require(PDFDocument(data: PDFVectorTextOCRTests().fixture(fields: fields,
            freePaths: true, fontSize: 4)))
        let page = try #require(pdf.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 450, width: 550, height: 350), for: .cropBox)
        let file = root.appendingPathComponent("crop.pdf")
        #expect(pdf.write(to: file))
        let before = try Data(contentsOf: file)
        let result = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        for field in fields { #expect(result.text.contains(field)) }
        let geometry = try #require(result.geometry)
        #expect(geometry.coordinateSpace == .pdfCropBottomLeft)
        #expect(geometry.lines.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.bounds) })
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func tinyConflictingAmountIsFlaggedAndNeverOverwritesExistingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-tiny-conflict-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conflict.pdf")
        try PDFVectorTextOCRTests().fixture(fields: ["Beitrag: 82,47 EUR", fields[1], fields[2]],
            freePaths: true, embeddedFields: ["Beitrag: 49,99 EUR"], fontSize: 4).write(to: file)
        let result = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        #expect(result.text.contains("Beitrag: 49,99 EUR") && !result.text.contains("82,47"))
        #expect(result.text.contains(fields[1]) && result.text.contains(fields[2]))
        #expect(result.info.needsReview && (result.info.metrics?.regionRecoveryConflicts ?? 0) > 0)
    }

    @Test func proposalScanIsCancellableAndSolidRulesAreNotTextEvidence() throws {
        let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 10, y: 70, width: 150, height: 8))
        let image = try #require(context.makeImage())
        #expect(try OCRSmallTextRegions.proposals(in: image) {}.isEmpty)
        #expect(throws: CancellationError.self) {
            try OCRSmallTextRegions.proposals(in: image) { throw CancellationError() }
        }
    }
}
