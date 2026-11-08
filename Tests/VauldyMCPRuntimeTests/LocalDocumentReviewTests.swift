import Foundation
import AppKit
import PDFKit
import Testing
@testable import VauldyCore
import VauldyDemoDocuments

@Suite("Local OCR quality review")
struct LocalDocumentReviewTests {
    @Test(arguments: [0, 90, 180, 270])
    func previewPixelsMatchSourceGeometryAfterScalingAndRotation(rotation: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-review-alignment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(url: file as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        // Nonzero crop origin tests translation as well as scale and rotation.
        context.fill(CGRect(x: 40 + 0.15 * 500, y: 60 + 0.7 * 650, width: 0.2 * 500, height: 0.05 * 650))
        context.endPDFPage(); context.closePDF()
        let pdf = try #require(PDFDocument(url: file)), physical = try #require(pdf.page(at: 0))
        physical.setBounds(CGRect(x: 40, y: 60, width: 500, height: 650), for: .cropBox)
        physical.rotation = rotation
        #expect(pdf.write(to: file))
        let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
        let document = try await store.stage(file: file).document
        let hash = try #require(document.localImport?.contentHash)
        let bytes = try await store.reviewPageImage(documentID: document.id, page: 1, sourceHash: hash)
        let bitmap = try #require(NSBitmapImageRep(data: bytes))
        var page = LocalOCRPage(info: .init(page: 1, method: .vision), text: "Markierung")
        page.geometry = .vision(texts: ["Markierung"], bounds: [CGRect(x: 0.15, y: 0.7, width: 0.2, height: 0.05)], confidences: [0.9])
        page.geometry?.configuration = LocalOCRPageCache.configuration
        page.geometry?.rotationDegrees = rotation
        let layout = try #require(LocalOCRPageLayout(sourceHash: hash, page: page))
        let inspected = LocalDocumentReview.Page(id: 1, text: page.text, info: page.info, layout: layout)
        let box = try #require(inspected.previewBounds(for: inspected.focus(quote: "Markierung")).first)
        let color = try #require(bitmap.colorAt(x: Int(box.midX * Double(bitmap.pixelsWide)), y: Int((1 - box.midY) * Double(bitmap.pixelsHigh)))?.usingColorSpace(.deviceRGB))
        #expect(color.greenComponent > 0.9 && color.redComponent < 0.1 && color.blueComponent < 0.1)
    }

    @Test func selectsFirstAffectedPhysicalPageAndRejectsAmbiguousText() throws {
        var document = VaultDocument(title: "Synthetisch", sourceName: "Langer Name.pdf",
            ocrText: "--- Seite 1 ---\nGesichert\n\n--- Seite 2 ---\n\n--- Seite 3 ---\nErste Fassung\n\n--- Seite 3 ---\nZweite Fassung",
            pageCount: 3)
        var metadata = LocalImportMetadata(contentHash: "test", fileExtension: "pdf")
        metadata.state = .partial
        metadata.pages = [
            .init(page: 1, method: .embeddedText),
            .init(page: 2, method: .unreadable, needsReview: true),
            .init(page: 3, method: .vision)
        ]
        document.localImport = metadata
        let review = try #require(LocalDocumentReview(document))
        #expect(review.firstReviewPage == 2)
        #expect(review.pages[0].text == "Gesichert")
        #expect(review.pages[1].info?.method == .unreadable)
        #expect(review.pages[2].text == nil)
        #expect(review.pages[2].needsReview)
    }

    @Test func rendersVerifiedPhysicalPageWithoutChangingSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-review-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("synthetic.pdf")
        try ExampleDocument.writePDF(to: pdf)
        let original = try Data(contentsOf: pdf)
        let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
        let earlier = root.appendingPathComponent("earlier.pdf")
        try (original + Data("\n% separate fixture\n".utf8)).write(to: earlier)
        _ = try await store.stage(file: earlier)
        let staged = try await store.stage(file: pdf).document
        let metadata = try #require(staged.localImport)
        let snapshot = try Data(contentsOf: store.snapshotURL)
        let preview = try await store.reviewPageImage(documentID: staged.id, page: 1, sourceHash: metadata.contentHash)
        #expect(Array(preview.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let second = try await store.reviewPageImage(documentID: staged.id, page: 2, sourceHash: metadata.contentHash)
        #expect(second != preview)
        await #expect(throws: LocalImportError.invalidDocument) {
            try await store.reviewPageImage(documentID: staged.id, page: 200, sourceHash: metadata.contentHash)
        }
        await #expect(throws: LocalImportError.staleAttempt) {
            try await store.reviewPageImage(documentID: staged.id, page: 1, sourceHash: "stale")
        }
        #expect(try Data(contentsOf: store.snapshotURL) == snapshot)
        #expect(try Data(contentsOf: pdf) == original)
    }
}
