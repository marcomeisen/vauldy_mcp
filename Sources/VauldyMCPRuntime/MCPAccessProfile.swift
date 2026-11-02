import Foundation

/// Local grant, never accepted through tool arguments. Each connection gets its own profile.
public struct MCPAccessProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int = currentVersion
    public var revision: UUID = UUID()
    public var connectionID: UUID = UUID()
    public var connectionName: String = "MCP-Client"
    public var desktopClient: MCPDesktopClient? = nil
    public var enabled: Bool
    public var vaultPath: String
    public var allowedDocumentIDs: Set<UUID>
    public var acknowledgedCloudDisclosure: Bool

    public init(vaultPath: String, allowedDocumentIDs: Set<UUID> = [], enabled: Bool = false,
                acknowledgedCloudDisclosure: Bool = false) {
        self.vaultPath = vaultPath
        self.allowedDocumentIDs = allowedDocumentIDs
        self.enabled = enabled
        self.acknowledgedCloudDisclosure = acknowledgedCloudDisclosure
    }

    public func validate() throws {
        guard version == Self.currentVersion, vaultPath.hasPrefix("/"),
              !vaultPath.contains("\0"), connectionName.count <= 80,
              allowedDocumentIDs.count <= 20_000 else { throw MCPAccessError.configuration }
        if enabled && (!acknowledgedCloudDisclosure || allowedDocumentIDs.isEmpty) {
            throw MCPAccessError.notAuthorized
        }
    }
}

public enum MCPAccessError: LocalizedError, Equatable {
    case configuration, notAuthorized, invalidArguments, unavailable, privacy, stale, tooLarge
    public var errorDescription: String? {
        switch self {
        case .configuration: "Die lokale MCP-Einrichtung fehlt oder ist ungültig. Bitte Vauldy MCP Einrichtung öffnen."
        case .notAuthorized: "Kein Dokumentzugriff freigegeben. Bitte die Freigabe lokal in Vauldy MCP Einrichtung prüfen."
        case .invalidArguments: "Ungültige Anfrage. Bitte die beschriebenen Werkzeugparameter verwenden."
        case .unavailable: "Der freigegebene lokale Bestand ist nicht lesbar. Original und Bestand bleiben unverändert."
        case .privacy: "Der Inhalt konnte nicht sicher bereinigt werden und wurde nicht ausgegeben."
        case .stale: "Die Freigabe oder das Dokument hat sich geändert. Bitte erneut suchen."
        case .tooLarge: "Der Inhalt überschreitet die Grenzen dieser Version. Es wurde kein unvollständiger Inhalt als vollständig ausgegeben."
        }
    }
}

public protocol MCPProfileSource: Sendable {
    func load() throws -> MCPAccessProfile
}

public struct FileMCPProfileSource: MCPProfileSource {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> MCPAccessProfile {
        do {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw MCPAccessError.configuration }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 2_000_001) ?? Data()
            guard data.count <= 2_000_000 else { throw MCPAccessError.configuration }
            let profile = try JSONDecoder().decode(MCPAccessProfile.self, from: data)
            try profile.validate()
            return profile
        } catch let error as MCPAccessError { throw error }
        catch { throw MCPAccessError.configuration }
    }

    public func save(_ value: MCPAccessProfile) throws {
        try value.validate()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
