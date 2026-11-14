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
    private let targetedRetry: Bool
    private let correctPDFScale: Bool
    private let regionRecovery: Bool
    private let scaleSmallRegions: Bool
    private let smallTextDetection: Bool
    private let denseCoverage: Bool
    private let lineRecovery: Bool
    public init(cacheRoot: URL? = nil, baseline: Bool = false) {
        self.init(cacheRoot: cacheRoot, baseline: baseline, targetedRetry: !baseline, correctPDFScale: !baseline, regionRecovery: !baseline, lineRecovery: !baseline)
    }
    init(cacheRoot: URL? = nil, baseline: Bool = false, targetedRetry: Bool, correctPDFScale: Bool = true, regionRecovery: Bool = true,
         scaleSmallRegions: Bool = true, smallTextDetection: Bool = true, denseCoverage: Bool = true, lineRecovery: Bool = true) {
        self.cacheRoot = cacheRoot; self.baseline = baseline; self.targetedRetry = targetedRetry
        self.correctPDFScale = correctPDFScale
        self.regionRecovery = regionRecovery
        self.scaleSmallRegions = scaleSmallRegions
        self.smallTextDetection = smallTextDetection
        self.denseCoverage = denseCoverage; self.lineRecovery = lineRecovery
    }
    public func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        let cancellation = OCRCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let mode = (baseline ? "-legacy-render" : (targetedRetry ? "" : "-single-pass"))
                            + (correctPDFScale ? "" : "-legacy-pdf-scale")
                            + (regionRecovery ? "" : "-coverage-only")
                            + (scaleSmallRegions ? "" : "-unscaled-regions")
                            + (smallTextDetection ? "" : "-single-scale-detection")
                            + (denseCoverage ? "" : "-legacy-dense-coverage")
                            + (lineRecovery ? "" : "-legacy-line-review")
                        let configuration = LocalOCRPageCache.configuration + mode
                        let cache = try cacheRoot.map {
                            try LocalOCRPageCache(root: $0, file: file, configuration: configuration)
                        }
                        if file.pathExtension.lowercased() == "pdf" {
                            return try Self.pdf(file, cancellation: cancellation, progress: progress, cache: cache,
                                                baseline: baseline, targetedRetry: targetedRetry, correctPDFScale: correctPDFScale,
                                                configuration: configuration, regionRecovery: regionRecovery, scaleSmallRegions: scaleSmallRegions, smallTextDetection: smallTextDetection, denseCoverage: denseCoverage, lineRecovery: lineRecovery)
                        }
                        return try Self.images(file, cancellation: cancellation, progress: progress, cache: cache,
                                               targetedRetry: targetedRetry, configuration: configuration, checkCoverage: !baseline,
                                               regionRecovery: regionRecovery, scaleSmallRegions: scaleSmallRegions, smallTextDetection: smallTextDetection, denseCoverage: denseCoverage, lineRecovery: lineRecovery)
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func pdf(_ file: URL, cancellation: OCRCancellation,
                            progress: @escaping @Sendable (LocalImportProgress) -> Void, cache: LocalOCRPageCache?,
                            baseline: Bool, targetedRetry: Bool, correctPDFScale: Bool, configuration: String,
                            regionRecovery: Bool, scaleSmallRegions: Bool, smallTextDetection: Bool, denseCoverage: Bool, lineRecovery: Bool) throws -> LocalOCRResult {
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
            var page: LocalOCRPage = try autoreleasepool {
                let lookup = LocalStopwatch()
                if var hit = cache?.load(page: index + 1) {
                    var metrics = LocalOCRMetrics(); metrics.lineReview = hit.info.metrics?.lineReview; metrics.cacheHit = true; metrics.cacheMilliseconds = lookup.milliseconds
                    hit.info.metrics = metrics; hit.info.elapsedMilliseconds = lookup.milliseconds
                    return hit
                }
                let start = Date()
                let recovery = RegionRecoveryBudget(enabled: regionRecovery, scaleSmallRegions: scaleSmallRegions, smallTextDetection: smallTextDetection, denseCoverage: denseCoverage, lineRecovery: lineRecovery)
                guard let source = document.page(at: index), let reference = source.pageRef else {
                    return LocalOCRPage(info: .init(page: index + 1, method: .unreadable, needsReview: true), text: "")
                }
                let inspectionClock = LocalStopwatch()
                let embedded = source.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Raster/form content can hold a scanned body alongside a small text header. Never certify the header alone.
                let inspection = PDFContentInspection.inspect(reference)
                let inspectionMS = inspectionClock.milliseconds
                let usableEmbedded = isUsableEmbeddedText(embedded, legacy: baseline)
                if usableEmbedded && (baseline ? !hasExternalGraphics(reference) : (!inspection.uncertain && inspection.imageRects.isEmpty)) {
                    var result = LocalOCRPage(info: .init(page: index + 1, method: .embeddedText,
                                                   elapsedMilliseconds: milliseconds(start)), text: embedded)
                    var metrics = LocalOCRMetrics(); metrics.inspectionMilliseconds = inspectionMS; result.info.metrics = metrics
                    result.geometry = embeddedGeometry(source, text: embedded)
                    if !baseline { try checkPDFCoverage(reference, result: &result, cancellation: cancellation, recovery: recovery) }
                    result.info.elapsedMilliseconds = milliseconds(start)
                    return result
                }
                do {
                    var result: LocalOCRPage
                    let crop = reference.getBoxRect(.cropBox)
                    let images = inspection.imageRects.map { $0.intersection(crop) }.filter { !$0.isNull && !$0.isEmpty }
                    let textBounds = source.selection(for: NSRange(location: 0, length: source.numberOfCharacters))?.selectionsByLine().map { $0.bounds(for: source) } ?? []
                    let hybrid = reference.rotationAngle == 0 && !baseline && usableEmbedded && !inspection.uncertain && !images.isEmpty && images.count <= 4
                        && images.reduce(0, { $0 + $1.width * $1.height }) < crop.width * crop.height * 0.2
                        && images.allSatisfy { image in !textBounds.contains { $0.intersects(image) } }
                    if hybrid {
                        result = try recognizeRegions(reference, regions: images, scale: 3, page: index + 1,
                                                      cancellation: cancellation, targetedRetry: targetedRetry, recovery: recovery)
                        var geometry = embeddedGeometry(source, text: embedded)
                        geometry.append(result.geometry, textOffset: embedded.utf16.count + 1)
                        result.geometry = geometry
                        result.text = embedded + (result.text.isEmpty ? "" : "\n" + result.text)
                        result.info.method = .embeddedTextAndVision
                        try checkPDFCoverage(reference, result: &result, cancellation: cancellation, recovery: recovery)
                    } else {
                        let scale: CGFloat = baseline ? 3 : (inspection.imageRects.isEmpty && !inspection.uncertain ? adaptiveScale(source) : max(3, adaptiveScale(source)))
                        // A corrected rendering is available only for a known full-page raster.
                        // The first pass decides from measured glyph size whether it is needed.
                        var correctedScale: CGFloat?
                        if correctPDFScale, embedded.isEmpty, !inspection.uncertain,
                           inspection.imageRects.count == 1, inspection.imageScales.count == 1,
                           inspection.imageRects[0].contains(crop), let native = inspection.imageScales[0],
                           native.isFinite, native >= 1 {
                            correctedScale = min(scale, native)
                        }
                        let regions = baseline || reference.rotationAngle != 0 ? [crop] : pageRegions(crop, scale: scale)
                        result = try recognizeRegions(reference, regions: regions, scale: scale, page: index + 1,
                                                      cancellation: cancellation, targetedRetry: targetedRetry,
                                                      correctedScale: regions.count == 1 && regions[0] == crop ? correctedScale : nil,
                                                      checkCoverage: !baseline, recovery: recovery)
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
            page.geometry?.configuration = configuration
            page.geometry?.formBlocks()
            if page.geometry?.coverage?.needsReview == true { page.info.needsReview = true }
            if page.info.metrics?.cacheHit != true { try cache?.save(page) }
            pages.append(page)
        }
        try cancellation.check()
        progress(.init(completedPages: count, totalPages: count, stage: "Texterkennung abgeschlossen"))
        return LocalOCRResult(pages: pages)
    }

    private static func images(_ file: URL, cancellation: OCRCancellation,
                               progress: @escaping @Sendable (LocalImportProgress) -> Void, cache: LocalOCRPageCache?,
                               targetedRetry: Bool, configuration: String, checkCoverage: Bool, regionRecovery: Bool,
                               scaleSmallRegions: Bool, smallTextDetection: Bool, denseCoverage: Bool, lineRecovery: Bool) throws -> LocalOCRResult {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { throw LocalImportError.invalidDocument }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw LocalImportError.invalidDocument }
        guard count <= 200 else { throw LocalImportError.tooManyPages }
        var pages: [LocalOCRPage] = []
        var textBytes = 0
        for index in 0..<count {
            try cancellation.check()
            progress(.init(completedPages: index, totalPages: count, stage: "Texterkennung"))
            var page: LocalOCRPage = try autoreleasepool {
                let lookup = LocalStopwatch()
                if var hit = cache?.load(page: index + 1) {
                    var metrics = LocalOCRMetrics(); metrics.lineReview = hit.info.metrics?.lineReview; metrics.cacheHit = true; metrics.cacheMilliseconds = lookup.milliseconds
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
                    var page = try recognizeImageTiles(image, page: index + 1, cancellation: cancellation,
                                                      targetedRetry: targetedRetry, checkCoverage: checkCoverage, regionRecovery: regionRecovery,
                                                      scaleSmallRegions: scaleSmallRegions, smallTextDetection: smallTextDetection, denseCoverage: denseCoverage, lineRecovery: lineRecovery)
                    page.info.metrics?.renderMilliseconds = renderMS
                    let coverageMS = page.info.metrics?.coverageMilliseconds ?? 0
                    let recoveryMS = page.info.metrics?.regionRetryMilliseconds ?? 0
                    page.info.metrics?.recognitionMilliseconds = max(0, recognitionClock.milliseconds - coverageMS - recoveryMS)
                    page.info.elapsedMilliseconds = milliseconds(start)
                    if ratio > 4 && min(image.width, image.height) < 800 { page.info.needsReview = true }
                    return page
                } catch is CancellationError { throw CancellationError() }
                catch { return LocalOCRPage(info: .init(page: index + 1, method: .unreadable, needsReview: true), text: "") }
            }
            textBytes += page.text.utf8.count
            guard textBytes <= 900_000 else { throw LocalImportError.fileTooLarge }
            try cancellation.check()
            page.geometry?.configuration = configuration
            page.geometry?.formBlocks()
            if page.geometry?.coverage?.needsReview == true { page.info.needsReview = true }
            if page.info.metrics?.cacheHit != true { try cache?.save(page) }
            pages.append(page)
        }
        try cancellation.check()
        progress(.init(completedPages: count, totalPages: count, stage: "Texterkennung abgeschlossen"))
        return LocalOCRResult(pages: pages)
    }

    private static func recognizeImageTiles(_ image: CGImage, page: Int, cancellation: OCRCancellation,
                                            targetedRetry: Bool, checkCoverage: Bool, regionRecovery: Bool, scaleSmallRegions: Bool, smallTextDetection: Bool, denseCoverage: Bool, lineRecovery: Bool) throws -> LocalOCRPage {
        var retries = RetryBudget(enabled: targetedRetry)
        let recovery = RegionRecoveryBudget(enabled: regionRecovery, scaleSmallRegions: scaleSmallRegions, smallTextDetection: smallTextDetection, denseCoverage: denseCoverage, lineRecovery: lineRecovery)
        let vertical = image.height > image.width
        let long = max(image.width, image.height), short = min(image.width, image.height)
        guard long > 3072 && long > short * 4 else {
            var result = try recognizeImage(image, page: page, cancellation: cancellation, retries: &retries,
                                            checkCoverage: checkCoverage, recovery: recovery)
            var metrics = LocalOCRMetrics(); metrics.renderedPixels = image.width * image.height; metrics.recognitionRegions = 1
            metrics.mergeCoverage(result.info.metrics)
            retries.record(in: &metrics)
            recovery.record(in: &metrics)
            result.info.metrics = metrics; return result
        }
        var offset = 0, pieces: [LocalOCRPage] = [], metrics = LocalOCRMetrics()
        while offset < long {
            try cancellation.check()
            let length = min(2800, long - offset)
            let box = vertical ? CGRect(x: 0, y: offset, width: short, height: length) : CGRect(x: offset, y: 0, width: length, height: short)
            guard let tile = image.cropping(to: box) else { throw LocalImportError.invalidDocument }
            var piece = try recognizeImage(tile, page: page, cancellation: cancellation, retries: &retries,
                                           checkCoverage: checkCoverage, recovery: recovery)
            metrics.mergeCoverage(piece.info.metrics)
            piece.geometry?.transform(LocalOCRGeometry.cropTransform(box, width: image.width, height: image.height))
            pieces.append(piece)
            metrics.recognitionRegions += 1; metrics.renderedPixels += tile.width * tile.height
            if offset + length == long { break }; offset += length - 80
        }
        let text = pieces.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        let confidence = pieces.compactMap(\.info.confidence)
        var result = LocalOCRPage(info: .init(page: page, method: text.isEmpty ? (pieces.allSatisfy { $0.info.method == .blank } ? .blank : .unreadable) : .vision,
            confidence: confidence.isEmpty ? nil : confidence.reduce(0, +) / Double(confidence.count),
            needsReview: pieces.contains { $0.info.needsReview }), text: text)
        retries.record(in: &metrics)
        recovery.record(in: &metrics)
        result.geometry = joinedGeometry(pieces)
        result.info.metrics = metrics; return result
    }

    private static func recognizeImage(_ image: CGImage, page: Int, cancellation: OCRCancellation,
                                       retries: inout RetryBudget, replacement: (() throws -> CGImage)? = nil,
                                       checkCoverage: Bool = true, recovery: RegionRecoveryBudget) throws -> LocalOCRPage {
        let originalWidth = image.width, originalHeight = image.height
        let cropBounds = OCRWhiteMargins.contentBounds(in: image) ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let image = image.cropping(to: cropBounds) ?? image
        if isBlank(image) { return LocalOCRPage(info: .init(page: page, method: .blank), text: "") }
        let observations = try readLines(image, languageCorrection: true, cancellation: cancellation)
        let lines = observations.compactMap { observation in
            observation.topCandidates(1).first.map { (observation, $0) }
        }
        // Select image resolution from geometry, never from expected text, numeric values
        // or confidence. Most detected lines below the existing 16-pixel small-print threshold cannot resolve small glyphs.
        let tinyLines = lines.filter { glyphHeight($0.0, in: image) < 16 }.count
        if let replacement, tinyLines >= 2, tinyLines * 2 >= lines.count {
            try cancellation.check()
            return try recognizeImage(replacement(), page: page, cancellation: cancellation, retries: &retries,
                                      checkCoverage: checkCoverage, recovery: recovery)
        }
        let original = lines.map { $0.1.string }.joined(separator: "\n")
        guard original.rangeOfCharacter(from: .alphanumerics) != nil else {
            var result = LocalOCRPage(info: .init(page: page, method: .unreadable, needsReview: true), text: "")
            if checkCoverage {
                result.geometry = .vision(texts: [], bounds: [], confidences: [])
                try checkImageCoverage(image, result: &result, cancellation: cancellation, recovery: recovery)
                result.geometry?.transform(LocalOCRGeometry.cropTransform(cropBounds, width: originalWidth, height: originalHeight))
            }
            return result
        }
        let confidence = lines.reduce(0.0) { $0 + Double($1.1.confidence) } / Double(lines.count)
        var result = LocalOCRPage(info: .init(page: page, method: .vision, confidence: confidence,
                                             needsReview: confidence < 0.75 || original.count < 20), text: original)
        var text = lines.map { $0.1.string }
        var bounds = lines.map { $0.0.boundingBox }
        var confidences = lines.map { Double($0.1.confidence) }
        result.geometry = .vision(texts: text, bounds: bounds, confidences: confidences)
        guard recovery.lineRecovery || retries.remaining > 0 else {
            if checkCoverage { try checkImageCoverage(image, result: &result, cancellation: cancellation, recovery: recovery) }
            result.geometry?.transform(LocalOCRGeometry.cropTransform(cropBounds, width: originalWidth, height: originalHeight))
            return result
        }
        let targets = lines.indices.compactMap { index -> (index: Int, identifier: Bool, smallPrint: Bool, ambiguous: Bool, confidence: Float)? in
            let (observation, line) = lines[index]
            let identifier = OCRLineRecovery.isIdentifier(line.string)
            let smallPrint = glyphHeight(observation, in: image) < 16
            let ambiguous = identifier && OCRLineRecovery.hasConfusableIdentifier(line.string)
            guard ambiguous || smallPrint || line.confidence < (identifier ? 0.94 : 0.75) else { return nil }
            return (index, identifier, smallPrint, ambiguous, line.confidence)
        }.sorted {
            if recovery.lineRecovery {
                return OCRLineRecovery.priority(identifier: $0.identifier, ambiguous: $0.ambiguous, confidence: $0.confidence, index: $0.index)
                    < OCRLineRecovery.priority(identifier: $1.identifier, ambiguous: $1.ambiguous, confidence: $1.confidence, index: $1.index)
            }
            return ($0.identifier ? 0 : 1, $0.confidence, $0.index) < ($1.identifier ? 0 : 1, $1.confidence, $1.index)
        }
        if recovery.lineRecovery {
            let uncertain = Set(targets.filter { $0.ambiguous || $0.smallPrint || $0.confidence < ($0.identifier ? 0.94 : 0.75) }.map(\.index))
            var state = OCRLineReviewState(uncertain: uncertain, ambiguous: Set(targets.filter(\.ambiguous).map(\.index)))
            var normalizedCrops = 0
            for target in targets {
                guard retries.remaining > 0 else { break }
                try cancellation.check()
                let index = target.index
                let (observation, first) = lines[index]
                state.attempted.insert(index)
                guard let crop = rectifiedLineCrop(image, observation: observation) else {
                    state.unavailable.insert(index); continue
                }
                retries.attempted += 1
                let enhanced = OCRLineContrast.normalize(crop.image, target: crop.target)
                if enhanced != nil { normalizedCrops += 1 }
                let second: OCRRegionRecovery.Candidate?
                do {
                    let observations = try readLines(enhanced ?? crop.image, languageCorrection: !target.identifier, cancellation: cancellation)
                    second = OCRLineRecovery.select(observations.compactMap { item in
                        item.topCandidates(1).first.map { OCRRegionRecovery.Candidate(text: $0.string, bounds: item.boundingBox, confidence: $0.confidence) }
                    }, target: crop.target)
                } catch is CancellationError { throw CancellationError() }
                catch { state.unavailable.insert(index); continue }
                guard let second else { state.unavailable.insert(index); continue }
                let alternatives = observation.topCandidates(3).dropFirst().map(\.string)
                let decision = OCRLineRecovery.decide(original: first.string, confidence: first.confidence,
                    alternatives: alternatives, retry: second.text, retryConfidence: second.confidence,
                    identifier: target.identifier, smallPrint: target.smallPrint, allowSmallGlyphRepair: true)
                if decision == .review { state.conflicts.insert(index); continue }
                let unchanged = OCRRegionRecovery.canonical(first.string) == OCRRegionRecovery.canonical(second.text)
                // A keep decision alone does not confirm a weak source line.
                guard decision == .replace || (uncertain.contains(index) && unchanged && !target.ambiguous) else { continue }
                guard let context = rectifiedLineCrop(image, observation: observation, contextPadding: 0.6) else {
                    state.unavailable.insert(index); continue
                }
                let normalized = OCRLineContrast.normalize(context.image, target: context.target, maximumGain: 2)
                if normalized != nil { normalizedCrops += 1 }
                let confirmation: OCRRegionRecovery.Candidate?
                do {
                    let observations = try readLines(normalized ?? context.image, languageCorrection: false, cancellation: cancellation)
                    confirmation = OCRLineRecovery.select(observations.compactMap { item in
                        item.topCandidates(1).first.map { OCRRegionRecovery.Candidate(text: $0.string, bounds: item.boundingBox, confidence: $0.confidence) }
                    }, target: context.target)
                } catch is CancellationError { throw CancellationError() }
                catch { state.unavailable.insert(index); continue }
                guard let confirmation else { state.unavailable.insert(index); continue }
                let secondOnPage = OCRRegionRecovery.Candidate(text: second.text,
                    bounds: second.bounds.applying(crop.transform), confidence: second.confidence)
                let confirmedOnPage = OCRRegionRecovery.Candidate(text: confirmation.text,
                    bounds: confirmation.bounds.applying(context.transform), confidence: confirmation.confidence)
                let confidence = min(second.confidence, confirmation.confidence)
                guard OCRRegionRecovery.sameObservation(secondOnPage, confirmedOnPage) else {
                    state.conflicts.insert(index); continue
                }
                guard confidence >= (target.identifier ? 0.94 : 0.85), !target.ambiguous else { continue }
                if decision == .replace {
                    guard OCRLineRecovery.decide(original: first.string, confidence: first.confidence, alternatives: alternatives,
                        retry: confirmation.text, retryConfidence: confidence, identifier: target.identifier,
                        smallPrint: target.smallPrint, allowSmallGlyphRepair: true) == .replace else { state.conflicts.insert(index); continue }
                    text[index] = second.text; retries.recovered += 1
                }
                state.confirm(index, repaired: decision == .replace)
                bounds[index] = secondOnPage.bounds
                confidences[index] = Double(confidence)
            }
            var assessment = state.summary
            assessment.normalizedCrops = normalizedCrops
            let effectiveConfidence = confidences.reduce(0, +) / Double(confidences.count)
            assessment.lowConfidenceRegions = effectiveConfidence < 0.75 ? 1 : 0
            assessment.shortTextRegions = text.joined(separator: "\n").count < 20 ? 1 : 0
            retries.hasLineReview = true; retries.lineReview.merge(assessment)
            result.info.confidence = effectiveConfidence
            result.info.needsReview = assessment.needsReview || assessment.repairedLines > 0
        } else {
        // Both passes can confidently confuse the same glyphs in a code.
        if targets.contains(where: { $0.ambiguous }) { result.info.needsReview = true }
        for target in targets.prefix(retries.remaining) {
            try cancellation.check()
            let (observation, first) = lines[target.index]
            guard let crop = lineCrop(image, bounds: observation.boundingBox) else { continue }
            retries.attempted += 1
            let reread: [VNRecognizedTextObservation]
            do {
                reread = try readLines(crop.image, languageCorrection: !target.identifier, cancellation: cancellation)
            } catch is CancellationError { throw CancellationError() }
            catch { result.info.needsReview = true; continue }
            let candidates = reread.compactMap { item in item.topCandidates(1).first.map {
                OCRRegionRecovery.Candidate(text: $0.string, bounds: item.boundingBox, confidence: $0.confidence)
            } }
            guard let second = OCRLineRecovery.select(candidates, target: crop.target, joinFragments: false) else {
                if target.identifier || target.confidence < 0.55 { result.info.needsReview = true }
                continue
            }
            let alternatives = observation.topCandidates(3).dropFirst().map(\.string)
            switch OCRLineRecovery.decide(original: first.string, confidence: first.confidence, alternatives: alternatives,
                                          retry: second.text, retryConfidence: second.confidence,
                                          identifier: target.identifier, smallPrint: target.smallPrint) {
            case .keep: break
            case .review: result.info.needsReview = true
            case .replace:
                // Confirm an actual repair in a different context and without
                // language correction. Numeric/identifier disagreement still blocks it.
                guard let context = lineCrop(image, bounds: observation.boundingBox, contextPadding: 0.6) else {
                    result.info.needsReview = true; continue
                }
                let confirmation: OCRRegionRecovery.Candidate?
                do {
                    let observations = try readLines(context.image, languageCorrection: false, cancellation: cancellation)
                    confirmation = OCRLineRecovery.select(observations.compactMap { item in
                        item.topCandidates(1).first.map { OCRRegionRecovery.Candidate(text: $0.string, bounds: item.boundingBox, confidence: $0.confidence) }
                    }, target: context.target, joinFragments: false)
                } catch is CancellationError { throw CancellationError() }
                catch { result.info.needsReview = true; continue }
                let secondOnPage = OCRRegionRecovery.Candidate(text: second.text,
                    bounds: second.bounds.applying(LocalOCRGeometry.cropTransform(crop.bounds, width: image.width, height: image.height)), confidence: second.confidence)
                guard let confirmation else { result.info.needsReview = true; continue }
                let confirmedOnPage = OCRRegionRecovery.Candidate(text: confirmation.text,
                    bounds: confirmation.bounds.applying(LocalOCRGeometry.cropTransform(context.bounds, width: image.width, height: image.height)), confidence: confirmation.confidence)
                let confidence = min(second.confidence, confirmation.confidence)
                guard OCRRegionRecovery.sameObservation(secondOnPage, confirmedOnPage), confirmation.confidence >= 0.85,
                      OCRLineRecovery.decide(original: first.string, confidence: first.confidence, alternatives: alternatives,
                        retry: confirmation.text, retryConfidence: confidence, identifier: target.identifier, smallPrint: target.smallPrint) == .replace else {
                    result.info.needsReview = true; continue
                }
                text[target.index] = second.text; retries.recovered += 1
                bounds[target.index] = secondOnPage.bounds
                confidences[target.index] = Double(confidence)
            }
        }
        }
        result.text = text.joined(separator: "\n")
        result.geometry = .vision(texts: text, bounds: bounds, confidences: confidences)
        for index in text.indices where text[index] != lines[index].1.string {
            result.geometry?.lines[index].priorReadings = [lines[index].1.string]
        }
        if checkCoverage { try checkImageCoverage(image, result: &result, cancellation: cancellation, recovery: recovery) }
        if recovery.lineRecovery {
            do {
                try NativeOCRFieldRecovery.recover(image, page: &result, budget: recovery.fields,
                    check: { try cancellation.check() }, read: { crop in
                        try readLines(crop, languageCorrection: false, cancellation: cancellation, minimumTextHeight: 0)
                    })
            } catch is CancellationError { throw CancellationError() }
            catch { result.info.needsReview = true }
        }
        result.geometry?.transform(LocalOCRGeometry.cropTransform(cropBounds, width: originalWidth, height: originalHeight))
        return result
    }

    private static func readLines(_ image: CGImage, languageCorrection: Bool, cancellation: OCRCancellation,
                                  minimumTextHeight: Float? = nil)
        throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let minimumTextHeight { request.minimumTextHeight = minimumTextHeight }
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = true
        cancellation.register(request)
        defer { cancellation.register(nil) }
        try cancellation.check()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { try cancellation.check(); throw error }
        try cancellation.check()
        return request.results ?? []
    }

    /// Axis-aligned height includes a slanted line's entire rise. Measure across
    /// the quadrilateral instead, so long, tilted small print is still retried.
    private static func glyphHeight(_ observation: VNRecognizedTextObservation, in image: CGImage) -> CGFloat {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot((a.x - b.x) * CGFloat(image.width), (a.y - b.y) * CGFloat(image.height))
        }
        return min(distance(observation.topLeft, observation.bottomLeft),
                   distance(observation.topRight, observation.bottomRight))
    }

    private struct DetectedCharacters {
        var groups: [[CGRect]]
        var limited = false
    }
    private static func detectCharacters(_ image: CGImage, cancellation: OCRCancellation,
                                         segmented: Bool) throws -> DetectedCharacters? {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = true
        cancellation.register(request)
        defer { cancellation.register(nil) }
        try cancellation.check()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { try cancellation.check(); return nil }
        try cancellation.check()
        let observations = request.results ?? []
        guard !observations.contains(where: { $0.characterBoxes == nil }) else { return nil }
        if !segmented {
            return DetectedCharacters(groups: observations.prefix(129).map { ($0.characterBoxes ?? []).prefix(257).map(\.boundingBox) })
        }
        var result = DetectedCharacters(groups: [], limited: observations.count > 1024)
        for observation in observations.prefix(1024) {
            try cancellation.check()
            let boxes = observation.characterBoxes ?? []
            if boxes.count > 4096 { result.limited = true }
            for start in stride(from: 0, to: min(boxes.count, 4096), by: 256) {
                guard result.groups.count < 1024 else { result.limited = true; return result }
                result.groups.append(boxes[start..<min(start + 256, boxes.count)].map(\.boundingBox))
            }
        }
        return result
    }

    private static func detectCoverage(_ image: CGImage, lines: [LocalOCRLine], cancellation: OCRCancellation,
                                       detail: RegionRecoveryBudget) throws -> LocalOCRVisualCoverage {
        guard let detected = try detectCharacters(image, cancellation: cancellation, segmented: detail.denseCoverage) else {
            return .init(status: .unavailable, regions: [])
        }
        var characters = detected.groups
        var limited = detected.limited
        if detail.smallTextDetection {
            // Ink is only a proposal for a local detector crop, never textual evidence.
            let proposals = try OCRSmallTextRegions.proposals(in: image) { try cancellation.check() }
            if proposals.count > 1024 { limited = true }
            for box in proposals.prefix(1024) {
                try cancellation.check()
                let bounds = CGRect(x: box.minX / CGFloat(image.width),
                    y: 1 - box.maxY / CGFloat(image.height), width: box.width / CGFloat(image.width),
                    height: box.height / CGFloat(image.height))
                if characters.contains(where: { boxes in
                    let region = boxes.reduce(CGRect.null) { $0.union($1) }
                    let overlap = region.intersection(bounds)
                    return !overlap.isNull && overlap.width * overlap.height >= bounds.width * bounds.height * 0.8
                }) { continue }
                let padded = box.insetBy(dx: -12, dy: -max(12, box.height)).integral
                    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let size = OCRRegionRecovery.retrySize(width: Int(padded.width), height: Int(padded.height),
                    glyphHeight: box.height, enabled: true) else { limited = true; continue }
                guard detail.reserveDetection(pixels: size.width * size.height) else { limited = true; break }
                guard let raw = image.cropping(to: padded), let crop = resizeRegion(raw, width: size.width, height: size.height),
                      let found = try detectCharacters(crop, cancellation: cancellation, segmented: detail.denseCoverage) else { limited = true; continue }
                let transform = LocalOCRGeometry.cropTransform(padded, width: image.width, height: image.height)
                if found.limited { limited = true }
                for boxes in found.groups {
                    let mapped = boxes.map { $0.applying(transform) }
                    let region = mapped.reduce(CGRect.null) { $0.union($1) }
                    // Avoid double-counting a line found at both scales.
                    guard !characters.contains(where: { prior in
                        let old = prior.reduce(CGRect.null) { $0.union($1) }
                        let overlap = old.intersection(region)
                        let area = min(old.width * old.height, region.width * region.height)
                        return area > 0 && !overlap.isNull && overlap.width * overlap.height > area * 0.5
                    }) else { continue }
                    characters.append(mapped)
                }
            }
        }
        var result = detail.denseCoverage
            ? try LocalOCRVisualCoverage.segmented(characters: characters, lines: lines) { try cancellation.check() }
            : LocalOCRVisualCoverage.compare(characters: characters, lines: lines)
        if limited && result.status == .checked { result.status = .limited }
        return result
    }

    private static func checkImageCoverage(_ image: CGImage, result: inout LocalOCRPage,
                                           cancellation: OCRCancellation, recovery: RegionRecoveryBudget) throws {
        guard let geometry = result.geometry else { return }
        let clock = LocalStopwatch()
        let before = recovery.milliseconds
        result.geometry?.coverage = try detectCoverage(image, lines: geometry.lines, cancellation: cancellation, detail: recovery)
        try recoverMarkedRegions(image, result: &result, cancellation: cancellation, budget: recovery)
        var metrics = result.info.metrics ?? LocalOCRMetrics()
        metrics.regionRetryMilliseconds = recovery.milliseconds - before
        metrics.coverageMilliseconds = max(0, clock.milliseconds - (recovery.milliseconds - before))
        result.info.metrics = metrics
    }

    private static func checkPDFCoverage(_ page: CGPDFPage, result: inout LocalOCRPage,
                                         cancellation: OCRCancellation, recovery: RegionRecoveryBudget) throws {
        guard var geometry = result.geometry else { return }
        let clock = LocalStopwatch()
        let before = recovery.milliseconds
        var metrics = result.info.metrics ?? LocalOCRMetrics()
        do {
            try cancellation.check()
            let rendered = try renderPDF(page, region: page.getBoxRect(.cropBox), requestedScale: 3)
            let coordinates = pdfCoordinates(page, rendered: rendered)
            geometry.transform(coordinates.inverted())
            geometry.coverage = try detectCoverage(rendered.image, lines: geometry.lines, cancellation: cancellation, detail: recovery)
            var candidate = result
            candidate.geometry = geometry
            let detailRenderer: ((CGRect, Int, Int) throws -> CGImage)? = referenceDetailRenderer(page,
                rendered: rendered, coordinates: coordinates)
            try recoverMarkedRegions(rendered.image, result: &candidate, cancellation: cancellation,
                                     budget: recovery, detailRenderer: detailRenderer)
            candidate.geometry?.transform(coordinates)
            if candidate.text != result.text {
                let originalLength = result.text.utf16.count
                result.geometry?.lines += candidate.geometry?.lines.filter { $0.location >= originalLength } ?? []
                result.geometry?.blocks = nil
                result.text = candidate.text
                result.info.method = candidate.info.method
            }
            result.geometry?.coverage = candidate.geometry?.coverage
            metrics.coverageRenderedPixels = (metrics.coverageRenderedPixels ?? 0) + rendered.image.width * rendered.image.height
        } catch is CancellationError { throw CancellationError() }
        catch { result.geometry?.coverage = .init(status: .unavailable, regions: []) }
        metrics.coverageMilliseconds = (metrics.coverageMilliseconds ?? 0) + max(0, clock.milliseconds - (recovery.milliseconds - before))
        recovery.record(in: &metrics)
        result.info.metrics = metrics
    }

    private static func recoverMarkedRegions(_ image: CGImage, result: inout LocalOCRPage,
                                             cancellation: OCRCancellation, budget: RegionRecoveryBudget,
                                             detailRenderer: ((CGRect, Int, Int) throws -> CGImage)? = nil) throws {
        guard budget.enabled, let geometry = result.geometry, let coverage = geometry.coverage,
              coverage.status == .checked, coverage.regions.contains(where: \.needsReview) else { return }
        let clock = LocalStopwatch()
        defer { budget.milliseconds += clock.milliseconds }
        let original = result
        var added = 0
        var targets = OCRRegionRecovery.windows(coverage.regions, grouped: budget.denseCoverage)
        var cursor = 0
        while cursor < targets.count {
            let target = targets[cursor]; cursor += 1
            try cancellation.check()
            let box = target.bounds
            let glyphHeight = target.glyphHeight * CGFloat(image.height)
            let pixels = CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
            let padded = pixels.insetBy(dx: -max(8, glyphHeight), dy: -max(8, glyphHeight * 0.5)).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let size = OCRRegionRecovery.retrySize(width: Int(padded.width), height: Int(padded.height),
                glyphHeight: glyphHeight, enabled: budget.scaleSmallRegions)
            guard let size else { continue }
            let pixelCount = size.width * size.height
            guard budget.reserve(pixels: pixelCount) else { break }
            let crop: CGImage
            if budget.smallTextDetection, budget.scaleSmallRegions, glyphHeight < 24, let detailRenderer {
                // Re-render vector outlines from the source rather than enlarging
                // their already rasterized, potentially lost strokes.
                crop = try detailRenderer(padded, size.width, size.height)
            } else {
                guard let raw = image.cropping(to: padded),
                      let resized = resizeRegion(raw, width: size.width, height: size.height) else { continue }
                crop = resized
            }
            let transform = LocalOCRGeometry.cropTransform(padded, width: image.width, height: image.height)
            let first: [OCRRegionRecovery.Candidate]
            let second: [OCRRegionRecovery.Candidate]
            do {
                budget.pixels += pixelCount
                first = try regionCandidates(crop, transform: transform, languageCorrection: true, cancellation: cancellation)
                budget.pixels += pixelCount
                second = try regionCandidates(crop, transform: transform, languageCorrection: false, cancellation: cancellation)
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
            guard first.count <= 8, second.count <= 8 else { continue }
            var conflicts: [CGRect] = []
            for candidate in first {
                let confirmations = second.filter { OCRRegionRecovery.sameObservation(candidate, $0) }
                guard confirmations.count == 1, let confirmation = confirmations.first else { continue }
                switch OCRRegionRecovery.decide(candidate, confirmedBy: confirmation, region: box,
                    existingText: result.text, existingLines: result.geometry?.lines ?? []) {
                case .unconfirmed, .overlap: continue
                case .conflict: budget.conflicts += 1; conflicts.append(candidate.bounds)
                case .append:
                    let offset = result.text.utf16.count + (result.text.isEmpty ? 0 : 1)
                    result.text += (result.text.isEmpty ? "" : "\n") + candidate.text
                    result.geometry?.lines.append(.init(location: offset, length: candidate.text.utf16.count,
                        bounds: candidate.bounds, confidence: Double(min(candidate.confidence, confirmation.confidence)), method: .vision))
                    result.geometry?.blocks = nil
                    added += 1
                }
            }
            // If a grouped context leaves a line unconfirmed, spend the
            // remaining ORIGINAL crop budget on that line, not more crops.
            if budget.denseCoverage, box.height > target.glyphHeight * 1.8 {
                let residual = coverage.regions.filter { region in
                    guard region.needsReview, box.contains(CGPoint(x: region.bounds.midX, y: region.bounds.midY)) else { return false }
                    if conflicts.contains(where: { $0.intersects(region.bounds) }) { return false }
                    return !(result.geometry?.lines ?? []).contains { line in
                        let overlap = line.bounds.intersection(region.bounds)
                        return !overlap.isNull && overlap.width * overlap.height >= region.bounds.width * region.bounds.height * 0.7
                    }
                }.map { (bounds: $0.bounds, glyphHeight: $0.bounds.height) }
                targets.insert(contentsOf: residual, at: cursor)
            }
        }
        guard added > 0 else { return }
        let verified = try detectCoverage(image, lines: result.geometry?.lines ?? [], cancellation: cancellation, detail: budget)
        let originalCharacters = coverage.detectedTotal
        let originalMissing = coverage.missingTotal
        let verifiedCharacters = verified.detectedTotal
        let verifiedMissing = verified.missingTotal
        guard verified.status == .checked, verifiedCharacters >= originalCharacters, verifiedMissing < originalMissing else {
            result = original
            return
        }
        result.geometry?.coverage = verified
        result.info.method = original.info.method == .embeddedText || original.info.method == .embeddedTextAndVision ? .embeddedTextAndVision : .vision
        budget.recoveredLines += added
    }

    private static func referenceDetailRenderer(_ page: CGPDFPage,
        rendered: (image: CGImage, transform: CGAffineTransform), coordinates: CGAffineTransform)
        -> ((CGRect, Int, Int) throws -> CGImage)? {
        // Partial-region rendering uses physical PDF coordinates. Rotated pages
        // retain the bounded image path until an equivalent transform is verified.
        guard page.rotationAngle == 0 else { return nil }
        let cropBox = page.getBoxRect(.cropBox)
        return { pixels, width, height in
            let normalized = CGRect(x: pixels.minX / CGFloat(rendered.image.width),
                y: 1 - pixels.maxY / CGFloat(rendered.image.height),
                width: pixels.width / CGFloat(rendered.image.width), height: pixels.height / CGFloat(rendered.image.height))
                .applying(coordinates)
            let physical = CGRect(x: cropBox.minX + normalized.minX * cropBox.width,
                y: cropBox.minY + normalized.minY * cropBox.height,
                width: normalized.width * cropBox.width, height: normalized.height * cropBox.height)
            let detail = try renderPDF(page, region: physical,
                requestedScale: min(CGFloat(width) / physical.width, CGFloat(height) / physical.height)).image
            guard let exact = resizeRegion(detail, width: width, height: height) else { throw LocalImportError.invalidDocument }
            return exact
        }
    }

    private static func regionCandidates(_ image: CGImage, transform: CGAffineTransform, languageCorrection: Bool,
                                          cancellation: OCRCancellation) throws -> [OCRRegionRecovery.Candidate] {
        try readLines(image, languageCorrection: languageCorrection, cancellation: cancellation).compactMap { observation in
            observation.topCandidates(1).first.map {
                OCRRegionRecovery.Candidate(text: $0.string, bounds: observation.boundingBox.applying(transform), confidence: $0.confidence)
            }
        }
    }

    private static func resizeRegion(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width != image.width || height != image.height else { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// One instance per physical page, shared by its tiles and PDF regions on the native queue.
    private final class RegionRecoveryBudget {
        let fields = NativeOCRFieldRecovery.Budget()
        let enabled: Bool
        let scaleSmallRegions: Bool
        let smallTextDetection: Bool
        let denseCoverage: Bool
        let lineRecovery: Bool
        var detectionRegions = 0
        var detectionPixels = 0
        var attempts = 0
        var pixels = 0
        var milliseconds = 0
        var recoveredLines = 0
        var conflicts = 0
        private var reservedPixels = 0
        init(enabled: Bool, scaleSmallRegions: Bool, smallTextDetection: Bool, denseCoverage: Bool, lineRecovery: Bool) {
            self.enabled = enabled; self.scaleSmallRegions = scaleSmallRegions
            self.smallTextDetection = smallTextDetection
            self.denseCoverage = denseCoverage; self.lineRecovery = lineRecovery
        }
        func reserveDetection(pixels: Int) -> Bool {
            guard detectionRegions < 16, detectionPixels + pixels <= 8_000_000 else { return false }
            detectionRegions += 1; detectionPixels += pixels
            return true
        }
        func reserve(pixels: Int) -> Bool {
            guard attempts < 4, reservedPixels + pixels * 2 <= 8_000_000 else { return false }
            attempts += 1
            reservedPixels += pixels * 2
            return true
        }
        func record(in metrics: inout LocalOCRMetrics) {
            fields.record(in: &metrics)
            if detectionRegions > 0 {
                metrics.smallTextDetectionRegions = detectionRegions
                metrics.smallTextDetectionPixels = detectionPixels
            }
            guard attempts > 0 else { return }
            metrics.regionRetries = attempts
            metrics.recoveredRegionLines = recoveredLines
            metrics.regionRetryPixels = pixels
            metrics.regionRetryMilliseconds = milliseconds
            metrics.regionRecoveryConflicts = conflicts
        }
    }

    private static func pdfCoordinates(_ page: CGPDFPage, rendered: (image: CGImage, transform: CGAffineTransform)) -> CGAffineTransform {
        let crop = page.getBoxRect(.cropBox)
        let pixels = CGAffineTransform(scaleX: CGFloat(rendered.image.width), y: CGFloat(rendered.image.height))
        let normalized = CGAffineTransform(a: 1 / crop.width, b: 0, c: 0, d: 1 / crop.height,
            tx: -crop.minX / crop.width, ty: -crop.minY / crop.height)
        return pixels.concatenating(rendered.transform.inverted()).concatenating(normalized)
    }

    private static func rectifiedLineCrop(_ image: CGImage, observation: VNRecognizedTextObservation,
                                         contextPadding: CGFloat = 0.3) -> OCRDeskewedLineCrop.Crop? {
        if let crop = OCRDeskewedLineCrop.make(image, corners: [observation.topLeft, observation.topRight,
            observation.bottomRight, observation.bottomLeft], contextPadding: contextPadding) { return crop }
        guard let crop = lineCrop(image, bounds: observation.boundingBox, contextPadding: contextPadding) else { return nil }
        return .init(image: crop.image, target: crop.target,
                     transform: LocalOCRGeometry.cropTransform(crop.bounds, width: image.width, height: image.height))
    }

    private static func lineCrop(_ image: CGImage, bounds: CGRect, contextPadding: CGFloat = 0.3) -> (image: CGImage, target: CGRect, bounds: CGRect)? {
        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let line = CGRect(x: bounds.minX * canvas.width, y: (1 - bounds.maxY) * canvas.height,
                          width: bounds.width * canvas.width, height: bounds.height * canvas.height)
        guard !line.isEmpty, canvas.intersects(line) else { return nil }
        let box = line.insetBy(dx: -max(6, line.height), dy: -max(3, line.height * contextPadding)).integral.intersection(canvas)
        guard box.width * box.height <= 1_000_000, let cropped = image.cropping(to: box) else { return nil }
        let target = CGRect(x: (line.minX - box.minX) / box.width, y: (box.maxY - line.maxY) / box.height,
                            width: line.width / box.width, height: line.height / box.height)
        let scale = min(3, 64 / line.height, 2048 / max(box.width, box.height))
        guard box.width * box.height * max(1, scale * scale) <= 1_000_000 else { return nil }
        guard scale > 1.05, let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (cropped, target, box) }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return (context.makeImage() ?? cropped, target, box)
    }

    private struct RetryBudget {
        let enabled: Bool
        var attempted = 0
        var recovered = 0
        var hasLineReview = false
        var lineReview = LocalOCRLineReview()
        var remaining: Int { enabled ? 4 - attempted : 0 }
        func record(in metrics: inout LocalOCRMetrics) {
            if hasLineReview { metrics.lineReview = lineReview }
            guard attempted > 0 else { return }
            metrics.targetedRetries = attempted
            metrics.recoveredLines = recovered
        }
    }

    private static func adaptiveScale(_ page: PDFPage) -> CGFloat {
        let count = min(page.numberOfCharacters, 500)
        let heights = (0..<count).map { page.characterBounds(at: $0).height }.filter { $0 > 2 && $0 < 100 }.sorted()
        // Aim for at least 32 pixels per glyph; scanned pages without embedded geometry retain 3x.
        guard !heights.isEmpty else { return 3 }
        return min(4, max(2, 32 / heights[heights.count / 5]))
    }
    private static func embeddedGeometry(_ page: PDFPage, text: String) -> LocalOCRGeometry {
        let crop = page.bounds(for: .cropBox)
        let transform = CGAffineTransform(a: 1 / crop.width, b: 0, c: 0, d: 1 / crop.height,
                                         tx: -crop.minX / crop.width, ty: -crop.minY / crop.height)
        let selections = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.selectionsByLine() ?? []
        var cursor = text.startIndex
        let lines = selections.compactMap { selection -> LocalOCRLine? in
            guard let value = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  let range = text.range(of: value, range: cursor..<text.endIndex) else { return nil }
            cursor = range.upperBound
            let offset = NSRange(range, in: text)
            return LocalOCRLine(location: offset.location, length: offset.length,
                bounds: selection.bounds(for: page).applying(transform).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)),
                confidence: nil, method: .embeddedText)
        }
        return LocalOCRGeometry(coordinateSpace: .pdfCropBottomLeft, rotationDegrees: (page.rotation % 360 + 360) % 360,
                                configuration: "", lines: lines)
    }

    private static func joinedGeometry(_ pages: [LocalOCRPage]) -> LocalOCRGeometry {
        var geometry = LocalOCRGeometry(coordinateSpace: .uprightImageBottomLeft, rotationDegrees: 0,
                                        configuration: "", lines: [])
        var offset = 0
        for page in pages where !page.text.isEmpty {
            geometry.append(page.geometry, textOffset: offset)
            offset += page.text.utf16.count + 1
        }
        return geometry
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
                                         page number: Int, cancellation: OCRCancellation, targetedRetry: Bool,
                                         correctedScale: CGFloat? = nil, checkCoverage: Bool = true,
                                         recovery: RegionRecoveryBudget) throws -> LocalOCRPage {
        var retries = RetryBudget(enabled: targetedRetry)
        var metrics = LocalOCRMetrics(), texts: [String] = [], confidences: [Double] = []
        var review = false, hasInk = false
        var pieces: [LocalOCRPage] = []
        for region in regions {
            try cancellation.check()
            try autoreleasepool {
                let renderClock = LocalStopwatch()
                var rendered = try renderPDF(page, region: region, requestedScale: scale, correctPDFScale: false)
                let image = rendered.image
                metrics.renderMilliseconds += renderClock.milliseconds; metrics.renderedPixels += image.width * image.height
                let recognitionClock = LocalStopwatch()
                let renderBeforeRetry = metrics.renderMilliseconds
                let replacement: (() throws -> CGImage)? = correctedScale.map { detailScale in
                    {
                        try cancellation.check()
                        let clock = LocalStopwatch()
                        let detail = try renderPDF(page, region: region, requestedScale: detailScale)
                        rendered = detail
                        metrics.renderMilliseconds += clock.milliseconds
                        metrics.renderedPixels += detail.image.width * detail.image.height
                        metrics.pdfScaleRetries = (metrics.pdfScaleRetries ?? 0) + 1
                        return detail.image
                    }
                }
                var result = try recognizeImage(image, page: number, cancellation: cancellation,
                                                retries: &retries, replacement: replacement, checkCoverage: checkCoverage, recovery: recovery)
                result.geometry?.transform(pdfCoordinates(page, rendered: rendered))
                metrics.mergeCoverage(result.info.metrics)
                pieces.append(result)
                metrics.recognitionMilliseconds += max(0, recognitionClock.milliseconds - (metrics.renderMilliseconds - renderBeforeRetry)
                    - (result.info.metrics?.coverageMilliseconds ?? 0) - (result.info.metrics?.regionRetryMilliseconds ?? 0))
                metrics.recognitionRegions += 1
                review = review || result.info.needsReview; hasInk = hasInk || result.info.method != .blank
                if let confidence = result.info.confidence { confidences.append(confidence) }
                // Overlaps may repeat lines. Keep them rather than risk deleting legitimate repeated amounts.
                if !result.text.isEmpty { texts.append(result.text) }
            }
        }
        let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        var result = LocalOCRPage(info: .init(page: number, method: texts.isEmpty ? (hasInk ? .unreadable : .blank) : .vision,
                                              confidence: confidence, needsReview: review), text: texts.joined(separator: "\n"))
        retries.record(in: &metrics)
        recovery.record(in: &metrics)
        result.geometry = joinedGeometry(pieces)
        result.geometry?.coordinateSpace = .pdfCropBottomLeft
        result.geometry?.rotationDegrees = Int((page.rotationAngle % 360 + 360) % 360)
        result.info.metrics = metrics
        return result
    }
    static func render(_ page: CGPDFPage, region: CGRect, requestedScale: CGFloat, correctPDFScale: Bool = true) throws -> CGImage {
        try renderPDF(page, region: region, requestedScale: requestedScale, correctPDFScale: correctPDFScale).image
    }
    private static func renderPDF(_ page: CGPDFPage, region: CGRect, requestedScale: CGFloat,
                                  correctPDFScale: Bool = true) throws -> (image: CGImage, transform: CGAffineTransform) {
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
            if correctPDFScale {
                // getDrawingTransform can center a small page at 1x instead of enlarging it.
                // Apply the bounded point-to-pixel scale explicitly; let CoreGraphics handle
                // only crop origin and rotation in page-sized coordinates.
                context.scaleBy(x: scale, y: scale)
                context.concatenate(page.getDrawingTransform(.cropBox,
                    rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            } else {
                // Established first pass; explicit scaling is reserved for a geometrically justified reread.
                context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
            }
        } else {
            context.scaleBy(x: scale, y: scale)
            if rotated { context.translateBy(x: region.height, y: 0); context.rotate(by: .pi / 2) }
            context.translateBy(x: -region.minX, y: -region.minY)
        }
        let transform = context.ctm
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw LocalImportError.invalidDocument }
        return (image, transform)
    }
    static func isUsableEmbeddedText(_ text: String, legacy: Bool = false) -> Bool {
        guard text.count >= 40, text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 25 else { return false }
        guard !text.contains("\u{FFFD}"), !text.contains("\0") else { return false }
        if legacy { return true }
        // An unmapped glyph in a PDF text layer can look correct on the page while
        // extraction silently corrupts an identifier or word. Re-read the visible page.
        return !text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .privateUse: true
            case .control: !CharacterSet.whitespacesAndNewlines.contains(scalar)
            default: false
            }
        }
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
