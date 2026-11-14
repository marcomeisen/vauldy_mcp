import Foundation
import CoreGraphics
import Testing
import VauldyDocumentIntelligence
import VauldyMCPRuntime
@testable import VauldyMCPSetup
@testable import VauldyCore

@Suite("Concrete local quality reasons and source locations")
struct LocalDocumentQualityTests {
    @Test func repairedReadingsRemainVisibleAndBoundToTheSource() throws {
        let text = "Leistung: Zahnriemenwechsel am Aggregat"
        let prior = "Leistung: Zahnriemerwechsel am Aggregat"
        var d = document(text: text)
        var page = LocalOCRPage(info: .init(page: 1, method: .vision, confidence: 1), text: text)
        page.geometry = .vision(texts: [text], bounds: [CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)], confidences: [1])
        page.geometry?.configuration = LocalOCRPageCache.configuration
        page.geometry?.lines[0].priorReadings = [prior]
        let hash = try #require(d.localImport?.contentHash)
        d.localImport?.pages[0].layout = try #require(LocalOCRPageLayout(sourceHash: hash, page: page))
        let roundtrip = try JSONDecoder().decode(VaultDocument.self, from: JSONEncoder().encode(d))
        let review = try #require(LocalDocumentReview(roundtrip))
        #expect(review.pages[0].revisions.first?.previous == [prior])
        #expect(review.pages[0].revisions.first?.current == text && review.pages[0].needsReview)
        #expect(review.quality.issues.contains { $0.title == "Lesung geändert" && $0.focus?.page == 1 })
        d.ocrText = "--- Seite 1 ---\nUngebundener neuer Text"
        #expect(try #require(LocalDocumentReview(d)).pages[0].revisions.isEmpty)
        page.geometry?.lines[0].priorReadings = Array(repeating: prior, count: 5)
        #expect(LocalOCRPageLayout(sourceHash: hash, page: page) == nil)
    }

    private struct ReportOCR: LocalDocumentOCR {
        func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
            .init(pages: [.init(info: .init(page: 1, method: .embeddedText), text: "Unbekannte Unterlage\nDies ist eine synthetische Beschreibung ohne belegte Dokumentart.")])
        }
    }

    @Test @MainActor func inventoryReportBindsConcreteReasonsWithoutChangingGrantOrStartingWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-quality-report-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = MCPInstallation(root: root.appendingPathComponent("installation"))
        let store = LocalDocumentStore(root: installation.root.appendingPathComponent("vault"))
        let file = root.appendingPathComponent("synthetic.pdf")
        try Data("%PDF synthetic source for injected OCR".utf8).write(to: file)
        let imported = try await LocalImportService(store: store, ocr: ReportOCR()).importFile(file)
        let profile = MCPAccessProfile(vaultPath: store.snapshotURL.path, allowedDocumentIDs: [imported.documentID], acknowledgedCloudDisclosure: true)
        let profileURL = installation.profileURL(profile.connectionID)
        try FileMCPProfileSource(url: profileURL).save(profile)
        let before = try Data(contentsOf: profileURL)
        let model = InventoryWorkflowModel(installation: installation, executable: URL(fileURLWithPath: "/not-launched"),
            profile: profile, updatesChatGPT: false) { _ in }
        model.acknowledged = true; model.acknowledgedReview = true
        try await model.makeReport()
        #expect(model.report?.snapshotDigest == (try LocalInventoryFingerprint.snapshot(store.snapshotURL)))
        #expect(model.qualityByID[imported.documentID]?.issues.contains { $0.category == .classification && $0.focus?.page == 1 } == true)
        #expect(model.reviewCount == 0 && model.report?.readyIDs.isEmpty == true)
        #expect(model.report?.reviewIDs == [imported.documentID])
        #expect(!model.acknowledged && !model.acknowledgedReview)
        #expect(try Data(contentsOf: profileURL) == before)
        let workerStatus = try await model.worker.status()
        #expect(!workerStatus.running)
    }

    private func document(text: String = "Rechnung\nGegenstand: Fahrrad\nDies ist eine synthetische Übersicht zur Wartung des Fahrrads.", count: Int = 1) -> VaultDocument {
        var d = VaultDocument(title: "Synthetisch", sourceName: "test.pdf", ocrText: "--- Seite 1 ---\n" + text, pageCount: count)
        var m = LocalImportMetadata(contentHash: String(repeating: "a", count: 64), fileExtension: "pdf")
        m.state = .completed; m.originalState = .available
        m.pages = (1...count).map { .init(page: $0, method: .vision) }; d.localImport = m
        return d
    }

    @Test func unreadableIsNotAMissingOriginalPageAndBlankCountsAsProcessed() throws {
        var d = document(count: 3)
        d.localImport?.pages[1].method = .unreadable
        d.localImport?.pages[2].method = .blank
        let q = try #require(LocalDocumentReview(d)).quality
        #expect(q.processedPages == 2 && q.expectedPages == 3)
        #expect(q.issues.contains { $0.category == .text && $0.focus?.page == 2 && $0.title == "Kein lesbarer Text erkannt" })
        #expect(!q.issues.contains { $0.focus?.page == 3 })
        #expect(q.processingLabel.contains("vorhandenen Seiten"))
        #expect(LocalDocumentQuality.completenessExplanation.contains("nicht"))
    }

    @Test func completedAnalysisDoesNotProveManualOrTableValidation() async throws {
        var d = document()
        d.applyBaseAnalysis(try await LocalRuleBasedDocumentAnalyzer().analyze(pages: d.baseAnalysisPages))
        #expect(d.baseAnalysisStatus == "completed")
        let q = try #require(LocalDocumentReview(d)).quality
        #expect(q.reviewCount == 0)
        #expect(q.headline == "Textprüfung: keine automatischen Prüfhinweise")
        #expect(q.issues.contains { !$0.requiresReview && $0.title == "Aussteller nicht belegt" })
        #expect(LocalDocumentQuality.manualReviewLabel.contains("nicht dokumentiert"))
        #expect(LocalDocumentQuality.tableLabel.contains("Keine separate"))
        #expect(!q.headline.localizedCaseInsensitiveContains("validiert"))
    }

    @Test func unknownKindAndFieldConflictAreIndependentOfOCR() async throws {
        var d = document(text: "Unbekannte Unterlage\nDies ist eine synthetische längere Beschreibung einer nicht zugeordneten Unterlage.")
        d.applyBaseAnalysis(try await LocalRuleBasedDocumentAnalyzer().analyze(pages: d.baseAnalysisPages))
        var proposal = try #require(d.currentBaseAnalysis).documents
        proposal[0].issues.append("CONFLICTING_ISSUEDATE")
        d.applyBaseAnalysis(.init(status: .needsReview, analyzedPages: [1], documents: proposal))
        let q = try #require(LocalDocumentReview(d)).quality
        #expect(q.issues.contains { $0.category == .classification && $0.title == "Dokumentart unklar" && $0.focus?.page == 1 })
        #expect(q.issues.contains { $0.title == "Dokumentdatum: widersprüchliche Angaben" })
        #expect(!q.issues.contains { $0.category == .text })
        #expect(q.reviewCount == 0 && q.textIssues.isEmpty)
        #expect(!q.basisIssues.isEmpty)
        #expect(q.basisIssues.contains { $0.requiresReview })
    }

    @Test func missingOrFailedAnalysisDoesNotCreateTextWarnings() throws {
        var d = document()
        for analysis in [nil, DocumentBaseAnalysis.failed(pages: [1]),
                         DocumentBaseAnalysis(status: .unavailable, analyzedPages: [1], documents: [])] {
            d.baseAnalysis = analysis
            let quality = try #require(LocalDocumentReview(d)).quality
            #expect(quality.reviewCount == 0)
            #expect(quality.textIssues.isEmpty && !quality.basisIssues.isEmpty)
        }
    }

    @Test func realOCRWarningRemainsVisibleAlongsideOptionalMetadata() throws {
        var d = document()
        d.localImport?.pages[0].needsReview = true
        let quality = try #require(LocalDocumentReview(d)).quality
        #expect(quality.reviewCount == 1)
        #expect(quality.textIssues.first?.category == .text)
        #expect(!quality.basisIssues.isEmpty)
    }

    @Test func aggregateLineWarningsNeverInventAnExactLocation() throws {
        var d = document(); var lines = LocalOCRLineReview(); lines.ambiguousIdentifiers = 2; lines.conflictingReadings = 1
        var metrics = LocalOCRMetrics(); metrics.lineReview = lines
        d.localImport?.pages[0].metrics = metrics
        let q = try #require(LocalDocumentReview(d)).quality
        let issues = q.issues.filter { $0.category == .text }
        #expect(issues.count == 2)
        #expect(issues.allSatisfy { $0.focus?.page == 1 && $0.focus?.bounds.isEmpty == true && $0.focus?.quote == nil })
    }

    @Test func geometryAndQuoteStayBoundToPhysicalSourceAndUTF16() throws {
        let text = "🚲 Jörg Müller\nBetrag: 13,80 €"
        var d = document(text: text)
        var page = LocalOCRPage(info: .init(page: 1, method: .vision), text: text)
        let box = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1)
        page.geometry = .vision(texts: ["🚲 Jörg Müller", "Betrag: 13,80 €"], bounds: [CGRect(x: 0.1, y: 0.7, width: 0.6, height: 0.1), box], confidences: [0.9, 0.9])
        page.geometry?.configuration = LocalOCRPageCache.configuration
        page.geometry?.coverage = .init(status: .checked, regions: [.init(bounds: box, detectedCharacters: 12, coveredCharacters: 1)])
        let sourceHash = try #require(d.localImport?.contentHash)
        let bound = try #require(LocalOCRPageLayout(sourceHash: sourceHash, page: page))
        d.localImport?.pages[0].layout = bound
        let review = try #require(LocalDocumentReview(d)), physical = review.pages[0]
        let focus = physical.focus(quote: "Betrag: 13,80 €")
        #expect(focus.bounds == [box] && focus.quote == "Betrag: 13,80 €")
        #expect(physical.previewBounds(for: focus) == [box])
        #expect(review.quality.issues.contains { $0.title == "Möglicherweise nicht erfasster Textbereich" && $0.focus?.bounds == [box] })
        d.ocrText += " geändert"
        let stale = try #require(LocalDocumentReview(d)).pages[0]
        #expect(stale.layout == nil && stale.focus(quote: "Betrag: 13,80 €").bounds.isEmpty)
        d.localImport?.originalState = .changed
        #expect(try #require(LocalDocumentReview(d)).pages.allSatisfy { $0.layout == nil })
    }

    @Test(arguments: [0, 90, 180, 270]) func previewHighlightFollowsPDFRotation(rotation: Int) throws {
        let box = CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.1)
        var page = LocalOCRPage(info: .init(page: 1, method: .vision), text: "Text")
        page.geometry = .vision(texts: ["Text"], bounds: [box], confidences: [0.9])
        page.geometry?.rotationDegrees = rotation; page.geometry?.configuration = LocalOCRPageCache.configuration
        let layout = try #require(LocalOCRPageLayout(sourceHash: "source", page: page))
        let physical = LocalDocumentReview.Page(id: 1, text: page.text, info: page.info, layout: layout)
        let transformed = try #require(physical.previewBounds(for: physical.focus(quote: "Text")).first)
        #expect(transformed.minX >= 0 && transformed.minY >= 0 && transformed.maxX <= 1 && transformed.maxY <= 1)
        if rotation == 90 { #expect(abs(transformed.minX - 0.6) < 0.0001 && abs(transformed.minY - 0.6) < 0.0001) }
        if rotation == 270 { #expect(abs(transformed.minX - 0.3) < 0.0001 && abs(transformed.minY - 0.1) < 0.0001) }
    }
}
