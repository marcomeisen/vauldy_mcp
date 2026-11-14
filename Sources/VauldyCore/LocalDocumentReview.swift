import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Local inspection data. A text section only belongs to a page when its marker is unambiguous.
package struct LocalDocumentReview: Sendable {
    package struct Page: Identifiable, Sendable {
        package let id: Int
        package let text: String?
        package let info: LocalOCRPageInfo?
        package let layout: LocalOCRPageLayout?

        package struct Revision: Identifiable, Sendable {
            package let id: Int
            package let previous: [String]
            package let current: String
        }
        package var revisions: [Revision] {
            guard let text, let layout else { return [] }
            return layout.geometry.lines.compactMap { line in
                guard let prior = line.priorReadings, !prior.isEmpty,
                      let range = Range(NSRange(location: line.location, length: line.length), in: text) else { return nil }
                return Revision(id: line.location, previous: prior, current: String(text[range]))
            }
        }

        package func focus(quote: String) -> LocalDocumentQuality.Focus {
            guard let text, !quote.isEmpty, let range = text.range(of: quote) else { return .init(page: id) }
            let selected = NSRange(range, in: text)
            let boxes = layout?.geometry.lines.filter {
                NSIntersectionRange(selected, NSRange(location: $0.location, length: $0.length)).length > 0
            }.map(\.bounds) ?? []
            return .init(page: id, quote: quote, bounds: boxes)
        }

        /// PDF geometry is in unrotated crop coordinates; the preview is upright.
        package func previewBounds(for focus: LocalDocumentQuality.Focus?) -> [CGRect] {
            guard let focus, focus.page == id, let layout else { return [] }
            return focus.bounds.map { box in
                switch layout.geometry.rotationDegrees {
                case 90: CGRect(x: box.minY, y: 1 - box.maxX, width: box.height, height: box.width)
                case 180: CGRect(x: 1 - box.maxX, y: 1 - box.maxY, width: box.width, height: box.height)
                case 270: CGRect(x: 1 - box.maxY, y: box.minX, width: box.height, height: box.width)
                default: box
                }
            }
        }

        package var needsReview: Bool {
            !revisions.isEmpty || info?.needsReview == true || info?.metrics?.lineReview?.needsReview == true
                || info?.method == .unreadable || text == nil && info?.method != .blank
        }
        package var reason: String {
            if info?.method == .unreadable { return "Auf dieser Seite wurde kein lesbarer Text erkannt." }
            if info?.method == .blank { return "Die Seite wurde als leer erkannt." }
            if text == nil { return "Dieser Seite ist kein gespeicherter Text eindeutig zugeordnet." }
            var reasons: [String] = []
            if !revisions.isEmpty {
                reasons.append("Lesungen oder Schreibweisen wurden präzisiert. Frühere Lesungen sind zum Vergleich erhalten; prüfe die Änderung am Original.")
            }
            if info?.metrics?.evidencePreservedFallback == true {
                reasons.append("Die bisherige belegte Seite wurde erhalten, weil der neue Lauf Text verändert oder verloren hätte.")
            }
            if let lines = info?.metrics?.lineReview {
                if lines.unconfirmedLines > 0 {
                    reasons.append(lines.unconfirmedLines == 1
                        ? "Eine unsichere Zeile ist noch nicht durch zwei passende Lesungen bestätigt."
                        : "\(lines.unconfirmedLines) unsichere Zeilen sind noch nicht durch zwei passende Lesungen bestätigt.")
                }
                if lines.ambiguousIdentifiers > 0 { reasons.append("Mehrdeutige Kennungen bleiben zur Prüfung markiert.") }
                if lines.conflictingReadings > 0 { reasons.append("Lesungen widersprechen sich; vorhandene Werte wurden erhalten.") }
                if lines.budgetLimitedLines > 0 { reasons.append("Das lokale Nachlesebudget ist erreicht; weitere unsichere Zeilen bleiben offen.") }
                if lines.lowConfidenceRegions > 0 { reasons.append("Die mittlere Zeilenkonfidenz liegt unter der Prüfgrenze.") }
                if lines.shortTextRegions > 0 { reasons.append("Ein Bildbereich enthält nur sehr wenig erkannten Text.") }
            }
            if let coverage = layout?.geometry.coverage {
                if coverage.regions.contains(where: \.needsReview) {
                    reasons.append("Die visuelle Prüfung hat möglicherweise nicht erfasste Textbereiche gefunden.")
                }
                if coverage.status != .checked { reasons.append("Die visuelle Textabdeckung konnte nicht vollständig geprüft werden.") }
            }
            if !reasons.isEmpty { return reasons.joined(separator: " ") }
            if info?.needsReview == true { return "Die Texterkennung hat diese Seite zur Prüfung markiert." }
            if info?.method == .blank { return "Die Seite wurde als leer erkannt." }
            if info == nil { return "Für diese Seite ist kein Prüfgrund gespeichert." }
            return "Für diese Seite liegt kein Prüfhinweis vor."
        }
    }

    package let name: String
    package let sourceHash: String
    package let state: LocalImportState
    package let originalState: LocalOriginalState?
    package let importProblem: String?
    package let analysisStatus: String
    package let pages: [Page]
    package let quality: LocalDocumentQuality
    package var firstReviewPage: Int { quality.issues.first(where: { $0.requiresReview && $0.focus != nil })?.focus?.page ?? pages.first(where: \.needsReview)?.id ?? 1 }

    package init?(_ document: VaultDocument) {
        guard let metadata = document.localImport else { return nil }
        name = document.sourceName.isEmpty ? document.title : document.sourceName
        sourceHash = metadata.contentHash
        state = metadata.state
        originalState = metadata.originalState
        importProblem = metadata.error?.errorDescription
        analysisStatus = document.baseAnalysisStatus

        let sections = VaultSourceState.sourceSections(document)
        let texts = Dictionary(uniqueKeysWithValues: sections.compactMap { section in
            section.page.map { ($0, section.text) }
        })
        let info = Dictionary(grouping: metadata.pages, by: \.page)
        let observed = max(texts.keys.max() ?? 0, info.keys.max() ?? 0)
        let count = min(200, max(1, document.pageCount ?? observed))
        pages = (1...count).map { index in
            let entries = info[index] ?? []
            let pageInfo = entries.count == 1 ? entries.first : nil
            let layout = pageInfo?.layout
            let valid = metadata.originalState == .available && layout?.matches(sourceHash: metadata.contentHash,
                page: index, text: texts[index] ?? "", configuration: LocalOCRPageCache.configuration) == true
            return Page(id: index, text: texts[index], info: pageInfo, layout: valid ? layout : nil)
        }
        quality = LocalDocumentQuality(document: document, pages: pages)
    }
}

extension LocalDocumentStore {
    /// The preview and its source hash refer to the same bytes. Keep the lease through
    /// decoding/rendering and never publish a temporary copy of the original.
    package func reviewPageImage(documentID: UUID, page: Int, sourceHash: String) async throws -> Data {
        guard (1...200).contains(page) else { throw LocalImportError.invalidDocument }
        return try await run {
            let access = try locked {
                guard let metadata = try read(ids: [documentID]).first(where: { $0.id == documentID })?.localImport,
                      metadata.contentHash == sourceHash else { throw LocalImportError.staleAttempt }
                return try checkedOriginal(metadata)
            }
            defer { access.close() }
            let bytes = try access.readData()
            guard LocalOriginalAccess.hash(bytes) == sourceHash else { throw LocalOriginalError.changed }
            return try LocalReviewImage.render(bytes, page: page)
        }
    }
}

private enum LocalReviewImage {
    static func render(_ data: Data, page: Int) throws -> Data {
        let image: CGImage
        if let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) {
            guard let physical = pdf.page(at: page) else { throw LocalImportError.invalidDocument }
            image = try renderPDF(physical)
        } else {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1400
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, page - 1, options)
            else { throw LocalImportError.unreadableFile }
            image = thumbnail
        }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw LocalImportError.unreadableFile
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw LocalImportError.unreadableFile }
        return output as Data
    }

    private static func renderPDF(_ page: CGPDFPage) throws -> CGImage {
        let bounds = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let (width, height) = rotated ? (bounds.height, bounds.width) : (bounds.width, bounds.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw LocalImportError.invalidDocument }
        let scale = min(2, 1400 / max(width, height))
        let pixels = (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
        let canvas = CGRect(x: 0, y: 0, width: pixels.0, height: pixels.1)
        guard let context = CGContext(data: nil, width: pixels.0, height: pixels.1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw LocalImportError.unreadableFile }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(canvas)
        // Quartz may center a 1× page in an enlarged bitmap. Scale the canonical
        // crop/rotation transform explicitly so normalized source geometry matches.
        context.scaleBy(x: canvas.width / width, y: canvas.height / height)
        context.concatenate(page.getDrawingTransform(.cropBox,
            rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw LocalImportError.unreadableFile }
        return image
    }
}
