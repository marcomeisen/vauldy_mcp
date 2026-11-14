import SwiftUI
import VauldyCore

/// Text/source warnings and optional extracted metadata are presented independently.
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
            DisclosureGroup("Hinweise zu Text und Original") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalDocumentQuality.completenessExplanation)
                    Text("Erfassung: \(quality.recognitionLabel)")
                    Text("Tabellen: \(LocalDocumentQuality.tableLabel). Zahlen und Zellzuordnung bei Bedarf am Original prüfen.")
                    Text(LocalDocumentQuality.manualReviewLabel)
                    issueGroups(quality.textIssues)
                }.font(.caption).padding(.top, 6)
            }.font(.caption)
            DisclosureGroup("Hinweise zu Basisangaben (optional)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(quality.analysisLabel)
                    Text(LocalDocumentQuality.basisExplanation)
                    issueGroups(quality.basisIssues)
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("document-optional-basis-information")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func issueGroups(_ findings: [LocalDocumentQuality.Issue]) -> some View {
        ForEach(LocalDocumentQuality.Category.allCases, id: \.self) { category in
            let issues = findings.filter { $0.category == category }
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
    }
}
