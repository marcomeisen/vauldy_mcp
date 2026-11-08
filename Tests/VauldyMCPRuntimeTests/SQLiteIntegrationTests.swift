import Foundation
import SQLite3
import Testing
import VauldyDemoDocuments
@testable import VauldyCore
@testable import VauldyMCPRuntime

@Suite("R3b local SQLite integration")
struct SQLiteIntegrationTests {
    @Test func rankProjectionPreservesWeightedScoresOrderAndUncoveredRows() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"))
        let db = try SQLiteDocumentStore(directory: store.snapshotURL.deletingLastPathComponent())
        let date = Date(timeIntervalSince1970: 1_000)
        let docs = [
            VaultDocument(title: "Versicherung", sourceName: "test.pdf", importedAt: date,
                          ocrText: "Versiche-\nrung versicherung versicherung versicherung versicherung versicherung"),
            VaultDocument(title: "Versicherungspolice Versicherung", sourceName: "test.pdf", importedAt: date),
            VaultDocument(title: "Versicherungspolice Versicherung", sourceName: "test.pdf", importedAt: date),
            VaultDocument(title: "Andere", sourceName: "test.pdf", importedAt: date,
                          status: "failed", ocrText: "Versicherung"),
            VaultDocument(title: "Nur im Text", sourceName: "test.pdf", importedAt: date,
                          ocrText: "Versicherung\u{0}Ausweichzeile")
        ]
        try db.save(docs)
        let persisted = try db.documents()
        let ids = persisted.map(\.id)
        for term in ["versicherung", "vers", "fehlenderbegriff"] {
            let projected = try db.rankScores(ids: ids, term: term)
            #expect(projected.uncovered == [docs[4].id])
            if term == "versicherung" {
                #expect(projected.scores.first { $0.id == docs[0].id }?.score == 28)
                #expect(projected.scores.first { $0.id == docs[1].id }?.score == 25)
            }
            let reference = try await LocalVault().search(documents: persisted, query: term, limit: 3)
            let actual = try LocalVault.rankedIDs(term: term, limit: 3, scores: projected.scores) { visit in
                for document in persisted where projected.uncovered.contains(document.id) { try visit(document) }
            }
            #expect(actual.ids == reference.hits.map(\.documentId))
            #expect(actual.count == reference.totalCount)
        }
        #expect(LocalVault.compactRankTerm("Versicherung Vertrag") == nil)
    }

    @Test func vocabularyMatchesScanForASCIIAndOCRAliases() {
        let ascii = (0...127).compactMap(Unicode.Scalar.init).map { "An\($0)fang" }.joined(separator: " ")
        for input in [ascii, "Versiche-\r\n\trung Wort\u{200B}trennung", "Ähnli-\nche Örtlichkeit A\u{0308}nderung"] {
            let vocabulary = VaultSearchVocabulary(input)
            #expect(Set(vocabulary.words) == Set(VaultSearchText.sourceTokens(input)))
            #expect(vocabulary.foldedChunks == Set(VaultSearchText.folded(input).split(whereSeparator: \.isWhitespace).map(String.init)))
            #expect(vocabulary.normalizedChunks == Set(VaultSearchText.normalized(input).split(whereSeparator: \.isWhitespace).map(String.init)))
        }
    }

    @Test func indexedRetrievalKeepsScanSemanticsAndSourceEvidence() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"))
        let db = try SQLiteDocumentStore(directory: store.snapshotURL.deletingLastPathComponent())
        let granted = [
            VaultDocument(title: "Police", sourceName: "test.pdf",
                          ocrText: "--- Seite 1 ---\nVersiche-\nrung und Wort\u{200B}trennung Pruefmarker123", pageCount: 1),
            VaultDocument(title: "Rechnung", sourceName: "test.pdf",
                          ocrText: "--- Seite 1 ---\nVersicherungsbedingungen und Zahlung", pageCount: 1),
            VaultDocument(title: "Vertrag", sourceName: "test.pdf",
                          ocrText: "--- Seite 1 ---\nVertrag zu den örtlichen Bedingungen", pageCount: 1),
            VaultDocument(title: "Unindexierbare Zeile", sourceName: "test.pdf",
                          ocrText: "--- Seite 1 ---\nAusweichmarker\u{0}Test", pageCount: 1)
        ]
        let privateRecord = VaultDocument(title: "Nicht freigegeben", sourceName: "test.pdf",
                                          ocrText: "--- Seite 1 ---\nPrivaterPruefmarker Versicherung", pageCount: 1)
        try db.save(granted + [privateRecord])
        let source = try profile(root, store: store, ids: Set(granted.map(\.id)))
        let persisted = try db.documents()
        let scan = ReadOnlyMCPRuntime(profiles: source, loadVault: { _ in persisted })
        let indexed = ReadOnlyMCPRuntime(profiles: source)
        for query in ["Versicherung Worttrennung", "Versiche", "Worttrennung", "PrivaterPruefmarker", "KeinTreffer"] {
            for mode in [VaultTextMatchMode.allTokens, .anyTermSubstring] {
                let old = try await scan.list(query: query, pageSize: 1, matchMode: mode, includeExcerpts: true)
                let new = try await indexed.list(query: query, pageSize: 1, matchMode: mode, includeExcerpts: true)
                #expect(new.totalCount == old.totalCount)
                #expect(new.items.map(\.excerpt) == old.items.map(\.excerpt))
                if let cursor = new.nextCursor, let oldCursor = old.nextCursor {
                    let more = try await indexed.list(cursor: cursor)
                    let oldMore = try await scan.list(cursor: oldCursor)
                    #expect(more.items.map(\.excerpt) == oldMore.items.map(\.excerpt))
                }
            }
        }
        for query in ["Versicherung", "Pruefmarker123", "örtlichen Bedingungen", "PrivaterPruefmarker", "KeinTreffer"] {
            let old = try await scan.search(query: query)
            let new = try await indexed.search(query: query)
            #expect(new.totalCount == old.totalCount)
            #expect(new.hits.map(\.excerpt) == old.hits.map(\.excerpt))
            #expect(new.hits.map(\.page) == old.hits.map(\.page))
            #expect(new.coverage.authorizedDocumentCount == 4)
        }
        #expect(try await indexed.list(query: "Ausweichmarker", includeExcerpts: false).totalCount == 1)
        let overview = try await indexed.topicOverview(query: nil, topic: "insurance", cursor: nil)
        #expect(overview.candidateCount == 2)
        let selected = try await indexed.list(query: "örtlichen", includeExcerpts: false)
        let handle = try #require(selected.items.first?.document)
        #expect(try await indexed.deadlineOverview(documents: [handle]).rows.count == 1)
        #expect(await indexed.snapshotDecodeCount == 0)

        let prior = try #require(try db.document(id: granted[0].id))
        var changed = prior
        changed.title = "Quittung"
        changed.ocrText = "--- Seite 1 ---\nErsetzterPruefmarker"
        try db.replace(changed, ifCurrent: prior)
        #expect(try await indexed.search(query: "Pruefmarker123").totalCount == 0)
        #expect(try await indexed.search(query: "ErsetzterPruefmarker").totalCount == 1)
        #expect(try await indexed.topicOverview(query: nil, topic: "insurance", cursor: nil).candidateCount == 1)
        #expect(await indexed.snapshotDecodeCount == 0)
    }

    @Test func compactProjectionMatchesLegacyCoverageAndKeepsHandlesBound() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"))
        let db = try SQLiteDocumentStore(directory: store.snapshotURL.deletingLastPathComponent())
        let ready = VaultDocument(title: "Private Titelfolge", sourceName: "private.pdf",
                                  ocrText: "--- Seite 1 ---\nSynthetische Quelle", pageCount: 1)
        var failed = VaultDocument(title: "Fehler", sourceName: "other.pdf")
        failed.status = "failed"
        let source = try profile(root, store: store, ids: [ready.id, failed.id, UUID()])
        try db.save([ready, failed])

        let runtime = ReadOnlyMCPRuntime(profiles: source)
        let status = try await runtime.status()
        let first = try await runtime.list(pageSize: 1, includeExcerpts: false)
        let cursor = try #require(first.nextCursor)
        let next = try await runtime.list(cursor: cursor)
        let items = first.items + next.items
        #expect(Set(items.map(\.processingStatus)) == ["source-ready", "failed"])
        #expect(items.allSatisfy { $0.title == "Freigegebenes Dokument" && $0.excerpt.isEmpty })
        let handle = try #require(items.first { $0.processingStatus == "source-ready" }?.document)
        #expect(try await runtime.read(document: handle).segments.contains { $0.text.contains("Synthetische Quelle") })
        #expect(await runtime.snapshotDecodeCount == 0)
        #expect(status.coverage.missingGrantedDocumentCount == 1)

        // An older writer invalidates the changed projection without needing to know its schema.
        var raw: OpaquePointer?
        try #require(sqlite3_open(store.snapshotURL.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        try #require(sqlite3_exec(raw, "UPDATE records SET payload=payload WHERE id='\(ready.id.uuidString)'", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: MCPAccessError.stale) { try await runtime.list(cursor: cursor) }
        await #expect(throws: MCPAccessError.stale) { try await runtime.read(document: handle) }
        let fallback = try await runtime.status()
        #expect(await runtime.snapshotDecodeCount == 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(fallback) == encoder.encode(status))

        // A schema-2 database from before R3d.1 has no projection table at all.
        try #require(sqlite3_exec(raw, """
            DROP TRIGGER project_record_insert;
            DROP TRIGGER project_record_update;
            DROP TRIGGER project_record_delete;
            DROP TABLE record_projection_v1;
            """, nil, nil, nil) == SQLITE_OK)
        let legacy = ReadOnlyMCPRuntime(profiles: source)
        #expect(try await encoder.encode(legacy.status()) == encoder.encode(status))
        #expect(await legacy.snapshotDecodeCount == 1)

        try await store.rebuildSQLiteProjections()
        let restarted = ReadOnlyMCPRuntime(profiles: source)
        let rebuilt = try await restarted.status()
        #expect(try encoder.encode(rebuilt) == encoder.encode(status))
        #expect(await restarted.snapshotDecodeCount == 0)
        let fresh = try #require(try await restarted.list(includeExcerpts: false).items.first?.document)
        var revoked = try source.load()
        revoked.enabled = false; revoked.revision = UUID()
        try source.save(revoked)
        await #expect(throws: MCPAccessError.notAuthorized) { try await restarted.read(document: fresh) }
    }

    @Test func nativeImportDuplicateRestartAndReadOnlyMCP() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"))
        let pdf = root.appendingPathComponent("synthetic.pdf"); try ExampleDocument.writePDF(to: pdf)
        let original = try Data(contentsOf: pdf)
        let result = try await LocalImportService(store: store).importFile(pdf)
        #expect(result.state == .completed)
        let reopened = LocalDocumentStore(root: store.root)
        let document = try #require(try await reopened.document(id: result.documentID))
        #expect(document.ocrText.contains("49,99 EUR"))
        #expect(document.currentBaseAnalysis != nil)
        let token = try LocalVaultSnapshotSource(fileURL: store.snapshotURL).generation
        let duplicate = try await LocalImportService(store: reopened).importFile(pdf)
        #expect(duplicate.documentID == result.documentID && duplicate.reusedOriginal)
        #expect(try LocalVaultSnapshotSource(fileURL: store.snapshotURL).generation == token)
        let source = try profile(root, store: store, ids: [document.id])
        let runtime = ReadOnlyMCPRuntime(profiles: source)
        let hit = try #require(try await runtime.search(query: "Fahrradwartung").hits.first)
        let read = try await runtime.read(document: hit.document)
        let wire = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        #expect(!wire.contains("Erika Musterfrau") && !wire.contains("erika@example.com"))
        #expect(!wire.contains(store.root.path))
        #expect(try Data(contentsOf: pdf) == original)
        #expect(try Data(contentsOf: await store.original(for: document.id)) == original)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("documents.json").path))
        #expect(throws: LocalImportError.foreignStore) { try LocalDocumentStore.createSQLite(at: store.root) }
    }

    @Test(arguments: [MCPIndexFeatures(), [.memoryTokenIndex], [.persistentTokenIndex]])
    func generationInvalidatesCacheHandlesCursorAndFinalResponse(features: MCPIndexFeatures) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"))
        let db = try SQLiteDocumentStore(directory: store.snapshotURL.deletingLastPathComponent())
        let records = (0..<3).map { VaultDocument(title: "Synthetisch \($0)", sourceName: "test.pdf", ocrText: "--- Seite 1 ---\nVersicherung", pageCount: 1) }
        try db.save(records)
        let source = try profile(root, store: store, ids: Set(records.prefix(2).map(\.id)))
        let runtime = ReadOnlyMCPRuntime(profiles: source, indexFeatures: features)
        let first = try await runtime.list(query: "Versicherung", pageSize: 1, includeExcerpts: false)
        #expect(first.totalCount == 2)
        let handle = try #require(first.items.first?.document), cursor = try #require(first.nextCursor)
        let guardBefore = try MCPResponseAccess(profile: source.load())
        let fingerprint = try LocalInventoryFingerprint.snapshot(store.snapshotURL)
        // Even an ungranted row changes transaction generation, without changing the selected OCR.
        let prior = try #require(try db.document(id: records[2].id))
        var changed = prior; changed.ocrText = "Unfreigegebener neuer Inhalt"
        try db.replace(changed, ifCurrent: prior)
        #expect(try LocalInventoryFingerprint.snapshot(store.snapshotURL) != fingerprint)
        #expect(throws: MCPAccessError.stale) { try guardBefore.verify(using: source) }
        await #expect(throws: MCPAccessError.stale) { try await runtime.list(cursor: cursor) }
        await #expect(throws: MCPAccessError.stale) { try await runtime.read(document: handle) }
        #expect(try await runtime.list(query: "Versicherung", includeExcerpts: false).totalCount == 2)
        #expect(try await runtime.list(query: "Unfreigegebener", includeExcerpts: false).totalCount == 0)
        let selected = try #require(try db.document(id: records[0].id))
        var edited = selected; edited.ocrText = "--- Seite 1 ---\nQuittung"
        try db.replace(edited, ifCurrent: selected)
        #expect(try await runtime.list(query: "Versicherung", includeExcerpts: false).totalCount == 1)
        #expect(try await runtime.list(query: "Quittung", includeExcerpts: false).totalCount == 1)
        var revoked = try source.load(); revoked.allowedDocumentIDs = [records[1].id]; revoked.revision = UUID(); try source.save(revoked)
        #expect(try await runtime.list(includeExcerpts: false).totalCount == 1)
        await #expect(throws: MCPAccessError.stale) { try await runtime.read(document: handle) }
    }

    @Test func workerRecoveryAndStaleOCRCannotOverwriteCommittedState() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"))
        let pdf = root.appendingPathComponent("synthetic.pdf"); try ExampleDocument.writePDF(to: pdf)
        let first = try await store.stage(file: pdf)
        let attempt = UUID(), access = try await store.start(first.document.id, attempt: attempt)
        access.close()
        try await LocalDocumentStore(root: store.root).recoverInterrupted()
        #expect(try await store.document(id: first.document.id)?.localImport?.state == .interrupted)
        let result = try await LocalImportService(store: store).retry(documentID: first.document.id)
        #expect(result.state == .completed)
        await #expect(throws: LocalImportError.staleAttempt) { try await store.fail(first.document.id, attempt: attempt, error: .cancelled) }
        #expect(try await store.document(id: first.document.id)?.localImport?.state == .completed)
    }

    @Test func targetedReadsDoNotDecodeUngrantedPayloadAndRejectSelectedCorruption() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"))
        let db = try SQLiteDocumentStore(directory: store.snapshotURL.deletingLastPathComponent())
        let first = VaultDocument(title: "Freigegeben", sourceName: "test.pdf"), other = VaultDocument(title: "Privat", sourceName: "test.pdf")
        try db.save([first, other])
        var raw: OpaquePointer?; #expect(sqlite3_open(store.snapshotURL.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        #expect(sqlite3_exec(raw, "UPDATE records SET payload=x'00' WHERE id='\(other.id.uuidString)'", nil, nil, nil) == SQLITE_OK)
        let source = LocalVaultSnapshotSource(fileURL: store.snapshotURL)
        #expect(try source.loadSelection(allowedIDs: [first.id]).documents.map(\.id) == [first.id])
        #expect(throws: (any Error).self) { try source.loadSelection(allowedIDs: [other.id]) }
    }

    @Test func walCommitChangesAuthorityEvenWhenMainFileStatDoesNotChange() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalDocumentStore.createSQLite(at: root.appendingPathComponent("vault"))
        let db = try SQLiteDocumentStore(directory: store.snapshotURL.deletingLastPathComponent())
        let value = VaultDocument(title: "Synthetisch", sourceName: "test.pdf")
        try db.save([value])
        var raw: OpaquePointer?; #expect(sqlite3_open(store.snapshotURL.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        // The writer initializes WAL sidecars. A read-only NOFOLLOW connection must not
        // create missing journals; until then it may safely report unavailable.
        #expect(sqlite3_exec(raw, "PRAGMA journal_mode=WAL; UPDATE records SET content_hash=content_hash", nil, nil, nil) == SQLITE_OK)
        let before = try #require(try? MCPFileVersion(store.snapshotURL), "Read generation before WAL mutation")
        #expect(sqlite3_exec(raw, "BEGIN IMMEDIATE; UPDATE records SET content_hash='synthetic-change'", nil, nil, nil) == SQLITE_OK)
        let during = try #require(try? MCPFileVersion(store.snapshotURL), "Read committed generation while WAL writer is uncommitted")
        #expect(during.databaseGeneration == before.databaseGeneration)
        #expect(sqlite3_exec(raw, "COMMIT", nil, nil, nil) == SQLITE_OK)
        let after = try #require(try? MCPFileVersion(store.snapshotURL), "Read generation after WAL commit")
        #expect(after.databaseGeneration != before.databaseGeneration)
        #expect(after.inode == before.inode && after.size == before.size)
        #expect(after.modifiedSeconds == before.modifiedSeconds && after.modifiedNanoseconds == before.modifiedNanoseconds)
        // Read-only administration never persists derived state or rewrites the database.
        let bytes = try Data(contentsOf: store.snapshotURL)
        _ = try LocalVaultSnapshotSource(fileURL: store.snapshotURL).loadDocuments()
        #expect(try Data(contentsOf: store.snapshotURL) == bytes)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-r3b-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return root
    }
    private func profile(_ root: URL, store: LocalDocumentStore, ids: Set<UUID>) throws -> FileMCPProfileSource {
        var value = MCPAccessProfile(vaultPath: store.snapshotURL.path)
        value.enabled = true; value.acknowledgedCloudDisclosure = true; value.allowedDocumentIDs = ids
        let source = FileMCPProfileSource(url: root.appendingPathComponent("profile.json")); try source.save(value); return source
    }
}
