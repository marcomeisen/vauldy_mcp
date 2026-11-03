import Foundation
import Testing
import CryptoKit
import VauldyDemoDocuments
@testable import VauldyCore
@testable import VauldyMCPRuntime
@testable import VauldyRelay

private struct InventoryOCR: LocalDocumentOCR {
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        .init(pages: [.init(info: .init(page: 1, method: .embeddedText), text: "Rechnung\nAussteller: Beispiel Service GmbH\nGegenstand: Wartung Fahrrad\nRechnungsdatum: 01.01.2026\nGesamtbetrag: 49,99 EUR")])
    }
}
private final class InventoryCredentialMemory: RelayCredentialPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    var failWrites = false
    init(_ c: RelayCredentials) throws { data = try JSONEncoder().encode(c) }
    func read(allowUserInteraction: Bool) throws -> Data? { lock.lock(); defer { lock.unlock() }; #expect(!allowUserInteraction); return data }
    func write(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; if failWrites { throw RelayFailure.credentials }; self.data = data }
}
private struct InventoryFixture {
    let root: URL, sources: URL
    let installation: MCPInstallation
    var store: LocalDocumentStore { .init(root: installation.root.appendingPathComponent("vault")) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-inventory-" + UUID().uuidString).resolvingSymlinksInPath()
        sources = root.appendingPathComponent("sources")
        installation = .init(root: root.appendingPathComponent("installation"))
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = sources.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    func imported(_ name: String, _ text: String) async throws -> UUID {
        try await LocalImportService(store: store, ocr: InventoryOCR()).importFile(file(name, text), storage: .referenced).documentID
    }
    func profile(_ ids: Set<UUID>, enabled: Bool = true) throws -> MCPAccessProfile {
        let profile = MCPAccessProfile(vaultPath: store.snapshotURL.path, allowedDocumentIDs: ids, enabled: enabled, acknowledgedCloudDisclosure: true)
        try FileMCPProfileSource(url: installation.profileURL(profile.connectionID)).save(profile)
        return profile
    }
    func credentials(_ profile: MCPAccessProfile) throws -> RelayCredentials {
        var c = RelayCredentials(serviceToken: "synthetic-private-service")
        c.paired = true; c.deviceToken = "synthetic-private-device"; c.privateKey = P256.KeyAgreement.PrivateKey().rawRepresentation
        c.profileID = profile.connectionID; c.revision = profile.revision; c.profileFingerprint = try RelayCredentials.fingerprint(profile)
        return c
    }
}

@Suite("Guided inventory reconciliation and renewed grants")
struct InventoryWorkflowTests {
    @Test func previewClassifiesFilesWithoutWritesAndReportsUnavailableFolders() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.imported("same.pdf", "same")
        _ = try await f.imported("changed.pdf", "old")
        let changed = try f.file("changed.pdf", "new")
        _ = try f.file("new.pdf", "added"); _ = try f.file("copy.pdf", "same")
        let service = LocalInventoryReconciler(store: f.store), folder = try service.source(f.sources, recursive: true)
        let missing = f.root.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: missing) }
        let gone = try service.source(missing, recursive: false); try FileManager.default.removeItem(at: missing)
        let before = try Data(contentsOf: f.store.snapshotURL), original = try Data(contentsOf: changed)
        let plan = try await service.inspect([folder, folder, gone])
        #expect(plan.files.count == 3 && plan.duplicates == 1 && plan.issues.count == 1)
        #expect(plan.files.filter { $0.change == .changed }.count == 1)
        #expect(plan.files.filter { $0.change == .added }.count == 1)
        #expect(try Data(contentsOf: f.store.snapshotURL) == before)
        #expect(try Data(contentsOf: changed) == original)
        #expect(!FileManager.default.fileExists(atPath: f.store.root.appendingPathComponent("originals").path))
    }
    @Test func stalePreviewAndChangedSourceDoNotImportUnreviewedBytes() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try f.file("new.pdf", "before")
        let service = LocalInventoryReconciler(store: f.store)
        let plan = try await service.inspect([service.source(f.sources, recursive: true)])
        try Data("after".utf8).write(to: source)
        let worker = LocalImportWorker(store: f.store, executable: URL(fileURLWithPath: "/not-launched"), watchFolders: false)
        let result = try await service.apply(plan, worker: worker)
        #expect(result.imported == 0 && result.issues.count == 1)
        #expect(try await f.store.documents().isEmpty)
        _ = try await f.store.stage(file: f.file("other.pdf", "other"), storage: .referenced)
        await #expect(throws: LocalInventoryError.changed) { try await service.apply(plan, worker: worker) }
    }
    @Test func qualityKeepsSourceCoverageAndAnalysisSeparateAndRetainsMissingRecords() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let good = try await f.imported("good.pdf", "good")
        let missing = try await f.imported("missing.pdf", "missing")
        let changed = try await f.imported("changed.pdf", "old")
        try FileManager.default.removeItem(at: f.sources.appendingPathComponent("missing.pdf"))
        _ = try f.file("changed.pdf", "new")
        let before = try Data(contentsOf: f.store.snapshotURL)
        let report = try await MCPInventoryQualityService(store: f.store).report()
        #expect(report.rows.count == 3 && report.eligibleIDs == [good])
        #expect(report.rows.first { $0.id == missing }?.original == .unavailable)
        #expect(report.rows.first { $0.id == changed }?.original == .changed)
        #expect(report.rows.first { $0.id == changed }?.analysis == "stale")
        #expect(report.rows.first { $0.id == good }?.processing == "source-ready")
        #expect(throws: MCPAccessError.notAuthorized) { try report.validateSelection([missing], acknowledgedReview: true) }
        #expect(try Data(contentsOf: f.store.snapshotURL) == before)
    }
    @Test func reviewDocumentsRequireSeparateAcknowledgment() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.imported("review.pdf", "bytes")
        // Deliberately remove analysis in a synthetic record; OCR coverage remains complete.
        var docs = try await f.store.documents(); docs[0].baseAnalysis = nil
        try f.store.locked { try f.store.save(docs) }
        let report = try await MCPInventoryQualityService(store: f.store).report()
        #expect(report.eligibleIDs == [id] && report.readyIDs.isEmpty)
        #expect(throws: MCPAccessError.notAuthorized) { try report.validateSelection([id], acknowledgedReview: false) }
        try report.validateSelection([id], acknowledgedReview: true)
        try report.validateSelection([], acknowledgedReview: false)
    }
    @Test func reportRejectsSnapshotChangesDuringOriginalVerification() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.imported("one.pdf", "one")
        let url = f.store.snapshotURL
        await #expect(throws: LocalInventoryError.changed) {
            try await MCPInventoryQualityService(store: f.store).report { _, _ in
                let data = try! Data(contentsOf: url); try! (data + Data(" ".utf8)).write(to: url, options: .atomic)
            }
        }
    }
    @Test func renewalPreservesIdentityAndInvalidatesOldHandlesAndCursors() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.imported("first.pdf", "first"), second = try await f.imported("second.pdf", "second")
        let third = try await f.imported("third.pdf", "third")
        let p = try f.profile([first, second]), other = try f.profile([second])
        let otherBytes = try Data(contentsOf: f.installation.profileURL(other.connectionID))
        let original = try f.credentials(p), memory = try InventoryCredentialMemory(original)
        let store = RelayCredentialStore(installation: f.installation, persistence: memory)
        let runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: f.installation.profileURL(p.connectionID)))
        let old = try await runtime.list(pageSize: 1), handle = try #require(old.items.first?.document)
        let digest = try LocalInventoryFingerprint.snapshot(f.store.snapshotURL)
        let updated = try store.updateGrant(profileID: p.connectionID, expectedRevision: p.revision, ids: [first, second, third], digest: digest, expectedDeviceToken: original.deviceToken)
        #expect(updated.deviceToken == original.deviceToken && updated.privateKey == original.privateKey && updated.serviceToken == original.serviceToken && updated.paired)
        #expect(updated.profileID == p.connectionID && updated.revision != original.revision)
        #expect(try updated.validatedProfile(installation: f.installation) == f.installation.profileURL(p.connectionID))
        await #expect(throws: (any Error).self) { try await runtime.read(document: handle) }
        let cursor = try #require(old.nextCursor)
        await #expect(throws: (any Error).self) { try await runtime.list(cursor: cursor) }
        #expect(try await runtime.list().totalCount == 3)
        #expect(try Data(contentsOf: f.installation.profileURL(other.connectionID)) == otherBytes)
        #expect(try LocalInventoryFingerprint.snapshot(f.store.snapshotURL) == digest)
    }
    @Test(arguments: [true, false])
    func pausedAndEmptyGrantsRemainPaused(empty: Bool) async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.imported("one.pdf", "one"), p = try f.profile([id], enabled: empty)
        let c = try f.credentials(p), memory = try InventoryCredentialMemory(c)
        let store = RelayCredentialStore(installation: f.installation, persistence: memory)
        _ = try store.updateGrant(profileID: p.connectionID, expectedRevision: p.revision, ids: empty ? [] : [id], digest: LocalInventoryFingerprint.snapshot(f.store.snapshotURL), expectedDeviceToken: c.deviceToken)
        let saved = try FileMCPProfileSource(url: f.installation.profileURL(p.connectionID)).load()
        #expect(!saved.enabled && saved.connectionID == p.connectionID)
    }
    @Test func failedCredentialWriteCannotExpandRelayAndCanBeReconfirmed() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try await f.imported("a.pdf", "a"), b = try await f.imported("b.pdf", "b")
        let p = try f.profile([a]), c = try f.credentials(p), memory = try InventoryCredentialMemory(c)
        let store = RelayCredentialStore(installation: f.installation, persistence: memory), digest = try LocalInventoryFingerprint.snapshot(f.store.snapshotURL)
        memory.failWrites = true
        #expect(throws: RelayFailure.credentials) { try store.updateGrant(profileID: p.connectionID, expectedRevision: p.revision, ids: [a, b], digest: digest, expectedDeviceToken: c.deviceToken) }
        #expect(throws: RelayFailure.changedGrant) { try store.load()!.validatedProfile(installation: f.installation) }
        let current = try FileMCPProfileSource(url: f.installation.profileURL(p.connectionID)).load()
        memory.failWrites = false
        let repaired = try store.updateGrant(profileID: p.connectionID, expectedRevision: current.revision, ids: [a, b], digest: digest, expectedDeviceToken: c.deviceToken)
        #expect(try repaired.validatedProfile(installation: f.installation) == f.installation.profileURL(p.connectionID))
        #expect(repaired.deviceToken == c.deviceToken)
    }
    @Test func renewalRejectsStaleRevisionForeignProfileAndChangedSnapshot() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.imported("one.pdf", "one"), p = try f.profile([id]), other = try f.profile([id])
        let c = try f.credentials(p), memory = try InventoryCredentialMemory(c), store = RelayCredentialStore(installation: f.installation, persistence: memory)
        let bytes = try Data(contentsOf: f.installation.profileURL(p.connectionID)), digest = try LocalInventoryFingerprint.snapshot(f.store.snapshotURL)
        #expect(throws: MCPAccessError.stale) { try store.updateGrant(profileID: p.connectionID, expectedRevision: UUID(), ids: [], digest: digest, expectedDeviceToken: c.deviceToken) }
        #expect(throws: RelayFailure.signInRequired) { try store.updateGrant(profileID: other.connectionID, expectedRevision: other.revision, ids: [], digest: digest, expectedDeviceToken: c.deviceToken) }
        #expect(throws: LocalInventoryError.changed) { try store.updateGrant(profileID: p.connectionID, expectedRevision: p.revision, ids: [], digest: "stale", expectedDeviceToken: c.deviceToken) }
        #expect(try Data(contentsOf: f.installation.profileURL(p.connectionID)) == bytes)
    }
    @Test func explicitWorkerImportDoesNotResumeUnselectedWatchedFolders() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let automatic = f.root.appendingPathComponent("automatic")
        try FileManager.default.createDirectory(at: automatic, withIntermediateDirectories: true)
        let wanted = f.sources.appendingPathComponent("wanted.pdf"), unwanted = automatic.appendingPathComponent("unwanted.pdf")
        try SyntheticDocumentWriter.writePDF(pages: ["Rechnung Wartung 49,99 EUR"], to: wanted)
        try SyntheticDocumentWriter.writePDF(pages: ["Arztbrief Untersuchung"], to: unwanted)
        let wantedBytes = try Data(contentsOf: wanted), unwantedBytes = try Data(contentsOf: unwanted)
        _ = try await LocalWatchedFolderStore(store: f.store).add([automatic])
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = LocalImportWorker(store: f.store, executable: project.appendingPathComponent(".build/debug/vauldy-local"), watchFolders: false)
        let service = LocalInventoryReconciler(store: f.store)
        let plan = try await service.inspect([service.source(f.sources, recursive: true)])
        let result = try await service.apply(plan, worker: worker)
        let docs = try await f.store.documents()
        #expect(result.imported == 1)
        #expect(docs.count == 1)
        #expect(result.issues.isEmpty)
        #expect(docs.first?.sourceName == "wanted.pdf")
        #expect(try await worker.watchStatus().isEmpty)
        #expect(try Data(contentsOf: wanted) == wantedBytes && Data(contentsOf: unwanted) == unwantedBytes)
        #expect(!FileManager.default.fileExists(atPath: f.store.root.appendingPathComponent("originals").path))
        try await worker.stop()
        for _ in 0..<50 { if try await !worker.status().running { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(try await !worker.status().running)
    }
    @Test func managerRequiresExplicitDisclosureAndReviewConsent() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.imported("one.pdf", "one"), p = try f.profile([id], enabled: false)
        var docs = try await f.store.documents(); docs[0].baseAnalysis = nil
        try f.store.locked { try f.store.save(docs) }
        let c = try f.credentials(p), memory = try InventoryCredentialMemory(c), store = RelayCredentialStore(installation: f.installation, persistence: memory)
        let digest = try LocalInventoryFingerprint.snapshot(f.store.snapshotURL), before = try Data(contentsOf: f.installation.profileURL(p.connectionID))
        var request = RelayUIRequest(profileID: p.connectionID, revision: p.revision, profileFingerprint: try p.disclosureFingerprint(), documentIDs: [id], snapshotDigest: digest, nativeVerification: try await MCPInventoryQualityService(store: f.store).report().nativeVerification, acknowledgedReview: false)
        let denied = await RelayUIManager.handle(request, store: store) { Issue.record("No interactive authorization"); return .init(state: .init()) }
        #expect(denied.error != nil && !denied.state.keychainNeedsApproval)
        #expect(try Data(contentsOf: f.installation.profileURL(p.connectionID)) == before)
        request.acknowledgedReview = true; request.acknowledgedDisclosure = false
        let undisclosed = await RelayUIManager.handle(request, store: store) { .init(state: .init()) }
        #expect(undisclosed.error != nil)
        request.acknowledgedDisclosure = true
        let verification = request.nativeVerification; request.nativeVerification = nil
        let unverified = await RelayUIManager.handle(request, store: store) { .init(state: .init()) }
        #expect(unverified.error != nil)
        request.nativeVerification = verification
        let updated = await RelayUIManager.handle(request, store: store) { .init(state: .init()) }
        #expect(updated.error == nil && updated.state.paired && !updated.state.running && !updated.state.grantNeedsUpdate)
        #expect(try store.load()?.deviceToken == c.deviceToken)
    }
    @Test func sameRevisionProfileTamperingCannotChangeFrozenConsent() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.imported("one.pdf", "one"), p = try f.profile([id])
        let c = try f.credentials(p), memory = try InventoryCredentialMemory(c), store = RelayCredentialStore(installation: f.installation, persistence: memory)
        var altered = p; altered.connectionName = "Different recipient label"
        try FileMCPProfileSource(url: f.installation.profileURL(p.connectionID)).save(altered)
        #expect(throws: MCPAccessError.stale) {
            try store.updateGrant(profileID: p.connectionID, expectedRevision: p.revision, expectedFingerprint: p.disclosureFingerprint(), ids: [id], digest: LocalInventoryFingerprint.snapshot(f.store.snapshotURL), expectedDeviceToken: c.deviceToken)
        }
        #expect(try store.load()?.profileFingerprint == c.profileFingerprint)
    }
    @Test func renewedFolderAuthorityRetainsIdentityTextAndGrantsAfterFullHashMatch() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.imported("one.pdf", "synthetic bytes"), p = try f.profile([id])
        var docs = try await f.store.documents()
        let old = try #require(docs[0].localImport?.originalReference)
        docs[0].localImport?.originalReference = .init(version: 1, bookmark: Data("invalid synthetic bookmark".utf8), lastKnownPath: old.lastKnownPath, identity: old.identity)
        try f.store.locked { try f.store.save(docs) }
        let beforeText = docs[0].ocrText, profileBytes = try Data(contentsOf: f.installation.profileURL(p.connectionID))
        let service = LocalInventoryReconciler(store: f.store)
        let plan = try await service.inspect([service.source(f.sources, recursive: true)])
        #expect(plan.files.first?.change == .renewAccess)
        let result = try await service.apply(plan, worker: .init(store: f.store, executable: URL(fileURLWithPath: "/not-launched"), watchFolders: false))
        let after = try #require(try await f.store.documents().first)
        #expect(result.imported == 1 && result.issues.isEmpty && after.id == id && after.ocrText == beforeText)
        #expect(try await f.store.verifiedOriginalState(for: after) == .available)
        #expect(try Data(contentsOf: f.installation.profileURL(p.connectionID)) == profileBytes)
        #expect(try Data(contentsOf: f.sources.appendingPathComponent("one.pdf")) == Data("synthetic bytes".utf8))
    }
    @Test func staleNativeAttestationsAndInvalidBorrowedCapabilitiesFailClosed() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.imported("one.pdf", "one")
        let digest = try LocalInventoryFingerprint.snapshot(f.store.snapshotURL)
        await #expect(throws: LocalInventoryError.changed) {
            try await MCPInventoryQualityService(store: f.store).report(using: .init(snapshotDigest: digest, checkedAt: Date().addingTimeInterval(-121), verifiedIDs: [id]))
        }
        let before = try Data(contentsOf: f.store.snapshotURL)
        await #expect(throws: LocalOriginalError.unavailable) {
            try await f.store.start(id, attempt: UUID(), borrowedAccess: Data("invalid borrowed capability".utf8))
        }
        let docs = try await f.store.documents()
        #expect(docs[0].localImport?.originalState == .unavailable)
        #expect(docs[0].ocrText.contains("49,99"))
        #expect(try Data(contentsOf: f.sources.appendingPathComponent("one.pdf")) == Data("one".utf8))
        #expect(try Data(contentsOf: f.store.snapshotURL) != before)
    }
    @Test func borrowedAuthorityCannotBeSubstitutedAcrossDocuments() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.imported("first.pdf", "first"), second = try await f.imported("second.pdf", "second")
        let borrowed = try await f.store.borrowOriginal(for: second)
        await #expect(throws: LocalOriginalError.changed) { try await f.store.start(first, attempt: UUID(), borrowedAccess: borrowed) }
        #expect(try Data(contentsOf: f.sources.appendingPathComponent("first.pdf")) == Data("first".utf8))
        #expect(try Data(contentsOf: f.sources.appendingPathComponent("second.pdf")) == Data("second".utf8))
    }
    @Test func explicitSourceStatePublicationMakesChatCoverageHonestWithoutChangingTextOrGrant() async throws {
        let f = try InventoryFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.imported("one.pdf", "one"), p = try f.profile([id])
        let before = try #require(try await f.store.documents().first), grant = try Data(contentsOf: f.installation.profileURL(p.connectionID))
        try FileManager.default.removeItem(at: f.sources.appendingPathComponent("one.pdf"))
        let report = try await MCPInventoryQualityService(store: f.store).report()
        let digest = try await f.store.recordOriginalVerification([id: .unavailable], expectedDigest: report.snapshotDigest)
        let after = try #require(try await f.store.documents().first)
        #expect(after.id == before.id && after.ocrText == before.ocrText && after.baseAnalysis == before.baseAnalysis)
        #expect(after.localImport?.originalState == .unavailable)
        let runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: f.installation.profileURL(p.connectionID)))
        #expect(try await !runtime.status().coverage.processingComplete)
        #expect(try Data(contentsOf: f.installation.profileURL(p.connectionID)) == grant)
        await #expect(throws: LocalInventoryError.changed) { try await f.store.recordOriginalVerification([id: .available], expectedDigest: report.snapshotDigest) }
        #expect(digest != report.snapshotDigest)
    }
    @Test func olderAgentStatusIsReadableWithoutClaimingUpdateCapability() throws {
        let state = try JSONDecoder().decode(RelayUIState.self, from: Data("{\"provisioned\":true,\"paired\":true,\"running\":false}".utf8))
        #expect(state.provisioned && state.paired && !state.running)
        #expect(!state.supportsGrantUpdate && !state.grantNeedsUpdate && !state.keychainNeedsApproval)
        #expect(RelayUIState().supportsGrantUpdate)
    }
    @Test func fragmentedLargeSelectionsRemainBoundedAndDecodeCompletely() async throws {
        let request = RelayUIRequest(profileID: UUID(), revision: UUID(), profileFingerprint: "synthetic", documentIDs: Set((0..<2000).map { _ in UUID() }), snapshotDigest: "synthetic", nativeVerification: .init(snapshotDigest: "synthetic", checkedAt: Date(), verifiedIDs: []), acknowledgedReview: true)
        let bytes = try JSONEncoder().encode(request), pipe = Pipe()
        #expect(bytes.count > 8_000)
        let writer = Task.detached {
            for start in stride(from: 0, to: bytes.count, by: 1000) { try pipe.fileHandleForWriting.write(contentsOf: bytes[start..<min(bytes.count, start + 1000)]) }
            try pipe.fileHandleForWriting.close()
        }
        let decoded = try RelayUIInput.request(from: pipe.fileHandleForReading)
        try await writer.value
        #expect(decoded.documentIDs == request.documentIDs && decoded.operation == .updateGrant)
        #expect(!decoded.operation.allowsUserInteraction)
    }
}
