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
        guard isAvailable() else {
            throw VaultSnapshotError.missing
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: 128 * 1_024 * 1_024 + 1) ?? Data()
        } catch {
            throw VaultSnapshotError.unreadable
        }

        guard data.count <= 128 * 1_024 * 1_024 else { throw VaultSnapshotError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let documents = try decoder.decode([VaultDocument].self, from: data)
            guard Set(documents.map(\.id)).count == documents.count else { throw VaultSnapshotError.invalidFormat }
            return documents
        } catch {
            throw VaultSnapshotError.invalidFormat
        }
    }

    public static func defaultVaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VauldyMCP/vault/documents.json")
    }
}
