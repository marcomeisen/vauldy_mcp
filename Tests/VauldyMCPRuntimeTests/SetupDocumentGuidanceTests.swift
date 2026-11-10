import Foundation
import Testing
@testable import VauldyMCPSetup
@testable import VauldyCore

@Suite("Existing documents do not require another import")
struct SetupDocumentGuidanceTests {
    private func metadata(_ state: LocalImportState, original: LocalOriginalState = .available) -> LocalImportMetadata {
        var info = LocalImportMetadata(contentHash: String(repeating: "a", count: 64), fileExtension: "pdf")
        info.state = state; info.originalState = original
        info.pages = [.init(page: 1, method: .vision)]
        return info
    }

    @Test(arguments: ["needsReview", "failed", "stale", "unavailable", "pending"])
    func analysisFlagsAloneDoNotRequestAnotherOCR(status: String) {
        let display = SetupDocumentGuidance(metadata: metadata(.completed), hasText: true, analysisStatus: status)
        #expect(!display.needsTextReview)
        #expect(display.nextStep == nil)
        #expect(display.analysisExplanation.contains("weder einen neuen Import noch eine erneute Texterkennung"))
        #expect(display.textStatus == "Text vorhanden")
    }

    @Test(arguments: [LocalImportState.partial, .failed, .interrupted, .cancelled])
    func unfinishedOCRRetainsStoredTextAndGuidesToInspection(state: LocalImportState) {
        let display = SetupDocumentGuidance(metadata: metadata(state), hasText: true, analysisStatus: "needsReview")
        #expect(display.needsTextReview)
        #expect(display.textStatus.contains("Text vorhanden"))
        #expect(display.nextStep?.contains("Prüfstellen ansehen") == true)
        #expect(display.nextStep?.contains("kein erneuter Import nötig") == true)
    }

    @Test func absentTextAndPendingJobsStayDistinct() {
        let empty = SetupDocumentGuidance(metadata: metadata(.failed), hasText: false, analysisStatus: "unavailable")
        #expect(empty.needsTextReview && empty.textStatus == "Noch kein lesbarer Text")
        #expect(empty.nextStep?.contains("gespeicherte Original") == true)
        for state in [LocalImportState.queued, .recognizing] {
            let pending = SetupDocumentGuidance(metadata: metadata(state), hasText: false, analysisStatus: "pending")
            #expect(!pending.needsTextReview)
            #expect(pending.nextStep?.contains("Warte") == true)
        }
    }

    @Test func originalAccessIssuesAreNotOCRInstructions() {
        let absent = SetupDocumentGuidance(metadata: metadata(.completed, original: .unavailable), hasText: true, analysisStatus: "completed")
        #expect(absent.textStatus.contains("gespeicherter Text bleibt erhalten"))
        #expect(absent.nextStep?.contains("Originalzugriff") == true)
        let changed = SetupDocumentGuidance(metadata: metadata(.completed, original: .changed), hasText: true, analysisStatus: "stale")
        #expect(changed.textStatus.contains("historisch"))
        #expect(changed.nextStep?.contains("Originalfassung") == true)
    }

    @Test func pageReviewAndLegacyDocumentsArePreserved() {
        var info = metadata(.completed); info.pages[0].needsReview = true
        #expect(SetupDocumentGuidance(metadata: info, hasText: true, analysisStatus: "completed").needsTextReview)
        let legacy = SetupDocumentGuidance(metadata: nil, hasText: true, analysisStatus: "unavailable")
        #expect(!legacy.needsTextReview && legacy.nextStep == nil)
        let document = VaultDocument(title: "Synthetisch", sourceName: "test.pdf", ocrText: "--- Seite 1 ---\nBeitrag: 49,99 EUR", pageCount: 1)
        let before = document.ocrText
        #expect(SetupDocumentGuidance(document).textStatus == "Text vorhanden")
        #expect(document.ocrText == before)
    }

    @Test func storedButUnfinishedOutcomesAreNotFailedImports() {
        for state in [LocalImportState.failed, .interrupted, .cancelled] {
            let outcome = LocalImportOutcome(documentID: UUID(), state: state, reusedOriginal: false, pageCount: 1)
            let item = SetupImportReport.Item(name: "synthetic.pdf", outcome: outcome, isRetry: false)
            #expect(item.result == .textPending && item.documentID == outcome.documentID)
            #expect(item.ocrReview && item.detail?.contains("kein erneuter Import nötig") == true)
            #expect(SetupImportReport.Item(name: "synthetic.pdf", result: .failed).documentID == nil)
        }
        let outcome = LocalImportOutcome(documentID: UUID(), state: .partial, reusedOriginal: true, pageCount: 1)
        let item = SetupImportReport.Item(name: "existing.pdf", outcome: outcome, isRetry: false)
        #expect(item.result == .existing && item.ocrReview)
        let failedRetry = SetupImportReport.Item(name: "existing.pdf", result: .failed, documentID: outcome.documentID)
        #expect(failedRetry.result == .textPending && failedRetry.documentID == outcome.documentID)
        #expect(failedRetry.ocrReview)
    }
}
