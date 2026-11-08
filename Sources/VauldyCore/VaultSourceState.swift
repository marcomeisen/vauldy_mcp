import Foundation
import VauldyDocumentCore

package struct VaultSourceState {
    package let sourceCoverage: String
    package let processingStatus: String

    package func projection(for document: VaultDocument) -> VaultIndexProjection {
        var value = VaultIndexProjection(processingStatus: processingStatus, sourceCoverage: sourceCoverage,
              analysisStatus: document.baseAnalysisStatus, searchable: document.isSearchable)
        value.inventoryVersion = 1
        let date = document.importedAt
        if date.timeIntervalSinceReferenceDate.isFinite, date != .distantPast, date != .distantFuture {
            value.importedAt = date
        }
        if let hash = document.localImport?.contentHash, hash.count == 64,
           hash.allSatisfy({ "0123456789abcdef".contains($0) }) { value.contentHash = hash }
        value.originalState = document.localImport?.originalState?.rawValue
        return value
    }

    package static func physicalPage(_ page: Int, declaredCount: Int?) -> Bool {
        (1...10_000).contains(page) && (declaredCount.map { page <= $0 } ?? true)
    }

    package static func sourceSections(_ document: VaultDocument) -> [VauldyDocumentCore.VaultPageMarkedText.Section] {
        let sections = VauldyDocumentCore.VaultPageMarkedText.sections(in: document.ocrText)
        let occurrences = Dictionary(grouping: sections.compactMap(\.page), by: { $0 })
        return sections.map { section in
            guard let page = section.page, physicalPage(page, declaredCount: document.pageCount),
                  occurrences[page]?.count == 1 else { return .init(page: nil, text: section.text) }
            return section
        }
    }

    package init(_ document: VaultDocument) {
        let sections = Self.sourceSections(document)
        var complete = false
        if let count = document.pageCount, (1...10_000).contains(count), sections.map(\.page) == (1...count).map(Optional.some) {
            if let info = document.localImport {
                complete = info.state == .completed && info.pages.map(\.page) == Array(1...count)
                    && info.pages.allSatisfy { page in
                        page.method != .unreadable && !page.needsReview
                            && (page.method == .blank || sections.contains { $0.page == page.page && !$0.text.isEmpty })
                    }
            } else { complete = sections.allSatisfy { !$0.text.isEmpty } }
        }
        if document.localImport?.originalState == .changed || document.localImport?.originalState == .unavailable { complete = false }
        switch document.localImport?.originalState {
        case .changed: sourceCoverage = "original-changed-stored-ocr-is-historical"
        case .unavailable: sourceCoverage = "original-unavailable-stored-ocr-retained"
        default: sourceCoverage = complete ? (document.localImport == nil ? "all-declared-pages-have-ocr-text" : "all-declared-pages-processed") : "incomplete-or-unknown"
        }
        if let info = document.localImport {
            switch info.state {
            case .queued, .recognizing: processingStatus = "pending"
            case .failed, .cancelled, .interrupted: processingStatus = "failed"
            case .partial: processingStatus = "needs-review"
            case .completed: processingStatus = complete ? "source-ready" : "needs-review"
            }
        } else if document.status == "failed" || document.status == "cancelled" {
            processingStatus = "failed"
        } else if document.status == "partiallyAnalyzed" {
            processingStatus = "needs-review"
        } else if !document.isSearchable {
            processingStatus = "pending"
        } else { processingStatus = complete ? "source-ready" : "unknown" }
    }
}
