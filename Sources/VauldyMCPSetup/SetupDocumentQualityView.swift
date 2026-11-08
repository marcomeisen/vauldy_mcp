import SwiftUI
import VauldyCore

/// The same local quality explanation in the inventory, document list and page inspector.
struct SetupDocumentQualityView: View {
    let quality: LocalDocumentQuality
    let open: (LocalDocumentQuality.Focus) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(quality.headline, systemImage: quality.reviewCount > 0 ? "exclamationmark.circle" : "doc.text.magnifyingglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(quality.reviewCount > 0 ? Color.orange : Color.primary)
                .accessibilityIdentifier("document-quality-summary")
            Text(quality.processingLabel).font(.caption)
            DisclosureGroup("Prüfbereiche und konkrete Gründe") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalDocumentQuality.completenessExplanation)
                    Text("Erfassung: \(quality.recognitionLabel)")
                    Text(quality.analysisLabel)
                    Text("Tabellen: \(LocalDocumentQuality.tableLabel). Zahlen und Zellzuordnung bei Bedarf am Original prüfen.")
                    Text(LocalDocumentQuality.manualReviewLabel)
                    ForEach(LocalDocumentQuality.Category.allCases, id: \.self) { category in
                        let issues = quality.issues.filter { $0.category == category }
                        if !issues.isEmpty {
                            Text(category.title).font(.callout.weight(.semibold))
                            ForEach(issues) { issue in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(issue.title).fontWeight(.medium)
                                    Text(issue.detail).foregroundStyle(.secondary)
                                    if let focus = issue.focus {
                                        Button(focus.bounds.isEmpty ? "Seite \(focus.page) ansehen" : "Stelle auf Seite \(focus.page) ansehen") { open(focus) }
                                            .accessibilityIdentifier("quality-issue-\(issue.id)")
                                    } else { Text("Keine einzelne Fundstelle zugeordnet.").foregroundStyle(.secondary) }
                                }.padding(.leading, 8)
                            }
                        }
                    }
                }.font(.caption).padding(.top, 6)
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
