import Foundation

/// Refinement preserves literal evidence. A constrained, spatially bound native
/// word repair retains its prior reading in the local layout and remains review.
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
        func entries(_ text: String) -> [(text: String, offset: Int)] {
            var offset = 0
            return text.components(separatedBy: .newlines).compactMap { line in
                defer { offset += line.utf16.count + 1 }
                return line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (line, offset)
            }
        }
        func fallback() -> LocalOCRPage {
            var retained = previous
            retained.info.needsReview = true
            retained.info.elapsedMilliseconds = candidate.info.elapsedMilliseconds
            retained.info.metrics = candidate.info.metrics ?? LocalOCRMetrics()
            retained.info.metrics?.evidencePreservedFallback = true
            return retained
        }
        var result = candidate
        let available = entries(candidate.text)
        var next = 0, repaired = false
        let validGeometry = previous.geometry?.coordinateSpace == candidate.geometry?.coordinateSpace
            && previous.geometry?.rotationDegrees == candidate.geometry?.rotationDegrees
            && LocalOCRPageLayout(sourceHash: "validation-only", page: candidate) != nil
        for old in entries(previous.text) {
            let oldLine = previous.geometry?.lines.first { $0.location == old.offset && $0.length == old.text.utf16.count }
            var found: Int?
            for index in next..<available.count {
                let new = available[index]
                if new.text == old.text { found = index; break }
                guard validGeometry, let oldLine,
                      let line = candidate.geometry?.lines.first(where: { $0.location == new.offset && $0.length == new.text.utf16.count }),
                      line.priorReadings?.contains(old.text) == true else { continue }
                // Whitespace-only money presentation retains all source
                // characters and the original uncertainty; it is not a new OCR
                // reading. Every actual character repair still requires 0.95.
                let presentation = OCRNumericRefinement.isPresentationChange(old.text, new.text)
                    && line.confidence != nil && line.confidence == oldLine.confidence
                let characterRepair = (line.confidence ?? 0) >= 0.95
                    && ((line.sourceRepair == .decimalSeparator && OCRDecimalSourceRepair.permits(old.text, new.text))
                        || (line.policyIdentifierRepair == true && OCRPolicyIdentifierRepair.permits(old.text, new.text))
                        || OCRFieldRefinement.permits(old.text, new.text) || OCRLineRecovery.decide(original: old.text, confidence: 1, alternatives: [], retry: new.text,
                        retryConfidence: Float(line.confidence ?? 0), identifier: OCRLineRecovery.isIdentifier(old.text),
                        smallPrint: true, allowSmallGlyphRepair: true) == .replace)
                guard presentation || characterRepair else { continue }
                let overlap = oldLine.bounds.intersection(line.bounds)
                let area = min(oldLine.bounds.width * oldLine.bounds.height, line.bounds.width * line.bounds.height)
                guard area > 0, !overlap.isNull, overlap.width * overlap.height >= area * 0.7 else { continue }
                found = index; repaired = true; break
            }
            guard let found else { return fallback() }
            // Carry history through later unchanged reads as well. Never silently
            // truncate a history which no longer fits the bounded local schema.
            if let history = oldLine?.priorReadings, !history.isEmpty {
                guard validGeometry, let index = result.geometry?.lines.firstIndex(where: { $0.location == available[found].offset }) else { return fallback() }
                var retained = result.geometry!.lines[index].priorReadings ?? []
                for text in history where !retained.contains(text) { retained.append(text) }
                guard retained.count <= 4 else { return fallback() }
                result.geometry?.lines[index].priorReadings = retained
                if available[found].text == old.text, result.geometry?.lines[index].sourceRepair == nil {
                    result.geometry?.lines[index].sourceRepair = oldLine?.sourceRepair
                }
                if available[found].text == old.text, result.geometry?.lines[index].policyIdentifierRepair == nil {
                    result.geometry?.lines[index].policyIdentifierRepair = oldLine?.policyIdentifierRepair
                }
            }
            next = found + 1
        }
        if repaired || result.geometry?.lines.contains(where: { !($0.priorReadings ?? []).isEmpty }) == true {
            result.info.needsReview = true
        }
        return result
    }
}
