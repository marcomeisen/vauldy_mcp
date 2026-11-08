import Foundation
import Testing
@testable import VauldyCore

@Suite("Explicit OCR refinement preserves existing literal evidence")
struct EvidencePreservingOCRTests {
    private func page(_ text: String) -> LocalOCRPage { .init(info: .init(page: 1, method: .vision), text: text) }

    @Test func changedNumbersRemovedLinesAndDuplicateLossRetainThePreviousPage() {
        let previous = page("Beitrag: 49,99 EUR\nBedingung: Nur bei Wartung.\nBedingung: Nur bei Wartung.")
        for text in ["Beitrag: 49,999 EUR\nBedingung: Nur bei Wartung.\nBedingung: Nur bei Wartung.",
                     "Beitrag: 49,99 EUR", "Beitrag: 49,99 EUR\nBedingung: Nur bei Wartung."] {
            var candidate = page(text)
            candidate.info.elapsedMilliseconds = 123
            let retained = EvidencePreservingLocalOCR.preserving(previous: previous, candidate: candidate)
            #expect(retained.text == previous.text && retained.info.needsReview)
            #expect(retained.info.metrics?.evidencePreservedFallback == true)
            #expect(retained.info.elapsedMilliseconds == 123)
        }
        let added = page(previous.text + "\nBeginn: 27.01.2026")
        #expect(EvidencePreservingLocalOCR.preserving(previous: previous, candidate: added).text == added.text)
    }

    @Test func refinementUsesNormalOriginalValidationAndAtomicImportCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-preserve-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("fixture.pdf")
        let bytes = Data("synthetic original".utf8)
        try bytes.write(to: original)
        let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
        let initial = "Beitrag: 49,99 EUR\nBedingung: Nur bei Wartung."
        let outcome = try await LocalImportService(store: store, ocr: Fixed(pages: [page(initial)])).importFile(original)
        let document = try #require(try await store.document(id: outcome.documentID))
        let safe = try EvidencePreservingLocalOCR(document: document,
            candidate: Fixed(pages: [page(initial + "\nBeginn: 27.01.2026")]))
        _ = try await LocalImportService(store: store, ocr: safe).retry(documentID: document.id, expected: document)
        let updated = try #require(try await store.document(id: document.id))
        #expect(updated.id == document.id && updated.ocrText.contains(initial))
        #expect(updated.ocrText.contains("Beginn: 27.01.2026"))
        #expect(updated.localImport?.contentHash == document.localImport?.contentHash)
        #expect(try Data(contentsOf: original) == bytes)
        await #expect(throws: LocalImportError.staleAttempt) {
            _ = try await LocalImportService(store: store, ocr: safe).retry(documentID: document.id, expected: document)
        }
        #expect(try await store.document(id: document.id) == updated)
        let bad = try EvidencePreservingLocalOCR(document: updated, candidate: Fixed(pages: [page("Beitrag: 82,47 EUR")]))
        _ = try await LocalImportService(store: store, ocr: bad).retry(documentID: document.id, expected: updated)
        let retained = try #require(try await store.document(id: document.id))
        #expect(retained.ocrText == updated.ocrText)
        #expect(retained.localImport?.pages.first?.metrics?.evidencePreservedFallback == true)
        try Data("different synthetic bytes".utf8).write(to: root.appendingPathComponent("different.pdf"))
        await #expect(throws: LocalImportError.staleAttempt) {
            _ = try await bad.recognize(file: root.appendingPathComponent("different.pdf")) { _ in }
        }
    }
}

private struct Fixed: LocalDocumentOCR {
    let pages: [LocalOCRPage]
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        .init(pages: pages)
    }
}
