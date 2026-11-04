import CryptoKit
import Darwin
import Foundation
import VauldyCore

/// Opt-in cache scoped to the private directory of one local MCP profile.
struct PersistentMCPIndex {
    struct Result {
        let candidates: Set<UUID>?
        let projections: [UUID: VaultIndexProjection]
    }

    private let profileDirectory: URL
    private let directory: URL
    private var parent: URL { directory.deletingLastPathComponent() }
    private var retiredPrefix: String { directory.lastPathComponent + ".retired-" }
    private var file: URL { directory.appendingPathComponent("index-v1.sqlite") }
    private var verifiedFile: MCPFileVersion?

    init(profileURL: URL) {
        let key = SHA256.hash(data: Data(profileURL.lastPathComponent.utf8))
        profileDirectory = profileURL.deletingLastPathComponent()
        directory = (Self.canonicalDirectory(profileDirectory) ?? profileDirectory)
            .appendingPathComponent(".vauldy-index-" + key.map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    mutating func query(_ query: String?, profile: MCPAccessProfile, generation: Data,
                        records: [(document: VaultDocument, fingerprint: Data)],
                        validateCurrent: () throws -> Void) throws -> Result {
        try checkProfileDirectory()
        let lock = try acquireLock()
        defer { close(lock) }
        try confirmCurrent(validateCurrent)
        try cleanRetiredIndexes()
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw MCPAccessError.unavailable }
        try checkPrivate(directory, type: S_IFDIR)
        // Revocation can retire the directory while this process holds the writer lock.
        try confirmCurrent(validateCurrent)
        try cleanInterruptedBuilds(in: directory)
        try checkFiles(at: file)
        let scope = try profile.disclosureFingerprint()

        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let stamp = try MCPFileVersion(file)
                let validate = stamp != verifiedFile || FileManager.default.fileExists(atPath: journal(of: file).path)
                let index = try SQLiteVaultTokenIndex(file: file, scope: scope, create: false, validate: validate)
                let result = try result(from: index, query: query, generation: generation, records: records)
                try confirmCurrent(validateCurrent)
                verifiedFile = try MCPFileVersion(file)
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MCPAccessError {
                throw error
            } catch {
                // Obsolete, unreadable or damaged data is replaceable. The JSON source still owns the result.
                verifiedFile = nil
            }
        }

        let staging = directory.appendingPathComponent(".build-" + UUID().uuidString)
        let descriptor = open(staging.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw MCPAccessError.unavailable }
        close(descriptor)
        defer {
            try? removeFile(staging)
            try? removeFile(journal(of: staging))
        }
        let output: Result
        do {
            let index = try SQLiteVaultTokenIndex(file: staging, scope: scope)
            output = try result(from: index, query: query, generation: generation, records: records)
        }
        try confirmCurrent(validateCurrent)
        try checkFiles(at: file)
        // A hot journal belongs to the old inode, never to the replacement database.
        try removeFile(journal(of: file))
        guard rename(staging.path, file.path) == 0 else { throw MCPAccessError.unavailable }
        let parent = open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY)
        if parent >= 0 { _ = fsync(parent); close(parent) }
        try confirmCurrent(validateCurrent)
        verifiedFile = try MCPFileVersion(file)
        return output
    }

    func purgeIfPresent() {
        do {
            try checkProfileDirectory()
            // Retire the entire directory, including scratch and journals, without
            // waiting on SQLite. No other writer can recreate it until the old writer exits.
            try checkPrivate(directory, type: S_IFDIR, optional: true)
            let retired = parent.appendingPathComponent(retiredPrefix + UUID().uuidString)
            if rename(directory.path, retired.path) != 0 && errno != ENOENT { throw MCPAccessError.unavailable }
            try cleanRetiredIndexes()
        } catch {
            // A later call can retry interrupted cleanup. Access is checked from the profile.
        }
    }

    private func result(from index: SQLiteVaultTokenIndex, query: String?, generation: Data,
                        records: [(document: VaultDocument, fingerprint: Data)]) throws -> Result {
        try index.reconcile(records, generation: generation) { document in
            MCPSourceState(document).projection(for: document)
        }
        let candidates = try query.map { try index.matchingIDs(for: $0) }
        return Result(candidates: candidates, projections: index.projections)
    }

    private func confirmCurrent(_ validateCurrent: () throws -> Void) throws {
        do { try validateCurrent() }
        catch {
            purgeIfPresent()
            throw error
        }
    }

    private func checkProfileDirectory() throws {
        try checkPrivate(profileDirectory, type: S_IFDIR)
        guard Self.canonicalDirectory(profileDirectory)?.path == parent.path
        else { throw MCPAccessError.configuration }
    }

    private static func canonicalDirectory(_ url: URL) -> URL? {
        // Foundation may retain the macOS /var alias, which SQLite NOFOLLOW rejects.
        guard let resolved = url.withUnsafeFileSystemRepresentation({ path in path.flatMap { realpath($0, nil) } })
        else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func acquireLock() throws -> Int32 {
        let url = parent.appendingPathComponent(directory.lastPathComponent + ".lock")
        let descriptor = open(url.path, O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw MCPAccessError.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw MCPAccessError.unavailable
        }
        return descriptor
    }

    private func checkFiles(at url: URL) throws {
        try checkPrivate(url, type: S_IFREG, optional: true)
        try checkPrivate(journal(of: url), type: S_IFREG, optional: true)
        for suffix in ["-wal", "-shm"] {
            var info = stat()
            guard lstat(url.path + suffix, &info) != 0, errno == ENOENT else { throw MCPAccessError.configuration }
        }
    }

    private func checkPrivate(_ url: URL, type: mode_t, optional: Bool = false, limitSize: Bool = true) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if optional && errno == ENOENT { return }
            throw MCPAccessError.unavailable
        }
        guard info.st_mode & S_IFMT == type, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              type != S_IFREG || (info.st_nlink == 1 && (!limitSize || info.st_size <= 64 * 1_024 * 1_024)) else {
            throw MCPAccessError.configuration
        }
    }

    private func journal(of url: URL) -> URL { URL(fileURLWithPath: url.path + "-journal") }

    private func removeFile(_ url: URL) throws {
        try checkPrivate(url, type: S_IFREG, optional: true, limitSize: false)
        if unlink(url.path) != 0 && errno != ENOENT { throw MCPAccessError.unavailable }
    }

    private func cleanRetiredIndexes() throws {
        for entry in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent
            guard name.hasPrefix(retiredPrefix),
                  UUID(uuidString: String(name.dropFirst(retiredPrefix.count))) != nil else { continue }
            try checkPrivate(entry, type: S_IFDIR, optional: true)
            let database = entry.appendingPathComponent(file.lastPathComponent)
            try removeFile(database)
            try removeFile(journal(of: database))
            try removeFile(entry.appendingPathComponent("index.lock")) // Pilot versions stored their lock here.
            try cleanInterruptedBuilds(in: entry)
            if rmdir(entry.path) != 0 && errno != ENOENT && errno != ENOTEMPTY { throw MCPAccessError.unavailable }
        }
    }

    private func cleanInterruptedBuilds(in folder: URL) throws {
        let entries: [URL]
        do { entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".build-") else { continue }
            let suffix = name.hasSuffix("-journal") ? String(name.dropLast(8)) : name
            guard UUID(uuidString: String(suffix.dropFirst(7))) != nil else { continue }
            try removeFile(entry)
        }
    }
}
