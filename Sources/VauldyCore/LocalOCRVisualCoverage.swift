import Foundation
import CoreGraphics

public struct LocalOCRVisualRegion: Codable, Equatable, Sendable {
    public var bounds: CGRect
    public let detectedCharacters: Int
    public let coveredCharacters: Int
    public var needsReview: Bool {
        detectedCharacters - coveredCharacters >= 3 && Double(coveredCharacters) < Double(detectedCharacters) * 0.85
    }
}

public struct LocalOCRVisualCoverage: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case checked, unavailable, limited }
    public var status: Status
    public var regions: [LocalOCRVisualRegion]
    // Dense pages retain bounded region geometry plus exact streamed totals.
    public var comparedRegions: Int? = nil
    public var totalDetectedCharacters: Int? = nil
    public var totalCoveredCharacters: Int? = nil
    var detectedTotal: Int { totalDetectedCharacters ?? regions.reduce(0) { $0 + $1.detectedCharacters } }
    var missingTotal: Int { detectedTotal - (totalCoveredCharacters ?? regions.reduce(0) { $0 + $1.coveredCharacters }) }
    public var needsReview: Bool { status != .checked || regions.contains(where: \.needsReview) }

    mutating func append(_ other: Self) {
        let dense = comparedRegions != nil || other.comparedRegions != nil
        let count = (comparedRegions ?? regions.count) + (other.comparedRegions ?? other.regions.count)
        let detected = detectedTotal + other.detectedTotal
        let covered = detected - (missingTotal + other.missingTotal)
        if other.status == .unavailable { status = .unavailable }
        else if other.status == .limited && status == .checked { status = .limited }
        let all = regions + other.regions
        if dense {
            let missing = all.filter(\.needsReview)
            if missing.count > 128 && status == .checked { status = .limited }
            regions = Array((missing + all.filter { !$0.needsReview }).prefix(128))
            comparedRegions = count; totalDetectedCharacters = detected; totalCoveredCharacters = covered
        } else {
            if all.count > 128 && status == .checked { status = .limited }
            regions = Array(all.prefix(128))
        }
    }

    /// Compare at most eight batches of 128 regions, each with <=256 glyphs.
    /// Covered geometry may be omitted; every review region must be retained or
    /// the result remains limited. Totals still include the omitted geometry.
    static func segmented(characters: [[CGRect]], lines: [LocalOCRLine],
                          checkCancellation: () throws -> Void = {}) rethrows -> Self {
        if characters.count <= 128 { return compare(characters: characters, lines: lines) }
        var all: [LocalOCRVisualRegion] = []
        var status: Status = characters.count > 1024 ? .limited : .checked
        for start in stride(from: 0, to: min(characters.count, 1024), by: 128) {
            try checkCancellation()
            let batch = compare(characters: Array(characters[start..<min(start + 128, characters.count)]), lines: lines)
            if batch.status != .checked { status = batch.status }
            all += batch.regions
        }
        let missing = all.filter(\.needsReview)
        if missing.count > 128 { status = .limited }
        return Self(status: status, regions: Array((missing + all.filter { !$0.needsReview }).prefix(128)),
                    comparedRegions: all.count,
                    totalDetectedCharacters: all.reduce(0) { $0 + $1.detectedCharacters },
                    totalCoveredCharacters: all.reduce(0) { $0 + $1.coveredCharacters })
    }

    static func compare(characters: [[CGRect]], lines: [LocalOCRLine]) -> Self {
        var regions: [LocalOCRVisualRegion] = []
        var status: Status = characters.count > 128 ? .limited : .checked
        for detected in characters.prefix(128) where detected.count >= 3 {
            if detected.count > 256 { status = .limited }
            let boxes = Array(detected.prefix(256))
            let regionBounds = boxes.reduce(CGRect.null) { $0.union($1) }
            let candidates = lines.filter { $0.bounds.insetBy(dx: -0.004, dy: -0.004).intersects(regionBounds) }
            if candidates.count > 128 { status = .limited }
            let covered = boxes.filter { character in
                candidates.prefix(128).contains { line in
                    let padding = min(line.bounds.height * 0.1, 0.004)
                    let intersection = line.bounds.insetBy(dx: -padding, dy: -padding).intersection(character)
                    return !intersection.isNull && intersection.width * intersection.height >= character.width * character.height * 0.5
                }
            }.count
            regions.append(.init(bounds: regionBounds,
                                 detectedCharacters: boxes.count, coveredCharacters: covered))
        }
        return Self(status: status, regions: regions)
    }
}
