import Foundation
import CoreGraphics
import Testing
import VauldyDemoDocuments
@testable import VauldyCore
@testable import VauldyMCPRuntime

@Suite("Local OCR optimizations")
struct LocalOptimizationTests {
    @Test func formTextUsesEmbeddedTextAndRasterFooterRemainsCovered() async throws {
        try await fixture { root in
            let form = root.appendingPathComponent("form.pdf")
            try ExampleDocument.writeFormPDF(to: form)
            let plain = try await NativeLocalDocumentOCR().recognize(file: form, progress: { _ in })
            #expect(plain.pages.first?.info.method == .embeddedText)
            #expect(plain.pages.first?.text.contains("49,99") == true)
            let hybrid = root.appendingPathComponent("hybrid.pdf")
            try ExampleDocument.writeHybridPDF(to: hybrid)
            let result = try await NativeLocalDocumentOCR().recognize(file: hybrid, progress: { _ in })
            #expect(result.pages.first?.info.method == .embeddedTextAndVision)
            #expect(result.pages.first?.text.contains("49,99") == true)
            #expect(result.pages.first?.text.contains("12,34") == true)
            #expect(result.pages.first?.info.metrics?.recognitionRegions == 1)
            #expect((result.pages.first?.info.metrics?.renderedPixels ?? Int.max) < 1_000_000)
        }
    }
    @Test func pageCheckpointReusesOnlyUnchangedSuccessfulPages() async throws {
        try await fixture { root in
            let file = root.appendingPathComponent("mixed.pdf"), cache = root.appendingPathComponent("cache")
            try ExampleDocument.writePDF(to: file, blankLastPage: true)
            let ocr = NativeLocalDocumentOCR(cacheRoot: cache)
            let initial = try await ocr.recognize(file: file, progress: { _ in })
            let identity = try LocalOCRPageCache(root: cache, file: file)
            try FileManager.default.removeItem(at: identity.directory.appendingPathComponent("2.json"))
            let resumed = try await ocr.recognize(file: file, progress: { _ in })
            #expect(resumed.pages.map(\.text) == initial.pages.map(\.text))
            #expect(resumed.pages.map { $0.info.metrics?.cacheHit } == [true, false, true])
            #expect(resumed.pages.map(\.info.confidence) == initial.pages.map(\.info.confidence))
            let changedConfiguration = try LocalOCRPageCache(root: cache, file: file, configuration: "different-revision")
            #expect(changedConfiguration.load(page: 1) == nil)
            try Data("different bytes".utf8).write(to: file)
            let changedBytes = try LocalOCRPageCache(root: cache, file: file)
            #expect(changedBytes.load(page: 1) == nil)
        }
    }
    @Test func weakAndCorruptCacheEntriesCannotBecomeComplete() async throws {
        try await fixture { root in
            let file = root.appendingPathComponent("input.pdf"); try Data("original".utf8).write(to: file)
            let cache = try LocalOCRPageCache(root: root.appendingPathComponent("cache"), file: file)
            try cache.save(.init(info: .init(page: 1, method: .vision, confidence: 0.4, needsReview: true), text: "weak"))
            #expect(cache.load(page: 1) == nil)
            try Data("corrupt".utf8).write(to: cache.directory.appendingPathComponent("1.json"))
            #expect(cache.load(page: 1) == nil)
        }
    }
    @Test func narrowReceiptRegionsCoverEveryPointWithoutUnboundedImages() {
        let box = CGRect(x: 10, y: 20, width: 280, height: 5000)
        let regions = NativeLocalDocumentOCR.pageRegions(box, scale: 3)
        #expect(regions.count > 1)
        #expect(regions.first?.maxY == box.maxY && regions.last?.minY == box.minY)
        for pair in zip(regions, regions.dropFirst()) { #expect(pair.0.minY < pair.1.maxY) }
        #expect(regions.allSatisfy { $0.width == box.width && $0.height * 3 <= 2801 })
    }
    @Test func longReceiptImageRetainsTopMiddleAndBottomOnOnePhysicalPage() async throws {
        try await fixture { root in
            let file = root.appendingPathComponent("receipt.png")
            try ExampleDocument.writeLongReceiptPNG(to: file)
            let result = try await NativeLocalDocumentOCR().recognize(file: file, progress: { _ in })
            let page = try #require(result.pages.first)
            #expect(result.pages.count == 1)
            #expect((page.info.metrics?.recognitionRegions ?? 0) > 1)
            #expect(page.text.contains("49,99") && page.text.contains("27.01.2026") && page.text.contains("8246"))
        }
    }
    @Test func indexRebuildsOnlyChangedDocumentsAndDropsRemovedOnes() async throws {
        let index = LocalVault()
        var one = VaultDocument(title: "Rechnung", sourceName: "one", ocrText: "Fahrradwartung 49,99 EUR")
        let two = VaultDocument(title: "Bericht", sourceName: "two", ocrText: "Servicebericht 8246")
        _ = try await index.search(documents: [one, two], query: "Fahrradwartung")
        #expect(await index.indexBuildCount == 2)
        _ = try await index.search(documents: [one, two], query: "Servicebericht")
        #expect(await index.indexBuildCount == 2)
        one.ocrText = "Bremsen 12,34 EUR"
        #expect(try await index.search(documents: [one], query: "Fahrradwartung").hits.isEmpty)
        #expect(try await index.search(documents: [one], query: "Servicebericht").hits.isEmpty)
        #expect(await index.indexBuildCount == 3)
    }
    @Test func preparedPrivacyIsReusedButInvalidatedByContentAndGrant() async throws {
        try await fixture { root in
            let vault = root.appendingPathComponent("documents.json"), profileFile = root.appendingPathComponent("profile.json")
            var doc = VaultDocument(title: "Beleg", sourceName: "source", ocrText: "--- Seite 1 ---\nFahrradwartung\nName: Erika Musterfrau\nE-Mail: erika@example.com", pageCount: 1)
            func save() throws { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; try e.encode([doc]).write(to: vault, options: .atomic) }
            try save()
            var profile = MCPAccessProfile(vaultPath: vault.path)
            profile.enabled = true; profile.acknowledgedCloudDisclosure = true; profile.allowedDocumentIDs = [doc.id]
            try FileMCPProfileSource(url: profileFile).save(profile)
            let runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: profileFile))
            let first = try #require(try await runtime.search(query: "Fahrradwartung").hits.first)
            let read = try await runtime.read(document: first.document)
            #expect(!String(decoding: try JSONEncoder().encode(read), as: UTF8.self).contains("erika@example.com"))
            _ = try await runtime.search(query: "Fahrradwartung")
            #expect(await runtime.privacyBuildCount == 1)
            doc.ocrText += "\nE-Mail: neu@example.com"; try save()
            let second = try #require(try await runtime.search(query: "Fahrradwartung").hits.first)
            #expect(await runtime.privacyBuildCount == 2)
            #expect(!String(decoding: try JSONEncoder().encode(await runtime.read(document: second.document)), as: UTF8.self).contains("neu@example.com"))
            await #expect(throws: MCPAccessError.stale) { try await runtime.read(document: first.document) }
            profile.enabled = false; profile.revision = UUID(); try FileMCPProfileSource(url: profileFile).save(profile)
            await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.search(query: "Fahrradwartung") }
        }
    }
}
private func fixture(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-optimization-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}
