import Foundation

public enum VaultSnapshotError: LocalizedError, Equatable {
    case missing
    case unreadable
    case invalidFormat
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .missing:
            "Der lokale Vauldy-Vault wurde noch nicht angelegt."
        case .unreadable:
            "Der lokale Vauldy-Vault ist momentan nicht lesbar."
        case .invalidFormat:
            "Der lokale Vauldy-Vault hat ein unbekanntes oder beschädigtes Format."
        case .tooLarge:
            "Der lokale Bestand überschreitet die Größenbegrenzung dieser MCP-Version."
        }
    }
}

public protocol VaultSnapshotSource: Sendable {
    func loadDocuments() throws -> [VaultDocument]
    func isAvailable() -> Bool
}

public struct FileVaultSnapshotSource: VaultSnapshotSource, Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultVaultURL()) {
        self.fileURL = fileURL
    }

    public func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func loadDocuments() throws -> [VaultDocument] {
        guard isAvailable() else { throw VaultSnapshotError.missing }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch { throw VaultSnapshotError.unreadable }
        defer { try? handle.close() }
        guard try handle.seekToEnd() <= VaultStorageLimits.snapshotBytes else { throw VaultSnapshotError.tooLarge }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: VaultStorageLimits.snapshotBytes + 1) ?? Data()
        guard data.count <= VaultStorageLimits.snapshotBytes else { throw VaultSnapshotError.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do {
            let documents = try decoder.decode([VaultDocument].self, from: data)
            guard Set(documents.map(\.id)).count == documents.count else { throw VaultSnapshotError.invalidFormat }
            return documents
        } catch { throw VaultSnapshotError.invalidFormat }
    }

    /// Validate every record and ID, retaining only the selected records. No ungranted OCR cache.
    public func loadDocuments(allowedIDs: Set<UUID>?) throws -> [VaultDocument] {
        if let allowedIDs { return try loadSelection(allowedIDs: allowedIDs).documents }
        return try loadDocuments()
    }

    package func loadSelection(allowedIDs: Set<UUID>) throws -> (documents: [VaultDocument], encodedBytes: Int64, complete: Bool) {
        var documents: [VaultDocument] = [], total = 0
        var bytes: Int64 = 2
        try visitRecords { document, recordBytes in
            total += 1
            if allowedIDs.contains(document.id) {
                documents.append(document); bytes += Int64(recordBytes + 1)
            }
        }
        return (documents, bytes, documents.count == total)
    }

    package func visitDocuments(_ visit: (VaultDocument) throws -> Void) throws {
        try visitRecords { document, _ in try visit(document) }
    }

    private func visitRecords(_ visit: (VaultDocument, Int) throws -> Void) throws {
        guard isAvailable() else { throw VaultSnapshotError.missing }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch { throw VaultSnapshotError.unreadable }
        defer { try? handle.close() }
        // Reject oversized files before allocating/decoding, including sparse files.
        guard try handle.seekToEnd() <= VaultStorageLimits.snapshotBytes else { throw VaultSnapshotError.tooLarge }
        try handle.seek(toOffset: 0)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        enum State { case start, first, next, record, separator, end }
        var state = State.start, record = Data(), ids = Set<UUID>()
        var depth = 0, quoted = false, escaped = false, total = 0
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do { chunk = try autoreleasepool { try handle.read(upToCount: 64 * 1_024) ?? Data() } }
            catch { throw VaultSnapshotError.unreadable }
            if chunk.isEmpty { break }
            total += chunk.count
            guard total <= VaultStorageLimits.snapshotBytes else { throw VaultSnapshotError.tooLarge }
            var recordStart: Int? = state == .record ? chunk.startIndex : nil
            try chunk.withUnsafeBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                for index in bytes.indices {
                    let byte = bytes[index]
                    let whitespace = byte == 32 || byte == 9 || byte == 10 || byte == 13
                    switch state {
                    case .start:
                        if whitespace { continue }
                        guard byte == 91 else { throw VaultSnapshotError.invalidFormat }
                        state = .first
                    case .first, .next:
                        if whitespace { continue }
                        if byte == 93 && state == .first { state = .end; continue }
                        guard byte == 123 else { throw VaultSnapshotError.invalidFormat }
                        recordStart = index; depth = 1; quoted = false; escaped = false; state = .record
                    case .record:
                        if quoted {
                            if escaped { escaped = false }
                            else if byte == 92 { escaped = true }
                            else if byte == 34 { quoted = false }
                        } else if byte == 34 { quoted = true }
                        else if byte == 123 || byte == 91 { depth += 1 }
                        else if byte == 125 || byte == 93 {
                            depth -= 1
                            if depth == 0 {
                                record.append(chunk[recordStart!...index]); recordStart = nil
                                let document: VaultDocument
                                do { document = try autoreleasepool { try decoder.decode(VaultDocument.self, from: record) } }
                                catch { throw VaultSnapshotError.invalidFormat }
                                guard ids.insert(document.id).inserted else { throw VaultSnapshotError.invalidFormat }
                                try visit(document, record.count)
                                record.removeAll(keepingCapacity: true); state = .separator
                            }
                        }
                    case .separator:
                        if whitespace { continue }
                        if byte == 44 { state = .next }
                        else if byte == 93 { state = .end }
                        else { throw VaultSnapshotError.invalidFormat }
                    case .end:
                        guard whitespace else { throw VaultSnapshotError.invalidFormat }
                    }
                }
            }
            if let recordStart { record.append(chunk[recordStart..<chunk.endIndex]) }
        }
        guard state == .end else { throw VaultSnapshotError.invalidFormat }
    }

    public static func defaultVaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VauldyMCP/vault/documents.json")
    }
}
