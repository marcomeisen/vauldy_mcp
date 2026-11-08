import Foundation
import Darwin

// Foundation can spell the same macOS /var path differently for files and directories.
// realpath gives a consistent filesystem identity and also detects replaced symlink ancestors.
private func canonicalWatchPath(_ url: URL) throws -> String {
    guard let pointer = url.withUnsafeFileSystemRepresentation({ path in path.flatMap { realpath($0, nil) } }) else {
        throw LocalWatchError.invalidFolder
    }
    defer { free(pointer) }
    return String(cString: pointer)
}

public struct LocalWatchedFolder: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public var bookmark: Data? = nil
    public var recursive: Bool
    public var enabled: Bool
    public init(id: UUID = UUID(), path: String, recursive: Bool = false, enabled: Bool = true) {
        self.id = id; self.path = path; self.recursive = recursive; self.enabled = enabled
    }
}

extension LocalWatchedFolder {
    static func authorizing(_ url: URL, recursive: Bool) throws -> Self {
        let access = LocalOriginalAccess(url: url); defer { access.close() }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw LocalWatchError.invalidFolder }
        var folder = Self(path: try canonicalWatchPath(url), recursive: recursive)
        do { folder.bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { throw LocalWatchError.invalidFolder }
        let reopened = try folder.openDirectory(); defer { reopened.close() }
        return folder
    }
    func openDirectory() throws -> LocalOriginalAccess {
        let url: URL
        if let bookmark {
            guard !bookmark.isEmpty, bookmark.count <= 65_536 else { throw LocalWatchError.invalidFolder }
            var stale = false
            do { url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) }
            catch { throw LocalWatchError.invalidFolder }
        } else { url = URL(fileURLWithPath: path) }
        let access = LocalOriginalAccess(url: url)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { access.close(); throw LocalWatchError.invalidFolder }
        return access
    }
}

public enum LocalWatchError: String, Error, LocalizedError, Sendable {
    case invalidFolder, invalidConfiguration, tooManyFolders, scanLimit
    public var errorDescription: String? {
        switch self {
        case .invalidFolder: "Bitte einen lesbaren Ordner außerhalb des lokalen Vauldy-Bestands wählen. Der Bestand darf auch nicht in diesem Ordner liegen."
        case .invalidConfiguration: "Die Ordnerliste ist beschädigt oder nicht zugänglich. Sie wurde nicht überschrieben."
        case .tooManyFolders: "Es können höchstens 32 Ordner beobachtet werden."
        case .scanLimit: "Dieser Import überschreitet die Grenze von 20.000 Einträgen. Wähle einen kleineren Bestand."
        }
    }
}

/// Trusted local configuration only. Neither paths nor future imports become MCP grants.
public struct LocalWatchedFolderStore: Sendable {
    public let store: LocalDocumentStore
    public init(store: LocalDocumentStore) { self.store = store }
    private var url: URL { store.root.appendingPathComponent("watched-folders.json") }

    public func folders() async throws -> [LocalWatchedFolder] {
        _ = try await store.documents()
        return try await Task.detached { try configuredFolders() }.value
    }

    func configuredFolders() throws -> [LocalWatchedFolder] { try locked { try read() } }

    @discardableResult
    public func add(_ urls: [URL], recursive: Bool = false) async throws -> [LocalWatchedFolder] {
        _ = try await store.documents()
        return try await Task.detached {
            let authorized = try urls.map { input in
                let access = LocalOriginalAccess(url: input); defer { access.close() }
                _ = try validatedPath(input)
                return try LocalWatchedFolder.authorizing(input, recursive: recursive)
            }
            return try locked {
                var folders = try read()
                for folder in authorized {
                    if let index = folders.firstIndex(where: { $0.path == folder.path }) {
                        folders[index].recursive = recursive; folders[index].enabled = true
                        folders[index].bookmark = folder.bookmark
                    } else { folders.append(folder) }
                }
                guard folders.count <= 32 else { throw LocalWatchError.tooManyFolders }
                try save(folders)
                return folders
            }
        }.value
    }

    public func setEnabled(_ enabled: Bool, id: UUID) async throws {
        try await change(id) { $0?.enabled = enabled }
    }

    public func remove(_ id: UUID) async throws { try await change(id) { $0 = nil } }

    private func change(_ id: UUID, mutation: @escaping @Sendable (inout LocalWatchedFolder?) -> Void) async throws {
        _ = try await store.documents()
        try await Task.detached {
            try locked {
                var folders = try read()
                guard let index = folders.firstIndex(where: { $0.id == id }) else { throw LocalWatchError.invalidConfiguration }
                var folder: LocalWatchedFolder? = folders[index]
                mutation(&folder)
                if let folder { folders[index] = folder } else { folders.remove(at: index) }
                try save(folders)
            }
        }.value
    }

    private func validatedPath(_ input: URL) throws -> String {
        guard input.isFileURL, input.path.hasPrefix("/") else { throw LocalWatchError.invalidFolder }
        let path = try canonicalWatchPath(input)
        let folder = URL(fileURLWithPath: path)
        let root = try canonicalWatchPath(store.root)
        guard path != root, !path.hasPrefix(root + "/"), !root.hasPrefix(path == "/" ? "/" : path + "/"),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.isReadableFile(atPath: path) else { throw LocalWatchError.invalidFolder }
        return path
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let lock = try LocalWorkerLease(url: store.root.appendingPathComponent("watched-folders.lock"), wait: true)
        defer { lock.release() }
        return try operation()
    }

    private func read() throws -> [LocalWatchedFolder] {
        // A dangling link must not be interpreted as an absent configuration.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LocalWatchError.invalidConfiguration }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 256_000,
              let folders = try? JSONDecoder().decode([LocalWatchedFolder].self, from: Data(contentsOf: url)),
              folders.count <= 32, Set(folders.map(\.id)).count == folders.count,
              Set(folders.map(\.path)).count == folders.count,
              folders.allSatisfy({ $0.path.hasPrefix("/") && $0.path.utf8.count <= 8_192 && ($0.bookmark?.count ?? 0) <= 65_536 }) else {
            throw LocalWatchError.invalidConfiguration
        }
        return folders
    }

    private func save(_ folders: [LocalWatchedFolder]) throws {
        let data = try JSONEncoder().encode(folders)
        guard data.count <= 256_000 else { throw LocalWatchError.invalidConfiguration }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct LocalWatchScanStatus: Codable, Sendable {
    public enum Issue: String, Codable, Sendable { case unavailable, scanLimit, importFailed }
    public var folderID: UUID
    public var scannedAt: Date
    public var issue: Issue?
    public var submitted: Int
}

/// Polls between OCR jobs. Two unchanged observations avoid importing files still being copied.
/// Signatures are process-local; restarting rechecks bytes through the importer's SHA-256 dedupe.
actor LocalWatchedFolderMonitor {
    private struct Signature: Equatable {
        var size: Int
        var modified: Date
        var created: Date?
        var identity: UInt64?
    }
    private struct Observation { var signature: Signature; var submitted = false }
    private var observations: [String: Observation] = [:]
    private let store: LocalDocumentStore
    init(store: LocalDocumentStore) { self.store = store }

    func scan(_ folders: [LocalWatchedFolder], submit: @Sendable (URL) async throws -> Void) async -> [LocalWatchScanStatus] {
        var next: [String: Observation] = [:]
        var statuses: [LocalWatchScanStatus] = []
        var submissions = 0
        for folder in folders where folder.enabled {
            var status = LocalWatchScanStatus(folderID: folder.id, scannedAt: Date(), submitted: 0)
            do {
                let directoryAccess = try folder.openDirectory(); defer { directoryAccess.close() }
                let directory = directoryAccess.url
                let files = try await Task.detached { try Self.files(folder, excluding: self.store.root, directory: directory) }.value
                for file in files {
                    do {
                        guard try canonicalWatchPath(file) == file.path else { continue }
                        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                        let size = values.fileSize ?? 0
                        guard size > 0 else { continue }
                        guard size <= LocalDocumentStore.maximumOriginalBytes else { status.issue = .importFailed; continue }
                        let identity = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
                        let signature = Signature(size: size, modified: values.contentModificationDate ?? .distantPast,
                                                  created: values.creationDate, identity: identity?.uint64Value)
                        let key = file.path
                        if next[key] != nil { continue } // Overlapping watched folders.
                        guard next.count < 20_000 else { status.issue = .scanLimit; break }
                        var observation = Observation(signature: signature)
                        if let previous = observations[key], previous.signature == signature {
                            observation = previous
                            if !previous.submitted && submissions < 100 {
                                // Recheck the grant to watch this folder before referencing another original.
                                let current = try LocalWatchedFolderStore(store: store).configuredFolders()
                                guard current.contains(folder) else { break }
                                do {
                                    try await submit(file)
                                    observation.submitted = true; status.submitted += 1; submissions += 1
                                } catch { status.issue = .importFailed }
                            }
                        }
                        next[key] = observation
                    } catch { status.issue = .importFailed }
                }
            } catch LocalWatchError.scanLimit { status.issue = .scanLimit }
            catch { status.issue = .unavailable }
            statuses.append(status)
        }
        observations = next
        return statuses
    }

    private enum ScanFailure: Error { case unavailable }
    static func files(_ folder: LocalWatchedFolder, excluding root: URL, directory: URL) throws -> [URL] {
        try scanFiles(folder, excluding: root, directory: directory, includeUnsupported: false).supported
    }

    static func scanFiles(_ folder: LocalWatchedFolder, excluding root: URL, directory: URL,
                          includeUnsupported: Bool) throws -> (supported: [URL], unsupported: [URL]) {
        let resolved = try canonicalWatchPath(directory)
        let vault = try canonicalWatchPath(root)
        guard (folder.bookmark != nil || resolved == folder.path), resolved != vault, !resolved.hasPrefix(vault + "/"),
              !vault.hasPrefix(resolved == "/" ? "/" : resolved + "/"),
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ScanFailure.unavailable }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var failed = false
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !folder.recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: options,
                                                           errorHandler: { _, _ in failed = true; return false }) else { throw ScanFailure.unavailable }
        var files: [URL] = [], unsupported: [URL] = []
        var count = 0
        for case let file as URL in iterator {
            try Task.checkCancellation()
            count += 1
            guard count <= 20_000 else { throw LocalWatchError.scanLimit }
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            if LocalDocumentStore.supportedExtensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
            } else if includeUnsupported {
                unsupported.append(file)
            }
        }
        guard !failed else { throw ScanFailure.unavailable }
        return (files.sorted { $0.path < $1.path }, unsupported.sorted { $0.path < $1.path })
    }
}
