import Foundation
import Testing
import VauldyCore
import VauldyDemoDocuments

@Suite("Local OCR quality review")
struct LocalDocumentReviewTests {
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
