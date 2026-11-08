import Foundation
import CoreGraphics
import ImageIO
import Vision
@testable import VauldyCore

/// Rejected candidate, test target only. No customer entry point, cache or persisted schema.
/// This measures whether faint pixel bands yield confirmed NEW text without changing old evidence.
enum FaintRasterOCRExperiment {
    struct Result {
        var page: LocalOCRPage
        var proposals = 0, attempts = 0, pixels = 0, added = 0, unconfirmed = 0
        var diagnostics: [String: Int] {
            ["proposals": proposals, "attempts": attempts, "pixels": pixels, "added": added, "unconfirmed": unconfirmed]
        }
    }
    static func read(file: URL, preserving previous: LocalOCRPage) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LocalImportError.invalidDocument }
        var result = Result(page: previous)
        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let priorAttempts = previous.info.metrics?.regionRetries ?? 0
        let priorPixels = previous.info.metrics?.regionRetryPixels ?? 0
        for proposed in try OCRFaintRasterRegions.proposals(in: image, checkCancellation: { try Task.checkCancellation() }) {
            try Task.checkCancellation()
            let box = proposed.insetBy(dx: -8, dy: -max(4, proposed.height * 0.75)).integral.intersection(canvas)
            let transform = LocalOCRGeometry.cropTransform(box, width: image.width, height: image.height)
            let region = CGRect(x: transform.tx, y: transform.ty, width: transform.a, height: transform.d)
            guard result.page.geometry != nil, !(result.page.geometry?.lines ?? []).contains(where: { line in
                let overlap = line.bounds.intersection(region)
                let minimum = min(line.bounds.width * line.bounds.height, region.width * region.height)
                return minimum > 0 && !overlap.isNull && overlap.width * overlap.height >= minimum * 0.1
            }) else { continue }
            result.proposals += 1
            result.page.info.needsReview = true
            guard let size = OCRFaintRasterRegions.readSize(width: Int(box.width), height: Int(box.height), glyphHeight: proposed.height),
                  let raw = image.cropping(to: box) else { continue }
            guard priorAttempts + result.attempts < 4,
                  priorPixels + result.pixels + size.width * size.height * 2 <= 8_000_000 else {
                result.unconfirmed += 1; break
            }
            result.attempts += 1
            guard let one = try OCRFaintRasterRegions.enhance(raw, confirmation: false, checkCancellation: { try Task.checkCancellation() }),
                  let two = try OCRFaintRasterRegions.enhance(raw, confirmation: true, checkCancellation: { try Task.checkCancellation() }),
                  let firstImage = resize(one, width: size.width, height: size.height),
                  let secondImage = resize(two, width: size.width, height: size.height) else { result.unconfirmed += 1; continue }
            result.pixels += size.width * size.height * 2
            let first = try candidates(firstImage, transform: transform, correction: true)
            let second = try candidates(secondImage, transform: transform, correction: false)
            guard first.count <= 8, second.count <= 8 else { result.unconfirmed += 1; continue }
            let initialAdded = result.added
            for candidate in first {
                let confirmations = second.filter { OCRRegionRecovery.sameObservation(candidate, $0) }
                guard confirmations.count == 1, let confirmation = confirmations.first,
                      OCRRegionRecovery.decide(candidate, confirmedBy: confirmation, region: region,
                        existingText: result.page.text, existingLines: result.page.geometry?.lines ?? []) == .append else { continue }
                let offset = result.page.text.utf16.count + (result.page.text.isEmpty ? 0 : 1)
                result.page.text += (result.page.text.isEmpty ? "" : "\n") + candidate.text
                result.page.geometry?.lines.append(.init(location: offset, length: candidate.text.utf16.count,
                    bounds: candidate.bounds, confidence: Double(min(candidate.confidence, confirmation.confidence)), method: .vision))
                result.page.geometry?.blocks = nil
                result.added += 1
            }
            if result.added == initialAdded { result.unconfirmed += 1 }
        }
        return result
    }
    private static func candidates(_ image: CGImage, transform: CGAffineTransform, correction: Bool) throws -> [OCRRegionRecovery.Candidate] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]; request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = correction
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { .init(text: $0.string, bounds: observation.boundingBox.applying(transform), confidence: $0.confidence) }
        }
    }
    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
