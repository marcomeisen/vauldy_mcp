import Foundation

/// Explicit local refinement keeps an earlier literal line whenever a new read
/// would remove or change it. This never certifies that the retained line is correct.
public struct EvidencePreservingLocalOCR: LocalDocumentOCR {
    private let sourceHash: String
    private let previous: [LocalOCRPage]
    private let candidate: any LocalDocumentOCR

    public init(document: VaultDocument, candidate: any LocalDocumentOCR = NativeLocalDocumentOCR()) throws {
        guard let metadata = document.localImport, metadata.originalState == .available,
              !document.baseAnalysisPages.isEmpty, metadata.pages.map(\.page) == document.baseAnalysisPages.map(\.number)
        else { throw LocalImportError.invalidDocument }
        sourceHash = metadata.contentHash
        previous = document.baseAnalysisPages.map { section in
            let info = metadata.pages.first { $0.page == section.number }!
            var page = LocalOCRPage(info: info, text: section.text)
            if let layout = info.layout,
               layout.matches(sourceHash: metadata.contentHash, page: section.number, text: section.text,
                              configuration: layout.geometry.configuration) {
                page.geometry = layout.geometry
            }
            return page
        }
        self.candidate = candidate
    }

    public func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        // The import service owns the read-only original lease and verifies again at commit.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: LocalDocumentStore.maximumOriginalBytes + 1) ?? Data()
        guard bytes.count <= LocalDocumentStore.maximumOriginalBytes,
              LocalOriginalAccess.hash(bytes) == sourceHash else { throw LocalImportError.staleAttempt }
        let read = try await candidate.recognize(file: file, progress: progress)
        guard read.pages.map(\.info.page) == previous.map(\.info.page) else { throw LocalImportError.invalidDocument }
        return LocalOCRResult(pages: zip(previous, read.pages).map { Self.preserving(previous: $0.0, candidate: $0.1) })
    }

    static func preserving(previous: LocalOCRPage, candidate: LocalOCRPage) -> LocalOCRPage {
        let lines = previous.text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var available = candidate.text.components(separatedBy: .newlines)[...]
        let retainedInOrder = lines.allSatisfy { line in
            guard let index = available.firstIndex(of: line) else { return false }
            available = available[available.index(after: index)...]
            return true
        }
        guard retainedInOrder else {
            var retained = previous
            retained.info.needsReview = true
            retained.info.elapsedMilliseconds = candidate.info.elapsedMilliseconds
            retained.info.metrics = candidate.info.metrics ?? LocalOCRMetrics()
            retained.info.metrics?.evidencePreservedFallback = true
            return retained
        }
        return candidate
    }
}
