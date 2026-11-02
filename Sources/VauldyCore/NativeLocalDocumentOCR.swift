import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics

/// All native work stays on one background queue. Cancellation is joined before releasing the import lease.
public struct NativeLocalDocumentOCR: LocalDocumentOCR {
    private static let queue = DispatchQueue(label: "vauldy.local-ocr.native", qos: .userInitiated)
    private let cacheRoot: URL?
    private let baseline: Bool
    public init(cacheRoot: URL? = nil, baseline: Bool = false) { self.cacheRoot = cacheRoot; self.baseline = baseline }
    public func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        let cancellation = OCRCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let cache = try cacheRoot.map { try LocalOCRPageCache(root: $0, file: file) }
                        if file.pathExtension.lowercased() == "pdf" {
                            return try Self.pdf(file, cancellation: cancellation, progress: progress, cache: cache, baseline: baseline)
                        }
                        return try Self.images(file, cancellation: cancellation, progress: progress, cache: cache)
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func pdf(_ file: URL, cancellation: OCRCancellation,
                            progress: @escaping @Sendable (LocalImportProgress) -> Void, cache: LocalOCRPageCache?, baseline: Bool = false) throws -> LocalOCRResult {
        guard let document = PDFDocument(url: file) else { throw LocalImportError.invalidDocument }
        guard !document.isLocked else { throw LocalImportError.encryptedPDF }
        let count = document.pageCount
        guard count > 0 else { throw LocalImportError.invalidDocument }
        guard count <= 200 else { throw LocalImportError.tooManyPages }
        var pages: [LocalOCRPage] = []
        var textBytes = 0
        for index in 0..<count {
            try cancellation.check()
            progress(.init(completedPages: index, totalPages: count, stage: "Texterkennung"))
            let page: LocalOCRPage = try autoreleasepool {
                let lookup = LocalStopwatch()
                if var hit = cache?.load(page: index + 1) {
                    var metrics = LocalOCRMetrics(); metrics.cacheHit = true; metrics.cacheMilliseconds = lookup.milliseconds
                    hit.info.metrics = metrics; hit.info.elapsedMilliseconds = lookup.milliseconds
                    return hit
                }
                let start = Date()
                guard let source = document.page(at: index), let reference = source.pageRef else {
                    return LocalOCRPage(info: .init(page: index + 1, method: .unreadable, needsReview: true), text: "")
                }
                let inspectionClock = LocalStopwatch()
                let embedded = source.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Raster/form content can hold a scanned body alongside a small text header. Never certify the header alone.
                let inspection = PDFContentInspection.inspect(reference)
                let inspectionMS = inspectionClock.milliseconds
                if isUsableEmbeddedText(embedded) && (baseline ? !hasExternalGraphics(reference) : (!inspection.uncertain && inspection.imageRects.isEmpty)) {
                    var result = LocalOCRPage(info: .init(page: index + 1, method: .embeddedText,
                                                   elapsedMilliseconds: milliseconds(start)), text: embedded)
                    var metrics = LocalOCRMetrics(); metrics.inspectionMilliseconds = inspectionMS; result.info.metrics = metrics
                    return result
                }
                do {
                    var result: LocalOCRPage
                    let crop = reference.getBoxRect(.cropBox)
                    let images = inspection.imageRects.map { $0.intersection(crop) }.filter { !$0.isNull && !$0.isEmpty }
                    let textBounds = source.selection(for: NSRange(location: 0, length: source.numberOfCharacters))?.selectionsByLine().map { $0.bounds(for: source) } ?? []
                    let hybrid = reference.rotationAngle == 0 && !baseline && isUsableEmbeddedText(embedded) && !inspection.uncertain && !images.isEmpty && images.count <= 4
                        && images.reduce(0, { $0 + $1.width * $1.height }) < crop.width * crop.height * 0.2
                        && images.allSatisfy { image in !textBounds.contains { $0.intersects(image) } }
                    if hybrid {
                        result = try recognizeRegions(reference, regions: images, scale: 3, page: index + 1, cancellation: cancellation)
                        result.text = embedded + (result.text.isEmpty ? "" : "\n" + result.text)
                        result.info.method = .embeddedTextAndVision
                    } else {
                        let scale = baseline ? 3 : (inspection.imageRects.isEmpty && !inspection.uncertain ? adaptiveScale(source) : max(3, adaptiveScale(source)))
                        let regions = baseline || reference.rotationAngle != 0 ? [crop] : pageRegions(crop, scale: scale)
                        result = try recognizeRegions(reference, regions: regions, scale: scale, page: index + 1, cancellation: cancellation)
                    }
                    result.info.metrics?.inspectionMilliseconds = inspectionMS
                    result.info.elapsedMilliseconds = milliseconds(start)
                    let bounds = reference.getBoxRect(.cropBox)
                    if max(bounds.width, bounds.height) / max(1, min(bounds.width, bounds.height)) > 6 && (result.info.metrics?.recognitionRegions ?? 1) <= 1 {
                        result.info.needsReview = true
                    }
                    return result
                } catch is CancellationError { throw CancellationError() }
                catch {
                    return LocalOCRPage(info: .init(page: index + 1, method: .unreadable,
                                                   elapsedMilliseconds: milliseconds(start), needsReview: true), text: "")
                }
            }
            textBytes += page.text.utf8.count
            guard textBytes <= 900_000 else { throw LocalImportError.fileTooLarge }
            try cancellation.check()
            if page.info.metrics?.cacheHit != true { try cache?.save(page) }
            pages.append(page)
        }
        try cancellation.check()
        progress(.init(completedPages: count, totalPages: count, stage: "Texterkennung abgeschlossen"))
        return LocalOCRResult(pages: pages)
    }

    private static func images(_ file: URL, cancellation: OCRCancellation,
                               progress: @escaping @Sendable (LocalImportProgress) -> Void, cache: LocalOCRPageCache?, baseline: Bool = false) throws -> LocalOCRResult {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { throw LocalImportError.invalidDocument }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw LocalImportError.invalidDocument }
        guard count <= 200 else { throw LocalImportError.tooManyPages }
        var pages: [LocalOCRPage] = []
        var textBytes = 0
        for index in 0..<count {
            try cancellation.check()
            progress(.init(completedPages: index, totalPages: count, stage: "Texterkennung"))
            let page: LocalOCRPage = try autoreleasepool {
                let lookup = LocalStopwatch()
                if var hit = cache?.load(page: index + 1) {
                    var metrics = LocalOCRMetrics(); metrics.cacheHit = true; metrics.cacheMilliseconds = lookup.milliseconds
                    hit.info.metrics = metrics; hit.info.elapsedMilliseconds = lookup.milliseconds
                    return hit
                }
                let start = Date()
                let renderClock = LocalStopwatch()
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                let ratio = max(width, height) / max(1, min(width, height))
                guard ratio.isFinite else { throw LocalImportError.invalidDocument }
                let edge = ratio > 4 ? Int(min(12_288, max(3072, ratio * 1024))) : 3072
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                    kCGImageSourceShouldCacheImmediately: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    return LocalOCRPage(info: .init(page: index + 1, method: .unreadable, needsReview: true), text: "")
                }
                do {
                    let renderMS = renderClock.milliseconds
                    let recognitionClock = LocalStopwatch()
                    var page = try recognizeImageTiles(image, page: index + 1, cancellation: cancellation)
                    page.info.metrics?.renderMilliseconds = renderMS
                    page.info.metrics?.recognitionMilliseconds = recognitionClock.milliseconds
                    page.info.elapsedMilliseconds = milliseconds(start)
                    if ratio > 4 && min(image.width, image.height) < 800 { page.info.needsReview = true }
                    return page
                } catch is CancellationError { throw CancellationError() }
                catch { return LocalOCRPage(info: .init(page: index + 1, method: .unreadable, needsReview: true), text: "") }
            }
            textBytes += page.text.utf8.count
            guard textBytes <= 900_000 else { throw LocalImportError.fileTooLarge }
            try cancellation.check()
            if page.info.metrics?.cacheHit != true { try cache?.save(page) }
            pages.append(page)
        }
        try cancellation.check()
        progress(.init(completedPages: count, totalPages: count, stage: "Texterkennung abgeschlossen"))
        return LocalOCRResult(pages: pages)
    }

    private static func recognizeImageTiles(_ image: CGImage, page: Int, cancellation: OCRCancellation) throws -> LocalOCRPage {
        let vertical = image.height > image.width
        let long = max(image.width, image.height), short = min(image.width, image.height)
        guard long > 3072 && long > short * 4 else {
            var result = try recognizeImage(image, page: page, cancellation: cancellation)
            var metrics = LocalOCRMetrics(); metrics.renderedPixels = image.width * image.height; metrics.recognitionRegions = 1
            result.info.metrics = metrics; return result
        }
        var offset = 0, pieces: [LocalOCRPage] = [], metrics = LocalOCRMetrics()
        while offset < long {
            try cancellation.check()
            let length = min(2800, long - offset)
            let box = vertical ? CGRect(x: 0, y: offset, width: short, height: length) : CGRect(x: offset, y: 0, width: length, height: short)
            guard let tile = image.cropping(to: box) else { throw LocalImportError.invalidDocument }
            pieces.append(try recognizeImage(tile, page: page, cancellation: cancellation))
            metrics.recognitionRegions += 1; metrics.renderedPixels += tile.width * tile.height
            if offset + length == long { break }; offset += length - 80
        }
        let text = pieces.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        let confidence = pieces.compactMap(\.info.confidence)
        var result = LocalOCRPage(info: .init(page: page, method: text.isEmpty ? (pieces.allSatisfy { $0.info.method == .blank } ? .blank : .unreadable) : .vision,
            confidence: confidence.isEmpty ? nil : confidence.reduce(0, +) / Double(confidence.count),
            needsReview: pieces.contains { $0.info.needsReview }), text: text)
        result.info.metrics = metrics; return result
    }

    private static func recognizeImage(_ image: CGImage, page: Int, cancellation: OCRCancellation) throws -> LocalOCRPage {
        if isBlank(image) { return LocalOCRPage(info: .init(page: page, method: .blank), text: "") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        cancellation.register(request)
        defer { cancellation.register(nil) }
        try cancellation.check()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { try cancellation.check(); throw error }
        try cancellation.check()
        let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        let text = candidates.map(\.string).joined(separator: "\n")
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else {
            return LocalOCRPage(info: .init(page: page, method: .unreadable, needsReview: true), text: "")
        }
        let confidence = candidates.reduce(0.0) { $0 + Double($1.confidence) } / Double(candidates.count)
        return LocalOCRPage(info: .init(page: page, method: .vision, confidence: confidence,
                                       needsReview: confidence < 0.75 || text.count < 20), text: text)
    }

    private static func adaptiveScale(_ page: PDFPage) -> CGFloat {
        let count = min(page.numberOfCharacters, 500)
        let heights = (0..<count).map { page.characterBounds(at: $0).height }.filter { $0 > 2 && $0 < 100 }.sorted()
        // Aim for at least 32 pixels per glyph; scanned pages without embedded geometry retain 3x.
        guard !heights.isEmpty else { return 3 }
        return min(4, max(2, 32 / heights[heights.count / 5]))
    }
    static func pageRegions(_ box: CGRect, scale: CGFloat) -> [CGRect] {
        guard max(box.width, box.height) / max(1, min(box.width, box.height)) > 4 else { return [box] }
        let segment = 2800 / scale, overlap = 80 / scale
        guard box.height > box.width, box.height / (segment - overlap) <= 24 else { return [box] }
        var regions: [CGRect] = []; var top = box.maxY
        while top > box.minY {
            let bottom = max(box.minY, top - segment)
            regions.append(CGRect(x: box.minX, y: bottom, width: box.width, height: top - bottom))
            if bottom == box.minY { break }; top = bottom + overlap
        }
        return regions
    }
    private static func recognizeRegions(_ page: CGPDFPage, regions: [CGRect], scale: CGFloat,
                                         page number: Int, cancellation: OCRCancellation) throws -> LocalOCRPage {
        var metrics = LocalOCRMetrics(), texts: [String] = [], confidences: [Double] = []
        var review = false, hasInk = false
        for region in regions {
            try cancellation.check()
            try autoreleasepool {
                let renderClock = LocalStopwatch()
                let image = try render(page, region: region, requestedScale: scale)
                metrics.renderMilliseconds += renderClock.milliseconds; metrics.renderedPixels += image.width * image.height
                let recognitionClock = LocalStopwatch()
                let result = try recognizeImage(image, page: number, cancellation: cancellation)
                metrics.recognitionMilliseconds += recognitionClock.milliseconds; metrics.recognitionRegions += 1
                review = review || result.info.needsReview; hasInk = hasInk || result.info.method != .blank
                if let confidence = result.info.confidence { confidences.append(confidence) }
                // Overlaps may repeat lines. Keep them rather than risk deleting legitimate repeated amounts.
                if !result.text.isEmpty { texts.append(result.text) }
            }
        }
        let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        var result = LocalOCRPage(info: .init(page: number, method: texts.isEmpty ? (hasInk ? .unreadable : .blank) : .vision,
                                              confidence: confidence, needsReview: review), text: texts.joined(separator: "\n"))
        result.info.metrics = metrics
        return result
    }
    private static func render(_ page: CGPDFPage, region: CGRect, requestedScale: CGFloat) throws -> CGImage {
        guard region.width.isFinite, region.height.isFinite, region.width > 0, region.height > 0 else { throw LocalImportError.invalidDocument }
        let rotated = abs(page.rotationAngle) % 180 != 0
        let size = CGSize(width: rotated ? region.height : region.width, height: rotated ? region.width : region.height)
        let scale = min(3072 / max(size.width, size.height), requestedScale)
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw LocalImportError.invalidDocument }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
        // Full page uses Apple's crop/rotation transform; partial regions retain physical PDF coordinates.
        if region == page.getBoxRect(.cropBox) {
            context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        } else {
            context.scaleBy(x: scale, y: scale)
            if rotated { context.translateBy(x: region.height, y: 0); context.rotate(by: .pi / 2) }
            context.translateBy(x: -region.minX, y: -region.minY)
        }
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw LocalImportError.invalidDocument }
        return image
    }
    private static func isUsableEmbeddedText(_ text: String) -> Bool {
        guard text.count >= 40, text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 25 else { return false }
        return !text.contains("\u{FFFD}") && !text.contains("\0")
    }
    private static func hasExternalGraphics(_ page: CGPDFPage) -> Bool {
        guard let table = CGPDFOperatorTableCreate() else { return true }
        let callback: CGPDFOperatorCallback = { _, info in
            info?.assumingMemoryBound(to: Bool.self).pointee = true
        }
        CGPDFOperatorTableSetCallback(table, "Do", callback)
        CGPDFOperatorTableSetCallback(table, "BI", callback)
        let stream = CGPDFContentStreamCreateWithPage(page)
        var found = false
        let succeeded = withUnsafeMutablePointer(to: &found) { pointer in
            let scanner = CGPDFScannerCreate(stream, table, pointer)
            return CGPDFScannerScan(scanner)
        }
        return !succeeded || found
    }
    private static func isBlank(_ image: CGImage) -> Bool {
        let edge = 128
        var pixels = [UInt8](repeating: 255, count: edge * edge)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: edge, height: edge, bitsPerComponent: 8,
                bytesPerRow: edge, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
            context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return buffer.reduce(0) { $0 + ($1 < 245 ? 1 : 0) } < 2
        }
    }
    private static func milliseconds(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1_000) }
}

private final class OCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    func cancel() {
        lock.lock(); cancelled = true; let current = request; lock.unlock()
        current?.cancel()
    }
    func register(_ value: VNRequest?) {
        lock.lock(); request = value; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { value?.cancel() }
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
