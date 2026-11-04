import Foundation

/// Installs only MCP-owned files. Never edits a chatbot configuration or the app's archive.
public struct MCPInstallation: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VauldyMCP", isDirectory: true)) { self.root = root }
    public var binaryURL: URL { root.appendingPathComponent("bin/vauldy-mcp") }
    public var httpServerURL: URL { root.appendingPathComponent("bin/vauldy-mcp-http") }
    public var localCLIURL: URL { root.appendingPathComponent("bin/vauldy-local") }
    public var statusAppURL: URL { root.appendingPathComponent("bin/" + MCPStatusApp.bundleName, isDirectory: true) }
    public var connectionsURL: URL { root.appendingPathComponent("connections", isDirectory: true) }
    public func profileURL(_ id: UUID) -> URL { connectionsURL.appendingPathComponent(id.uuidString).appendingPathComponent("profile.json") }
    public func configurationURL(_ id: UUID) -> URL { connectionsURL.appendingPathComponent(id.uuidString).appendingPathComponent("mcp-config.json") }

    public var removedConnectionsURL: URL { root.appendingPathComponent("removed-connections", isDirectory: true) }

    public func install(binary: URL, profile: MCPAccessProfile, localCLI: URL? = nil, statusApp: URL? = nil, setupApp: URL? = nil) throws -> URL {
        guard !FileManager.default.fileExists(atPath: removedConnectionsURL.appendingPathComponent(profile.connectionID.uuidString).path) else { throw MCPAccessError.stale }
        try profile.validate()
        guard binary.isFileURL, FileManager.default.isExecutableFile(atPath: binary.path) else { throw MCPAccessError.configuration }
        try updateSoftware(binary: binary, localCLI: localCLI, statusApp: statusApp, setupApp: setupApp)
        try privateDirectory(connectionsURL)
        let path = profileURL(profile.connectionID)
        try privateDirectory(path.deletingLastPathComponent())
        try FileMCPProfileSource(url: path).save(profile)
        let configuration = try configurationData(profile.connectionID)
        let destination = configurationURL(profile.connectionID)
        try configuration.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try MCPAuditLog(profileURL: path).append(.profileSaved, count: profile.allowedDocumentIDs.count, revision: profile.revision)
        return destination
    }

    func prepareSoftwareDirectories() throws {
        try privateDirectory(root)
        try privateDirectory(binaryURL.deletingLastPathComponent())
    }

    func copySoftware(binary: URL, localCLI: URL?, statusApp: URL?) throws {
        // Atomic replacement also permits installing an update while an older process is still reading.
        if binary.standardizedFileURL != binaryURL.standardizedFileURL {
            try Data(contentsOf: binary).write(to: binaryURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binaryURL.path)
        }
        if let localCLI {
            if localCLI.standardizedFileURL != localCLIURL.standardizedFileURL {
                try Data(contentsOf: localCLI).write(to: localCLIURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: localCLIURL.path)
            }
        }
        let http = binary.deletingLastPathComponent().appendingPathComponent("vauldy-mcp-http")
        if FileManager.default.isExecutableFile(atPath: http.path), http.standardizedFileURL != httpServerURL.standardizedFileURL {
            try Data(contentsOf: http).write(to: httpServerURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: httpServerURL.path)
        }
        let relay = binary.deletingLastPathComponent().appendingPathComponent("vauldy-relay")
        if FileManager.default.isExecutableFile(atPath: relay.path) {
            let destination = binaryURL.deletingLastPathComponent().appendingPathComponent("vauldy-relay")
            if relay.standardizedFileURL != destination.standardizedFileURL {
                try Data(contentsOf: relay).write(to: destination, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            }
        }
        if let statusApp { try replaceBundle(statusApp, at: statusAppURL) }
    }

    func validateStatusApp(_ source: URL) throws {
        guard let bundle = Bundle(url: source), bundle.bundleIdentifier == "com.marcomeisen.vauldy.mcp-status",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "vauldy-mcp-status",
              FileManager.default.isExecutableFile(atPath: source.appendingPathComponent("Contents/MacOS/vauldy-mcp-status").path),
              (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { throw MCPAccessError.configuration }
        guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else { throw MCPAccessError.configuration }
        var count = 0; var bytes = 0
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            count += 1; bytes += values.fileSize ?? 0
            guard values.isSymbolicLink != true, count <= 64, bytes <= 100 * 1_024 * 1_024 else { throw MCPAccessError.configuration }
        }
    }

    func replaceBundle(_ source: URL, at destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        guard (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else { throw MCPAccessError.configuration }
        var count = 0, bytes = 0
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            count += 1; bytes += values.fileSize ?? 0
            guard values.isSymbolicLink != true, count <= 512, bytes <= 300 * 1_024 * 1_024 else { throw MCPAccessError.configuration }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".app-install-" + UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
    }

    public func configurationData(_ id: UUID) throws -> Data {
        struct Entry: Encodable { let command: String; let args: [String] }
        struct Configuration: Encodable { let mcpServers: [String: Entry] }
        let value = Configuration(mcpServers: ["vauldy": Entry(command: binaryURL.path, args: ["--profile", profileURL(id).path])])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public func profiles() throws -> [MCPAccessProfile] {
        guard FileManager.default.fileExists(atPath: connectionsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: connectionsURL, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .filter { !MCPRemovalState.isRemoved(profileURL: $0.appendingPathComponent("profile.json")) }
            .map { try FileMCPProfileSource(url: $0.appendingPathComponent("profile.json")).load() }
    }

    public func revoke(_ id: UUID) throws {
        _ = try setAccess(false, for: id)
    }

    private func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw MCPAccessError.configuration }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
