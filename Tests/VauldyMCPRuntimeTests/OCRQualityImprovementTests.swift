import Foundation
import Testing
@testable import VauldyCore

@Suite("Frozen OCR improvement and zero prior-field loss")
struct OCRQualityImprovementTests {
    struct Manifest: Decodable { let truth: [String: [String]]; let sha256: [String: String] }
    struct Baseline: Decodable { let inputHashes: [String: String]; let pages: [String: LocalOCRPage] }
    struct V15Fields: Decodable { let inputHashes: [String: String]; let fields: [String: [String]] }

    @Test func unchangedCorpusGainsFieldsWithoutLosingCorrectReadingsOrHistory() async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf:
            #require(Bundle.module.url(forResource: "faint-line-corpus", withExtension: "json"))))
        let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf:
            #require(Bundle.module.url(forResource: "ocr-v14-frozen-baseline", withExtension: "json"))))
        #expect(manifest.sha256 == baseline.inputHashes)
        let v17 = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf:
            #require(Bundle.module.url(forResource: "ocr-v17-image-baseline", withExtension: "json"))))
        #expect(manifest.sha256 == v17.inputHashes)
        let v15 = try JSONDecoder().decode(V15Fields.self, from: Data(contentsOf:
            #require(Bundle.module.url(forResource: "ocr-v15-correct-fields", withExtension: "json"))))
        #expect(v15.inputHashes == manifest.sha256 && v15.fields.values.reduce(0, { $0 + $1.count }) == 53)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-v15-frozen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var beforeTotal = 0, afterTotal = 0, preservedTotal = 0, unmarkedErrors = 0
        for name in manifest.truth.keys.sorted() {
            let fields = try #require(manifest.truth[name]), before = try #require(baseline.pages[name])
            let file = root.appendingPathComponent(name)
            try OCRFaintRasterTests().makeSample(name: name, fields: fields).write(to: file)
            let bytes = try Data(contentsOf: file)
            #expect(LocalOriginalAccess.hash(bytes) == manifest.sha256[name], Comment(rawValue: name))
            let after = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
            let retained = EvidencePreservingLocalOCR.preserving(previous: before, candidate: after)
            let latest = try #require(v17.pages[name])
            let latestFresh = EvidencePreservingLocalOCR.preserving(previous: latest, candidate: after)
            #expect(latestFresh.text == after.text, Comment(rawValue: name + " v17 fresh preserves new readings"))
            #expect(EvidencePreservingLocalOCR.preserving(previous: latestFresh, candidate: after).text == after.text)
            for field in fields where latest.text.contains(field) {
                #expect(after.text.contains(field), Comment(rawValue: name + " v17 " + field))
            }
            var evidence = after.text.components(separatedBy: .newlines)
                + (after.geometry?.lines.flatMap { $0.priorReadings ?? [] } ?? [])
            for line in latest.text.components(separatedBy: .newlines) {
                if let index = evidence.firstIndex(of: line) { evidence.remove(at: index) }
                else { Issue.record(Comment(rawValue: name + " lost v17 evidence: " + line)) }
            }
            if name == "tilted-9-right.png" {
                #expect(after.text.contains("Beitrag: 82,47 EUR"))
                #expect(after.geometry?.lines.last?.sourceRepair == .decimalSeparator)
            }
            if name == "ambiguous.png" {
                #expect(after.text.contains("Policennummer: IO0O-171"))
                let repaired = try #require(after.geometry?.lines.first { $0.policyIdentifierRepair == true })
                #expect(repaired.priorReadings?.contains("Policennummer: 1000-171") == true)
                #expect(after.info.needsReview)
            }
            let old = Set(fields.filter { before.text.contains($0) })
            let new = Set(fields.filter { after.text.contains($0) })
            let fresh = Set(fields.filter { retained.text.contains($0) })
            #expect(old.isSubset(of: new) && old.isSubset(of: fresh), Comment(rawValue: name))
            #expect(new == fresh, Comment(rawValue: name + " fresh retry must retain the improvement"))
            #expect(Set(v15.fields[name] ?? []).isSubset(of: new), Comment(rawValue: name + " retains every correct v15 field"))
            #expect(Set(v15.fields[name] ?? []).isSubset(of: fresh))
            let history = Set(retained.geometry?.lines.flatMap { $0.priorReadings ?? [] } ?? [])
            let current = Set(retained.text.components(separatedBy: .newlines))
            #expect(before.text.components(separatedBy: .newlines).allSatisfy { current.contains($0) || history.contains($0) })
            beforeTotal += old.count; afterTotal += new.count; preservedTotal += fresh.count
            if new.count < fields.count && !after.info.needsReview { unmarkedErrors += 1 }
            #expect(try Data(contentsOf: file) == bytes)
            if let path = ProcessInfo.processInfo.environment["VAULDY_OCR_IMPROVED_FIXTURES"] {
                let out = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try bytes.write(to: out.appendingPathComponent(name))
                try JSONEncoder().encode(after).write(to: out.appendingPathComponent(name + ".json"))
                try JSONEncoder().encode(retained).write(to: out.appendingPathComponent(name + ".fresh.json"))
                try JSONEncoder().encode(latestFresh).write(to: out.appendingPathComponent(name + ".v17-fresh.json"))
            }
        }
        print("QUALITY-V15 before=\(beforeTotal) after=\(afterTotal) fresh=\(preservedTotal) unmarked-errors=\(unmarkedErrors)")
        #expect(beforeTotal == 52 && afterTotal >= 55 && preservedTotal == afterTotal)
        #expect(unmarkedErrors == 0)
    }

    @Test func numericPolicyIdentifierRemainsNumeric() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-policy-control-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("numeric-policy.png")
        let original = "Policennummer: 1000-171"
        try LineScan(name: "numeric-policy", fields: [original, "Beitrag: 81,19 EUR"],
                     size: 15, gray: 0.67, noise: 3).write(to: file)
        let page = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
        #expect(page.text.contains(original))
        #expect(page.geometry?.lines.contains(where: { $0.policyIdentifierRepair == true }) == false)
    }

    @Test func aRepairCannotHideChangedNumbersOrAnUnrelatedPosition() {
        let old = "Leistung: Zahnriemerwechsel am Aggregat", new = "Leistung: Zahnriemenwechsel am Aggregat"
        func page(_ text: String, box: CGRect, prior: [String]? = nil) -> LocalOCRPage {
            var result = LocalOCRPage(info: .init(page: 1, method: .vision, confidence: 1), text: text)
            result.geometry = .vision(texts: [text], bounds: [box], confidences: [1])
            result.geometry?.configuration = LocalOCRPageCache.configuration
            result.geometry?.lines[0].priorReadings = prior
            return result
        }
        let box = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)
        let previous = page(old, box: box)
        let candidate = page(new, box: box, prior: [old])
        let accepted = EvidencePreservingLocalOCR.preserving(previous: previous, candidate: candidate)
        #expect(accepted.text == new && accepted.info.needsReview)
        #expect(accepted.geometry?.lines[0].priorReadings == [old])
        let repeated = EvidencePreservingLocalOCR.preserving(previous: accepted, candidate: page(new, box: box))
        #expect(repeated.geometry?.lines[0].priorReadings == [old] && repeated.info.needsReview)
        #expect(EvidencePreservingLocalOCR.preserving(previous: previous, candidate: page(new, box: box)).text == old)
        #expect(EvidencePreservingLocalOCR.preserving(previous: previous,
            candidate: page(new, box: box.offsetBy(dx: 0, dy: 0.3), prior: [old])).text == old)
        let money = page("Beitrag: 82.47 EUR", box: box)
        #expect(EvidencePreservingLocalOCR.preserving(previous: money,
            candidate: page("Beitrag: 82,47 EUR", box: box, prior: [money.text])).text == money.text)
        let duplicate = LocalOCRPage(info: .init(page: 1, method: .vision), text: old + "\n" + old)
        #expect(EvidencePreservingLocalOCR.preserving(previous: duplicate, candidate: candidate).text == duplicate.text)
    }
}
