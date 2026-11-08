import Foundation

/// Content-free timings. Cache hits retain original evidence but get their own measured lookup time.
public struct LocalOCRMetrics: Codable, Equatable, Sendable {
    public var inspectionMilliseconds = 0
    public var renderMilliseconds = 0
    public var recognitionMilliseconds = 0
    public var cacheMilliseconds = 0
    public var cacheHit = false
    public var renderedPixels = 0
    public var recognitionRegions = 0
    public var pdfScaleRetries: Int?
    public var coverageMilliseconds: Int?
    public var coverageRenderedPixels: Int?
    public var smallTextDetectionRegions: Int?
    public var smallTextDetectionPixels: Int?
    public var regionRetries: Int?
    public var recoveredRegionLines: Int?
    public var regionRetryMilliseconds: Int?
    public var regionRetryPixels: Int?
    public var regionRecoveryConflicts: Int?
    public var evidencePreservedFallback: Bool?
    public var targetedRetries: Int?
    public var recoveredLines: Int?
    public var lineReview: LocalOCRLineReview?
    public init() {}
    mutating func mergeCoverage(_ other: Self?) {
        if let value = other?.coverageMilliseconds { coverageMilliseconds = (coverageMilliseconds ?? 0) + value }
        if let value = other?.coverageRenderedPixels { coverageRenderedPixels = (coverageRenderedPixels ?? 0) + value }
    }
}

struct LocalStopwatch {
    private let start = DispatchTime.now().uptimeNanoseconds
    var milliseconds: Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
}

public struct LocalImportMetrics: Codable, Equatable, Sendable {
    public var analysisMilliseconds: Int? = nil
    public var validationMilliseconds: Int
    public var ocrMilliseconds: Int
    public var totalMilliseconds: Int
    public var storageMilliseconds: Int?
}
