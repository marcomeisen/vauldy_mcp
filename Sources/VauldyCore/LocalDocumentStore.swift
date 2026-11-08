import Foundation
import VauldyDocumentIntelligence
import CryptoKit
import Darwin

/// Independent store; never opens an app archive for writing. JSON snapshots remain read-only to MCP.
public struct LocalDocumentStore: Sendable {
    public let root: URL
    public var snapshotURL: URL { root.appendingPathComponent(isSQLite ? "sqlite/records.sqlite" : "documents.json") }
    public var storageKind: String { isSQLite ? "sqlite" : "json-snapshot" }
    var isSQLite: Bool {
        (try? JSONDecoder().decode(Marker.self, from: Data(contentsOf: root.appendingPathComponent("store.json"))).version).map { (3...4).contains($0) } == true
    }
    /// A format-4 promotion explicitly retains the logical JSON path in existing grants.
    /// No missing-file heuristic or profile/credential rewrite is involved.
    public static func resolvedSnapshotURL(_ input: URL) -> URL {
        let url = input.standardizedFileURL
        guard url.lastPathComponent == "documents.json",
              let marker = try? JSONDecoder().decode(Marker.self, from: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("store.json"))),
              marker.kind == "vauldy-local-core", marker.version == 4 else { return url }
        return url.deletingLastPathComponent().appendingPathComponent("sqlite/records.sqlite")
    }
    private func database() throws -> SQLiteDocumentStore { try SQLiteDocumentStore(directory: root.appendingPathComponent("sqlite")) }

    /// Explicit new-store creation only. Never converts, adopts or empties an existing directory.
    public static func createSQLite(at root: URL) throws -> LocalDocumentStore {
        guard mkdir(root.path, S_IRWXU) == 0 else { throw LocalImportError.foreignStore }
        let store = LocalDocumentStore(root: root)
        let lease = try LocalWorkerLease(url: root.appendingPathComponent("writer.lock"), wait: true)
        defer { lease.release() }
        _ = try SQLiteDocumentStore(directory: root.appendingPathComponent("sqlite"), create: true)
        var marker = Marker(); marker.version = 3
        try store.privateWrite(JSONEncoder().encode(marker), to: root.appendingPathComponent("store.json"))
        return store
    }

    public func document(id: UUID) async throws -> VaultDocument? {
        try await run { try locked { try read(ids: [id]).first { $0.id == id } } }
    }
    package func rebuildSQLiteProjections() async throws {
        guard isSQLite else { throw LocalImportError.foreignStore }
        try await run {
            try locked {
                guard isSQLite else { throw LocalImportError.foreignStore }
                try database().rebuildProjections()
            }
        }
    }
    public init(root: URL) { self.root = root.standardizedFileURL }

    private struct Marker: Codable { var kind = "vauldy-local-core"; var version = 1 }
    private static let io = DispatchQueue(label: "vauldy.local-store.io", qos: .utility)
    static let maximumOriginalBytes = 50 * 1_024 * 1_024
    static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "tif", "tiff", "heic", "heif"]

    public func documents() async throws -> [VaultDocument] {
        try await run { try locked { try read() } }
    }

    /// Queue setup checks the storage envelope without decoding every SQLite OCR payload.
    /// Each selected record is verified against its digest before use.
    func validateStorage() async throws {
        try await run { try locked {
            if isSQLite { _ = try database().count }
            else { _ = try read() }
        } }
    }

    public func recoverInterrupted() async throws {
        try await run {
            try locked {
                guard let lease = try? LocalWorkerLease(url: root.appendingPathComponent("ocr.lock")) else { return }
                defer { lease.release() }
                var documents = try isSQLite ? database().recognizingDocuments() : read()
                var changed = false
                for index in documents.indices where documents[index].localImport?.state == .recognizing {
                    documents[index].localImport?.state = .interrupted
                    documents[index].localImport?.error = .interrupted
                    documents[index].localImport?.attempt = nil
                    documents[index].status = "interrupted"
                    changed = true
                }
                if changed { try save(documents) }
            }
        }
    }

    public func stage(file: URL, storage: LocalOriginalStorage = .managedCopy, renewOriginalAccess: Bool = false) async throws -> (document: VaultDocument, duplicate: Bool) {
        try await run {
            guard file.isFileURL else { throw LocalImportError.unsupportedFile }
            let ext = file.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { throw LocalImportError.unsupportedFile }
            let reference = storage == .referenced ? try LocalOriginalReference.capture(file, excluding: root) : nil
            let access = try reference?.open(excluding: root) ?? LocalOriginalAccess(url: file)
            defer { access.close() }
            let data = try access.readData(), hash = LocalOriginalAccess.hash(data)
            return try locked {
                var documents = try isSQLite ? database().importCandidates(hash: hash, reference: reference) : read()
                var changed = false
                if let reference {
                    for index in documents.indices {
                        if let prior = documents[index].localImport?.originalReference,
                           prior.lastKnownPath == reference.lastKnownPath || prior.identity == reference.identity,
                           documents[index].localImport?.contentHash != hash {
                            documents[index].localImport?.originalState = .changed
                            changed = true
                        }
                    }
                }
                if let index = documents.firstIndex(where: { $0.localImport?.contentHash == hash }) {
                    if let reference, documents[index].localImport?.originalReference == nil {
                        documents[index].localImport?.referenceCandidate = reference; changed = true
                    } else if let reference, renewOriginalAccess {
                        // Explicit folder re-selection, after matching the complete
                        // content hash. Preserve identity, text and existing grants.
                        documents[index].localImport?.originalReference = reference
                        documents[index].localImport?.originalState = .available; changed = true
                    }
                    if changed { try save(documents) }
                    return (documents[index], true)
                }
                guard (try isSQLite ? database().count : documents.count) < VaultStorageLimits.importedDocuments else { throw LocalStoreCapacityError.documentCount }
                var document = VaultDocument(title: file.deletingPathExtension().lastPathComponent,
                                             sourceName: file.lastPathComponent,
                                             importedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                                             status: "imported")
                var metadata = LocalImportMetadata(contentHash: hash, fileExtension: ext)
                metadata.originalReference = reference; metadata.originalState = .available
                document.localImport = metadata
                documents.append(document)
                // Capacity preflight BEFORE copying an original or changing the store marker.
                // Later OCR can still exceed the byte limit; it is checked again at commit.
                let encoded: Data?
                if isSQLite { try database().validate(document); encoded = nil }
                else { encoded = try encodedSnapshot(documents) }
                if reference == nil {
                    let originals = root.appendingPathComponent("originals", isDirectory: true)
                    try privateDirectory(originals)
                    let original = originals.appendingPathComponent("\(hash).\(ext)")
                    try refuseSymlink(original)
                    if FileManager.default.fileExists(atPath: original.path) {
                        guard try Data(contentsOf: original) == data else { throw LocalImportError.damagedStore }
                    } else { try privateWrite(data, to: original) }
                } else { try requireReferenceStore() }
                try save(documents, encoded: encoded)
                return (document, false)
            }
        }
    }

    func acquireWorker() async throws -> LocalWorkerLease {
        try await run { try locked { try LocalWorkerLease(url: root.appendingPathComponent("ocr.lock")) } }
    }

    func start(_ id: UUID, attempt: UUID, borrowedAccess: Data? = nil, expected: VaultDocument? = nil) async throws -> LocalOriginalAccess {
        try await run { try locked {
            var documents = try read(ids: [id])
            guard let index = documents.firstIndex(where: { $0.id == id }),
                  var metadata = documents[index].localImport else { throw LocalImportError.staleAttempt }
            // A refinement draft may retain old evidence only while that exact
            // document is still current. Check before changing any import state.
            guard expected == nil || documents[index] == expected else { throw LocalImportError.staleAttempt }
            let access: LocalOriginalAccess
            do {
                if let borrowedAccess {
                    let opened = try LocalOriginalAccess.handoff(borrowedAccess, excluding: root, managedOriginal: metadata.originalReference == nil ? managedOriginalURL(metadata) : nil)
                    do {
                        try opened.verify(hash: metadata.contentHash)
                        if let reference = metadata.originalReference { guard try opened.fileIdentity() == reference.identity else { throw LocalOriginalError.changed } }
                        access = opened
                    } catch { opened.close(); throw error }
                } else { access = try checkedOriginal(metadata) }
            }
            catch let error as LocalOriginalError {
                documents[index].localImport?.originalState = error.state
                try save(documents); throw error
            }
            metadata.state = .recognizing; metadata.attempt = attempt; metadata.error = nil; metadata.updatedAt = Date()
            metadata.originalState = .available
            documents[index].localImport = metadata; documents[index].status = "ocrRunning"
            do { try save(documents) } catch { access.close(); throw error }
            return access
        } }
    }

    func finish(_ id: UUID, attempt: UUID, result: LocalOCRResult, metrics: LocalImportMetrics? = nil, analysis: DocumentBaseAnalysis? = nil, access: LocalOriginalAccess? = nil) async throws -> VaultDocument {
        guard !result.pages.isEmpty, result.pages.count <= 200,
              result.pages.map(\.info.page) == Array(1...result.pages.count) else { throw LocalImportError.invalidDocument }
        guard result.pages.reduce(0, { $0 + $1.text.utf8.count }) <= 900_000 else { throw LocalImportError.fileTooLarge }
        let storedPages = result.pages.map { page in
            var page = page
            let text = page.text.replacingOccurrences(of: #"(?m)^---\s*Seite\s*\d+\s*---\s*$"#,
                with: "[Seitenhinweis im Originaltext]", options: .regularExpression)
            if text != page.text { page.geometry = nil }
            page.text = text
            return page
        }
        return try await update(id, attempt: attempt) { document, metadata in
            if let access {
                try access.verify(hash: metadata.contentHash)
                if let reference = metadata.originalReference { guard try access.fileIdentity() == reference.identity else { throw LocalImportError.staleAttempt } }
            } else if metadata.originalReference != nil {
                let access = try checkedOriginal(metadata); access.close()
            }
            metadata.originalState = .available
            metadata.pages = storedPages.map { page in
                var info = page.info
                info.layout = LocalOCRPageLayout(sourceHash: metadata.contentHash, page: page)
                return info
            }
            metadata.pipelineVersion = 2
            metadata.metrics = metrics
            let unreadable = result.pages.contains { $0.info.method == .unreadable || $0.info.needsReview }
            let hasText = result.pages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            metadata.state = hasText ? (unreadable ? .partial : .completed) : .failed
            metadata.error = hasText ? nil : .noReadableText
            document.status = hasText ? (unreadable ? "partiallyAnalyzed" : "ocrComplete") : "failed"
            document.pageCount = result.pages.count
            document.ocrText = storedPages.map { page in
                // Physical page markers are generated by us, never trusted from source text.
                return "--- Seite \(page.info.page) ---\n\(page.text)"
            }.joined(separator: "\n\n")
            let confidences = result.pages.compactMap(\.info.confidence)
            document.ocrConfidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
            document.localImport = metadata
            if let analysis { document.applyBaseAnalysis(analysis) }
        }
    }

    /// Optimistic commit: analysis cannot overwrite a concurrently changed source or manual field.
    public func saveBaseAnalysis(_ analysis: DocumentBaseAnalysis, expected: VaultDocument) async throws -> VaultDocument {
        try await run { try locked {
            var documents = try read(ids: [expected.id])
            guard let index = documents.firstIndex(where: { $0.id == expected.id }), documents[index] == expected else {
                throw LocalImportError.staleAttempt
            }
            documents[index].applyBaseAnalysis(analysis)
            try save(documents)
            return documents[index]
        } }
    }

    func fail(_ id: UUID, attempt: UUID, error: LocalImportError, originalState: LocalOriginalState? = nil) async throws -> VaultDocument {
        try await update(id, attempt: attempt) { document, metadata in
            if let originalState { metadata.originalState = originalState }
            metadata.state = error == .cancelled ? .cancelled : .failed
            metadata.error = error
            document.status = error == .cancelled ? "cancelled" : "failed"
        }
    }

    public func original(for id: UUID) async throws -> URL {
        try await run { try locked {
            guard let metadata = try read(ids: [id]).first(where: { $0.id == id })?.localImport else { throw LocalImportError.unreadableFile }
            guard metadata.originalReference == nil else { throw LocalOriginalError.scopedAccessRequired }
            return try managedOriginalURL(metadata)
        } }
    }

    public func openOriginal(for id: UUID) async throws -> LocalOriginalAccess {
        try await run { try locked {
            var documents = try read(ids: [id])
            guard let index = documents.firstIndex(where: { $0.id == id }), let metadata = documents[index].localImport else { throw LocalImportError.unreadableFile }
            do { return try checkedOriginal(metadata) }
            catch let error as LocalOriginalError {
                documents[index].localImport?.originalState = error.state
                try save(documents); throw error
            }
        } }
    }

    func borrowOriginal(for id: UUID) async throws -> Data {
        let access = try await openOriginal(for: id); defer { access.close() }
        return try access.handoffBookmark()
    }

    /// Explicit local availability check; stored OCR is retained even when a source disappears.
    public func checkOriginals() async throws -> [VaultDocument] {
        try await run { try locked {
            var documents = try read()
            var changed = false
            for index in documents.indices {
                guard let metadata = documents[index].localImport, metadata.originalReference != nil else { continue }
                let state: LocalOriginalState
                do { let access = try checkedOriginal(metadata); access.close(); state = .available }
                catch let error as LocalOriginalError { state = error.state }
                catch { state = .unavailable }
                if state != metadata.originalState { documents[index].localImport?.originalState = state; changed = true }
            }
            if changed { try save(documents) }
            return documents
        } }
    }

    func checkedOriginal(_ metadata: LocalImportMetadata) throws -> LocalOriginalAccess {
        let access: LocalOriginalAccess
        if let reference = metadata.originalReference { access = try reference.open(excluding: root) }
        else { access = LocalOriginalAccess(url: try managedOriginalURL(metadata)) }
        do { try access.verify(hash: metadata.contentHash); return access }
        catch {
            access.close()
            if metadata.originalReference == nil, let sourceError = error as? LocalOriginalError {
                throw sourceError == .changed ? LocalImportError.invalidDocument : LocalImportError.unreadableFile
            }
            if metadata.originalReference != nil, error is LocalImportError { throw LocalOriginalError.changed }
            throw error
        }
    }

    /// Cancelling a queued job must be visible even if it never acquired the native OCR lease.
    func cancelPending(_ id: UUID) async throws {
        try await run { try locked {
            var documents = try read(ids: [id])
            guard let index = documents.firstIndex(where: { $0.id == id }),
                  let state = documents[index].localImport?.state,
                  state == .queued || state == .interrupted else { return }
            documents[index].localImport?.state = .cancelled
            documents[index].localImport?.error = .cancelled
            documents[index].localImport?.updatedAt = Date()
            documents[index].status = "cancelled"
            try save(documents)
        } }
    }

    private func update(_ id: UUID, attempt: UUID,
                        mutation: @escaping @Sendable (inout VaultDocument, inout LocalImportMetadata) throws -> Void) async throws -> VaultDocument {
        try await run { try locked {
            var documents = try read(ids: [id])
            guard let index = documents.firstIndex(where: { $0.id == id }),
                  var metadata = documents[index].localImport, metadata.attempt == attempt else { throw LocalImportError.staleAttempt }
            try mutation(&documents[index], &metadata)
            metadata.attempt = nil; metadata.updatedAt = Date()
            documents[index].localImport = metadata
            try save(documents)
            return documents[index]
        } }
    }

    func managedOriginalURL(_ metadata: LocalImportMetadata) throws -> URL {
        guard metadata.contentHash.count == 64,
              metadata.contentHash.allSatisfy({ "0123456789abcdef".contains($0) }),
              Self.supportedExtensions.contains(metadata.fileExtension) else { throw LocalImportError.damagedStore }
        let directory = root.appendingPathComponent("originals")
        try refuseSymlink(directory)
        let url = directory.appendingPathComponent("\(metadata.contentHash).\(metadata.fileExtension)")
        try refuseSymlink(url)
        return url
    }

    func requireReferenceStore() throws {
        let markerURL = root.appendingPathComponent("store.json")
        var marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        if marker.version < 2 { marker.version = 2; try privateWrite(JSONEncoder().encode(marker), to: markerURL) }
    }

    func locked<T>(_ operation: () throws -> T) throws -> T {
        do {
            guard !FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("INCOMPLETE").path) else { throw LocalImportError.foreignStore }
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("SQLITE_ACTIVATION_PENDING").path) else { throw LocalImportError.storageUnavailable }
            try privateDirectory(root)
            let markerURL = root.appendingPathComponent("store.json")
            if !FileManager.default.fileExists(atPath: markerURL.path) {
                let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
                guard entries.allSatisfy({ $0 == "writer.lock" }) || entries.contains("writer.lock") else {
                    throw LocalImportError.foreignStore
                }
            }
            let lock = try LocalWorkerLease(url: root.appendingPathComponent("writer.lock"), wait: true)
            defer { lock.release() }
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("SQLITE_ACTIVATION_PENDING").path) else { throw LocalImportError.storageUnavailable }
            try refuseSymlink(markerURL)
            if FileManager.default.fileExists(atPath: markerURL.path) {
                guard let marker = try? JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL)),
                      marker.kind == "vauldy-local-core", (1...4).contains(marker.version) else { throw LocalImportError.foreignStore }
                guard FileManager.default.fileExists(atPath: snapshotURL.path) else { throw LocalImportError.damagedStore }
            } else {
                let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
                guard entries.allSatisfy({ $0 == "writer.lock" }) else { throw LocalImportError.foreignStore }
                // Marker last: a partial initialization is recoverable explicitly, never mistaken for an empty archive.
                try privateWrite(Data("[]".utf8), to: snapshotURL)
                try privateWrite(try JSONEncoder().encode(Marker()), to: markerURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            return try operation()
        } catch let error as LocalStoreCapacityError { throw error }
        catch let error as LocalImportError { throw error }
        catch let error as LocalOriginalError { throw error }
        catch { throw LocalImportError.storageUnavailable }
    }

    func read(ids: Set<UUID>? = nil) throws -> [VaultDocument] {
        do {
            try refuseSymlink(snapshotURL)
            let documents = try isSQLite ? database().documents(ids: ids) : FileVaultSnapshotSource(fileURL: snapshotURL).loadDocuments()
            guard documents.allSatisfy({ $0.localImport != nil }) else { throw LocalImportError.damagedStore }
            return documents
        } catch VaultSnapshotError.tooLarge { throw LocalStoreCapacityError.snapshotBytes }
        catch { throw LocalImportError.damagedStore }
    }
    func encodedSnapshot(_ documents: [VaultDocument]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(documents)
        guard data.count <= VaultStorageLimits.snapshotBytes else { throw LocalStoreCapacityError.snapshotBytes }
        return data
    }
    func save(_ documents: [VaultDocument], encoded: Data? = nil) throws {
        if isSQLite { try database().save(documents); return }
        // Never overwrite or rotate away an unreadable current snapshot.
        _ = try read()
        let data = try encoded ?? encodedSnapshot(documents)
        let backup = root.appendingPathComponent("documents.backup.json")
        try refuseSymlink(backup)
        try privateWrite(Data(contentsOf: snapshotURL), to: backup)
        try privateWrite(data, to: snapshotURL)
    }
    func privateWrite(_ data: Data, to url: URL) throws {
        try refuseSymlink(url)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func privateDirectory(_ url: URL) throws {
        try refuseSymlink(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LocalImportError.storageUnavailable }
        // Only the dedicated store directory is touched; no parent permissions are changed.
    }
    func refuseSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LocalImportError.storageUnavailable }
    }
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.io.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// Advisory lock survives across actors/processes and is released by the OS after a crash.
final class LocalWorkerLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    init(url: URL, wait: Bool = false, create: Bool = true) throws {
        let fd = Darwin.open(url.path, (create ? O_CREAT : 0) | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LocalImportError.storageUnavailable }
        guard flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            close(fd); throw LocalImportError.workerBusy
        }
        descriptor = fd
    }
    func release() {
        mutex.lock(); defer { mutex.unlock() }
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}
