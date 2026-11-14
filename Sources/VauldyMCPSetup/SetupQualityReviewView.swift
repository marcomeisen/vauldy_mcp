import AppKit
import SwiftUI
import VauldyCore

struct SetupQualityReviewView: View {
    let store: LocalDocumentStore
    let executable: URL?
    var blocked = false
    var didUpdate: (VaultDocument) -> Void = { _ in }
    var initialPage: Int? = nil
    var initialQuote: String? = nil
    var initialFocus: LocalDocumentQuality.Focus? = nil
    let documentID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFocus: LocalDocumentQuality.Focus?
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

    init(model: SetupModel, documentID: UUID, reportID: UUID?, initialPage: Int? = nil, initialQuote: String? = nil, initialFocus: LocalDocumentQuality.Focus? = nil) {
        self.store = model.localStore; self.executable = model.localExecutable; self.documentID = documentID
        self.blocked = model.importing || model.busy; self.initialPage = initialPage; self.initialQuote = initialQuote; self.initialFocus = initialFocus
        self.didUpdate = { model.updateQualityReview($0, reportID: reportID) }
    }

    init(store: LocalDocumentStore, executable: URL?, documentID: UUID, initialPage: Int? = nil, initialFocus: LocalDocumentQuality.Focus? = nil, didUpdate: @escaping (VaultDocument) -> Void) {
        self.store = store; self.executable = executable; self.documentID = documentID
        self.initialPage = initialPage; self.initialFocus = initialFocus; self.didUpdate = didUpdate
    }

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
        preview != nil && renderedRequest == request && !loadingPreview && !retrying && !blocked
            && review?.state != .queued && review?.state != .recognizing && executable != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Qualität und Fundstellen prüfen").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let review {
                Text(review.name).lineLimit(2).truncationMode(.middle).help(review.name)
                    .accessibilityLabel(review.name)
                pageControls(review)
            }
            Divider()
            ScrollViewReader { scroll in
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
                        Text("Texterkennung: " + page.reason).font(.callout.weight(.medium))
                            .accessibilityIdentifier("review-page-reason")
                        SetupDocumentQualityView(quality: review.quality) { focus in
                            pageNumber = focus.page; selectedFocus = focus
                            withAnimation { scroll.scrollTo("review-source", anchor: .top) }
                        }
                        HStack(alignment: .top, spacing: 20) {
                            originalPanel
                            textPanel(page).frame(maxWidth: .infinity, alignment: .leading)
                        }.id("review-source")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
              .onChange(of: renderedRequest) { _, request in
                  if request != nil, selectedFocus != nil { scroll.scrollTo("review-source", anchor: .top) }
              }
            }
            Divider()
            HStack { actions }
        }
        .padding(22)
        .frame(width: 860, height: 740)
        .interactiveDismissDisabled(retrying)
        .task { await load() }
        .onChange(of: pageNumber) { _, value in if selectedFocus?.page != value { selectedFocus = nil } }
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
                let ratio = preview.size.width / max(1, preview.size.height)
                let width = min(390, 480 * ratio)
                Image(nsImage: preview).resizable().frame(width: width, height: width / ratio)
                    .overlay { GeometryReader { proxy in
                        ForEach(Array((page?.previewBounds(for: selectedFocus) ?? []).enumerated()), id: \.offset) { _, box in
                            Rectangle().fill(Color.orange.opacity(0.16)).border(Color.orange, width: 2)
                                .frame(width: box.width * proxy.size.width, height: box.height * proxy.size.height)
                                .offset(x: box.minX * proxy.size.width, y: (1 - box.maxY) * proxy.size.height)
                        }
                    }.allowsHitTesting(false) }
                    .accessibilityLabel("Vorschau der Originalseite \(pageNumber)")
                    .accessibilityIdentifier("review-original-preview")
                if let crop = focusedCrop(preview) {
                    Text("Markierter Ausschnitt").font(.caption.weight(.semibold))
                    Image(nsImage: crop).resizable().scaledToFit().frame(maxWidth: 390, maxHeight: 160)
                        .accessibilityLabel("Markierter Ausschnitt der Originalseite \(pageNumber)")
                        .accessibilityIdentifier("review-focused-crop")
                } else if selectedFocus != nil {
                    Text("Keine genaue Bereichsposition gespeichert; die ganze Seite wird angezeigt.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let previewProblem {
                SetupNotice(text: previewProblem, warning: true)
            }
        }.frame(width: 390, alignment: .leading)
    }

    private func focusedCrop(_ image: NSImage) -> NSImage? {
        let boxes = page?.previewBounds(for: selectedFocus) ?? []
        guard let first = boxes.first, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let box = boxes.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -0.015, dy: -0.015).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(x: box.minX * CGFloat(cg.width), y: (1 - box.maxY) * CGFloat(cg.height), width: box.width * CGFloat(cg.width), height: box.height * CGFloat(cg.height)).integral
        guard let crop = cg.cropping(to: pixels) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
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
                if let quote = selectedFocus?.quote, !quote.isEmpty, text.contains(quote) {
                    Text("Ausgewählter Beleg").font(.caption.weight(.semibold))
                    Text(verbatim: quote).textSelection(.enabled).padding(6)
                        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("review-selected-quote")
                }
                Text(verbatim: text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !page.revisions.isEmpty {
                    DisclosureGroup("Frühere Lesungen vergleichen") {
                        ForEach(page.revisions) { revision in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Früher").font(.caption.weight(.semibold))
                                ForEach(revision.previous, id: \.self) { Text(verbatim: $0).textSelection(.enabled) }
                                Text("Aktuell – am Original prüfen").font(.caption.weight(.semibold))
                                Text(verbatim: revision.current).textSelection(.enabled)
                            }.padding(.vertical, 4)
                        }
                    }.accessibilityIdentifier("review-prior-readings")
                }
            } else {
                Text("Kein lesbarer Seitentext vorhanden.").foregroundStyle(.secondary)
            }
        }
    }

    private func readReview() async throws -> (VaultDocument, LocalDocumentReview) {
        guard let document = try await store.document(id: documentID),
              let snapshot = LocalDocumentReview(document) else { throw LocalImportError.unreadableFile }
        return (document, snapshot)
    }

    private func load() async {
        defer { loading = false }
        do {
            let (_, snapshot) = try await readReview()
            try Task.checkCancellation()
            pageNumber = snapshot.pages.contains(where: { $0.id == initialPage }) ? (initialPage ?? snapshot.firstReviewPage) : snapshot.firstReviewPage
            if let page = snapshot.pages.first(where: { $0.id == pageNumber }) {
                selectedFocus = snapshot.quality.issues.first(where: { $0.focus == initialFocus && initialFocus != nil })?.focus
                    ?? initialQuote.map { page.focus(quote: $0) }
                    ?? snapshot.quality.issues.first(where: { $0.focus?.page == pageNumber })?.focus
            }
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
            let data = try await store.reviewPageImage(documentID: documentID, page: request.page,
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
        guard canRetry, let executable, let previous = review else { return }
        retrying = true
        problem = nil
        result = nil
        before = nil
        defer { retrying = false }
        do {
            let (_, latest) = try await readReview()
            guard latest.sourceHash == previous.sourceHash else { throw LocalOriginalError.changed }
            guard latest.state != .queued, latest.state != .recognizing else { throw LocalImportError.workerBusy }
            let worker = LocalImportWorker(store: store, executable: executable, watchFolders: false)
            let outcome = try await worker.retry(documentID: documentID, fresh: true)
            let (document, updated) = try await readReview()
            guard updated.sourceHash == latest.sourceHash else { throw LocalOriginalError.changed }
            pageNumber = min(pageNumber, updated.pages.count)
            review = updated
            selectedFocus = nil
            previewRevision = UUID()
            didUpdate(document)
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
                selectedFocus = nil
                previewRevision = UUID()
                didUpdate(document)
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
