import Foundation
import Testing
@testable import VauldyCore

@Suite("Vauldy MCP Runtime")
struct VaultRuntimeTests {
    @Test("Suche priorisiert belegte Titel- und Seitentreffer")
    func searchFindsRelevantPage() async throws {
        let invoice = VaultDocument(
            title: "Stadtwerke Rechnung",
            sourceName: "rechnung.pdf",
            category: "invoice",
            ocrText: """
            --- Seite 1 ---
            Rechnung der Stadtwerke.

            --- Seite 2 ---
            Der Rechnungsbetrag beträgt 125,00 EUR und ist bis zum 15.10.2026 zu zahlen.
            """,
            summary: "Die Stadtwerke stellen 125,00 EUR in Rechnung.",
            entities: [
                VaultEntity(type: "amount", value: "125,00 EUR", confidence: 0.98, sourceSnippet: "Rechnungsbetrag beträgt 125,00 EUR")
            ]
        )
        let noise = VaultDocument(
            title: "Versicherung",
            sourceName: "vertrag.pdf",
            category: "insurance",
            ocrText: "Allgemeine Vertragsbedingungen",
            summary: "Versicherungsvertrag ohne Rechnungsangaben."
        )
        let runtime = LocalVault(source: MemoryVaultSource(documents: [noise, invoice]))

        let result = try await runtime.search(query: "Wie hoch ist der Rechnungsbetrag?")

        #expect(result.hits.first?.documentId == invoice.id)
        #expect(result.hits.first?.page == 2)
        #expect(result.hits.first?.reference == "[Ref:\(invoice.id.uuidString):S.2]")
    }

    @Test("Nicht fertig analysierte Dokumente bleiben unsichtbar")
    func searchExcludesUnsearchableDocuments() async throws {
        let unfinished = VaultDocument(
            title: "Geheimer Entwurf",
            sourceName: "entwurf.pdf",
            status: "analyzing",
            ocrText: "SeltenesSuchwort"
        )
        let runtime = LocalVault(source: MemoryVaultSource(documents: [unfinished]))

        let result = try await runtime.search(query: "SeltenesSuchwort")

        #expect(result.hits.isEmpty)
    }

    @Test("Private Antwort nennt Betrag und Referenz ohne vollständigen OCR-Text")
    func privateAnswerIsGroundedAndMinimal() async throws {
        let document = VaultDocument(
            title: "Telefonrechnung September",
            sourceName: "telefon.pdf",
            category: "invoice",
            ocrText: """
            --- Seite 3 ---
            Zu zahlen sind 49,99 EUR. Interner Langtext, der nicht vollständig ausgegeben werden soll.
            """,
            summary: "Die Telefonrechnung weist einen offenen Betrag aus.",
            entities: [
                VaultEntity(type: "amount", value: "49,99 EUR", confidence: 0.99, sourceSnippet: "Zu zahlen sind 49,99 EUR")
            ]
        )
        let runtime = LocalVault(source: MemoryVaultSource(documents: [document]))

        let result = try await runtime.answerPrivately(question: "Welchen Betrag muss ich zahlen?")

        #expect(result.answer.contains("49,99 EUR"))
        #expect(result.answer.contains("[Ref:\(document.id.uuidString):S.3]"))
        #expect(result.confidence == 0.99)
        #expect(result.externalProcessing == false)
        #expect(result.processingLocation == "local")
        #expect(result.disclosureLevel == "D1")
    }

    @Test("Status verrät keine Speicherpfade")
    func statusOnlyReturnsAggregateData() async throws {
        let document = VaultDocument(title: "Vertrag", sourceName: "vertrag.pdf", category: "contract")
        let runtime = LocalVault(source: MemoryVaultSource(documents: [document]))

        let status = try await runtime.status()

        #expect(status.available)
        #expect(status.documentCount == 1)
        #expect(status.searchableDocumentCount == 1)
        #expect(status.categories == ["contract": 1])
        #expect(status.accessMode == "read-only")
    }

    @Test("Snapshot-Leser versteht das bestehende Vauldy-Format")
    func fileSourceDecodesPersistedDocumentRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("documents.json")
        let json = """
        [{
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Testrechnung",
          "sourceName": "test.pdf",
          "importedAt": "2026-10-04T08:00:00Z",
          "category": "invoice",
          "status": "indexed",
          "ocrText": "--- Seite 1 ---\\nBetrag 10,00 EUR",
          "ocrConfidence": 0.95,
          "summary": "Testzusammenfassung",
          "categoryConfidence": 0.9,
          "entities": [{
            "id": "22222222-2222-2222-2222-222222222222",
            "type": "amount",
            "value": "10,00 EUR",
            "confidence": 0.99,
            "sourceSnippet": "Betrag 10,00 EUR",
            "evidence": {"page": 1, "startOffset": 0, "endOffset": 16}
          }],
          "deadlines": [],
          "contentFacts": null,
          "originalFileData": "cHJpdmF0ZQ==",
          "analysisEngine": "ruleBased"
        }]
        """
        try Data(json.utf8).write(to: fileURL, options: .atomic)

        let documents = try FileVaultSnapshotSource(fileURL: fileURL).loadDocuments()

        #expect(documents.count == 1)
        #expect(documents[0].entities.first?.value == "10,00 EUR")
        #expect(documents[0].contentFacts.isEmpty)
    }

    @Test("Suchergebnis verwendet ein transportstabiles ISO-8601-Datum")
    func searchResultEncodesImportedAtAsISO8601() async throws {
        let importedAt = try #require(ISO8601DateFormatter().date(from: "2026-10-04T08:00:00Z"))
        let document = VaultDocument(
            title: "Testvertrag",
            sourceName: "vertrag.pdf",
            importedAt: importedAt,
            category: "contract",
            ocrText: "Vertragsnummer V-123"
        )
        let runtime = LocalVault(source: MemoryVaultSource(documents: [document]))

        let result = try await runtime.search(query: "Vertragsnummer")

        #expect(result.hits.first?.importedAt == "2026-10-04T08:00:00Z")
    }
}

private struct MemoryVaultSource: VaultSnapshotSource {
    var documents: [VaultDocument]

    func loadDocuments() throws -> [VaultDocument] {
        documents
    }

    func isAvailable() -> Bool {
        true
    }
}
