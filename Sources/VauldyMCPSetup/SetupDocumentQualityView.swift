import SwiftUI
import VauldyCore

/// Text/source warnings and optional extracted metadata are presented independently.
struct SetupDocumentQualityView: View {
    let quality: LocalDocumentQuality
    let documentName: String?
    let open: (LocalDocumentQuality.Focus) -> Void
    init(quality: LocalDocumentQuality, documentName: String? = nil, open: @escaping (LocalDocumentQuality.Focus) -> Void) {
        self.quality = quality; self.documentName = documentName; self.open = open
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(quality.headline, systemImage: quality.requiresCoverageAttention ? "exclamationmark.circle" : "doc.text.magnifyingglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(quality.requiresCoverageAttention ? Color.orange : Color.primary)
                .accessibilityLabel(quality.requiresCoverageAttention ? "Prüfhinweis: \(quality.headline)" : quality.headline)
                .accessibilityIdentifier("document-quality-summary")
            Text(quality.processingLabel).font(.caption)
            Text(quality.chatImpact).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Text und Original prüfen") {
                VStack(alignment: .leading, spacing: 10) {
                    issueGroups(quality.textIssues)
                    DisclosureGroup("Technische Angaben") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalDocumentQuality.completenessExplanation)
                            Text("Erfassung: \(quality.recognitionLabel)")
                            Text("Tabellen: \(LocalDocumentQuality.tableLabel).")
                            Text(LocalDocumentQuality.manualReviewLabel)
                        }.foregroundStyle(.secondary)
                    }
                }.font(.caption).padding(.top, 6)
            }.font(.caption)
            DisclosureGroup("Basisangaben prüfen (optional)") {
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
                                .accessibilityLabel(documentName.map { "\(issue.title) in \($0) auf Seite \(focus.page) ansehen" } ?? "\(issue.title) auf Seite \(focus.page) ansehen")
                                .accessibilityIdentifier("quality-issue-\(issue.id)")
                        }
                    }.padding(.leading, 8)
                }
            }
        }
    }
}
