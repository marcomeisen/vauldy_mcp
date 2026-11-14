import Foundation
import Testing
@testable import VauldyCore

@Suite("Source-confirmed decimal punctuation")
struct OCRSourcePunctuationTests {
    @Test func onlyOneDecimalGlyphMayChangeAndEvidenceIsRequired() {
        #expect(OCRDecimalSourceRepair.permits("Beitrag: 82.47 EUR", "Beitrag: 82,47 EUR"))
        #expect(OCRDecimalSourceRepair.permits("Summe: -17,29 €", "Summe: -17.29 €"))
        for new in ["Beitrag: 82,48 EUR", "Beitrag: 82,47 USD", "Beitrag: -82,47 EUR", "Beitrag: 8247 EUR", "Betrag: 82,47 EUR"] {
            #expect(!OCRDecimalSourceRepair.permits("Beitrag: 82.47 EUR", new))
        }
        for value in ["Datum: 12.03.2026", "Kennung: 82.47", "Summe: 1.234 EUR", "Summe: 1.234,56 EUR", "82.47 EUR"] {
            #expect(!OCRDecimalSourceRepair.eligible(value))
        }
        func page(_ text: String, evidence: Bool = false, confidence: Double = 1, prior: [String]? = nil) -> LocalOCRPage {
            var result = LocalOCRPage(info: .init(page: 1, method: .vision, confidence: confidence), text: text)
            result.geometry = .vision(texts: [text], bounds: [CGRect(x: 0.1, y: 0.4, width: 0.4, height: 0.1)], confidences: [confidence])
            result.geometry?.configuration = LocalOCRPageCache.configuration
            result.geometry?.lines[0].priorReadings = prior
            result.geometry?.lines[0].sourceRepair = evidence ? .decimalSeparator : nil
            return result
        }
        let old = page("Beitrag: 82.47 EUR"), new = "Beitrag: 82,47 EUR"
        let valid = page(new, evidence: true, prior: [old.text])
        #expect(EvidencePreservingLocalOCR.preserving(previous: old, candidate: valid).text == new)
        for bad in [page(new, prior: [old.text]), page(new, evidence: true),
                    page(new, evidence: true, confidence: 0.9, prior: [old.text]),
                    page("Beitrag: 82,48 EUR", evidence: true, prior: [old.text])] {
            #expect(EvidencePreservingLocalOCR.preserving(previous: old, candidate: bad).text == old.text)
        }
        let persisted = try? JSONDecoder().decode(LocalOCRPage.self, from: JSONEncoder().encode(valid))
        #expect(persisted?.geometry?.lines[0].sourceRepair == .decimalSeparator)
        let repeated = EvidencePreservingLocalOCR.preserving(previous: valid, candidate: page(new))
        #expect(repeated.geometry?.lines[0].sourceRepair == .decimalSeparator)
        #expect(LocalOCRPageLayout(sourceHash: "validation", page: repeated) != nil)
        let changedLabel = page("Beitrog: 82,47 EUR", prior: [new])
        let labelResult = EvidencePreservingLocalOCR.preserving(previous: valid, candidate: changedLabel)
        #expect(labelResult.text == changedLabel.text && labelResult.geometry?.lines[0].sourceRepair == nil)
        #expect(LocalOCRPageLayout(sourceHash: "validation", page: labelResult) != nil)
    }

    @Test func genuineDotsCommasSignsAndOtherAmountsRemainUnchanged() async throws {
        struct Baseline: Decodable { let inputHashes: [String: String]; let pages: [String: LocalOCRPage] }
        let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf:
            #require(Bundle.module.url(forResource: "ocr-punctuation-controls-v17", withExtension: "json"))))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-punctuation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for size in [9, 13] {
          for (index, field) in ["Beitrag: 82.47 EUR", "Beitrag: 17,29 EUR", "Summe: -39.51 EUR", "Summe: 1.234,56 EUR"].enumerated() {
            let file = root.appendingPathComponent("source-\(size)-\(index).png")
            try LineScan(name: "source", fields: ["Geltungsbereich: Fahrradzubehoer und Kleingeraete", "Leistung: Wartung am Aggregat", field],
                size: CGFloat(size), gray: 0.7, noise: 5, fontName: "Helvetica-Oblique", angle: 0.08).write(to: file)
            let bytes = try Data(contentsOf: file)
            #expect(LocalOriginalAccess.hash(bytes) == baseline.inputHashes[file.lastPathComponent])
            let before = try #require(baseline.pages[file.lastPathComponent])
            let result = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
            // Three additional 9-point controls already fail in the unchanged
            // v17 engine. Preserve those literal readings rather than calling
            // them correct; all 13-point controls and the 9-point dot are exact.
            #expect(result.text == before.text, Comment(rawValue: file.lastPathComponent + " v17 preservation"))
            if size == 13 || index == 0 {
                #expect(result.text.contains(field), Comment(rawValue: field + " -> " + result.text))
            }
            #expect(EvidencePreservingLocalOCR.preserving(previous: before, candidate: result).text == result.text)
            #expect(try Data(contentsOf: file) == bytes)
            #expect((result.info.metrics?.fieldRetries ?? 0) <= 8)
            #expect((result.info.metrics?.fieldRetryPixels ?? 0) <= 8_000_000)
          }
        }
    }
}
