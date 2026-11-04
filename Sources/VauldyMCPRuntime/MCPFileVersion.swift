import Darwin
import Foundation
import VauldyCore

/// Filesystem identity, including ctime, so same-size edits and restored mtime invalidate caches.
struct MCPFileVersion: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let mode: UInt16
    let owner: UInt32
    init(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MCPAccessError.unavailable }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw MCPAccessError.unavailable }
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        mode = value.st_mode; owner = value.st_uid
    }
}

/// One bounded in-memory source, no extra archive or persistent raw index. Owned by the runtime actor.
struct MCPVaultSnapshotCache {
    private let maximumBytes: Int64
    init(maximumBytes: Int64 = 64 * 1_024 * 1_024) { self.maximumBytes = maximumBytes }
    private var path: String?
    private var version: MCPFileVersion?
    private var documents: [VaultDocument]?
    private(set) var decodeCount = 0
    var retainsDocuments: Bool { documents != nil }
    mutating func clear() { path = nil; version = nil; documents = nil }
    mutating func load(_ path: String) throws -> (documents: [VaultDocument], version: MCPFileVersion) {
        let url = URL(fileURLWithPath: path)
        do {
            let before = try MCPFileVersion(url)
            if self.path == path, self.version == before, let documents { return (documents, before) }
            clear()
            let value = try FileVaultSnapshotSource(fileURL: url).loadDocuments()
            decodeCount += 1
            guard try MCPFileVersion(url) == before else { throw MCPAccessError.stale }
            if before.size <= maximumBytes { self.path = path; version = before; documents = value }
            return (value, before)
        } catch { clear(); throw error }
    }
}
