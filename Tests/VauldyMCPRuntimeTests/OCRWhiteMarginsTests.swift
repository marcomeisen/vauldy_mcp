import CoreGraphics
import Foundation
import Testing
@testable import VauldyCore

@Suite("OCR white margin preservation")
struct OCRWhiteMarginsTests {
    @Test func sparsePageKeepsEveryMarkAndPadding() throws {
        let image = try raster(width: 400, height: 600, marks: [(80, 60, 0, 0, 0), (310, 140, 0, 0, 0), (145, 520, 0, 0, 0)])
        let bounds = try #require(OCRWhiteMargins.contentBounds(in: image))
        for point in [(80, 60), (310, 140), (145, 520)] {
            #expect(bounds.contains(CGPoint(x: point.0, y: point.1)))
        }
        #expect(bounds.minX < 80 && bounds.maxX > 310 && bounds.minY < 60 && bounds.maxY > 520)
        #expect(bounds.width < 400 && bounds.height < 600)
        let cropped = OCRWhiteMargins.cropped(image)
        #expect(cropped.width == Int(bounds.width) && cropped.height == Int(bounds.height))
    }
    @Test func nearWhiteColorAndIsolatedFooterCannotBeDiscarded() throws {
        let image = try raster(width: 400, height: 600, marks: [(100, 100, 0, 0, 0), (1, 598, 255, 255, 254)])
        let bounds = try #require(OCRWhiteMargins.contentBounds(in: image))
        #expect(bounds.contains(CGPoint(x: 1, y: 598)))
        #expect(bounds.contains(CGPoint(x: 100, y: 100)))
    }
    @Test func contentAtAllEdgesKeepsTheWholePage() throws {
        let image = try raster(width: 400, height: 600, marks: [(0, 0, 0, 0, 0), (399, 599, 0, 0, 0)])
        #expect(OCRWhiteMargins.contentBounds(in: image) == CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(OCRWhiteMargins.cropped(image) === image)
    }
    @Test func blankAndOutOfBudgetInputsRemainUnmodified() throws {
        for image in [try raster(width: 400, height: 600, marks: []), try raster(width: 4000, height: 8, marks: [])] {
            #expect(OCRWhiteMargins.contentBounds(in: image) == nil)
            #expect(OCRWhiteMargins.cropped(image) === image)
        }
    }
    @Test func oldConfigurationCannotReturnACompletedButIncompleteCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-ocr-version-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.pdf"); try Data("synthetic original".utf8).write(to: file)
        let old = try LocalOCRPageCache(root: root.appendingPathComponent("cache"), file: file,
            configuration: "ocr-v2-accurate-de-en-correction-hybrid-adaptive-" + ProcessInfo.processInfo.operatingSystemVersionString)
        try old.save(.init(info: .init(page: 1, method: .vision), text: "Kontoauszug\nAbsender: Musterbank eG"))
        #expect(old.load(page: 1) != nil)
        let current = try LocalOCRPageCache(root: root.appendingPathComponent("cache"), file: file)
        #expect(current.identity != old.identity && current.load(page: 1) == nil)
    }
}

private func raster(width: Int, height: Int, marks: [(Int, Int, UInt8, UInt8, UInt8)]) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))
    let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    data.initialize(repeating: 255, count: width * height * 4)
    for (x, y, r, g, b) in marks {
        let index = (y * width + x) * 4
        data[index] = r; data[index + 1] = g; data[index + 2] = b
    }
    return try #require(context.makeImage())
}
