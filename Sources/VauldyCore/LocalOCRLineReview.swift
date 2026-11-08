import Foundation

/// Local, content-free evidence for the line decision. Missing legacy metadata
/// never implies that an earlier page was reviewed by this policy.
public struct LocalOCRLineReview: Codable, Equatable, Sendable {
    public var uncertainLines = 0
    public var confirmedUncertainLines = 0
    public var unconfirmedLines = 0
    public var ambiguousIdentifiers = 0
    public var conflictingReadings = 0
    public var unavailableRetries = 0
    public var budgetLimitedLines = 0
    public var repairedLines = 0
    public var confirmedUnchangedLines = 0
    public var normalizedCrops = 0
    public var lowConfidenceRegions = 0
    public var shortTextRegions = 0
    public init() {}

    public enum Reason: String, Codable, Sendable {
        case unconfirmedLine, ambiguousIdentifier, conflictingReadings, retryBudgetExhausted
        case lowPageConfidence, shortText
    }
    public var reasons: [Reason] {
        var result: [Reason] = []
        if unconfirmedLines > 0 { result.append(.unconfirmedLine) }
        if ambiguousIdentifiers > 0 { result.append(.ambiguousIdentifier) }
        if conflictingReadings > 0 { result.append(.conflictingReadings) }
        if budgetLimitedLines > 0 { result.append(.retryBudgetExhausted) }
        if lowConfidenceRegions > 0 { result.append(.lowPageConfidence) }
        if shortTextRegions > 0 { result.append(.shortText) }
        return result
    }
    public var needsReview: Bool { !reasons.isEmpty }

    mutating func merge(_ other: Self) {
        uncertainLines += other.uncertainLines
        confirmedUncertainLines += other.confirmedUncertainLines
        unconfirmedLines += other.unconfirmedLines
        ambiguousIdentifiers += other.ambiguousIdentifiers
        conflictingReadings += other.conflictingReadings
        unavailableRetries += other.unavailableRetries
        budgetLimitedLines += other.budgetLimitedLines
        repairedLines += other.repairedLines
        confirmedUnchangedLines += other.confirmedUnchangedLines
        normalizedCrops += other.normalizedCrops
        lowConfidenceRegions += other.lowConfidenceRegions
        shortTextRegions += other.shortTextRegions
    }
}

/// An unsuccessful optional retry cannot make an uncertain source line disappear
/// from the assessment. Only a confirmed reading resolves it; ambiguous codes stay open.
struct OCRLineReviewState {
    let uncertain: Set<Int>
    let ambiguous: Set<Int>
    var attempted: Set<Int> = []
    var confirmed: Set<Int> = []
    var repaired: Set<Int> = []
    var unchanged: Set<Int> = []
    var conflicts: Set<Int> = []
    var unavailable: Set<Int> = []

    mutating func confirm(_ index: Int, repaired: Bool) {
        guard !ambiguous.contains(index), !conflicts.contains(index) else { return }
        confirmed.insert(index)
        if repaired { self.repaired.insert(index) } else { unchanged.insert(index) }
    }
    var summary: LocalOCRLineReview {
        var result = LocalOCRLineReview()
        result.uncertainLines = uncertain.count
        result.confirmedUncertainLines = uncertain.intersection(confirmed).count
        result.unconfirmedLines = uncertain.subtracting(confirmed).count
        result.ambiguousIdentifiers = ambiguous.count
        result.conflictingReadings = conflicts.count
        result.unavailableRetries = unavailable.count
        result.budgetLimitedLines = uncertain.subtracting(attempted).count
        result.repairedLines = repaired.count
        result.confirmedUnchangedLines = unchanged.count
        return result
    }
}
