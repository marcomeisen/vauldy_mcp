import Foundation
import Testing
@testable import VauldyCore

/// Optional native gate over ACTUAL external OCR output, not invented expected text.
/// The external provider is intentionally not part of the production OCR factory.
@Suite("German alternative OCR evidence comparison")
struct LocalOCRAlternativeComparisonTests {
    private struct Manifest: Decodable { let truth: [String: [String]]; let sha256: [String: String] }
    private struct Run: Decodable {
        struct Variant: Decodable {
            struct Case: Decodable { let file: String; let textSHA256: String }
            let name: String; let cases: [Case]
        }
        let fixtures: String; let sourceHashes: [String: String]; let variants: [Variant]
        let engine: String?; let language: String?
    }
    private struct Candidate: Decodable { let engine: String; let language: String; let text: String }
    private struct Summary: Encodable {
        let name: String; let before: Int; let after: Int; let lost: Int
        let preservedEvidence: Bool; let unexpectedAdditions: Int; let fallbackPages: Int
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAULDY_OCR_ALTERNATIVE_RUN"] != nil,
                   "Requires an explicitly prepared isolated German local OCR corpus run"))
    func realGermanCandidateCannotOverwritePriorEvidence() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VAULDY_OCR_ALTERNATIVE_RUN"]))
        let run = try JSONDecoder().decode(Run.self, from: Data(contentsOf: root.appendingPathComponent("comparison.json")))
        let engine = run.engine ?? "tesseract"
        let language = run.language ?? "deu"
        #expect((engine == "tesseract" && language == "deu") || (engine == "paddleocr-pp-ocrv6-medium" && language == "de"))
        let fixtures = URL(fileURLWithPath: run.fixtures)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: #require(Bundle.module.url(forResource: "faint-line-corpus", withExtension: "json"))))
        var summaries: [Summary] = []
        for variant in run.variants {
            #expect(variant.cases.count == 35)
            #expect(Set(variant.cases.map(\.file)) == Set(manifest.truth.keys))
            var beforeCount = 0, afterCount = 0, lostCount = 0, unexpected = 0, fallbacks = 0
            var allEvidencePreserved = true
            for item in variant.cases {
                #expect(item.file == URL(fileURLWithPath: item.file).lastPathComponent)
                let original = try Data(contentsOf: fixtures.appendingPathComponent(item.file))
                #expect(LocalOriginalAccess.hash(original) == manifest.sha256[item.file])
                let beforeData = try Data(contentsOf: fixtures.appendingPathComponent(item.file + ".before.json"))
                #expect(LocalOriginalAccess.hash(beforeData) == run.sourceHashes[item.file + ".before.json"])
                let before = try JSONDecoder().decode(LocalOCRPage.self, from: beforeData)
                let candidateData = try Data(contentsOf: root.appendingPathComponent(variant.name).appendingPathComponent(item.file + ".candidate.json"))
                let external = try JSONDecoder().decode(Candidate.self, from: candidateData)
                #expect(external.engine == engine && external.language == language)
                #expect(LocalOriginalAccess.hash(Data(external.text.utf8)) == item.textSHA256)
                // Uncertified text-only input for the existing protection function. No invented
                // native confidence/geometry/provider tag. This DTO is NEVER saved to a vault.
                let candidate = LocalOCRPage(info: .init(page: before.info.page, method: .unreadable, needsReview: true), text: external.text)
                let protected = EvidencePreservingLocalOCR.preserving(previous: before, candidate: candidate)
                let fields = try #require(manifest.truth[item.file])
                let old = Set(fields.filter { before.text.contains($0) })
                let new = Set(fields.filter { protected.text.contains($0) })
                beforeCount += old.count; afterCount += new.count; lostCount += old.subtracting(new).count
                #expect(old.isSubset(of: new), Comment(rawValue: variant.name + "/" + item.file))
                var remaining = protected.text.split(whereSeparator: \.isNewline).map(String.init)[...]
                let retained = before.text.split(whereSeparator: \.isNewline).allSatisfy { oldLine in
                    guard let index = remaining.firstIndex(of: String(oldLine)) else { return false }
                    remaining = remaining[remaining.index(after: index)...]; return true
                }
                #expect(retained); allEvidencePreserved = allEvidencePreserved && retained
                if protected.info.metrics?.evidencePreservedFallback == true {
                    fallbacks += 1
                    #expect(protected.text == before.text)
                    #expect(protected.geometry == before.geometry)
                }
                var oldLines = before.text.split(whereSeparator: \.isNewline).map(String.init)
                for line in protected.text.split(whereSeparator: \.isNewline).map(String.init) {
                    if let index = oldLines.firstIndex(of: line) { oldLines.remove(at: index) }
                    else if !fields.contains(where: { $0.contains(line) }) { unexpected += 1 }
                }
                #expect(try Data(contentsOf: fixtures.appendingPathComponent(item.file)) == original)
                #expect(try Data(contentsOf: fixtures.appendingPathComponent(item.file + ".before.json")) == beforeData)
            }
            #expect(beforeCount == 52 && lostCount == 0)
            print("GERMAN-OCR \(variant.name) before=\(beforeCount) protected=\(afterCount) lost=\(lostCount) unexpected=\(unexpected) fallbacks=\(fallbacks)")
            summaries.append(.init(name: variant.name, before: beforeCount, after: afterCount, lost: lostCount,
                preservedEvidence: allEvidencePreserved, unexpectedAdditions: unexpected, fallbackPages: fallbacks))
        }
        try JSONEncoder().encode(summaries).write(to: root.appendingPathComponent("preserved-results.json"))
    }
}
