import Foundation
import Darwin

public struct LocalOriginalMigrationItem: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case eligible, alreadyReferenced, noSourceMatch, copyMissing, sourceUnavailable, contentMismatch
        case busy, recordChanged, migrated, copyRetained, notRun
    }
    public let documentID: UUID
    public var status: Status
    public var sourcePath: String?
    public var referenced = false
    public var copyRemoved = false
    public var bytesRemoved = 0
}
public struct LocalOriginalMigrationReport: Codable, Sendable {
    public var items: [LocalOriginalMigrationItem]
    public var unavailableFolders: Int
    public var eligibleDocuments: Int { items.filter { $0.status == .eligible }.count }
    public var referencedDocuments: Int { items.filter(\.referenced).count }
    public var copiesRemoved: Int { items.filter(\.copyRemoved).count }
    public var managedBytesRemoved: Int { items.reduce(0) { $0 + $1.bytesRemoved } }
}
public struct LocalOriginalMigrationPlan: Sendable {
    public let report: LocalOriginalMigrationReport
    let expected: [VaultDocument]
    let references: [UUID: LocalOriginalReference]
}

/// Explicit trusted local maintenance, never an MCP tool or automatic cleanup.
public struct LocalOriginalMigrationService: Sendable {
    public let store: LocalDocumentStore
    public init(store: LocalDocumentStore) { self.store = store }
    public func inspect(sourceFolders: [URL], recursive: Bool = true) async throws -> LocalOriginalMigrationPlan {
        let documents = try await store.documents()
        let task = Task.detached { () throws -> LocalOriginalMigrationPlan in
            guard sourceFolders.count <= 32 else { throw LocalWatchError.tooManyFolders }
            let wanted = Set(documents.compactMap { $0.localImport?.contentHash })
            var matches: [String: LocalOriginalReference] = [:]
            var unavailable = 0, scanned = 0
            for input in sourceFolders {
                try Task.checkCancellation()
                do {
                    let folder = try LocalWatchedFolder.authorizing(input, recursive: recursive)
                    let access = try folder.openDirectory(); defer { access.close() }
                    for file in try LocalWatchedFolderMonitor.files(folder, excluding: store.root, directory: access.url) {
                        try Task.checkCancellation(); scanned += 1
                        guard scanned <= 20_000 else { throw LocalWatchError.invalidConfiguration }
                        do {
                            let source = LocalOriginalAccess(url: file); defer { source.close() }
                            let hash = LocalOriginalAccess.hash(try source.readData())
                            guard wanted.contains(hash), matches[hash] == nil else { continue }
                            matches[hash] = try LocalOriginalReference.capture(file, excluding: store.root)
                        } catch is CancellationError { throw CancellationError() }
                        catch { continue }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { unavailable += 1 }
            }
            var references: [UUID: LocalOriginalReference] = [:]
            var items: [LocalOriginalMigrationItem] = []
            for document in documents {
                try Task.checkCancellation()
                guard let metadata = document.localImport else { continue }
                var item = LocalOriginalMigrationItem(documentID: document.id, status: .noSourceMatch)
                do {
                    let managed = try store.managedOriginalURL(metadata)
                    if !FileManager.default.fileExists(atPath: managed.path) {
                        item.status = metadata.originalReference == nil ? .copyMissing : .alreadyReferenced
                    } else if metadata.state == .queued || metadata.state == .recognizing { item.status = .busy }
                    else if let reference = matches[metadata.contentHash] ?? metadata.originalReference ?? metadata.referenceCandidate {
                        let source = try reference.open(excluding: store.root); defer { source.close() }
                        let original = try source.readData()
                        let copy = LocalOriginalAccess(url: managed); defer { copy.close() }
                        let bytes = try copy.readData()
                        if LocalOriginalAccess.hash(original) == metadata.contentHash && bytes == original {
                            item.status = .eligible; item.sourcePath = source.url.path; references[document.id] = reference
                        } else { item.status = .contentMismatch }
                    }
                } catch { item.status = .sourceUnavailable }
                items.append(item)
            }
            return .init(report: .init(items: items, unavailableFolders: unavailable), expected: documents, references: references)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func apply(_ plan: LocalOriginalMigrationPlan) async throws -> LocalOriginalMigrationReport {
        let lease = try await store.acquireWorker(); defer { lease.release() }
        var report = plan.report
        for index in report.items.indices where report.items[index].status == .eligible {
            try Task.checkCancellation()
            let id = report.items[index].documentID
            guard let expected = plan.expected.first(where: { $0.id == id }), let reference = plan.references[id] else { continue }
            do { report.items[index] = try await store.convertOriginal(expected: expected, reference: reference) }
            catch { report.items[index].status = .copyRetained }
        }
        return report
    }
}

extension LocalDocumentStore {
    func convertOriginal(expected: VaultDocument, reference: LocalOriginalReference) async throws -> LocalOriginalMigrationItem {
        try await run { try locked {
            guard !isSQLite else { throw LocalImportError.foreignStore }
            var documents = try read()
            var item = LocalOriginalMigrationItem(documentID: expected.id, status: .recordChanged)
            guard let index = documents.firstIndex(where: { $0.id == expected.id }), documents[index] == expected,
                  let metadata = documents[index].localImport else { return item }
            guard metadata.state != .queued && metadata.state != .recognizing else { item.status = .busy; return item }
            let managed = try managedOriginalURL(metadata)
            let copy = LocalOriginalAccess(url: managed); defer { copy.close() }
            let copyIdentity = try copy.fileIdentity(), bytes = try copy.readData()
            let source = try reference.open(excluding: root); defer { source.close() }
            let original = try source.readData()
            guard original == bytes, LocalOriginalAccess.hash(bytes) == metadata.contentHash else { item.status = .contentMismatch; return item }
            // A persisted bookmark must reopen independently before storage is changed.
            let reopened = try reference.open(excluding: root); defer { reopened.close() }
            guard try reopened.readData() == bytes else { item.status = .contentMismatch; return item }
            try requireReferenceStore()
            documents[index].localImport?.originalReference = reference
            documents[index].localImport?.referenceCandidate = nil
            documents[index].localImport?.originalState = .available
            try save(documents)
            do {
                // Both recoverable snapshots must refer to the verified original before unlink.
                try privateWrite(Data(contentsOf: snapshotURL), to: root.appendingPathComponent("documents.backup.json"))
                for url in [snapshotURL, root.appendingPathComponent("documents.backup.json")] {
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    try handle.synchronize()
                }
                let directory = Darwin.open(root.path, O_RDONLY | O_CLOEXEC)
                guard directory >= 0 else { throw LocalImportError.storageUnavailable }
                defer { Darwin.close(directory) }
                guard fsync(directory) == 0 else { throw LocalImportError.storageUnavailable }
                let persisted = try read()
                guard let current = persisted.first(where: { $0.id == expected.id })?.localImport,
                      current.originalReference == reference else { throw LocalImportError.staleAttempt }
                let final = try checkedOriginal(current); defer { final.close() }
                guard try final.readData() == bytes else { throw LocalOriginalError.changed }
            } catch {
                // A failed final access check retains the managed copy and restores its backing.
                documents[index] = expected
                try save(documents)
                try privateWrite(Data(contentsOf: snapshotURL), to: root.appendingPathComponent("documents.backup.json"))
                throw error
            }
            item.referenced = true; item.sourcePath = source.url.path; item.status = .copyRetained
            // Several legacy records can share one content-addressed copy.
            if documents.contains(where: { $0.localImport?.originalReference == nil && $0.localImport?.contentHash == metadata.contentHash && $0.localImport?.fileExtension == metadata.fileExtension }) { return item }
            try refuseSymlink(managed)
            guard try copy.fileIdentity() == copyIdentity, try copy.readData() == bytes,
                  try source.readData() == bytes else { return item }
            if Darwin.unlink(managed.path) == 0 {
                item.status = .migrated; item.copyRemoved = true; item.bytesRemoved = bytes.count
            }
            return item
        } }
    }
}
