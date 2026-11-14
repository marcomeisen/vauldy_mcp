import Foundation
import CoreGraphics
import Vision

enum NativeOCRFieldRecovery {
    /// Shared by every tile of one physical page. No unbounded per-cell OCR.
    final class Budget {
        var attempts = 0, pixels = 0, repaired = 0, added = 0, formatted = 0
        func reserve(_ images: [CGImage]) -> Bool {
            let count = images.reduce(0) { $0 + $1.width * $1.height }
            guard attempts < 8, count <= 8_000_000 - pixels else { return false }
            attempts += 1; pixels += count; return true
        }
        func record(in metrics: inout LocalOCRMetrics) {
            guard attempts > 0 || formatted > 0 else { return }
            metrics.fieldRetries = attempts; metrics.fieldRetryPixels = pixels
            metrics.fieldRepairs = repaired; metrics.recoveredTableRows = added
            metrics.numericFormatRepairs = formatted
        }
    }

    static func recover(_ image: CGImage, page: inout LocalOCRPage, budget: Budget,
                        check: () throws -> Void,
                        read: (CGImage) throws -> [VNRecognizedTextObservation]) throws {
        guard page.geometry != nil else { return }
        for index in page.geometry!.lines.indices {
            try check()
            let line = page.geometry!.lines[index], original = value(line, in: page.text)
            guard OCRFieldRefinement.needsVehicleRetry(original) else { continue }
            guard let first = crop(image, bounds: line.bounds, scale: 1, padding: 3),
                  let second = crop(image, bounds: line.bounds, scale: 2, padding: 10),
                  budget.reserve([first, second]) else { page.info.needsReview = true; continue }
            let a = try read(first).compactMap { $0.topCandidates(1).first }
            let b = try read(second).compactMap { $0.topCandidates(1).first }
            if a.count == 1, b.count == 1, a[0].confidence >= 0.95, b[0].confidence >= 0.95,
               a[0].string == original, b[0].string == original { continue }
            page.info.needsReview = true
            guard a.count == 1, b.count == 1, a[0].confidence >= 0.95, b[0].confidence >= 0.95,
                  a[0].string == b[0].string, OCRFieldRefinement.permitsVehicleRepair(original, a[0].string) else { continue }
            if replace(index, with: a[0].string, confidence: min(a[0].confidence, b[0].confidence), page: &page) {
                budget.repaired += 1
            }
        }
        // Tiny decimal punctuation can disappear during deskew/contrast work.
        // Read the original pixels at two scales without either transformation.
        for index in page.geometry!.lines.indices {
            try check()
            let line = page.geometry!.lines[index], original = value(line, in: page.text)
            guard line.method == .vision, line.bounds.height * CGFloat(image.height) <= 24,
                  OCRDecimalSourceRepair.eligible(original),
                  let first = crop(image, bounds: line.bounds, scale: 3, padding: 10),
                  let second = crop(image, bounds: line.bounds, scale: 5, padding: 12),
                  budget.reserve([first, second]) else { continue }
            let a = try read(first).compactMap { $0.topCandidates(1).first }
            let b = try read(second).compactMap { $0.topCandidates(1).first }
            guard a.count == 1, b.count == 1, a[0].confidence >= 0.95, b[0].confidence >= 0.95,
                  a[0].string == b[0].string, OCRDecimalSourceRepair.permits(original, a[0].string) else { continue }
            if replace(index, with: a[0].string, confidence: min(a[0].confidence, b[0].confidence), page: &page) {
                page.geometry?.lines[index].sourceRepair = .decimalSeparator
                budget.repaired += 1
            }
        }
        for index in page.geometry!.lines.indices {
            try check()
            let line = page.geometry!.lines[index], original = value(line, in: page.text)
            guard line.method == .vision,
                  let views = OCRPolicyIdentifierRepair.views(image, bounds: line.bounds, line: original),
                  budget.reserve(views.images),
                  let reading = OCRPolicyIdentifierRepair.reading(original, views: views,
                                                                  observations: try views.images.map(read))
            else { continue }
            if replace(index, with: reading.0, confidence: reading.1, page: &page) {
                page.geometry?.lines[index].policyIdentifierRepair = true
                budget.repaired += 1
            }
        }
        // Presentation only: preserve every digit, separator, sign and the
        // observed currency side. No new character is recognized or inferred.
        for index in page.geometry!.lines.indices {
            try check()
            let line = page.geometry!.lines[index], original = value(line, in: page.text)
            guard let formatted = OCRNumericRefinement.money(original),
                  let confidence = line.confidence, confidence.isFinite,
                  OCRNumericRefinement.isPresentationChange(original, formatted) else { continue }
            if replace(index, with: formatted, confidence: Float(confidence), page: &page) {
                budget.formatted += 1
            }
        }
        for grid in try OCRRuledTable.detect(image, check: check) {
            for row in 1..<(grid.rows.count - 1) {
                try check()
                let boxes = (0..<(grid.columns.count - 1)).map { OCRTableContext.cellBounds(grid, row: row, column: $0, image: image) }
                let known: [[Int]] = boxes.map { box in
                    page.geometry!.lines.indices.filter { index in
                        let line = page.geometry!.lines[index]
                        let intersection = box.intersection(line.bounds)
                        return box.contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY))
                            && !intersection.isNull && intersection.width * intersection.height >= line.bounds.width * line.bounds.height * 0.9
                    }
                }
                let old = known.map { indices in indices.map { value(page.geometry!.lines[$0], in: page.text) }.joined(separator: " ") }
                let units = Set(old.indices.filter { OCRFieldRefinement.needsUnitRetry(old[$0]) || OCRNumericRefinement.needsMetreRetry(old[$0]) })
                let raisedMetres = old.contains(where: OCRNumericRefinement.needsMetreRetry)
                guard old.contains(where: { $0.isEmpty || OCRFieldRefinement.needsUnitRetry($0) || OCRNumericRefinement.needsRetry($0) }),
                      let first = try OCRTableContext.make(image, grid: grid, row: row, scale: raisedMetres ? 3 : 2, unitColumns: units, check: check),
                      let second = try OCRTableContext.make(image, grid: grid, row: row, scale: 3, unitColumns: units, cellGap: raisedMetres ? 10 : nil, check: check) else { continue }
                let targets = first.cells.map(\.column).filter { old[$0].isEmpty || OCRFieldRefinement.needsUnitRetry(old[$0]) || OCRNumericRefinement.needsRetry(old[$0]) }
                guard !targets.isEmpty else { continue }
                page.info.needsReview = true
                guard budget.reserve([first.image, second.image]) else { continue }
                let a = OCRTableContext.readings(try read(first.image), in: first)
                let b = OCRTableContext.readings(try read(second.image), in: second)
                var accepted = [Int: String]()
                for column in targets {
                    guard var x = a[column], var y = b[column], x.confidence >= 0.95, y.confidence >= 0.95 else { continue }
                    if OCRNumericRefinement.needsRetry(old[column]) {
                        x.text = OCRNumericRefinement.money(x.text) ?? x.text
                        y.text = OCRNumericRefinement.money(y.text) ?? y.text
                    }
                    guard x.text == y.text else { continue }
                    if old[column].isEmpty {
                        // Recover genuinely missing numeric cells only. A cell
                        // with existing content is never overwritten by a digit.
                        if x.text.range(of: #"^[0-9]{1,4}$"#, options: .regularExpression) != nil { accepted[column] = x.text }
                    } else if known[column].count == 1 && (OCRFieldRefinement.permitsUnitRepair(old[column], x.text) || OCRNumericRefinement.permits(old[column], x.text)) {
                        let index = known[column][0]
                        if replace(index, with: x.text, confidence: min(x.confidence, y.confidence), page: &page) {
                            budget.repaired += 1
                            if OCRNumericRefinement.needsMetreRetry(old[column]) {
                                page.geometry?.lines[index].bounds = boxes[column]
                            }
                        }
                    }
                }
                guard !accepted.isEmpty else { continue }
                // A contextual row is added only when every other visible cell
                // exactly agrees with existing source text in that same cell.
                let columns = first.cells.map(\.column)
                let stable = columns.filter { !old[$0].isEmpty }
                guard stable.count >= 2, columns.allSatisfy({ column in
                    guard let x = a[column], let y = b[column], x.confidence >= 0.95, y.confidence >= 0.95,
                          x.text == y.text else { return false }
                    return accepted[column] == x.text || x.text == old[column]
                }) else { continue }
                let text = columns.compactMap { a[$0]?.text }.joined(separator: " ")
                let confidence = columns.map { min(a[$0]!.confidence, b[$0]!.confidence) }.min()!
                let offset = page.text.utf16.count + 1
                page.text += "\n" + text
                page.geometry?.lines.append(.init(location: offset, length: text.utf16.count,
                    bounds: OCRTableContext.rowBounds(grid, row: row, image: image), confidence: Double(confidence), method: .vision))
                page.geometry?.blocks = nil; page.info.needsReview = true; budget.added += 1
            }
        }
    }

    private static func value(_ line: LocalOCRLine, in text: String) -> String {
        guard let range = Range(NSRange(location: line.location, length: line.length), in: text) else { return "" }
        return String(text[range])
    }

    private static func replace(_ index: Int, with text: String, confidence: Float, page: inout LocalOCRPage) -> Bool {
        guard let line = page.geometry?.lines[index] else { return false }
        let old = value(line, in: page.text)
        var history = line.priorReadings ?? []
        if !history.contains(old) { history.append(old) }
        guard !old.isEmpty, history.count <= 4, old.utf16.count <= 4096 else { return false }
        let delta = text.utf16.count - line.length
        page.text = (page.text as NSString).replacingCharacters(in: NSRange(location: line.location, length: line.length), with: text)
        for i in page.geometry!.lines.indices where page.geometry!.lines[i].location > line.location {
            page.geometry?.lines[i].location += delta
        }
        page.geometry?.lines[index].length = text.utf16.count
        page.geometry?.lines[index].confidence = Double(confidence)
        page.geometry?.lines[index].priorReadings = history
        page.geometry?.blocks = nil; page.info.needsReview = true; return true
    }

    private static func crop(_ image: CGImage, bounds: CGRect, scale: Int, padding: Int) -> CGImage? {
        let pixels = CGRect(x: bounds.minX * CGFloat(image.width), y: (1 - bounds.maxY) * CGFloat(image.height),
            width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height))
            .insetBy(dx: -CGFloat(padding), dy: -CGFloat(padding)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, let raw = image.cropping(to: pixels) else { return nil }
        let width = raw.width * scale + 64, height = raw.height * scale + 64
        guard width <= 4096, width * height <= 1_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(raw, in: CGRect(x: 32, y: 32, width: width - 64, height: height - 64))
        return context.makeImage()
    }
}
