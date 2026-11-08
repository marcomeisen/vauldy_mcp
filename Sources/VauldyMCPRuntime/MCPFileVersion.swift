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
    let databaseGeneration: String?
    init(_ url: URL) throws {
        let url = LocalDocumentStore.resolvedSnapshotURL(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MCPAccessError.unavailable }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw MCPAccessError.unavailable }
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        mode = value.st_mode; owner = value.st_uid
        databaseGeneration = try LocalVaultSnapshotSource(fileURL: url).generation
    }
}

/// Pins the authority used for an outgoing tool reply across encoding and audit I/O.
package struct MCPResponseAccess {
    private let profile: MCPAccessProfile
    private let version: MCPFileVersion?

    package init(profile: MCPAccessProfile) throws {
        self.profile = profile
        version = profile.enabled ? try MCPFileVersion(URL(fileURLWithPath: profile.vaultPath)) : nil
    }

    package func verify(using source: any MCPProfileSource) throws {
        try Task.checkCancellation()
        guard version == nil || (try? MCPFileVersion(URL(fileURLWithPath: profile.vaultPath))) == version,
              try source.load() == profile else {
            throw MCPAccessError.stale
        }
    }
}

/// One bounded in-memory source, no extra archive or persistent raw index. Owned by the runtime actor.
struct MCPVaultSnapshotCache {
    private let maximumBytes: Int64
    init(maximumBytes: Int64 = 64 * 1_024 * 1_024) { self.maximumBytes = maximumBytes }
    private var path: String?
    private var version: MCPFileVersion?
    private var documents: [VaultDocument]?
    private var allowedIDs: Set<UUID>?
    private var completeSelection = false
    private(set) var decodeCount = 0
    var retainsDocuments: Bool { documents != nil }
    mutating func clear() { path = nil; version = nil; documents = nil; allowedIDs = nil; completeSelection = false }
    mutating func load(_ path: String, allowedIDs: Set<UUID>? = nil) throws -> (documents: [VaultDocument], version: MCPFileVersion) {
        let url = URL(fileURLWithPath: path)
        do {
            let before = try MCPFileVersion(url)
            if self.path == path, self.version == before, self.allowedIDs == allowedIDs, let documents { return (documents, before) }
            // Once the same immutable generation is known to be fully selected, use the
            // faster bounded bulk decoder. This retains no extra documents beyond the grant.
            let bulk = allowedIDs == nil || (self.path == path && version == before &&
                self.allowedIDs == allowedIDs && completeSelection)
            clear()
            let source = LocalVaultSnapshotSource(fileURL: url)
            let value: [VaultDocument], retainedBytes: Int64, complete: Bool
            if bulk && !source.isSQLite {
                value = try source.loadDocuments(); retainedBytes = before.size; complete = true
            } else {
                let selection = try source.loadSelection(allowedIDs: allowedIDs ?? Set(try source.loadDocuments().map(\.id)))
                value = selection.documents; retainedBytes = selection.encodedBytes; complete = selection.complete
            }
            decodeCount += 1
            guard try MCPFileVersion(url) == before else { throw MCPAccessError.stale }
            // Keep scope/identity even when the payload exceeds the cache budget. A source or
            // profile change invalidates the bulk-path decision before the next read.
            self.path = path; version = before; self.allowedIDs = allowedIDs; completeSelection = complete
            if retainedBytes <= maximumBytes { documents = value }
            return (value, before)
        } catch { clear(); throw error }
    }
}
