import Foundation
import CryptoKit

public enum LocalInventoryError: LocalizedError {
    case changed, wrongStore, noSources
    public var errorDescription: String? {
        switch self {
        case .changed: "Bestand oder Quelle wurde inzwischen verändert. Bitte den Abgleich erneut erstellen."
        case .wrongStore: "Der geführte Abgleich benötigt den eigenen lokalen MCP-Bestand. Ein fremdes Archiv wird nicht verändert."
        case .noSources: "Bitte mindestens einen Quellordner auswählen."
        }
    }
}
public enum LocalInventoryFingerprint {
    public static func snapshot(_ url: URL) throws -> String {
        if let generation = try LocalVaultSnapshotSource(fileURL: url).generation {
            // A replaced database with a restored generation must also invalidate reports.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? ""):\(generation)"
            return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw LocalInventoryError.wrongStore }
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
public struct LocalInventoryPlan: Sendable {
    public enum Change: String, Sendable { case added, changed, unchanged, pending, renewAccess }
    public struct File: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
        public let change: Change
        fileprivate let hash: String
        fileprivate let folder: LocalWatchedFolder
    }
    public struct Issue: Identifiable, Sendable {
        public let id = UUID()
        public let source: String
        public let message: String
    }
    public let files: [File]
    public let issues: [Issue]
    public let duplicates: Int
    public let snapshotDigest: String
    public var importCount: Int { files.filter { $0.change != .unchanged }.count }
}
public struct LocalInventoryImportResult: Sendable {
    public let imported: Int
    public let issues: [LocalInventoryPlan.Issue]
}

/// Explicit, bounded local maintenance. Scanning is observational; importing needs
/// a separate user action. No source writes, deletions, grants or watcher changes.
public struct LocalInventoryReconciler: Sendable {
    public let store: LocalDocumentStore
    public init(store: LocalDocumentStore) { self.store = store }
    public func source(_ url: URL, recursive: Bool) throws -> LocalWatchedFolder {
        try LocalWatchedFolder.authorizing(url, recursive: recursive)
    }
    public func inspect(_ folders: [LocalWatchedFolder]) async throws -> LocalInventoryPlan {
        guard !folders.isEmpty else { throw LocalInventoryError.noSources }
        guard folders.count <= 32 else { throw LocalWatchError.tooManyFolders }
        _ = try await store.documents()
        let digest = try LocalInventoryFingerprint.snapshot(store.snapshotURL)
        let documents = try await store.documents()
        let task = Task.detached { () throws -> LocalInventoryPlan in
            var files: [LocalInventoryPlan.File] = [], issues: [LocalInventoryPlan.Issue] = []
            var paths = Set<String>(), hashes = Set<String>(), duplicates = 0
            let byHash = Dictionary(documents.compactMap { d in d.localImport.map { ($0.contentHash, d) } }, uniquingKeysWith: { a, _ in a })
            let byPath = Dictionary(documents.compactMap { d in d.localImport?.originalReference.map { (URL(fileURLWithPath: $0.lastKnownPath).resolvingSymlinksInPath().path, d) } }, uniquingKeysWith: { a, _ in a })
            let byIdentity = Set(documents.compactMap { $0.localImport?.originalReference?.identity })
            for folder in folders {
                try Task.checkCancellation()
                do {
                    let access = try folder.openDirectory(); defer { access.close() }
                    let candidates = try LocalWatchedFolderMonitor.files(folder, excluding: store.root, directory: access.url)
                    for url in candidates {
                        try Task.checkCancellation()
                        guard paths.insert(url.path).inserted else { continue }
                        guard paths.count <= 20_000 else { throw LocalImportError.fileTooLarge }
                        do {
                            let file = LocalOriginalAccess(url: url); defer { file.close() }
                            try file.requireOutside(store.root)
                            let hash = LocalOriginalAccess.hash(try file.readData())
                            guard hashes.insert(hash).inserted else { duplicates += 1; continue }
                            let prior = byHash[hash]
                            let identity = try file.fileIdentity()
                            let change: LocalInventoryPlan.Change
                            if let prior {
                                if prior.localImport?.state == .queued { change = .pending }
                                else if let metadata = prior.localImport, metadata.originalReference != nil {
                                    do { let old = try store.checkedOriginal(metadata); old.close(); change = .unchanged }
                                    catch { change = .renewAccess }
                                } else { change = .unchanged }
                            } else { change = (byPath[url.resolvingSymlinksInPath().path] == nil && !byIdentity.contains(identity)) ? .added : .changed }
                            files.append(.init(url: url, change: change, hash: hash, folder: folder))
                        } catch is CancellationError { throw CancellationError() }
                        catch { issues.append(.init(source: url.lastPathComponent, message: "Datei nicht lesbar oder außerhalb der Verarbeitungsgrenzen.")) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(.init(source: URL(fileURLWithPath: folder.path).lastPathComponent, message: "Ordner nicht vollständig lesbar oder Eintragsgrenze überschritten.")) }
            }
            guard try LocalInventoryFingerprint.snapshot(store.snapshotURL) == digest else { throw LocalInventoryError.changed }
            return .init(files: files, issues: issues, duplicates: duplicates, snapshotDigest: digest)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    public func apply(_ plan: LocalInventoryPlan, worker: LocalImportWorker,
                      progress: @escaping @Sendable (LocalImportProgress) -> Void = { _ in }) async throws -> LocalInventoryImportResult {
        guard worker.store.root.resolvingSymlinksInPath().path == store.root.resolvingSymlinksInPath().path, try LocalInventoryFingerprint.snapshot(store.snapshotURL) == plan.snapshotDigest else { throw LocalInventoryError.changed }
        var imported = 0, issues = plan.issues
        for item in plan.files where item.change != .unchanged {
            try Task.checkCancellation()
            do {
                let folder = try item.folder.openDirectory(); defer { folder.close() }
                let file = LocalOriginalAccess(url: item.url); defer { file.close() }
                guard try LocalOriginalAccess.hash(file.readData()) == item.hash else { throw LocalInventoryError.changed }
                let result = try await worker.importFile(item.url, storage: .referenced, renewOriginalAccess: item.change == .renewAccess, progress: progress)
                imported += 1
                if result.state != .completed { issues.append(.init(source: item.url.lastPathComponent, message: "Texterkennung nicht vollständig abgeschlossen; im Qualitätsbericht prüfen.")) }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(.init(source: item.url.lastPathComponent, message: "Datei inzwischen verändert, nicht erreichbar oder Import fehlgeschlagen. Bitte erneut abgleichen.")) }
        }
        return .init(imported: imported, issues: issues)
    }
}

extension LocalDocumentStore {
    /// Keep a report's snapshot fixed through the explicit local grant commit.
    public func withUnchangedInventory<T>(_ digest: String, perform: () throws -> T) throws -> T {
        let result: Result<T, Error> = try locked {
            Result {
                _ = try read()
                guard try LocalInventoryFingerprint.snapshot(snapshotURL) == digest else { throw LocalInventoryError.changed }
                return try perform()
            }
        }
        return try result.get()
    }

    /// Publish the explicit local check as source-state metadata, preserving
    /// document identity, text, analysis and grants. Preview/report alone stays read-only.
    public func recordOriginalVerification(_ states: [UUID: LocalOriginalState], expectedDigest: String) async throws -> String {
        try await run {
            try withUnchangedInventory(expectedDigest) {
                var documents = try read()
                guard Set(states.keys).isSubset(of: Set(documents.map(\.id))) else { throw LocalInventoryError.changed }
                var changed = false
                for index in documents.indices {
                    if let state = states[documents[index].id], documents[index].localImport?.originalState != state {
                        documents[index].localImport?.originalState = state; changed = true
                    }
                }
                if changed { try save(documents) }
                return try LocalInventoryFingerprint.snapshot(snapshotURL)
            }
        }
    }
    /// Does not mutate the snapshot, including on missing/changed sources.
    public func verifiedOriginalState(for document: VaultDocument) async throws -> LocalOriginalState? {
        try Task.checkCancellation()
        guard let metadata = document.localImport else { return nil }
        return try await run {
            do { let access = try checkedOriginal(metadata); access.close(); return .available }
            catch let error as LocalOriginalError { return error.state }
            catch { return .unavailable }
        }
    }
}
