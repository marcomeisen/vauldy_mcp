import SwiftUI
import VauldyCore
import VauldyDocumentIntelligence

/// Local presentation of the current persisted analysis; no OCR or model work in views.
struct SetupDocumentAnalysisView: View {
    let document: VaultDocument
    var body: some View {
        DisclosureGroup("Übersicht und Basisangaben") {
            VStack(alignment: .leading, spacing: 12) {
                if let analysis = document.currentBaseAnalysis, !analysis.documents.isEmpty {
                    ForEach(Array(analysis.documents.enumerated()), id: \.offset) { _, card in
                        VStack(alignment: .leading, spacing: 8) {
                            if analysis.documents.count > 1 { Text(card.title).font(.headline) }
                            Text(card.overview?.value ?? "Keine belegte Übersicht vorhanden.")
                                .textSelection(.enabled)
                            ForEach(card.fields.filter { [.issuer, .recipient, .issueDate, .subject, .titleYear].contains($0.role) }, id: \.role) { field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(label(field.role)): \(field.value)").textSelection(.enabled).help(field.quote)
                                    Text("Quelle: Seite \(field.page)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("Originalseiten: \(card.pages.map(String.init).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Lokal aus dem erfassten Text abgeleitet. Bitte Angaben am Original prüfen.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(document.baseAnalysisStatus == "stale" ? "Die Basisanalyse ist veraltet. Lies das Original erneut, um Text und Angaben zu aktualisieren." : "Keine aktuelle belegte Basisanalyse vorhanden. Du kannst das Original erneut lesen.")
                        .foregroundStyle(.secondary)
                }
            }.font(.callout).padding(.top, 8)
        }.font(.callout)
    }
    private func label(_ role: BaseFieldRole) -> String {
        switch role {
        case .issuer: "Aussteller"
        case .recipient: "Empfänger"
        case .issueDate: "Dokumentdatum"
        case .subject: "Gegenstand"
        case .titleYear: "Jahr im Titel"
        default: "Angabe"
        }
    }
}
