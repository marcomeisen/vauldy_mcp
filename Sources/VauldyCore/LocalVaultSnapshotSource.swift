import Foundation

/// Read-only adapter shared by local administration and MCP. Existing JSON keeps its decoder,
/// bounds and semantics. A format-4 marker explicitly promotes a legacy logical path;
/// a missing JSON file alone never selects another backend.
public struct LocalVaultSnapshotSource: VaultSnapshotSource {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = LocalDocumentStore.resolvedSnapshotURL(fileURL) }
    package var isSQLite: Bool { fileURL.lastPathComponent == "records.sqlite" }
    private func requirePublished() throws {
        let root = isSQLite ? fileURL.deletingLastPathComponent().deletingLastPathComponent() : fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("SQLITE_ACTIVATION_PENDING").path) { throw VaultSnapshotError.unreadable }
        if FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("INCOMPLETE").path) { throw VaultSnapshotError.unreadable }
    }
    package func database() throws -> SQLiteDocumentStore {
        try requirePublished()
        return try SQLiteDocumentStore(directory: fileURL.deletingLastPathComponent(), readOnly: true)
    }
    package var generation: String? { get throws { try requirePublished(); return isSQLite ? try database().generation : nil } }
    public func isAvailable() -> Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    public func loadDocuments() throws -> [VaultDocument] {
        try requirePublished()
        if isSQLite { return try database().documents() }
        return try FileVaultSnapshotSource(fileURL: fileURL).loadDocuments()
    }
    package func loadSelection(allowedIDs: Set<UUID>) throws -> (documents: [VaultDocument], encodedBytes: Int64, complete: Bool) {
        try requirePublished()
        if !isSQLite { return try FileVaultSnapshotSource(fileURL: fileURL).loadSelection(allowedIDs: allowedIDs) }
        let db = try database(), before = try db.generation
        let documents = try db.documents(ids: allowedIDs)
        let complete = try documents.count == db.count
        guard try db.generation == before else { throw VaultSnapshotError.unreadable }
        // Encoding is bounded to the selected records; never load ungranted payloads to size a cache.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try documents.reduce(Int64(2)) { try $0 + Int64(encoder.encode($1).count + 1) }
        return (documents, bytes, complete)
    }
}
