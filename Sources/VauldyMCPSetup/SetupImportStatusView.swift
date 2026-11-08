import SwiftUI

struct SetupImportStatusView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        if model.importing { SetupImportProgress(model: model) }
        else if let report = model.importReport { SetupImportResultView(model: model, report: report).id(report.id) }
    }
}

struct SetupImportProgress: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.importCancelling ? "Abbruch läuft" : (model.retryingOCR ? "OCR wird erneut ausgeführt" : "Lokaler Import")).font(.headline)
            if let total = model.importTotal, total > 0 {
                ProgressView(value: Double(model.importProcessed), total: Double(total)) {
                    Text("\(model.importProcessed) von \(total) Dokumenten verarbeitet")
                }.accessibilityIdentifier("batch-import-progress")
            } else if model.importTotal == nil && !model.importCancelling {
                ProgressView("Ordner werden nach Dokumenten durchsucht …")
            }
            if let file = model.importFileName {
                Text(file).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(file)
                if let progress = model.importProgress {
                    let stage = progress.stage == "Wartet auf lokalen Worker" ? "Wartet auf lokale Verarbeitung" : progress.stage
                    let pages = progress.totalPages > 0 ? " · \(progress.completedPages) von \(progress.totalPages) Seiten" : ""
                    Text(stage + pages).font(.caption).foregroundStyle(.secondary)
                } else if !model.importCancelling {
                    Text(model.retryingOCR ? "Gesichertes Original wird vorbereitet …" : "Datei wird vorbereitet …").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(model.importCancelling
                    ? "Vauldy wartet, bis die laufende Texterkennung endet. Gesicherte Originale bleiben erhalten."
                    : "Originale und Texterkennung bleiben auf diesem Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.retryingOCR ? "OCR abbrechen" : "Import abbrechen", action: model.cancelImport).disabled(model.importCancelling)
            }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SetupImportResultView: View {
    @ObservedObject var model: SetupModel
    let report: SetupImportReport
    @State private var details: DetailScope?
    @State private var reviewItem: SetupImportReport.Item?
    private enum DetailScope { case issues, review, all }

    private var title: String {
        if report.cancelled { return report.isRetry ? "OCR abgebrochen" : "Import abgebrochen" }
        if report.batchError != nil { return report.isRetry ? "OCR konnte nicht abgeschlossen werden" : "Import konnte nicht abgeschlossen werden" }
        return report.isRetry ? "Ergebnis der Texterkennung" : "Importergebnis"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Bericht ausblenden") { model.importReport = nil }.buttonStyle(.borderless)
            }
            if !report.summary.isEmpty { Text(report.summary) }
            if report.items.contains(where: { $0.documentID != nil }) {
                Text("Bereits übernommene Dokumente nicht erneut importieren. Prüfe bei Bedarf den gespeicherten Text; fehlende Basisangaben allein erfordern keine neue Texterkennung.")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("import-existing-guidance")
            }
            if let error = report.batchError { SetupNotice(text: error, warning: true) }
            if report.cancelled {
                Text("Gesicherte Originale bleiben erhalten. Ausstehende Texterkennung kann erneut gestartet werden.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if report.items.allSatisfy({ $0.result == .skipped }) && report.batchError == nil {
                Text("Keine unterstützten Dokumente gefunden.").foregroundStyle(.secondary)
            }
            if report.ocrReviewCount > 0 { Text("Texterkennung prüfen (\(report.ocrReviewCount))").font(.callout) }
            if report.analysisReviewCount > 0 { Text("Basisanalyse prüfen (\(report.analysisReviewCount))").font(.callout) }
            ViewThatFits(in: .horizontal) {
                HStack { detailActions }
                VStack(alignment: .leading) { detailActions }
            }
            if let details {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items(for: details)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).lineLimit(2).truncationMode(.middle).help(item.name)
                            Text(item.result.title).font(.callout).foregroundStyle(.secondary)
                            if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            if item.documentID != nil {
                                Button("Seite prüfen") { reviewItem = item }
                                    .accessibilityLabel("Seite prüfen: \(item.name)")
                                    .accessibilityIdentifier("review-import-page")
                            }
                        }
                    }
                }.accessibilityIdentifier("import-file-results")
            }
            if !report.newDocumentIDs.isEmpty {
                Text("Neue Dokumente bleiben bis zur ausdrücklichen Freigabe für Chatbots gesperrt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("import-result")
            .sheet(item: $reviewItem) { item in
                if let documentID = item.documentID {
                    SetupQualityReviewView(model: model, documentID: documentID, reportID: report.id)
                }
            }
    }

    @ViewBuilder private var detailActions: some View {
        if !report.issues.isEmpty {
            Button(details == .issues ? "Fehler ausblenden" : "Fehler anzeigen") {
                details = details == .issues ? nil : .issues
            }
        }
        if !report.items.isEmpty {
            Button(details == .all ? "Dateiliste ausblenden" : "Alle Dateiergebnisse anzeigen") {
                details = details == .all ? nil : .all
            }
        }
        if !report.newDocumentIDs.isEmpty {
            Button("Neu importierte Dokumente anzeigen") {
                details = nil
                model.showImportedDocuments(report.newDocumentIDs)
            }.disabled(model.busy)
        }
        if !items(for: .review).isEmpty {
            Button(details == .review ? "Prüffälle ausblenden" : "Prüffälle anzeigen") {
                details = details == .review ? nil : .review
            }.accessibilityIdentifier("import-quality-issues")
        }
    }

    private func items(for scope: DetailScope) -> [SetupImportReport.Item] {
        switch scope {
        case .issues: report.issues
        case .review: report.items.filter { $0.documentID != nil && ($0.ocrReview || $0.analysisReview || $0.result.isIssue) }
        case .all: report.items
        }
    }
}
