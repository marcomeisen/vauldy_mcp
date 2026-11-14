import Foundation
import CoreGraphics

/// Local source geometry only. Offsets refer to the exact physical page text in UTF-16.
public struct LocalOCRLine: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var bounds: CGRect
    public var confidence: Double?
    public var method: LocalOCRMethod
    /// Earlier literal readings retained locally when two contextual reads
    /// support a constrained word repair. They are not additional source facts.
    public var priorReadings: [String]? = nil
    /// Set only by the paired, unrectified source-reading path. This local
    /// evidence distinguishes a measured punctuation repair from formatting.
    public enum SourceRepair: String, Codable, Sendable { case decimalSeparator }
    public var sourceRepair: SourceRepair? = nil
    /// Optional, so earlier readers can decode the layout and its prior readings.
    var policyIdentifierRepair: Bool? = nil
}

public struct LocalOCRGeometry: Codable, Equatable, Sendable {
    public enum CoordinateSpace: String, Codable, Sendable {
        case pdfCropBottomLeft, uprightImageBottomLeft
    }
    public var coordinateSpace: CoordinateSpace
    public var rotationDegrees: Int
    public var configuration: String
    public var lines: [LocalOCRLine]
    public var blocks: [LocalOCRTextBlock]?
    public var coverage: LocalOCRVisualCoverage?

    mutating func formBlocks() { blocks = OCRTextBlocks.make(lines) }

    static func vision(texts: [String], bounds: [CGRect], confidences: [Double]) -> Self {
        var offset = 0
        let lines = texts.indices.map { index in
            let length = texts[index].utf16.count
            defer { offset += length + 1 }
            return LocalOCRLine(location: offset, length: length, bounds: bounds[index],
                                confidence: confidences[index], method: .vision)
        }
        return Self(coordinateSpace: .uprightImageBottomLeft, rotationDegrees: 0, configuration: "", lines: lines)
    }

    mutating func transform(_ transform: CGAffineTransform) {
        blocks = nil
        lines = lines.compactMap { line in
            var line = line
            line.bounds = line.bounds.applying(transform).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return line.bounds.isNull || line.bounds.isEmpty ? nil : line
        }
        if var coverage {
            let transformed = coverage.regions.compactMap { region -> LocalOCRVisualRegion? in
                var region = region
                region.bounds = region.bounds.applying(transform).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if region.bounds.isNull || region.bounds.isEmpty { return nil }
                return region
            }
            if transformed.count != coverage.regions.count && coverage.status == .checked { coverage.status = .limited }
            coverage.regions = transformed
            self.coverage = coverage
        }
    }

    mutating func append(_ other: Self?, textOffset: Int) {
        guard let other else { return }
        blocks = nil
        lines += other.lines.map { line in
            var line = line
            line.location += textOffset
            return line
        }
        if let otherCoverage = other.coverage {
            if coverage == nil { coverage = otherCoverage }
            else { coverage?.append(otherCoverage) }
        }
    }

    /// CGImage crop boxes start at the top left; Vision boxes start at the bottom left.
    static func cropTransform(_ crop: CGRect, width: Int, height: Int) -> CGAffineTransform {
        CGAffineTransform(a: crop.width / CGFloat(width), b: 0, c: 0, d: crop.height / CGFloat(height),
                          tx: crop.minX / CGFloat(width), ty: (CGFloat(height) - crop.maxY) / CGFloat(height))
    }
}

public struct LocalOCRPageLayout: Codable, Equatable, Sendable {
    public let version: Int
    public let sourceHash: String
    public let page: Int
    public let textHash: String
    public let geometry: LocalOCRGeometry

    init?(sourceHash: String, page: LocalOCRPage) {
        guard let geometry = page.geometry, !geometry.configuration.isEmpty,
              Self.valid(geometry, text: page.text), (1...200).contains(page.info.page) else { return nil }
        version = 1
        self.sourceHash = sourceHash
        self.page = page.info.page
        textHash = LocalOriginalAccess.hash(Data(page.text.utf8))
        self.geometry = geometry
    }

    public func matches(sourceHash: String, page: Int, text: String, configuration: String) -> Bool {
        version == 1 && self.sourceHash == sourceHash && self.page == page
            && geometry.configuration == configuration && Self.valid(geometry, text: text)
            && textHash == LocalOriginalAccess.hash(Data(text.utf8))
    }

    private static func valid(_ geometry: LocalOCRGeometry, text: String) -> Bool {
        guard (!geometry.lines.isEmpty || geometry.coverage != nil), geometry.lines.count <= 4096,
              [0, 90, 180, 270].contains(geometry.rotationDegrees) else { return false }
        if let blocks = geometry.blocks {
            guard blocks == OCRTextBlocks.make(geometry.lines) else { return false }
        }
        if let coverage = geometry.coverage {
            guard coverage.regions.count <= 128 else { return false }
            let totals = [coverage.comparedRegions, coverage.totalDetectedCharacters, coverage.totalCoveredCharacters]
            if totals.contains(where: { $0 != nil }) {
                guard let regions = coverage.comparedRegions, let detected = coverage.totalDetectedCharacters,
                      let covered = coverage.totalCoveredCharacters,
                      (coverage.regions.count...24_576).contains(regions), (0...6_291_456).contains(detected),
                      covered >= 0, covered <= detected,
                      detected >= coverage.regions.reduce(0, { $0 + $1.detectedCharacters }),
                      covered >= coverage.regions.reduce(0, { $0 + $1.coveredCharacters }) else { return false }
            }
            guard coverage.regions.count <= 128, coverage.regions.allSatisfy({ region in
                region.detectedCharacters >= 3 && region.coveredCharacters >= 0
                    && region.coveredCharacters <= region.detectedCharacters && validBounds(region.bounds)
            }) else { return false }
        }
        let units = Array(text.utf16)
        let count = units.count
        return geometry.lines.allSatisfy { line in
            let box = line.bounds
            if let prior = line.priorReadings {
                guard prior.count <= 4, Set(prior).count == prior.count,
                      prior.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 4096 }) else { return false }
            }
            if line.sourceRepair == .decimalSeparator || line.policyIdentifierRepair == true {
                guard line.method == .vision, (line.confidence ?? 0) >= 0.95,
                      line.location >= 0, line.location <= count, line.length > 0, line.length <= count - line.location,
                      let range = Range(NSRange(location: line.location, length: line.length), in: text)
                else { return false }
                let current = String(text[range])
                if line.sourceRepair == .decimalSeparator,
                   line.priorReadings?.contains(where: { OCRDecimalSourceRepair.permits($0, current) }) != true { return false }
                if line.policyIdentifierRepair == true,
                   line.priorReadings?.contains(where: { OCRPolicyIdentifierRepair.permits($0, current) }) != true { return false }
            }
            return line.location >= 0 && line.location <= count && line.length > 0 && line.length <= count - line.location
                && !(0xDC00...0xDFFF).contains(units[line.location])
                && (line.location + line.length == count || !(0xDC00...0xDFFF).contains(units[line.location + line.length]))
                && validBounds(box)
                && (line.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true)
        }
    }

    private static func validBounds(_ box: CGRect) -> Bool {
        [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite)
            && box.width > 0 && box.height > 0 && box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1
    }
}
