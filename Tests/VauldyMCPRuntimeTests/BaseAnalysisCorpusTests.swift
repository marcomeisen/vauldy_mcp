import Foundation
import Testing
import VauldyDocumentIntelligence
@testable import VauldyCore

struct OverviewCorpus: Decodable {
    let version: Int
    let cases: [Case]
    struct Case: Decodable {
        let id: String
        let domain: String
        let split: String
        let filename: String
        let pages: [Page]
        let expected: Expected
        struct Page: Decodable { let text: String; let needsReview: Bool }
        struct Expected: Decodable {
            let kind: String?
            let issuer: String?
            let issueDate: String?
            let subject: String?
            let titleYear: String?
            let overviewContains: [String]
            let status: String
            let logicalDocuments: Int
        }
        var sourcePages: [BaseAnalysisPage] { pages.enumerated().map { .init(number: $0.offset + 1, text: $0.element.text, needsReview: $0.element.needsReview) } }
        var ocr: LocalOCRResult { .init(pages: pages.enumerated().map {
            .init(info: .init(page: $0.offset + 1, method: $0.element.text.isEmpty ? .unreadable : .embeddedText,
                             needsReview: $0.element.needsReview), text: $0.element.text)
        }) }
    }
    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "overview-corpus", withExtension: "json"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@Suite("Document-wide local base analysis")
struct BaseAnalysisCorpusTests {
    @Test func allAnnotatedDomainsAndHoldoutsMeetTheirIndependentExpectations() async throws {
        let corpus = try OverviewCorpus.load()
        #expect(corpus.version == 1)
        #expect(Set(corpus.cases.map(\.domain)).count == 14)
        #expect(corpus.cases.contains { $0.split == "holdout" })
        var observed: [(OverviewCorpus.Case, DocumentBaseAnalysis)] = []
        for fixture in corpus.cases {
            let result = try await LocalRuleBasedDocumentAnalyzer().analyze(pages: fixture.sourcePages)
            check(result, against: fixture)
            observed.append((fixture, result))
            #expect(result.analyzedPages == Array(1...fixture.pages.count), "\(fixture.id): page coverage")
            for card in result.documents {
                for field in card.fields {
                    #expect(card.pages.contains(field.page), "\(fixture.id): source ownership")
                    #expect(fixture.pages[field.page - 1].text.contains(field.quote), "\(fixture.id): unchanged evidence")
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["VAULDY_BASE_ANALYSIS_REPORT"] {
            try writeCorpusReport(observed, to: URL(fileURLWithPath: path))
        }
    }

    @Test func importReloadAndExplicitReanalysisUseTheSameAcceptancePath() async throws {
        for fixture in try OverviewCorpus.load().cases {
            try await baseStore { root, store in
                let file = root.appendingPathComponent(fixture.filename)
                let original = Data("synthetic source \(fixture.id)".utf8)
                try original.write(to: file)
                let outcome = try await LocalImportService(store: store, ocr: CorpusOCR(result: fixture.ocr)).importFile(file)
                let reloaded = LocalDocumentStore(root: store.root)
                let document = try #require(try await reloaded.documents().first)
                let analysis = try #require(document.currentBaseAnalysis)
                check(analysis, against: fixture)
                #expect(document.baseAnalysisSourceHash != nil)
                #expect(try Data(contentsOf: await reloaded.original(for: outcome.documentID)) == original)
                let repeated = try await LocalBaseAnalysisService(store: reloaded).analyze(documentID: outcome.documentID)
                #expect(repeated.currentBaseAnalysis == analysis, "\(fixture.id): reanalysis idempotence")
                #expect(repeated.title == document.title && repeated.summary == document.summary)
                #expect(try Data(contentsOf: file) == original)
                let duplicate = try await LocalImportService(store: reloaded, ocr: CorpusOCR(result: .init(pages: []))).importFile(file)
                #expect(duplicate.reusedOriginal && duplicate.documentID == outcome.documentID)
            }
        }
    }

    @Test func sourceChangesInvalidateStoredAnalysisAndManualMetadataSurvives() async throws {
        let fixture = try #require(try OverviewCorpus.load().cases.first)
        try await baseStore { root, store in
            let file = root.appendingPathComponent(fixture.filename); try Data("synthetic".utf8).write(to: file)
            _ = try await LocalImportService(store: store, ocr: CorpusOCR(result: fixture.ocr)).importFile(file)
            var document = try #require(try await store.documents().first)
            document.title = "Meine eigene Bezeichnung"; document.summary = "Meine eigene Notiz"
            try write([document], store: store)
            let repeated = try await LocalBaseAnalysisService(store: store).analyze(documentID: document.id)
            #expect(repeated.title == document.title && repeated.summary == document.summary)
            var changed = repeated; changed.ocrText += "\nKorrigierte Quelle"
            try write([changed], store: store)
            #expect(changed.baseAnalysisStatus == "stale")
            await #expect(throws: LocalImportError.staleAttempt) {
                try await store.saveBaseAnalysis(try #require(repeated.baseAnalysis), expected: repeated)
            }
        }
    }

    @Test func analysisFailurePreservesSuccessfulOCRWithoutPretendingSuccess() async throws {
        let fixture = try #require(try OverviewCorpus.load().cases.first)
        try await baseStore { root, store in
            let file = root.appendingPathComponent(fixture.filename); try Data("synthetic".utf8).write(to: file)
            let outcome = try await LocalImportService(store: store, ocr: CorpusOCR(result: fixture.ocr), analyzer: FailingBaseAnalyzer()).importFile(file)
            let document = try #require(try await store.documents().first)
            #expect(outcome.state == .completed)
            #expect(document.isSearchable)
            #expect(document.baseAnalysisStatus == "failed")
            #expect(document.summary.isEmpty)
            #expect(document.baseAnalysis?.issues == ["ANALYSIS_FAILED"])
        }
    }

    @Test func wrappedOrdinalsAndAmountContinuationsRemainInTheLiteralOverview() async throws {
        let text = "Mitteilung\nAbsender: Beispiel Wasserwerk\nBetreff: Zählerwechsel\nDer Zähler wird am 12.\nDezember 2026 ausgetauscht. Der\nGesamtbetrag von 30,00 EUR wird nur bei Zusatzarbeiten fällig.\n•Name: Erika Musterfrau\nE-Mail: erika@example.com"
        let result = try await LocalRuleBasedDocumentAnalyzer().analyze(pages: [.init(number: 1, text: text)])
        let overview = try #require(result.documents.first?.overview)
        #expect(overview.value.contains("12. Dezember 2026"))
        #expect(overview.value.contains("30,00 EUR wird nur bei Zusatzarbeiten fällig."))
        #expect(text.contains(overview.quote))
    }

    @Test func proposedForeignPageAndWrongRolesCannotBecomeAcceptedFacts() throws {
        let pages = [BaseAnalysisPage(number: 1, text: "Rechnung\nEmpfänger: Fremde Bank\nGeburtsdatum: 01.01.1980\nBetreff: Fahrradreparatur\nWir berechnen die vereinbarte Reparatur des Fahrrads mit einem Gesamtbetrag von 49,99 EUR.")]
        let wrongIssuer = BaseEvidenceField(role: .issuer, value: "Fremde Bank", page: 1, quote: "Empfänger: Fremde Bank")
        let wrongDate = BaseEvidenceField(role: .issueDate, value: "1980-01-01", page: 1, quote: "Geburtsdatum: 01.01.1980")
        let foreignSubject = BaseEvidenceField(role: .subject, value: "Fahrradreparatur", page: 2, quote: "Betreff: Fahrradreparatur")
        let result = BaseAnalysisPipeline.finalize([.init(pages: [1], kind: .invoice, issuer: wrongIssuer,
                                                         issueDate: wrongDate, subject: foreignSubject)], pages: pages)
        let card = try #require(result.documents.first)
        #expect(card.issuer == nil && card.issueDate == nil && card.subject == nil)
        #expect(result.status == .needsReview)
    }
}

func check(_ result: DocumentBaseAnalysis, against fixture: OverviewCorpus.Case) {
    #expect(result.status.rawValue == fixture.expected.status, "\(fixture.id): status \(result.issues)")
    #expect(result.documents.count == fixture.expected.logicalDocuments, "\(fixture.id): logical documents")
    guard let first = result.documents.first else { return }
    #expect(first.kind.rawValue == fixture.expected.kind, "\(fixture.id): type")
    #expect(first.issuer?.value == fixture.expected.issuer, "\(fixture.id): issuer")
    #expect(first.issueDate?.value == fixture.expected.issueDate, "\(fixture.id): issue date")
    #expect(first.subject?.value == fixture.expected.subject, "\(fixture.id): subject")
    #expect(first.titleYear?.value == fixture.expected.titleYear, "\(fixture.id): title year role")
    for term in fixture.expected.overviewContains {
        #expect(first.overview?.value.contains(term) == true, "\(fixture.id): critical overview fact \(term)")
    }
}
private struct CorpusOCR: LocalDocumentOCR {
    let result: LocalOCRResult
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult { result }
}
private struct FailingBaseAnalyzer: DocumentBaseAnalyzing {
    struct Failure: Error {}
    func analyze(pages: [BaseAnalysisPage]) async throws -> DocumentBaseAnalysis { throw Failure() }
}
func baseStore(body: (URL, LocalDocumentStore) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-base-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root, LocalDocumentStore(root: root.appendingPathComponent("vault")))
}
private func write(_ documents: [VaultDocument], store: LocalDocumentStore) throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(documents).write(to: store.snapshotURL, options: .atomic)
}
