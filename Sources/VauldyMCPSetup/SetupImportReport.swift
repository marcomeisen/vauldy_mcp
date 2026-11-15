import Foundation
import VauldyCore

struct SetupImportReport: Identifiable {
    struct Item: Identifiable {
        enum Result: Hashable {
            case imported, existing, refreshed, textPending, failed, skipped, cancelled, unavailableFolder

            var title: String {
                switch self {
                case .imported: "Neu importiert"
                case .existing: "Bereits vorhanden"
                case .refreshed: "Text erneut gelesen"
                case .textPending: "Im Bestand · Texterkennung offen"
                case .failed: "Fehlgeschlagen"
                case .skipped: "Übersprungen"
                case .cancelled: "Abgebrochen"
                case .unavailableFolder: "Ordner nicht lesbar"
                }
            }

            var isIssue: Bool { self == .textPending || self == .failed || self == .skipped || self == .unavailableFolder }
        }

        let id = UUID()
        let name: String
        let result: Result
        var documentID: UUID?
        var detail: String?
        var ocrReview = false

        init(name: String, result: Result, detail: String? = nil, documentID: UUID? = nil) {
            self.name = name
            self.result = documentID != nil && result == .failed ? .textPending : result
            self.detail = detail; self.documentID = documentID
            ocrReview = documentID != nil && (result == .failed || result == .cancelled)
        }

        init(name: String, outcome: LocalImportOutcome, isRetry: Bool) {
            self.name = name
            documentID = outcome.documentID
            let readable = outcome.state == .completed || outcome.state == .partial
            if outcome.reusedOriginal { result = .existing }
            else if !readable { result = .textPending }
            else { result = isRetry ? .refreshed : .imported }
            ocrReview = [.partial, .failed, .interrupted, .cancelled].contains(outcome.state)
            if !readable { detail = "Das Dokument ist bereits im Bestand. Die Texterkennung ist noch nicht abgeschlossen; kein erneuter Import nötig." }
        }
    }

    let id = UUID()
    let isRetry: Bool
    var items: [Item] = []
    var addedDocumentIDs: Set<UUID> = []
    var cancelled = false
    var batchError: String?

    var issues: [Item] { items.filter { $0.result.isIssue } }
    var newDocumentIDs: Set<UUID> { addedDocumentIDs }
    var ocrReviewCount: Int { Set(items.filter(\.ocrReview).compactMap(\.documentID)).count }
    var summary: String {
        let labels: [(Item.Result, String)] = [
            (.existing, "bereits vorhanden"), (.refreshed, "mit erneut gelesenem Text"),
            (.textPending, "im Bestand, Texterkennung offen"), (.failed, "fehlgeschlagen"), (.skipped, "übersprungen"), (.unavailableFolder, "Ordner nicht lesbar")
        ]
        let counts = items.reduce(into: [Item.Result: Int]()) { $0[$1.result, default: 0] += 1 }
        let additions = isRetry ? [] : ["\(addedDocumentIDs.count) neu im lokalen Bestand"]
        return (additions + labels.compactMap { result, label in counts[result].map { "\($0) \(label)" } }).joined(separator: " · ")
    }
}
