import Foundation
import CoreGraphics
import Testing
@testable import VauldyCore

@Suite("Small marked OCR regions")
struct OCRSmallRegionTests {
    @Test func cropWorkRemainsBoundedAndNormalTextIsUnchanged() throws {
        let tiny = try #require(OCRRegionRecovery.retrySize(width: 200, height: 30, glyphHeight: 8, enabled: true))
        #expect(tiny.width == 600 && tiny.height == 90)
        let normal = try #require(OCRRegionRecovery.retrySize(width: 200, height: 80, glyphHeight: 28, enabled: true))
        #expect(normal.width == 200 && normal.height == 80)
        let off = try #require(OCRRegionRecovery.retrySize(width: 200, height: 30, glyphHeight: 8, enabled: false))
        #expect(off.width == 200 && off.height == 30)
        let large = try #require(OCRRegionRecovery.retrySize(width: 1500, height: 500, glyphHeight: 8, enabled: true))
        #expect(large.width * large.height <= 1_000_000)
        #expect(OCRRegionRecovery.retrySize(width: Int.max, height: 2, glyphHeight: 8, enabled: true) == nil)
        #expect(OCRRegionRecovery.retrySize(width: 10, height: 2, glyphHeight: .nan, enabled: true) == nil)
    }

    @Test func detectedSmallVectorLabelsAreRecoveredExactly() async throws {
        try await compare(size: 6, requireAllFields: true)
    }

    @Test(arguments: [CGFloat(4), 5]) func tinyTextMustNowMeetAllThreeExactFields(size: CGFloat) async throws {
        try await compare(size: size, requireAllFields: true)
    }

    private func compare(size: CGFloat, requireAllFields: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-small-region-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("small.pdf")
        let fields = ["Beitrag: 49,99 EUR", "Beginn: 27.01.2026", "Versicherungsart: Hausrat"]
        let bytes = try PDFVectorTextOCRTests().fixture(fields: fields, freePaths: true,
            embeddedFields: ["Selbstbehalt: 110,00 EUR"], fontSize: size)
        try bytes.write(to: file)
        let base = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, regionRecovery: false)
            .recognize(file: file) { _ in }.pages.first)
        let before = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, smallTextDetection: false)
            .recognize(file: file) { _ in }.pages.first)
        let after = try #require(try await NativeLocalDocumentOCR(targetedRetry: true)
            .recognize(file: file) { _ in }.pages.first)
        #expect(after.text.hasPrefix(base.text))
        #expect(after.text.contains("Selbstbehalt: 110,00 EUR"))
        if requireAllFields {
            for field in fields { #expect(after.text.contains(field), Comment(rawValue: field)) }
        }
        #expect(fields.filter { after.text.contains($0) }.count >= fields.filter { before.text.contains($0) }.count)
        #expect((after.info.metrics?.regionRetries ?? 0) <= 4)
        #expect((after.info.metrics?.regionRetryPixels ?? 0) <= 8_000_000)
        #expect(try Data(contentsOf: file) == bytes)
        #expect((after.info.metrics?.smallTextDetectionRegions ?? 0) <= 16)
        #expect((after.info.metrics?.smallTextDetectionPixels ?? 0) <= 8_000_000)
        if let path = ProcessInfo.processInfo.environment["VAULDY_OCR_SMALL_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try bytes.write(to: output.appendingPathComponent("small-\(Int(size)).pdf"))
            try JSONEncoder().encode(base).write(to: output.appendingPathComponent("previous-\(Int(size)).json"))
            try JSONEncoder().encode(before).write(to: output.appendingPathComponent("v11-\(Int(size)).json"))
            try JSONEncoder().encode(after).write(to: output.appendingPathComponent("current-\(Int(size)).json"))
        }
        print("SMALL-REGION size=\(size) before=\(fields.filter { before.text.contains($0) }.count)/3 after=\(fields.filter { after.text.contains($0) }.count)/3 pixels=\(after.info.metrics?.regionRetryPixels ?? 0)")
    }
}
