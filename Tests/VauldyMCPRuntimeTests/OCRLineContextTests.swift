import CoreGraphics
import Testing
@testable import VauldyCore

@Suite("Conservative line context selection")
struct OCRLineContextTests {
    @Test func neighbouringLinesDoNotDiscardTheUniqueTarget() {
        let target = CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.15)
        let wanted = OCRRegionRecovery.Candidate(text: "Schutz fuer Hausrat", bounds: target, confidence: 0.99)
        let neighbour = OCRRegionRecovery.Candidate(text: "Beitrag: 49,99 EUR", bounds: target.offsetBy(dx: 0, dy: 0.3), confidence: 1)
        #expect(OCRLineRecovery.select([neighbour, wanted], target: target)?.text == wanted.text)
        #expect(OCRLineRecovery.select([wanted, wanted], target: target) == nil)
        let merged = OCRRegionRecovery.Candidate(text: wanted.text + neighbour.text,
            bounds: target.union(neighbour.bounds), confidence: 1)
        #expect(OCRLineRecovery.select([merged], target: target) == nil)
        #expect(OCRLineRecovery.decide(original: "Schutz Hausrat", confidence: 0.5, alternatives: [],
            retry: wanted.text, retryConfidence: wanted.confidence, identifier: false) == .replace)
        #expect(OCRLineRecovery.decide(original: "Beitrag: 49,99 EUR", confidence: 0.4, alternatives: [],
            retry: "Beitrag: 49,89 EUR", retryConfidence: 1, identifier: false) == .review)
    }
}
