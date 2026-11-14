import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import Testing
@testable import VauldyCore

@Suite("Faint raster recovery on frozen v14 corpus")
struct OCRFaintRasterTests {
    private struct Manifest: Decodable {
        let truth: [String: [String]]
        let sha256: [String: String]
    }
    @Test func fixedCorpusMeasuresCandidateWithoutLosingAnyPriorField() async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: #require(Bundle.module.url(forResource: "faint-line-corpus", withExtension: "json"))))
        #expect(manifest.truth.count == 35 && manifest.truth.values.reduce(0, { $0 + $1.count }) == 79)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-frozen-v15-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var oldTotal = 0, newTotal = 0
        var results: [[String: String]] = []
        for name in manifest.truth.keys.sorted() {
            let fields = try #require(manifest.truth[name]); let sample = try makeSample(name: name, fields: fields)
            let file = root.appendingPathComponent(name); try sample.write(to: file)
            let bytes = try Data(contentsOf: file)
            #expect(LocalOriginalAccess.hash(bytes) == manifest.sha256[name], Comment(rawValue: name + " frozen image"))
            let before = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
            let experiment = try FaintRasterOCRExperiment.read(file: file, preserving: before)
            let after = experiment.page
            let b = Set(fields.filter { before.text.contains($0) }), a = Set(fields.filter { after.text.contains($0) })
            oldTotal += b.count; newTotal += a.count
            let metrics = after.info.metrics
            print("FAINT15 \(name) exact=\(b.count)/\(a.count)/\(fields.count) proposals=\(experiment.proposals) attempts=\(experiment.attempts) added=\(experiment.added)")
            #expect(b.isSubset(of: a), Comment(rawValue: name + " prior exact fields"))
            #expect((metrics?.regionRetries ?? 0) + experiment.attempts <= 4)
            #expect((metrics?.regionRetryPixels ?? 0) + experiment.pixels <= 8_000_000)
            #expect(try Data(contentsOf: file) == bytes)
            let preserved = EvidencePreservingLocalOCR.preserving(previous: before, candidate: after)
            var remaining = preserved.text.split(whereSeparator: \.isNewline).map(String.init).makeIterator()
            #expect(before.text.split(whereSeparator: \.isNewline).allSatisfy { old in
                while let next = remaining.next() { if next == old { return true } }; return false
            })
            results.append(["file":name,"before":String(b.count),"after":String(a.count),"expected":String(fields.count)])
            if let path = ProcessInfo.processInfo.environment["VAULDY_OCR_FAINT_FIXTURES"] {
                let out = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try bytes.write(to: out.appendingPathComponent(name))
                try JSONEncoder().encode(before).write(to: out.appendingPathComponent(name + ".before.json"))
                try JSONEncoder().encode(after).write(to: out.appendingPathComponent(name + ".json"))
                try JSONEncoder().encode(experiment.diagnostics).write(to: out.appendingPathComponent(name + ".diagnostics.json"))
                try JSONEncoder().encode(results).write(to: out.appendingPathComponent("results.json"))
            }
        }
        print("FROZEN79 before=\(oldTotal) after=\(newTotal) expected=79")
        #expect(oldTotal >= 52)
        // This test-only contrast experiment must preserve the current engine.
        // OCRQualityImprovementTests compares production against the frozen v14 readings.
        #expect(newTotal >= oldTotal)
    }

    @Test func noisyBlankControlsDoNotCreateDocumentText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-faint-negative-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for noise in [0, 15, 25] {
            let file = root.appendingPathComponent("negative-\(noise).png")
            try LineScan(name: "negative", fields: [], size: 13, noise: noise).write(to: file)
            let before = try #require(try await NativeLocalDocumentOCR().recognize(file: file) { _ in }.pages.first)
            let experiment = try FaintRasterOCRExperiment.read(file: file, preserving: before)
            let after = experiment.page
            #expect(after.text == before.text)
            #expect(experiment.added == 0)
        }
    }

    @Test func faintProposalsAndEnhancementStayBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-faint-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("probe.png")
        try LineScan(name: "probe", fields: ["Schutz fuer Fahrrad und Hausrat", "Leistung: Wartung der Heizungsanlage"], size: 13, gray: 0.88, noise: 15).write(to: file)
        let bytes = try Data(contentsOf: file)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let proposals = try OCRFaintRasterRegions.proposals(in: image) {}
        #expect(proposals.count <= 64)
        #expect(proposals.contains { $0.intersects(CGRect(x: 50, y: 105, width: 200, height: 14)) })
        #expect(proposals.contains { $0.intersects(CGRect(x: 50, y: 150, width: 240, height: 14)) })
        var enhancedCount = 0
        for proposal in proposals {
            let box = proposal.insetBy(dx: -8, dy: -max(4, proposal.height * 0.75)).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let raw = try #require(image.cropping(to: box))
            for confirmation in [false, true] {
                guard let enhanced = try OCRFaintRasterRegions.enhance(raw, confirmation: confirmation, checkCancellation: {}) else { continue }
                enhancedCount += 1
                #expect(enhanced.width == raw.width && enhanced.height == raw.height)
                let size = try #require(OCRFaintRasterRegions.readSize(width: raw.width, height: raw.height, glyphHeight: proposal.height))
                #expect(size.width * size.height <= 1_000_000 && max(size.width, size.height) <= 4096)
            }
        }
        #expect(enhancedCount >= 4)
        #expect(OCRFaintRasterRegions.readSize(width: 0, height: 3, glyphHeight: 5) == nil)
        #expect(OCRFaintRasterRegions.readSize(width: 4097, height: 1, glyphHeight: 5) == nil)
        #expect(OCRFaintRasterRegions.readSize(width: 1, height: 1, glyphHeight: .nan) == nil)
        #expect(throws: CancellationError.self) { try OCRFaintRasterRegions.enhance(image, confirmation: false) { throw CancellationError() } }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(throws: CancellationError.self) { try OCRFaintRasterRegions.proposals(in: image) { throw CancellationError() } }
    }

    func makeSample(name: String, fields: [String]) throws -> LineScan {
        let stem = String(name.dropLast(4))
        let named: [String: LineScan] = [
            "clean": .init(name: stem, fields: fields, size: 22),
            "faint-words": .init(name: stem, fields: fields, size: 16, gray: 0.84, noise: 5),
            "invoice": .init(name: stem, fields: fields, size: 13, gray: 0.78, noise: 13),
            "payroll": .init(name: stem, fields: fields, size: 15, gray: 0.87, noise: 8),
            "date": .init(name: stem, fields: fields, size: 14, gray: 0.82, noise: 10),
            "ambiguous": .init(name: stem, fields: fields, size: 15, gray: 0.67, noise: 3),
            "dense": .init(name: stem, fields: fields, size: 13, gray: 0.79, noise: 12, gap: 20)
        ]
        if let sample = named[stem] { return sample }
        let parts = stem.split(separator: "-").map(String.init)
        if parts[0] == "grid" {
            return .init(name: stem, fields: fields, size: CGFloat(try #require(Int(parts[1]))),
                gray: CGFloat(try #require(Int(parts[2]))) / 100, noise: try #require(Int(parts[3])))
        }
        if parts[0] == "mixed" {
            return .init(name: stem, fields: fields, size: 15, gray: 0.12, noise: 3,
                faintWord: parts[2], faintGray: CGFloat(try #require(Int(parts[1]))) / 100)
        }
        if parts[0] == "italic" {
            return .init(name: stem, fields: fields, size: CGFloat(try #require(Int(parts.last!))),
                gray: 0.6, noise: 5, fontName: parts[1..<parts.count-1].joined(separator: "-"))
        }
        #expect(parts[0] == "tilted")
        return .init(name: stem, fields: fields, size: CGFloat(try #require(Int(parts[1]))), gray: 0.7,
            noise: 5, fontName: "Helvetica-Oblique", angle: parts[2] == "left" ? -0.08 : 0.08)
    }
}
