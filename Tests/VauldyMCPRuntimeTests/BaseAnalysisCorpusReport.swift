import Foundation
import VauldyDocumentIntelligence

func writeCorpusReport(_ results: [(OverviewCorpus.Case, DocumentBaseAnalysis)], to url: URL, scope: String = "Synthetic OCR transcripts and independent expected roles; not a real-document/model/OCR accuracy benchmark.") throws {
    var confusion: [String: [String: Int]] = [:]
    var statuses: [String: Int] = [:]
    var critical = 0, retained = 0, fieldChecks = 0, correctFields = 0, falseFields = 0, actualFields = 0, missingFields = 0
    let rows: [[String: Any]] = results.map { fixture, analysis in
        let first = analysis.documents.first
        let expected = fixture.expected.kind ?? "unavailable", actual = first?.kind.rawValue ?? "unavailable"
        confusion[expected, default: [:]][actual, default: 0] += 1
        statuses[analysis.status.rawValue, default: 0] += 1
        let pairs = [(fixture.expected.issuer, first?.issuer?.value), (fixture.expected.issueDate, first?.issueDate?.value),
                     (fixture.expected.subject, first?.subject?.value), (fixture.expected.titleYear, first?.titleYear?.value)]
        for (gold, value) in pairs {
            if gold != nil { fieldChecks += 1; if gold == value { correctFields += 1 } }
            if value != nil { actualFields += 1; if value != gold { falseFields += 1 } }
            if gold != nil && value == nil { missingFields += 1 }
        }
        for term in fixture.expected.overviewContains { critical += 1; if first?.overview?.value.contains(term) == true { retained += 1 } }
        let passed = expected == actual && analysis.status.rawValue == fixture.expected.status
            && pairs.allSatisfy { $0.0 == $0.1 } && analysis.documents.count == fixture.expected.logicalDocuments
            && fixture.expected.overviewContains.allSatisfy { first?.overview?.value.contains($0) == true }
        return ["id": fixture.id, "domain": fixture.domain, "split": fixture.split, "passed": passed,
                "expectedStatus": fixture.expected.status, "actualStatus": analysis.status.rawValue,
                "expectedType": expected, "actualType": actual, "issues": analysis.issues,
                "physicalPages": fixture.pages.count, "analyzedPages": analysis.analyzedPages]
    }
    let labels = Set(confusion.keys).union(confusion.values.flatMap(\.keys))
    let f1 = labels.map { label -> Double in
        let tp = confusion[label]?[label] ?? 0
        let predicted = confusion.values.reduce(0) { $0 + ($1[label] ?? 0) }
        let expected = confusion[label]?.values.reduce(0, +) ?? 0
        return predicted + expected == 0 ? 0 : 2 * Double(tp) / Double(predicted + expected)
    }
    let report: [String: Any] = ["corpusVersion": 1, "engine": "local-rules-extractive-v1", "cases": results.count,
        "scope": scope,
        "domains": Set(results.map { $0.0.domain }).sorted(), "outcomes": statuses, "classificationConfusion": confusion,
        "macroF1": f1.reduce(0, +) / Double(max(1, f1.count)), "populatedFieldChecks": fieldChecks,
        "correctPopulatedFields": correctFields, "falsePopulatedFields": falseFields,
        "actualPopulatedFields": actualFields, "missingExpectedFields": missingFields,
        "criticalOverviewFacts": critical, "retainedCriticalOverviewFacts": retained,
        "allPassed": rows.allSatisfy { $0["passed"] as? Bool == true }, "results": rows]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
