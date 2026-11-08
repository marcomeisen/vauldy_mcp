import AppKit
import SwiftUI
import VauldyCore

struct SetupQualityReviewView: View {
    @ObservedObject var model: SetupModel
    let documentID: UUID
    let reportID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var review: LocalDocumentReview?
    @State private var before: LocalDocumentReview?
    @State private var pageNumber = 1
    @State private var preview: NSImage?
    @State private var renderedRequest: PreviewRequest?
    @State private var previewProblem: String?
    @State private var loadingPreview = false
    @State private var loading = true
    @State private var retrying = false
    @State private var retryTask: Task<Void, Never>?
    @State private var problem: String?
    @State private var result: String?
    @State private var previewRevision = UUID()

    private struct PreviewRequest: Equatable {
        let page: Int
        let hash: String
        let revision: UUID
    }

    private var request: PreviewRequest? {
        review.map { PreviewRequest(page: pageNumber, hash: $0.sourceHash, revision: previewRevision) }
    }
    private var page: LocalDocumentReview.Page? {
        review?.pages.first { $0.id == pageNumber }
    }
    private var canRetry: Bool {
        preview != nil && renderedRequest == request && !loadingPreview && !retrying && !model.importing && !model.busy
            && review?.state != .queued && review?.state != .recognizing && model.localExecutable != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Texterkennung prüfen").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let review {
                Text(review.name).lineLimit(2).truncationMode(.middle).help(review.name)
                    .accessibilityLabel(review.name)
                pageControls(review)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading { ProgressView("Gespeicherte Texterkennung wird geladen …") }
                    if let problem { SetupNotice(text: problem, warning: true) }
                    if let result { SetupNotice(text: result, warning: false) }
                    if let review, let page {
                        if let issue = review.importProblem { SetupNotice(text: issue, warning: true) }
                        if review.analysisStatus != "completed" {
                            Text("Der Hinweis zur Basisanalyse bedeutet keinen fehlenden Import. Erneut lesen ist nur bei fehlendem oder fehlerhaftem Text nötig.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if review.originalState == .changed || previewProblem != nil {
                            Text("Der gespeicherte Text gehört zum zuletzt gelesenen Original.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Text(page.reason).font(.callout.weight(.medium))
                            .accessibilityIdentifier("review-page-reason")
                        originalPanel
                        Divider()
                        textPanel(page)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            Divider()
            HStack { actions }
        }
        .padding(22)
        .frame(width: 540, height: 530)
        .interactiveDismissDisabled(retrying)
        .task { await load() }
        .task(id: request) { await loadPreview(request) }
        .accessibilityIdentifier("ocr-quality-review")
    }

    @ViewBuilder private var actions: some View {
        Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction).disabled(retrying)
        Spacer(minLength: 8)
        if retrying {
            ProgressView("Text wird lokal erneut gelesen …").controlSize(.small)
            Button("Abbrechen") { retryTask?.cancel() }
        }
        else {
            Button("Text erneut lesen") {
                guard retryTask == nil else { return }
                retryTask = Task {
                    await retry()
                    retryTask = nil
                }
            }
                .buttonStyle(.bordered).disabled(!canRetry)
                .accessibilityHint("Liest das ganze Dokument erneut und vergleicht die ausgewählte Seite.")
                .accessibilityIdentifier("review-retry")
        }
    }

    private func pageControls(_ review: LocalDocumentReview) -> some View {
        HStack {
            Button("Vorherige Seite", systemImage: "chevron.left") { pageNumber -= 1 }
                .labelStyle(.iconOnly).keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(pageNumber <= 1 || retrying)
            Picker("Seite", selection: $pageNumber) {
                ForEach(review.pages) { page in Text("Seite \(page.id)").tag(page.id) }
            }.labelsHidden().accessibilityLabel("Seite").fixedSize()
                .accessibilityIdentifier("review-page-picker").disabled(retrying)
            Button("Nächste Seite", systemImage: "chevron.right") { pageNumber += 1 }
                .labelStyle(.iconOnly).keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(pageNumber >= review.pages.count || retrying)
            Spacer()
        }
    }

    private var originalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original · Seite \(pageNumber)").font(.headline).accessibilityAddTraits(.isHeader)
            if loadingPreview {
                ProgressView("Original wird geprüft …")
            } else if let preview, renderedRequest == request {
                Image(nsImage: preview).resizable().scaledToFit()
                    .frame(maxWidth: 510, maxHeight: 280)
                    .accessibilityLabel("Vorschau der Originalseite \(pageNumber)")
                    .accessibilityIdentifier("review-original-preview")
            } else if let previewProblem {
                SetupNotice(text: previewProblem, warning: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textPanel(_ page: LocalDocumentReview.Page) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let before, before.sourceHash == review?.sourceHash,
               let previous = before.pages.first(where: { $0.id == page.id }) {
                Text(previous.text == page.text ? "Text auf dieser Seite unverändert." : "Text auf dieser Seite geändert.")
                    .font(.callout).accessibilityIdentifier("review-comparison")
                textSection("Vorher", page: previous)
                Divider()
                textSection("Nachher", page: page)
            } else {
                textSection("Erkannter Text", page: page)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textSection(_ title: String, page: LocalDocumentReview.Page) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if before != nil { Text(page.reason).font(.caption).foregroundStyle(.secondary) }
            if let text = page.text, !text.isEmpty {
                Text(verbatim: text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Kein lesbarer Seitentext vorhanden.").foregroundStyle(.secondary)
            }
        }
    }

    private func readReview() async throws -> (VaultDocument, LocalDocumentReview) {
        guard let document = try await model.localStore.document(id: documentID),
              let snapshot = LocalDocumentReview(document) else { throw LocalImportError.unreadableFile }
        return (document, snapshot)
    }

    private func load() async {
        defer { loading = false }
        do {
            let (_, snapshot) = try await readReview()
            try Task.checkCancellation()
            pageNumber = snapshot.firstReviewPage
            review = snapshot
        } catch is CancellationError {
            return
        } catch { problem = "Der gespeicherte Import ist nicht lesbar." }
    }

    private func loadPreview(_ request: PreviewRequest?) async {
        guard let request else { return }
        preview = nil
        renderedRequest = nil
        previewProblem = nil
        loadingPreview = true
        defer { if self.request == request { loadingPreview = false } }
        do {
            let data = try await model.localStore.reviewPageImage(documentID: documentID, page: request.page,
                                                                 sourceHash: request.hash)
            try Task.checkCancellation()
            guard self.request == request else { return }
            guard let image = NSImage(data: data) else { throw LocalImportError.unreadableFile }
            preview = image
            renderedRequest = request
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            previewProblem = (error as? LocalOriginalError)?.errorDescription
                ?? "Diese Originalseite konnte nicht geprüft und angezeigt werden."
        }
    }

    private func retry() async {
        guard canRetry, let executable = model.localExecutable, let previous = review else { return }
        retrying = true
        problem = nil
        result = nil
        before = nil
        defer { retrying = false }
        do {
            let (_, latest) = try await readReview()
            guard latest.sourceHash == previous.sourceHash else { throw LocalOriginalError.changed }
            guard latest.state != .queued, latest.state != .recognizing else { throw LocalImportError.workerBusy }
            let worker = LocalImportWorker(store: model.localStore, executable: executable, watchFolders: false)
            let outcome = try await worker.retry(documentID: documentID, fresh: true)
            let (document, updated) = try await readReview()
            guard updated.sourceHash == latest.sourceHash else { throw LocalOriginalError.changed }
            pageNumber = min(pageNumber, updated.pages.count)
            review = updated
            previewRevision = UUID()
            model.updateQualityReview(document, reportID: reportID)
            if outcome.state == .completed || outcome.state == .partial {
                before = latest
                result = "Texterkennung beendet. Vergleiche den Text der ausgewählten Seite."
            } else { problem = updated.importProblem ?? "Die erneute Texterkennung wurde nicht abgeschlossen." }
        } catch {
            problem = error is CancellationError ? "Die erneute Texterkennung wurde abgebrochen."
                : (error as? LocalizedError)?.errorDescription ?? "Die erneute Texterkennung ist fehlgeschlagen."
            if let (document, updated) = try? await readReview() {
                pageNumber = min(pageNumber, updated.pages.count)
                review = updated
                previewRevision = UUID()
                model.updateQualityReview(document, reportID: reportID)
            }
        }
    }
}

extension SetupModel {
    func updateQualityReview(_ document: VaultDocument, reportID: UUID?) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
            documents.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        guard let reportID, var report = importReport, report.id == reportID else { return }
        for index in report.items.indices where report.items[index].documentID == document.id {
            let state = document.localImport?.state
            report.items[index].ocrReview = state == .partial || state == .failed || state == .interrupted
            report.items[index].analysisReview = document.isSearchable && document.baseAnalysisStatus != "completed"
        }
        importReport = report
    }
}
