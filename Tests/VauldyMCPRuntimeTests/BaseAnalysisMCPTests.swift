import Foundation
import Testing
import VauldyCore
import VauldyDocumentIntelligence
import VauldyDemoDocuments
@testable import VauldyMCPRuntime

@Suite("Base analysis through original import and MCP")
struct BaseAnalysisMCPTests {
    @Test func annotatedPDFOriginalsPersistCorrectRolesAcrossDocumentDomains() async throws {
        let corpus = try OverviewCorpus.load()
        // low_quality is a transcript/quality-state unit fixture, not a fabricated
        // native OCR confidence. Native quality is measured from generated originals.
        for fixture in corpus.cases where fixture.id != "low_quality" {
            try await baseStore { root, store in
                let file = root.appendingPathComponent(fixture.filename)
                try SyntheticDocumentWriter.writePDF(pages: fixture.pages.map(\.text), to: file)
                let original = try Data(contentsOf: file)
                let outcome = try await LocalImportService(store: store).importFile(file)
                let document = try #require(try await LocalDocumentStore(root: store.root).documents().first)
                try diagnostics(document, fixture: fixture.id, mode: "embedded", original: file)
                check(try #require(document.currentBaseAnalysis), against: fixture)
                #expect(try Data(contentsOf: await store.original(for: outcome.documentID)) == original)
                #expect(try Data(contentsOf: file) == original)
            }
        }
    }

    @Test func rasterOriginalsUseNativeOCRBeforeTheSameAnalysisPipeline() async throws {
        let ids: Set<String> = ["invoice", "bank", "authority", "medical", "housing", "school", "vehicle", "insurance"]
        var measurements: [(OverviewCorpus.Case, VauldyDocumentIntelligence.DocumentBaseAnalysis)] = []
        for fixture in try OverviewCorpus.load().cases where ids.contains(fixture.id) {
            try await baseStore { root, store in
                let file = root.appendingPathComponent(fixture.filename)
                try SyntheticDocumentWriter.writePDF(pages: fixture.pages.map(\.text), rasterPages: [1], to: file)
                let original = try Data(contentsOf: file)
                let outcome = try await LocalImportService(store: store).importFile(file)
                let document = try #require(try await store.documents().first)
                try diagnostics(document, fixture: fixture.id, mode: "raster", original: file)
                #expect(outcome.state == .completed)
                #expect(document.localImport?.pages.first?.method == .vision)
                #expect(document.localImport?.pages.first?.metrics?.pdfScaleRetries == nil)
                let analysis = try #require(document.currentBaseAnalysis)
                measurements.append((fixture, analysis))
                let card = try #require(analysis.documents.first)
                // Every golden field and critical fact is a blocking regression gate.
                check(analysis, against: fixture)
                for field in card.fields {
                    #expect(document.ocrText.contains(field.quote))
                    #expect(field.page == 1)
                }
                #expect(card.issuer == nil || card.issuer?.value == fixture.expected.issuer)
                #expect(card.issueDate == nil || card.issueDate?.value == fixture.expected.issueDate)
                let reloaded = try #require(try await LocalDocumentStore(root: store.root).documents().first)
                check(try #require(reloaded.currentBaseAnalysis), against: fixture)
                #expect(try Data(contentsOf: file) == original)
                #expect(try Data(contentsOf: await store.original(for: outcome.documentID)) == original)
            }
        }
        if let path = ProcessInfo.processInfo.environment["VAULDY_BASE_ANALYSIS_NATIVE_REPORT"] {
            try writeCorpusReport(measurements, to: URL(fileURLWithPath: path),
                                  scope: "Eight raster-only synthetic PDF originals imported with Apple Vision, persisted and reloaded. Strict golden failures remain visible; not a real-document accuracy claim.")
        }
    }

    @Test func metadataIsProtectedPaginatedAndRevocableWithoutMutatingTheStore() async throws {
        let packet = try #require(try OverviewCorpus.load().cases.first { $0.id == "packet" })
        try await baseStore { root, store in
            let file = root.appendingPathComponent(packet.filename)
            try SyntheticDocumentWriter.writePDF(pages: packet.pages.map(\.text), to: file)
            let outcome = try await LocalImportService(store: store).importFile(file)
            let profileURL = root.appendingPathComponent("profile.json")
            var profile = MCPAccessProfile(vaultPath: store.snapshotURL.path, allowedDocumentIDs: [outcome.documentID],
                                           enabled: false, acknowledgedCloudDisclosure: true)
            let source = FileMCPProfileSource(url: profileURL); try source.save(profile)
            let runtime = ReadOnlyMCPRuntime(profiles: source)
            await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.list() }
            profile.enabled = true; profile.revision = UUID(); try source.save(profile)
            let before = try Data(contentsOf: store.snapshotURL)
            let hit = try #require(try await runtime.list().items.first)
            #expect(hit.analysisStatus == "needsReview")
            let first = try await runtime.readMetadata(document: hit.document)
            #expect(first.logicalDocumentCount == 2 && first.documents.count == 1 && first.hasMore)
            #expect(first.documents[0].pages == [1])
            let next = try #require(first.nextCursor)
            let second = try await runtime.readMetadata(document: hit.document, cursor: next)
            #expect(!second.hasMore && second.documents[0].pages == [2])
            #expect(first.documents[0].overview?.contains("49,99") == true)
            #expect(second.documents[0].overview?.contains("89,90") == true)
            let json = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
            #expect(!json.contains(outcome.documentID.uuidString) && !json.contains(store.root.path))
            #expect(try await runtime.status().analysisCoverage.needsReview == 1)
            #expect(try Data(contentsOf: store.snapshotURL) == before)
            profile.enabled = false; profile.revision = UUID(); try source.save(profile)
            await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.readMetadata(document: hit.document, cursor: next) }
        }
    }

    @Test func metadataSharesContentPrivacyMappingAndCannotExposeRecipientOrIdentifiers() async throws {
        try await baseStore { root, store in
            let file = root.appendingPathComponent("synthetic-private.pdf")
            let text = "Rechnung\nAussteller: Beispielwerkstatt GmbH\nEmpfänger: Erika Musterfrau\nDokumentdatum: 20.10.2026\nBetreff: Wartung des Fahrrads\nWir berechnen Erika Musterfrau die Wartung des Fahrrads mit einem Gesamtbetrag von 49,99 EUR.\n\nE-Mail: erika@example.com\nIBAN: DE89370400440532013000"
            try SyntheticDocumentWriter.writePDF(pages: [text], to: file)
            let imported = try await LocalImportService(store: store).importFile(file)
            let profileURL = root.appendingPathComponent("profile.json")
            let profile = MCPAccessProfile(vaultPath: store.snapshotURL.path, allowedDocumentIDs: [imported.documentID],
                                           enabled: true, acknowledgedCloudDisclosure: true)
            let source = FileMCPProfileSource(url: profileURL); try source.save(profile)
            let runtime = ReadOnlyMCPRuntime(profiles: source)
            let hit = try #require(try await runtime.search(query: "Wartung").hits.first)
            let content = try await runtime.read(document: hit.document)
            let metadata = try await runtime.readMetadata(document: hit.document)
            let recipient = try #require(metadata.documents.first?.fields.first { $0.role == "recipient" })
            #expect(recipient.value != "Erika Musterfrau")
            #expect(content.segments.contains { $0.text.contains(recipient.value) })
            for json in [try JSONEncoder().encode(metadata), try JSONEncoder().encode(content), try JSONEncoder().encode(hit)] {
                let output = String(decoding: json, as: UTF8.self)
                for secret in ["Erika", "Musterfrau", "erika@example.com", "DE89370400440532013000", imported.documentID.uuidString, root.path] {
                    #expect(!output.localizedCaseInsensitiveContains(secret))
                }
            }
            #expect(metadata.documents.first?.overview?.contains("49,99 EUR") == true)
        }
    }

    @Test func warningCodesCannotCarryArbitrarySourceText() {
        #expect(MCPAnalysisWarnings.safe(["ANALYSIS_FAILED", "secret@example.com"]) == ["ANALYSIS_FAILED", "UNRECOGNIZED_ANALYSIS_ISSUE"])
    }
}

private func diagnostics(_ document: VaultDocument, fixture: String, mode: String, original: URL) throws {
    guard let path = ProcessInfo.processInfo.environment["VAULDY_BASE_ANALYSIS_DIAGNOSTICS"] else { return }
    let root = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(contentsOf: original).write(to: root.appendingPathComponent("\(mode)-\(fixture).pdf"))
    try Data(document.ocrText.utf8).write(to: root.appendingPathComponent("\(mode)-\(fixture).txt"))
    try JSONEncoder().encode(document.currentBaseAnalysis).write(to: root.appendingPathComponent("\(mode)-\(fixture).json"))
}
