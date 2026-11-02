import Darwin
import Foundation

public enum MCPDesktopClient: String, CaseIterable, Codable, Sendable {
    case chatgpt, claude
    public var title: String { self == .chatgpt ? "ChatGPT Desktop" : "Claude Desktop" }
}

public enum MCPClientBinding: String, Sendable { case registered, notRegistered, conflict, unavailable }

public enum MCPRegistrationError: LocalizedError {
    case clientMissing, invalidConfiguration, conflict, changed, processFailed
    public var errorDescription: String? {
        switch self {
        case .clientMissing: "Die ChatGPT-Desktop-App mit lokaler MCP-Unterstützung wurde nicht gefunden. Bitte installieren oder die manuelle Konfiguration verwenden."
        case .invalidConfiguration: "Die Client-Konfiguration ist nicht lesbar, beschädigt oder verknüpft. Sie wurde nicht ersetzt."
        case .conflict: "Im Client existiert bereits ein anderer oder deaktivierter Eintrag „vauldy“. Bitte diesen dort prüfen und bei Bedarf entfernen; er wurde nicht überschrieben."
        case .changed: "Die Client-Konfiguration wurde während der Einrichtung geändert. Bitte erneut verbinden."
        case .processFailed: "Die ChatGPT-Konfiguration konnte nicht geprüft werden. Bitte die Desktop-App aktualisieren oder die manuelle Konfiguration verwenden."
        }
    }
}

/// Explicit, local client registration. Never changes the disclosure profile or starts a chatbot.
public struct MCPClientRegistration: Sendable {
    public let home: URL
    public let chatGPTCLI: URL?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, chatGPTCLI: URL? = nil) {
        self.home = home.resolvingSymlinksInPath()
        self.chatGPTCLI = chatGPTCLI ?? Self.findChatGPTCLI(home: home)
    }

    public static func findChatGPTCLI(home: URL) -> URL? {
        let suffix = "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        return [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            .map { $0.appendingPathComponent(suffix) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func configurationURL(for client: MCPDesktopClient) -> URL {
        home.appendingPathComponent(client == .chatgpt ? ".codex/config.toml" : "Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Read-only verification, including paused grants. A stored client hint is not a verified binding.
    public func binding(_ client: MCPDesktopClient, binary: URL, profile: URL) throws -> MCPClientBinding {
        let url = configurationURL(for: client)
        let data = try readConfiguration(url)
        guard let data else { return .notRegistered }
        let args = ["--profile", profile.path]
        if client == .claude {
            guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  config["mcpServers"] == nil || config["mcpServers"] is [String: Any] else { throw MCPRegistrationError.invalidConfiguration }
            guard let entry = (config["mcpServers"] as? [String: Any])?["vauldy"] else { return .notRegistered }
            let expected: [String: Any] = ["command": binary.path, "args": args]
            return (entry as? NSDictionary)?.isEqual(to: expected) == true ? .registered : .conflict
        }
        guard let chatGPTCLI else { return .unavailable }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-binding-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        try privateWrite(data, to: stage.appendingPathComponent("config.toml"))
        guard let entry = try clientEntries(cli: chatGPTCLI, stage: stage).first(where: { $0["name"] as? String == "vauldy" }) else { return .notRegistered }
        return matches(entry, command: binary.path, args: args) ? .registered : .conflict
    }

    /// Returns false for an already matching entry. A different entry is a visible conflict.
    @discardableResult
    public func register(_ client: MCPDesktopClient, binary: URL, profile: URL) throws -> Bool {
        let grant = try FileMCPProfileSource(url: profile).load()
        guard grant.enabled else { throw MCPAccessError.notAuthorized }
        guard binary.isFileURL, profile.isFileURL,
              FileManager.default.isExecutableFile(atPath: binary.path) else { throw MCPAccessError.configuration }
        if client == .chatgpt && chatGPTCLI == nil { throw MCPRegistrationError.clientMissing }
        let destination = configurationURL(for: client)
        try checkPath(destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // Serializes our installers; also compare bytes to catch independent client edits.
        let lock = destination.deletingLastPathComponent().appendingPathComponent(".vauldy-registration.lock")
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MCPRegistrationError.invalidConfiguration }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MCPRegistrationError.changed }
        let before = try readConfiguration(destination)
        let args = ["--profile", profile.path]
        let updated: Data?
        switch client {
        case .claude: updated = try claudeConfiguration(before, command: binary.path, args: args)
        case .chatgpt: updated = try chatGPTConfiguration(before, command: binary.path, args: args)
        }
        guard let updated else { return false }
        guard try readConfiguration(destination) == before else { throw MCPRegistrationError.changed }
        if let before {
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent(destination.lastPathComponent + ".vauldy-backup-" + UUID().uuidString)
            try privateWrite(before, to: backup)
        }
        // Do not overwrite an edit made while the backup was written.
        guard try readConfiguration(destination) == before else { throw MCPRegistrationError.changed }
        try privateWrite(updated, to: destination)
        try MCPAuditLog(profileURL: profile).append(.clientRegistered, operation: client == .chatgpt ? .chatgpt : .claude, revision: grant.revision)
        return true
    }

    private func claudeConfiguration(_ data: Data?, command: String, args: [String]) throws -> Data? {
        var object: [String: Any]
        if let data {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPRegistrationError.invalidConfiguration
            }
            object = parsed
        } else { object = [:] }
        guard object["mcpServers"] == nil || object["mcpServers"] is [String: Any] else {
            throw MCPRegistrationError.invalidConfiguration
        }
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        let entry: [String: Any] = ["command": command, "args": args]
        if let existing = servers["vauldy"] {
            guard let existing = existing as? NSDictionary, existing.isEqual(to: entry) else { throw MCPRegistrationError.conflict }
            return nil
        }
        servers["vauldy"] = entry; object["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func chatGPTConfiguration(_ data: Data?, command: String, args: [String]) throws -> Data? {
        guard let chatGPTCLI else { throw MCPRegistrationError.clientMissing }
        // Use the client's TOML parser in an isolated home. Never let its config writer normalize
        // unrelated user settings. The final change only appends a validated new table.
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-client-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let config = stage.appendingPathComponent("config.toml")
        try privateWrite(data ?? Data(), to: config)
        let entries = try clientEntries(cli: chatGPTCLI, stage: stage)
        if let existing = entries.first(where: { $0["name"] as? String == "vauldy" }) {
            guard matches(existing, command: command, args: args) else { throw MCPRegistrationError.conflict }
            return nil
        }
        func quoted(_ value: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        let table = try "\n[mcp_servers.vauldy]\ncommand = \(quoted(command))\nargs = [\(args.map { try quoted($0) }.joined(separator: ", "))]\n"
        var result = data ?? Data(); result.append(Data(table.utf8))
        try privateWrite(result, to: config)
        let verified = try clientEntries(cli: chatGPTCLI, stage: stage)
        guard let entry = verified.first(where: { $0["name"] as? String == "vauldy" }),
              matches(entry, command: command, args: args) else { throw MCPRegistrationError.processFailed }
        return result
    }

    private func matches(_ entry: [String: Any], command: String, args: [String]) -> Bool {
        guard let transport = entry["transport"] as? [String: Any] else { return false }
        func empty(_ value: Any?) -> Bool {
            value == nil || value is NSNull || (value as? [String: String])?.isEmpty == true || (value as? [String])?.isEmpty == true
        }
        return entry["enabled"] as? Bool == true && transport["type"] as? String == "stdio"
            && transport["command"] as? String == command && transport["args"] as? [String] == args
            && empty(transport["env"]) && empty(transport["env_vars"]) && empty(transport["cwd"])
            && empty(entry["enabled_tools"]) && empty(entry["disabled_tools"])
    }

    private func clientEntries(cli: URL, stage: URL) throws -> [[String: Any]] {
        let output = stage.appendingPathComponent("output.json")
        try privateWrite(Data(), to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = cli; process.arguments = ["mcp", "list", "--json"]
        process.currentDirectoryURL = stage
        process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": stage.path]) { _, staged in staged }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw MCPRegistrationError.processFailed }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            if ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 4_000_000 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let bytes = try readConfiguration(output),
              let entries = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else {
            throw MCPRegistrationError.processFailed
        }
        return entries
    }

    private func readConfiguration(_ url: URL) throws -> Data? {
        try checkPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 4_000_000 else { throw MCPRegistrationError.invalidConfiguration }
        return try Data(contentsOf: url)
    }

    private func checkPath(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw MCPRegistrationError.invalidConfiguration
            }
            if current.standardizedFileURL == home.standardizedFileURL ||
                current.standardizedFileURL == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL { break }
            current.deleteLastPathComponent()
        }
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".vauldy-write-\(UUID())")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MCPRegistrationError.invalidConfiguration }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: data); try file.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw MCPRegistrationError.invalidConfiguration }
    }
}
