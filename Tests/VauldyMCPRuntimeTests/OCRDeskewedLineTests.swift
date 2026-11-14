import CoreGraphics
import Foundation
import Testing
@testable import VauldyCore

@Suite("Measured small tilted lines")
struct OCRDeskewedLineTests {
    @Test func rectificationPreservesSourceCoordinatesAndPixelBudget() throws {
        let width = 600, height = 300
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for angle: CGFloat in [-0.08, 0.08] {
            let rotate = CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: 300, y: 150))
            let points = [CGPoint(x: -180, y: 6), CGPoint(x: 180, y: 6), CGPoint(x: 180, y: -6), CGPoint(x: -180, y: -6)]
                .map { $0.applying(rotate) }
            context.saveGState(); context.concatenate(rotate); context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: -180, y: -6, width: 360, height: 12)); context.restoreGState()
            let image = try #require(context.makeImage())
            let normalized = points.map { CGPoint(x: $0.x / CGFloat(width), y: $0.y / CGFloat(height)) }
            let crop = try #require(OCRDeskewedLineCrop.make(image, corners: normalized, contextPadding: 0.6))
            #expect(crop.image.width * crop.image.height <= 1_000_000)
            #expect(crop.target.height * CGFloat(crop.image.height) < 40)
            let corners = [CGPoint(x: crop.target.minX, y: crop.target.maxY), CGPoint(x: crop.target.maxX, y: crop.target.maxY),
                           CGPoint(x: crop.target.maxX, y: crop.target.minY), CGPoint(x: crop.target.minX, y: crop.target.minY)]
            for (point, expected) in zip(corners, normalized) {
                let mapped = point.applying(crop.transform)
                #expect(abs(mapped.x - expected.x) < 0.0001 && abs(mapped.y - expected.y) < 0.0001)
            }
        }
    }

    @Test func unsafeTransformsAndStraightLinesDoNotEnterRectification() throws {
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let points = [CGPoint(x: 0.1, y: 0.6), CGPoint(x: 0.9, y: 0.6), CGPoint(x: 0.9, y: 0.4), CGPoint(x: 0.1, y: 0.4)]
        #expect(OCRDeskewedLineCrop.make(image, corners: points, contextPadding: 0.3) == nil)
        #expect(OCRDeskewedLineCrop.make(image, corners: [], contextPadding: 0.3) == nil)
        #expect(OCRDeskewedLineCrop.make(image, corners: points, contextPadding: .nan) == nil)
    }

    @Test func smallGlyphRepairCannotChangeNumbersIdentifiersOrSeveralLetters() {
        #expect(OCRLineRecovery.decide(original: "Leistung: Zahnriemerwechsel am Aggregat", confidence: 1,
            alternatives: [], retry: "Leistung: Zahnriemenwechsel am Aggregat", retryConfidence: 1,
            identifier: false, smallPrint: true, allowSmallGlyphRepair: true) == .replace)
        #expect(OCRLineRecovery.decide(original: "Beitrag: 82.47 EUR", confidence: 1,
            alternatives: [], retry: "Beitrag: 82,47 EUR", retryConfidence: 1,
            identifier: false, smallPrint: true, allowSmallGlyphRepair: true) == .review)
        #expect(OCRLineRecovery.decide(original: "Vertragsnummer: ABCDEF", confidence: 1,
            alternatives: [], retry: "Vertragsnummer: ABXDEF", retryConfidence: 1,
            identifier: true, smallPrint: true, allowSmallGlyphRepair: true) == .review)
        #expect(OCRLineRecovery.decide(original: "Leistung: Wartung", confidence: 1,
            alternatives: [], retry: "Leistung: Zahlung", retryConfidence: 1,
            identifier: false, smallPrint: true, allowSmallGlyphRepair: true) == .review)
    }
}
