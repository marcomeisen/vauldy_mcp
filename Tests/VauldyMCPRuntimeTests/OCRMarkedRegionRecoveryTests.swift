import Foundation
import CoreGraphics
import Testing
@testable import VauldyCore

@Suite("Marked OCR region recovery")
struct OCRMarkedRegionRecoveryTests {
    @Test func agreementGeometryAndExistingValuesGateEveryAddition() {
        let box = CGRect(x: 0.1, y: 0.3, width: 0.6, height: 0.05)
        let existing = "Beitrag: 49,99 EUR"
        let first = OCRRegionRecovery.Candidate(text: "Beitrag: 82,47 EUR", bounds: box, confidence: 1)
        #expect(OCRRegionRecovery.decide(first, confirmedBy: first, region: box,
            existingText: existing, existingLines: []) == .conflict)
        let different = OCRRegionRecovery.Candidate(text: "Beitrag: 82,41 EUR", bounds: box, confidence: 1)
        #expect(OCRRegionRecovery.decide(first, confirmedBy: different, region: box,
            existingText: "", existingLines: []) == .unconfirmed)
        let oldLines = LocalOCRGeometry.vision(texts: [existing], bounds: [box], confidences: [1]).lines
        #expect(OCRRegionRecovery.decide(first, confirmedBy: first, region: box,
            existingText: "", existingLines: oldLines) == .overlap)
        let newField = OCRRegionRecovery.Candidate(text: "Versicherungsart: Hausrat", bounds: box, confidence: 1)
        #expect(OCRRegionRecovery.decide(newField, confirmedBy: newField, region: box,
            existingText: existing, existingLines: []) == .append)
        #expect(OCRRegionRecovery.decide(newField, confirmedBy: newField,
            region: CGRect(x: 0.1, y: 0.7, width: 0.6, height: 0.05), existingText: "", existingLines: []) == .unconfirmed)
        let uncertain = OCRRegionRecovery.Candidate(text: "Policennummer: IO0O-171", bounds: box, confidence: 1)
        #expect(OCRRegionRecovery.decide(uncertain, confirmedBy: uncertain, region: box,
            existingText: "", existingLines: []) == .unconfirmed)
    }

    @Test(arguments: [0, 1]) func missingFieldsAreAddedWithoutChangingExistingEvidence(sample: Int) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fields = sample == 0 ? ["Beitrag: 49,99 EUR", "Beginn: 27.01.2026", "Versicherungsart: Hausrat"]
            : ["Rechnungsbetrag: 82,47 EUR", "Zahlbar bis: 19.08.2027", "Leistung: Wartung"]
        let existing = "Selbstbehalt: 110,00 EUR"
        let file = root.appendingPathComponent("recovered-\(sample).pdf")
        let bytes = try PDFVectorTextOCRTests().fixture(fields: fields, freePaths: true, embeddedFields: [existing])
        try bytes.write(to: file)
        let before = try await read(file, recovery: false)
        let after = try await read(file)
        #expect(before.info.needsReview && !fields.contains(where: before.text.contains))
        for field in fields { #expect(after.text.contains(field), Comment(rawValue: field)) }
        #expect(after.text.hasPrefix(before.text) && after.text.components(separatedBy: existing).count == 2)
        #expect(Array(after.geometry?.lines.prefix(before.geometry?.lines.count ?? 0) ?? []) == before.geometry?.lines)
        #expect(after.info.method == .embeddedTextAndVision && !after.info.needsReview)
        #expect(after.geometry?.coverage?.needsReview == false)
        #expect(after.info.metrics?.recoveredRegionLines == 3 && (after.info.metrics?.regionRetries ?? 0) <= 4)
        #expect((after.info.metrics?.regionRetryPixels ?? 0) <= 8_000_000)
        #expect(LocalOCRPageLayout(sourceHash: LocalOriginalAccess.hash(bytes), page: after) != nil)
        #expect(try Data(contentsOf: file) == bytes)
        print("OCR-REGION sample=\(sample) exact=0/\(fields.filter { after.text.contains($0) }.count)/\(fields.count) "
              + "preserved=\(after.text.hasPrefix(before.text)) retries=\(after.info.metrics?.regionRetries ?? 0) "
              + "recovered=\(after.info.metrics?.recoveredRegionLines ?? 0) ms=\(after.info.metrics?.regionRetryMilliseconds ?? 0)")
        try export(bytes, name: "recovered-\(sample).pdf")
    }

    @Test func conflictingNumericValueRemainsUnchangedAndVisibleForReview() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conflict.pdf")
        let bytes = try PDFVectorTextOCRTests().fixture(fields: ["Beitrag: 82,47 EUR", "Beginn: 27.01.2026"],
            freePaths: true, embeddedFields: ["Beitrag: 49,99 EUR"])
        try bytes.write(to: file)
        let before = try await read(file, recovery: false), after = try await read(file)
        #expect(after.text.hasPrefix(before.text) && after.text.contains("Beitrag: 49,99 EUR"))
        #expect(!after.text.contains("82,47") && after.text.contains("Beginn: 27.01.2026"))
        #expect(after.info.needsReview && after.geometry?.coverage?.needsReview == true)
        #expect((after.info.metrics?.regionRecoveryConflicts ?? 0) >= 1)
        try export(bytes, name: "conflict.pdf")
    }

    @Test func neighbouringGapsShareTheOriginalFourCropBudget() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fields = ["Rate Alpha: 11,10 EUR", "Rate Beta: 22,20 EUR", "Rate Gamma: 33,30 EUR",
                      "Rate Delta: 44,40 EUR", "Rate Epsilon: 55,50 EUR"]
        let file = root.appendingPathComponent("budget.pdf")
        try PDFVectorTextOCRTests().fixture(fields: fields, freePaths: true).write(to: file)
        let old = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, denseCoverage: false).recognize(file: file) { _ in }.pages.first)
        #expect(old.info.needsReview && old.info.metrics?.regionRetries == 4)
        let after = try await read(file)
        let recovered = fields.filter { after.text.contains($0) }.count
        #expect((after.info.metrics?.regionRetries ?? 0) <= 4)
        #expect(recovered == fields.count && after.info.metrics?.recoveredRegionLines == recovered)
        #expect(!after.info.needsReview && after.geometry?.coverage?.needsReview == false)
    }

    @Test func completeTextTriggersNoAdditionalRegionalOCR() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("complete.pdf")
        try PDFVectorTextOCRTests().fixture(fields: ["Beitrag: 49,99 EUR", "Beginn: 27.01.2026"], embeddedBody: true).write(to: file)
        let before = try await read(file, recovery: false), after = try await read(file)
        #expect(after.text == before.text && after.info.metrics?.regionRetries == nil)
        #expect(!after.info.needsReview && after.info.method == .embeddedText)
    }

    private func read(_ file: URL, recovery: Bool = true) async throws -> LocalOCRPage {
        try #require(try await NativeLocalDocumentOCR(targetedRetry: true, regionRecovery: recovery)
            .recognize(file: file) { _ in }.pages.first)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-region-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func export(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["VAULDY_OCR_REGION_FIXTURES"] else { return }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }
}
