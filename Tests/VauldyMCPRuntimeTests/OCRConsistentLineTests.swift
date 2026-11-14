import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VauldyCore

@Suite("Consistent uncertain line assessment")
struct OCRConsistentLineTests {
    @Test func failedRetryPathsAlwaysKeepTheSameSourceUncertainty() throws {
        for path in 0..<4 {
            var state = OCRLineReviewState(uncertain: [0], ambiguous: [])
            state.attempted.insert(0)
            if path == 0 { state.unavailable.insert(0) } // no matching line
            if path == 1 { state.unavailable.insert(0) } // native/crop failure
            // path 2: unchanged weak crop; path 3: repair not confirmed
            #expect(state.summary.needsReview)
            #expect(state.summary.reasons == [.unconfirmedLine])
            #expect(state.summary.unconfirmedLines == 1)
        }
        var confirmed = OCRLineReviewState(uncertain: [0], ambiguous: [])
        confirmed.attempted.insert(0); confirmed.confirm(0, repaired: false)
        #expect(!confirmed.summary.needsReview && confirmed.summary.confirmedUnchangedLines == 1)
        let bytes = try JSONEncoder().encode(confirmed.summary)
        #expect(try JSONDecoder().decode(LocalOCRLineReview.self, from: bytes) == confirmed.summary)
    }

    @Test func budgetAndAmbiguousCodesCannotClearUncertainty() {
        var state = OCRLineReviewState(uncertain: Set(0..<7), ambiguous: [0])
        for index in 0..<4 { state.attempted.insert(index); state.confirm(index, repaired: false) }
        #expect(state.summary.unconfirmedLines == 4 && state.summary.budgetLimitedLines == 3)
        #expect(state.summary.ambiguousIdentifiers == 1 && state.summary.needsReview)
        #expect(state.summary.reasons == [.unconfirmedLine, .ambiguousIdentifier, .retryBudgetExhausted])
        var conflict = OCRLineReviewState(uncertain: [0], ambiguous: [])
        conflict.attempted.insert(0); conflict.conflicts.insert(0); conflict.confirm(0, repaired: true)
        #expect(conflict.summary.unconfirmedLines == 1 && conflict.summary.repairedLines == 0)
    }

    @Test func clearSmallIdentifiersDoNotStarveAnUncertainWordLine() {
        let rows = (0..<5).map { index in (index: index, identifier: index < 4, confidence: Float(index < 4 ? 0.99 : 0.4)) }
        let old = rows.sorted { ($0.identifier ? 0 : 1, $0.confidence, $0.index) < ($1.identifier ? 0 : 1, $1.confidence, $1.index) }
        let current = rows.sorted {
            OCRLineRecovery.priority(identifier: $0.identifier, ambiguous: false, confidence: $0.confidence, index: $0.index)
                < OCRLineRecovery.priority(identifier: $1.identifier, ambiguous: false, confidence: $1.confidence, index: $1.index)
        }
        #expect(!old.prefix(4).contains(where: { $0.index == 4 }))
        #expect(current.first?.index == 4)
    }

    @Test func fragmentsNeedOneLineGeometryAndStillCannotChangeNumbers() throws {
        let box = CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.1)
        let a = OCRRegionRecovery.Candidate(text: "Schutz fuer", bounds: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.1), confidence: 0.96)
        let b = OCRRegionRecovery.Candidate(text: "Hausrat", bounds: CGRect(x: 0.42, y: 0.4, width: 0.38, height: 0.1), confidence: 0.98)
        #expect(OCRLineRecovery.select([a,b], target: box, joinFragments: false) == nil)
        let joined = try #require(OCRLineRecovery.select([b,a], target: box))
        #expect(joined.text == "Schutz fuer Hausrat" && joined.confidence == 0.96)
        #expect(OCRLineRecovery.select([a,a,b], target: box) == nil)
        let neighbour = OCRRegionRecovery.Candidate(text: "anderer Absatz", bounds: b.bounds.offsetBy(dx: 0, dy: 0.2), confidence: 1)
        #expect(OCRLineRecovery.select([a,neighbour], target: box) == nil)
        #expect(OCRLineRecovery.decide(original: "Beitrag: 49,99 EUR", confidence: 0.4, alternatives: [],
            retry: "Beitrag: 49,89 EUR", retryConfidence: 1, identifier: false) == .review)
    }

    @Test func localReviewExplainsPendingLinesAndEvidenceFallback() throws {
        var document = VaultDocument(title: "Synthetisch", sourceName: "fixture.png", ocrText: "--- Seite 1 ---\nBisherige Belegzeile", pageCount: 1)
        var metadata = LocalImportMetadata(contentHash: "synthetic", fileExtension: "png")
        metadata.state = .partial
        var info = LocalOCRPageInfo(page: 1, method: .vision, needsReview: true)
        var metrics = LocalOCRMetrics()
        var review = LocalOCRLineReview(); review.unconfirmedLines = 2; review.budgetLimitedLines = 1
        metrics.lineReview = review; metrics.evidencePreservedFallback = true
        info.metrics = metrics; metadata.pages = [info]; document.localImport = metadata
        let page = try #require(LocalDocumentReview(document)?.pages.first)
        #expect(page.reason.contains("2 unsichere Zeilen") && page.reason.contains("Nachlesebudget"))
        #expect(page.reason.contains("bisherige belegte Seite wurde erhalten"))
        let old = #"{"inspectionMilliseconds":1,"renderMilliseconds":2,"recognitionMilliseconds":3,"cacheMilliseconds":0,"cacheHit":false,"renderedPixels":20,"recognitionRegions":1}"#
        #expect(try JSONDecoder().decode(LocalOCRMetrics.self, from: Data(old.utf8)).lineReview == nil)
    }

    @Test func contrastKeepsGreyLevelsAndRefusesFlatOrOversizedPatches() throws {
        func image(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let target = CGRect(x: 0, y: 0, width: 1, height: 1)
        let input = [UInt8](repeating: 220, count: 50) + [UInt8](repeating: 235, count: 50) + [UInt8](repeating: 250, count: 100)
        let source = try image(input, width: 20, height: 10)
        let enhanced = try #require(OCRLineContrast.normalize(source, target: target))
        let bytes = try #require(enhanced.dataProvider?.data) as Data
        #expect(Set(bytes).count >= 3) // antialias levels are not binarized
        #expect(bytes.min()! < input.min()! && bytes.max() == 255)
        #expect((source.dataProvider?.data as Data?) == Data(input))
        let withDarkNeighbour = [UInt8](repeating: 0, count: 200) + [UInt8](repeating: 220, count: 100) + [UInt8](repeating: 250, count: 100)
        #expect(OCRLineContrast.normalize(try image(withDarkNeighbour, width: 20, height: 20),
            target: CGRect(x: 0, y: 0, width: 1, height: 0.5)) != nil)
        #expect(OCRLineContrast.normalize(try image([UInt8](repeating: 250, count: 200), width: 20, height: 10), target: target) == nil)
        #expect(OCRLineContrast.normalize(try image([UInt8](repeating: 250, count: 1_001_000), width: 1001, height: 1000), target: target) == nil)
    }

    @Test func difficultNativeLinesKeepExactValuesAndRepeatReviewReasons() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-line-v14-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let samples: [LineScan] = [
            .init(name: "clean", fields: ["Vertragsnummer: VX-739245", "Beitrag: 82,47 EUR", "Versicherungsart: Hausrat"], size: 22),
            .init(name: "faint-words", fields: ["Schutz fuer Fahrrad und Hausrat", "Beitrag: 49,99 EUR"], size: 16, gray: 0.84, noise: 5),
            .init(name: "invoice", fields: ["Leistung: Wartung der Heizungsanlage", "Rechnungsnummer: RX-739245"], size: 13, gray: 0.78, noise: 13),
            .init(name: "payroll", fields: ["Arbeitgeber: Musterbetrieb", "Abrechnung: November 2026"], size: 15, gray: 0.87, noise: 8),
            .init(name: "date", fields: ["Beginn: 19.08.2027", "Schutz fuer das Wohngebaeude"], size: 14, gray: 0.82, noise: 10),
            .init(name: "ambiguous", fields: ["Policennummer: IO0O-171", "Beitrag: 81,19 EUR"], size: 15, gray: 0.67, noise: 3),
            .init(name: "dense", fields: ["Hinweis: Wartung erforderlich", "Schutz fuer das Wohngebaeude", "Leistung: Inspektion der Anlage", "Abrechnung: November 2026", "Beitrag: 49,99 EUR", "Beginn: 19.08.2027"], size: 13, gray: 0.79, noise: 12, gap: 20)
        ]
        var records: [[String: String]] = []
        for sample in samples {
            let file = root.appendingPathComponent(sample.name + ".png")
            try sample.write(to: file)
            try exportFrozen(file: file, fields: sample.fields)
            let bytes = try Data(contentsOf: file)
            let prior = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, lineRecovery: false).recognize(file: file) { _ in }.pages.first)
            let current = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
            let repeated = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
            let before = Set(sample.fields.filter { prior.text.contains($0) }), after = Set(sample.fields.filter { current.text.contains($0) })
            print("LINE-V14 \(sample.name) exact=\(before.count)/\(after.count)/\(sample.fields.count) review=\(prior.info.needsReview)/\(current.info.needsReview) retry=\(current.info.metrics?.targetedRetries ?? 0) repaired=\(current.info.metrics?.recoveredLines ?? 0) reasons=\(current.info.metrics?.lineReview?.reasons.map(\.rawValue) ?? [])")
            #expect(before.isSubset(of: after), Comment(rawValue: sample.name))
            #expect(current.text == repeated.text && current.info.needsReview == repeated.info.needsReview, Comment(rawValue: sample.name))
            #expect(current.info.metrics?.lineReview == repeated.info.metrics?.lineReview, Comment(rawValue: sample.name))
            #expect((current.info.metrics?.targetedRetries ?? 0) <= 4)
            #expect(try Data(contentsOf: file) == bytes)
            let preserved = EvidencePreservingLocalOCR.preserving(previous: prior, candidate: current)
            let oldLines = prior.text.split(whereSeparator: \.isNewline).map(String.init)
            var iterator = preserved.text.split(whereSeparator: \.isNewline).map(String.init).makeIterator()
            #expect(oldLines.allSatisfy { old in
                while let next = iterator.next() {
                    if next == old { return true }
                    if preserved.geometry?.lines.contains(where: { $0.policyIdentifierRepair == true && $0.priorReadings?.contains(old) == true }) == true,
                       OCRPolicyIdentifierRepair.permits(old, next) { return true }
                }
                return false
            })
            if sample.name == "clean" { #expect(after.count == sample.fields.count && !current.info.needsReview) }
            if sample.name == "ambiguous" { #expect(after.count == sample.fields.count && current.info.needsReview) }
            records.append(["sample":sample.name,"before":String(before.count),"after":String(after.count),"expected":String(sample.fields.count)])
            if let path = ProcessInfo.processInfo.environment["VAULDY_OCR_LINE_FIXTURES"] {
                let out = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try bytes.write(to: out.appendingPathComponent(sample.name + ".png"))
                try JSONEncoder().encode(current).write(to: out.appendingPathComponent(sample.name + ".json"))
                try JSONEncoder().encode(records).write(to: out.appendingPathComponent("native-results.json"))
            }
        }
    }

    @Test func nativeHarderLineGrid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-hard-lines-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for size in [9, 11, 13] {
            for gray in [0.88, 0.93] {
                for noise in [15, 25] {
                    let name = "grid-\(size)-\(Int(gray * 100))-\(noise)"
                    let fields = ["Schutz fuer Fahrrad und Hausrat", "Leistung: Wartung der Heizungsanlage"]
                    let sample = LineScan(name: name, fields: fields, size: CGFloat(size), gray: gray, noise: noise)
                    let file = root.appendingPathComponent(name + ".png"); try sample.write(to: file)
                    try exportFrozen(file: file, fields: fields)
                    let before = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, lineRecovery: false).recognize(file: file) { _ in }.pages.first)
                    let after = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
                    let b = Set(fields.filter { before.text.contains($0) }), a = Set(fields.filter { after.text.contains($0) })
                    print("HARD-LINE \(name) exact=\(b.count)/\(a.count)/2 repaired=\(after.info.metrics?.recoveredLines ?? 0) normalized=\(after.info.metrics?.lineReview?.normalizedCrops ?? 0) review=\(before.info.needsReview)/\(after.info.needsReview)")
                    #expect(b.isSubset(of: a), Comment(rawValue: name))
                }
            }
        }
    }

    @Test func faintWordsWithinOtherwiseDarkLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-mixed-lines-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for gray in [0.78, 0.85, 0.92] {
            for word in ["fuer", "Fahrrad"] {
                let name = "mixed-\(Int(gray * 100))-\(word)"
                let fields = ["Schutz fuer Fahrrad und Hausrat", "Beitrag: 82,47 EUR"]
                let file = root.appendingPathComponent(name + ".png")
                try LineScan(name: name, fields: fields, size: 15, gray: 0.12, noise: 3,
                    faintWord: word, faintGray: gray).write(to: file)
                try exportFrozen(file: file, fields: fields)
                let before = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, lineRecovery: false).recognize(file: file) { _ in }.pages.first)
                let after = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
                let b = Set(fields.filter { before.text.contains($0) }), a = Set(fields.filter { after.text.contains($0) })
                print("MIXED-LINE \(name) exact=\(b.count)/\(a.count)/2 repaired=\(after.info.metrics?.recoveredLines ?? 0) review=\(before.info.needsReview)/\(after.info.needsReview)")
                #expect(b.isSubset(of: a), Comment(rawValue: name))
            }
        }
    }

    @Test func nativeItalicWordLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-italic-lines-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for font in ["Times-Italic", "Courier-Oblique", "Helvetica-Oblique"] {
            for size in [11, 14] {
                let name = "italic-\(font)-\(size)"
                let fields = ["Leistung: Zahnriemenwechsel am Aggregat", "Beitrag: 82,47 EUR"]
                let file = root.appendingPathComponent(name + ".png")
                try LineScan(name: name, fields: fields, size: CGFloat(size), gray: 0.6, noise: 5, fontName: font).write(to: file)
                try exportFrozen(file: file, fields: fields)
                let before = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, lineRecovery: false).recognize(file: file) { _ in }.pages.first)
                let after = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
                let b = Set(fields.filter { before.text.contains($0) }), a = Set(fields.filter { after.text.contains($0) })
                print("ITALIC-LINE \(name) exact=\(b.count)/\(a.count)/2 repaired=\(after.info.metrics?.recoveredLines ?? 0) review=\(before.info.needsReview)/\(after.info.needsReview)")
                #expect(b.isSubset(of: a), Comment(rawValue: name))
            }
        }
    }

    @Test func tiltedNoisyWordLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-tilted-lines-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for size in [9, 12] {
            for angle in [-0.08, 0.08] {
                let name = "tilted-\(size)-\(angle < 0 ? "left" : "right")"
                let fields = ["Geltungsbereich: Fahrradzubehoer und Kleingeraete", "Leistung: Zahnriemenwechsel am Aggregat", "Beitrag: 82,47 EUR"]
                let file = root.appendingPathComponent(name + ".png")
                try LineScan(name: name, fields: fields, size: CGFloat(size), gray: 0.7, noise: 5,
                    fontName: "Helvetica-Oblique", angle: angle).write(to: file)
                try exportFrozen(file: file, fields: fields)
                let before = try #require(try await NativeLocalDocumentOCR(targetedRetry: true, lineRecovery: false).recognize(file: file) { _ in }.pages.first)
                let after = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
                let b = Set(fields.filter { before.text.contains($0) }), a = Set(fields.filter { after.text.contains($0) })
                print("TILTED-LINE \(name) exact=\(b.count)/\(a.count)/3 repaired=\(after.info.metrics?.recoveredLines ?? 0) review=\(before.info.needsReview)/\(after.info.needsReview)")
                #expect(b.isSubset(of: a), Comment(rawValue: name))
            }
        }
    }
    private func exportFrozen(file: URL, fields: [String]) throws {
        guard let path = ProcessInfo.processInfo.environment["VAULDY_OCR_FROZEN_FIXTURES"] else { return }
        let root = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent(file.lastPathComponent)
        let data = try Data(contentsOf: file)
        if FileManager.default.fileExists(atPath: output.path) { #expect(try Data(contentsOf: output) == data) }
        else { try data.write(to: output) }
        let manifest = root.appendingPathComponent("truth.json")
        var truth = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: manifest))) ?? [:]
        if let previous = truth[file.lastPathComponent] { #expect(previous == fields) }
        truth[file.lastPathComponent] = fields
        try JSONEncoder().encode(truth).write(to: manifest)
    }

}

struct LineScan {
    let name: String
    let fields: [String]
    let size: CGFloat
    var gray: CGFloat = 0.05
    var noise: Int = 0
    var gap: CGFloat = 45
    var faintWord: String? = nil
    var faintGray: CGFloat = 0.85
    var fontName = "Helvetica"
    var angle: CGFloat = 0

    func write(to file: URL) throws {
        let width = 840, height = 480
        var pixels = [UInt8](repeating: 255, count: width * height)
        let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 420, y: 240); context.rotate(by: angle); context.translateBy(x: -420, y: -240)
            for (index, line) in (["Synthetische Zeilenpruefung"] + fields).enumerated() {
                if index > 0, let faintWord {
                    var x: CGFloat = 55
                    let parts = line.split(separator: " ")
                    for (position, part) in parts.enumerated() {
                        let value = String(part) + (position < parts.count - 1 ? " " : "")
                        let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
                            .init(kCTForegroundColorAttributeName as String): CGColor(gray: part == faintWord ? faintGray : gray, alpha: 1)]
                        let rendered = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
                        context.textPosition = CGPoint(x: x, y: 410 - CGFloat(index) * gap); CTLineDraw(rendered, context)
                        x += CTLineGetTypographicBounds(rendered, nil, nil, nil)
                    }
                    continue
                }
                let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): CTFontCreateWithName((index == 0 ? "Helvetica" : fontName) as CFString, index == 0 ? 25 : size, nil),
                    .init(kCTForegroundColorAttributeName as String): CGColor(gray: index == 0 ? 0.05 : gray, alpha: 1)]
                context.textPosition = CGPoint(x: 55, y: 410 - CGFloat(index) * gap)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
            }
            return try #require(context.makeImage())
        }
        // Seeded pixel noise is independent of OCR output and expected answers.
        var state: UInt64 = 739245
        if noise > 0 {
            for index in pixels.indices {
                state = state &* 6364136223846793005 &+ 1
                let delta = Int((state >> 32) % UInt64(noise * 2 + 1)) - noise
                pixels[index] = UInt8(max(0, min(255, Int(pixels[index]) + delta)))
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let noisy = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        _ = image // retains the drawing context's image until pixel noise is prepared
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, noisy, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
