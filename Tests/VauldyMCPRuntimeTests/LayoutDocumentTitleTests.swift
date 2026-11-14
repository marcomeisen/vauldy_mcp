import Foundation
import Testing
import VauldyDocumentIntelligence
@testable import VauldyCore

@Suite("Layout evidence for document titles")
struct LayoutDocumentTitleTests {
    private let body = [
        line("Diese Angaben dienen Ihnen zur Information.", y: 0.48),
        line("Die nächste Seite enthält die Einzelheiten.", y: 0.45),
        line("Bewahren Sie dieses Schreiben auf.", y: 0.42),
    ]

    @Test func headingWinsOverProseForwardingAndTableLabels() {
        let lines = [
            line("Beispiel Versicherung AG", y: 0.91, height: 0.030, x: 0.66, width: 0.25),
            line("Rechnung wird nach Zahlung gültig", y: 0.84, height: 0.042),
            line("Fwd: Versicherungsdokument", y: 0.80, height: 0.035),
            line("Rechnung: Bitte überweisen Sie den Betrag", y: 0.75, height: 0.035),
            line("Beitragsmitteilung", y: 0.71, height: 0.026),
            line("Vertrag", y: 0.62, x: 0.12, width: 0.24),
            line("Bezeichnung/*Begrüncurg", y: 0.62, x: 0.42, width: 0.24),
            line("Betrag", y: 0.62, x: 0.72, width: 0.16),
        ] + body
        let title = resolve(lines)
        #expect(title.value == "Beitragsmitteilung – Beispiel Versicherung AG")
        #expect(title.page == 1)
    }

    @Test func joinsAlignedHeadingLinesButNotBodyText() {
        let lines = [
            line("Rechnung", y: 0.80, height: 0.030),
            line("Fahrrad und Zubehör", y: 0.767, height: 0.028),
            line("Kundenreferenz", y: 0.67),
        ] + body
        #expect(resolve(lines).value == "Rechnung Fahrrad und Zubehör – Aussteller unbekannt")
    }

    @Test func recurringMarginsAndLaterHeadingsDoNotReplaceOpeningTitle() {
        let running = line("Vertrag", y: 0.94, height: 0.03)
        let lines = [running, line("Mitteilung", y: 0.73, height: 0.03)] + body
        let title = resolve(lines, later: [.init(number: 2, lines: [running, line("Rechnung", y: 0.81)])])
        #expect(title.value == "Mitteilung – Aussteller unbekannt")
    }

    @Test func comparableConflictingHeadingsYieldNeutralTitle() {
        let title = resolve([
            line("Rechnung", y: 0.80, height: 0.026),
            line("Versicherungsschein", y: 0.71, height: 0.026),
        ] + body)
        #expect(title.value == DocumentTitlePolicy.fallback)
        #expect(title.page == nil)
    }

    @Test func lowConfidenceTextAndRecipientAreNotPromoted() {
        let lines = [
            line("Empfänger: Beispiel GmbH", y: 0.95),
            line("Beispiel GmbH", y: 0.89, height: 0.025),
            line("Anschreiben zum Dyr", y: 0.82, height: 0.040, confidence: 0.42),
            line("Rechnung", y: 0.71, height: 0.027),
        ] + body
        #expect(resolve(lines).value == "Rechnung – Aussteller unbekannt")
    }

    @Test func knownTitleInTableDoesNotBecomeDocumentType() {
        let lines = [
            line("Vertrag", y: 0.79, x: 0.12, width: 0.15),
            line("Bezeichnung", y: 0.79, x: 0.38, width: 0.28),
            line("Betrag", y: 0.79, x: 0.72, width: 0.16),
        ] + body
        let evidence = BaseEvidenceField(role: .documentType, value: "contract", page: 1,
                                         quote: "Vertrag", origin: .documentHeading)
        let title = resolve(lines, analysis: .init(pages: [1], kind: .contract, kindEvidence: evidence))
        #expect(title.value == DocumentTitlePolicy.fallback)
    }

    @Test func preservesOnlyVerifiedTypesWhenLayoutIsInconclusive() {
        let heading = "Versicherungsschein"
        let evidence = BaseEvidenceField(role: .documentType, value: "insuranceNotice", page: 1,
                                         quote: heading, origin: .documentHeading)
        let card = BaseDocumentOverview(pages: [1], kind: .insuranceNotice, kindEvidence: evidence)
        #expect(DocumentTitlePolicy.retainedTypeTitle(heading + " – Fwd: Weiterleitung", analysis: card)
                    == "Versicherungsschein – Aussteller unbekannt")
        #expect(DocumentTitlePolicy.retainedTypeTitle("Vertrag wird gekündigt", analysis: card) == nil)
        #expect(DocumentTitlePolicy.retainedTypeTitle("Dokument – Aussteller unbekannt", analysis: card) == nil)
    }

    @Test func previewAndRetitleShareTheImportPolicyAndPreserveEvidence() async throws {
        try await baseStore { root, _ in
            let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("title-sqlite"))
            let original = root.appendingPathComponent("Testdatei.pdf")
            try Data("synthetic original".utf8).write(to: original)
            let lines = [
                line("Beispiel Versicherung AG", y: 0.92, height: 0.026),
                line("Beitragsmitteilung", y: 0.74, height: 0.025),
            ] + body
            let id = try await LocalImportService(store: store, ocr: LayoutTitleOCR(lines: lines))
                .importFile(original).documentID
            let imported = try #require(try await store.document(id: id))
            #expect(imported.title == "Beitragsmitteilung – Beispiel Versicherung AG")
            // Simulate a legacy generated title and compare a preview against the actual write path.
            let legacy = try await store.saveGeneratedTitle("Alter OCR-Titel", expected: imported)
            let service = LocalBaseAnalysisService(store: store)
            let before = try Data(contentsOf: store.snapshotURL)
            let proposal = try #require(try await service.previewTitles().first)
            #expect(proposal.before == legacy.title)
            #expect(proposal.after == imported.title)
            #expect(proposal.method == "layout")
            #expect(proposal.headingPage == 1)
            #expect(try Data(contentsOf: store.snapshotURL) == before)
            let refreshed = try await service.regenerateTitle(documentID: id)
            #expect(refreshed == imported)
            let manual = try await store.saveManualTitle("Eigener Titel", expected: refreshed)
            let manualPreview = try #require(try await service.previewTitles().first)
            #expect(manualPreview.after == manual.title)
            #expect(manualPreview.automaticTitle == imported.title)
            #expect(manualPreview.manualOverride)
            #expect(try await store.document(id: id) == manual)

            var wrongText = imported
            wrongText.ocrText = wrongText.ocrText.replacingOccurrences(of: "Beitragsmitteilung", with: "Andere Bezeichnung")
            let analysis = try await LocalRuleBasedDocumentAnalyzer().analyze(pages: wrongText.baseAnalysisPages)
            #expect(!wrongText.resolvedTitle(using: analysis).usesLayout)
        }
    }

    private func resolve(_ lines: [TitleLayoutPage.Line], later: [TitleLayoutPage] = [],
                         analysis: BaseDocumentOverview? = nil) -> LayoutDocumentTitle {
        LayoutDocumentTitle.resolve(first: .init(number: 1, lines: lines), later: later, analysis: analysis)
    }
}

private func line(_ text: String, y: Double, height: Double = 0.013, x: Double = 0.15,
                  width: Double = 0.34, confidence: Double = 0.97) -> TitleLayoutPage.Line {
    .init(text: text, bounds: CGRect(x: x, y: y, width: width, height: height), confidence: confidence)
}

private struct LayoutTitleOCR: LocalDocumentOCR {
    let lines: [TitleLayoutPage.Line]
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        var page = LocalOCRPage(info: .init(page: 1, method: .vision), text: lines.map(\.text).joined(separator: "\n"))
        page.geometry = .vision(texts: lines.map(\.text), bounds: lines.map(\.bounds),
                                confidences: lines.map { $0.confidence ?? 1 })
        page.geometry?.configuration = "synthetic-title-layout"
        return .init(pages: [page])
    }
}
