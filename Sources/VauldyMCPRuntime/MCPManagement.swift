import CryptoKit
import Darwin
import Foundation

public enum MCPSetupSection: String, CaseIterable, Codable, Sendable {
    case overview, connections, documents, folders, oauth, settings
    public var title: String {
        switch self {
        case .overview: "Übersicht"
        case .connections: "Verbindungen"
        case .documents: "Dokumente"
        case .folders: "Ordner"
        case .oauth: "ChatGPT & Claude"
        case .settings: "Einstellungen"
        }
    }
    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .connections: "bubble.left.and.bubble.right"
        case .documents: "doc.on.doc"
        case .folders: "folder"
        case .oauth: "link.badge.plus"
        case .settings: "slider.horizontal.3"
        }
    }
}

public struct MCPSetupRequest: Codable, Sendable {
    public var section: MCPSetupSection
    public var connectionID: UUID?
    public var diagnose: Bool?
    public var createdAt: Date
    public init(section: MCPSetupSection, connectionID: UUID? = nil, diagnose: Bool = false) {
        self.section = section; self.connectionID = connectionID; self.diagnose = diagnose; createdAt = Date()
    }
}

public enum MCPSoftwareState: String, Sendable { case notInstalled, updateAvailable, current }

public struct MCPSoftwareStatus: Sendable {
    public var state: MCPSoftwareState
    public var installedVersion: String?
    public var availableVersion: String
    public var installedBuildID: String?
    public var availableBuildID: String?
    public var canRollback: Bool
    public init(state: MCPSoftwareState, installedVersion: String?, availableVersion: String = MCPBuild.version, canRollback: Bool = false, installedBuildID: String? = nil, availableBuildID: String? = nil) {
        self.state = state; self.installedVersion = installedVersion; self.availableVersion = availableVersion; self.canRollback = canRollback
        self.installedBuildID = installedBuildID; self.availableBuildID = availableBuildID
    }
}

/// Serializes local access changes across the setup UI and menu agent. Never used through MCP arguments.
struct MCPManagementLock {
    let descriptor: Int32
    init(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MCPAccessError.configuration }
        guard flock(fd, LOCK_EX) == 0 else { close(fd); throw MCPAccessError.configuration }
        descriptor = fd
    }
    func release() { flock(descriptor, LOCK_UN); close(descriptor) }
}

extension MCPInstallation {
    public var setupAppURL: URL {
        let managed = softwareDirectory.appendingPathComponent(Self.setupBundleName, isDirectory: true)
        return FileManager.default.fileExists(atPath: managed.path) ? managed
            : root.appendingPathComponent(Self.setupBundleName, isDirectory: true)
    }

    @discardableResult
    public func setAccess(_ enabled: Bool, for id: UUID, expectedRevision: UUID? = nil) throws -> MCPAccessProfile {
        try changeProfile(id, expectedRevision: expectedRevision) { value in
            value.enabled = enabled
            // Resuming cannot invent an acknowledgment or a document grant.
            try value.validate()
        }
    }

    @discardableResult
    public func updateSelection(_ ids: Set<UUID>, for id: UUID, expectedRevision: UUID,
                                acknowledgedDisclosure: Bool = false, expectedFingerprint: String? = nil) throws -> MCPAccessProfile {
        try changeProfile(id, expectedRevision: expectedRevision) { value in
            if let expectedFingerprint { guard try value.disclosureFingerprint() == expectedFingerprint else { throw MCPAccessError.stale } }
            guard ids.isSubset(of: value.allowedDocumentIDs) || acknowledgedDisclosure else { throw MCPAccessError.notAuthorized }
            if acknowledgedDisclosure { value.acknowledgedCloudDisclosure = true }
            value.allowedDocumentIDs = ids
            if ids.isEmpty { value.enabled = false }
            // Preserve paused access when a selection is saved, including an expanded selection.
            try value.validate()
        }
    }

    /// Remove active access, retaining the disabled connection history locally.
    /// Neither the vault nor client configuration is owned by this operation.
    @discardableResult
    public func removeConnection(_ id: UUID, expectedRevision: UUID) throws -> URL {
        let path = profileURL(id), directory = path.deletingLastPathComponent()
        let archive = removedConnectionsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        for url in [root, connectionsURL, directory, removedConnectionsURL, archive] {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw MCPAccessError.configuration }
        }
        if FileManager.default.fileExists(atPath: archive.path) {
            let old = try FileMCPProfileSource(url: archive.appendingPathComponent("profile.json")).load()
            guard old.connectionID == id, !old.enabled else { throw MCPAccessError.configuration }
            return archive
        }
        let lock = try MCPManagementLock(directory.appendingPathComponent("profile-update.lock"))
        defer { lock.release() }
        let source = FileMCPProfileSource(url: path)
        var profile = try source.load()
        guard profile.revision == expectedRevision, profile.connectionID == id else { throw MCPAccessError.stale }
        let vault = URL(fileURLWithPath: profile.vaultPath).resolvingSymlinksInPath().path
        let ownedDirectory = directory.resolvingSymlinksInPath().path
        guard vault != ownedDirectory, !vault.hasPrefix(ownedDirectory + "/") else { throw MCPAccessError.configuration }
        guard (try? removedConnectionsURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw MCPAccessError.configuration }
        try FileManager.default.createDirectory(at: removedConnectionsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: archive.path) else { throw MCPAccessError.stale }
        profile.enabled = false; profile.revision = UUID()
        try source.save(profile)
        try MCPAuditLog(profileURL: path).append(.profileRemoved, count: 0, revision: profile.revision)
        try FileManager.default.moveItem(at: directory, to: archive)
        return archive
    }

    private func changeProfile(_ id: UUID, expectedRevision: UUID?, mutation: (inout MCPAccessProfile) throws -> Void) throws -> MCPAccessProfile {
        let path = profileURL(id)
        let lock = try MCPManagementLock(path.deletingLastPathComponent().appendingPathComponent("profile-update.lock"))
        defer { lock.release() }
        let source = FileMCPProfileSource(url: path)
        var profile = try source.load()
        guard expectedRevision == nil || profile.revision == expectedRevision else { throw MCPAccessError.stale }
        try mutation(&profile)
        profile.revision = UUID()
        try source.save(profile)
        try MCPAuditLog(profileURL: path).append(profile.enabled ? .profileSaved : .profilePaused,
                                               count: profile.enabled ? profile.allowedDocumentIDs.count : 0, revision: profile.revision)
        return profile
    }

    /// Separate from installation/consent. No profile or client configuration is rewritten.
    func updateSoftware(binary: URL, localCLI: URL? = nil, statusApp: URL? = nil, setupApp: URL? = nil) throws {
        guard binary.isFileURL, FileManager.default.isExecutableFile(atPath: binary.path) else { throw MCPAccessError.configuration }
        try prepareSoftwareDirectories()
        let lock = try MCPManagementLock(root.appendingPathComponent("software-update.lock"))
        defer { lock.release() }
        guard try softwareGeneration() == nil else { throw MCPUpdateError.compatibility }
        if let localCLI {
            guard FileManager.default.isExecutableFile(atPath: localCLI.path) else { throw MCPAccessError.configuration }
        }
        if let statusApp { try validateStatusApp(statusApp) }
        let replacementSetup = setupApp.flatMap { $0.standardizedFileURL == setupAppURL.standardizedFileURL ? nil : $0 }
        if let replacementSetup {
            guard Bundle(url: replacementSetup)?.bundleIdentifier == "com.marcomeisen.vauldy.mcp-setup" else { throw MCPAccessError.configuration }
        }
        try copySoftware(binary: binary, localCLI: localCLI, statusApp: statusApp)
        if let replacementSetup { try replaceBundle(replacementSetup, at: setupAppURL) }
        struct Manifest: Codable { let version: String; let serverHash: String }
        let manifest = Manifest(version: MCPBuild.version, serverHash: try Self.hash(binaryURL))
        try writeManaged(JSONEncoder().encode(manifest), to: root.appendingPathComponent("software.json"))
    }

    public func softwareStatus(availableBinary: URL, localCLI: URL? = nil, statusApp: URL? = nil, setupApp: URL? = nil) throws -> MCPSoftwareStatus {
        guard FileManager.default.fileExists(atPath: binaryURL.path) else { return .init(state: .notInstalled, installedVersion: nil, availableBuildID: MCPBuildIdentity.read(availableBinary)) }
        let hash = try Self.hash(binaryURL)
        let generation = try softwareGeneration()
        var current = hash == (try Self.hash(availableBinary))
        var pairs: [(URL, URL)] = []
        let http = availableBinary.deletingLastPathComponent().appendingPathComponent("vauldy-mcp-http")
        if FileManager.default.isExecutableFile(atPath: http.path) { pairs.append((httpServerURL, http)) }
        let relay = availableBinary.deletingLastPathComponent().appendingPathComponent("vauldy-relay")
        if FileManager.default.isExecutableFile(atPath: relay.path) { pairs.append((binaryURL.deletingLastPathComponent().appendingPathComponent("vauldy-relay"), relay)) }
        if let localCLI { pairs.append((localCLIURL, localCLI)) }
        if let statusApp { pairs.append((statusAppURL.appendingPathComponent("Contents/MacOS/vauldy-mcp-status"), statusApp.appendingPathComponent("Contents/MacOS/vauldy-mcp-status"))) }
        if let setupApp {
            let installed = setupAppURL
            let executable = "Contents/MacOS/vauldy-mcp-setup"
            pairs.append((installed.appendingPathComponent(executable), setupApp.appendingPathComponent(executable)))
            let seal = "Contents/_CodeSignature/CodeResources"
            let availableSeal = setupApp.appendingPathComponent(seal)
            if FileManager.default.fileExists(atPath: availableSeal.path) {
                pairs.append((installed.appendingPathComponent(seal), availableSeal))
            }
        }
        for (installed, available) in pairs {
            if !FileManager.default.fileExists(atPath: installed.path) { current = false }
            else if try Self.hash(installed) != Self.hash(available) { current = false }
        }
        let version = generation?.version ?? (try? recordedSoftwareVersion())
        return .init(state: current ? .current : .updateAvailable,
                     installedVersion: version ?? (current ? MCPBuild.version : nil), canRollback: hasSoftwareRollback, installedBuildID: MCPBuildIdentity.read(binaryURL),
                     availableBuildID: MCPBuildIdentity.read(availableBinary))
    }

    func recordedSoftwareVersion() throws -> String? {
        struct Manifest: Decodable { let version: String; let serverHash: String }
        let url = root.appendingPathComponent("software.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let manifest = try JSONDecoder().decode(Manifest.self, from: readManaged(url, limit: 4_096))
        guard try manifest.serverHash == Self.hash(binaryURL) else { throw MCPUpdateError.compatibility }
        return manifest.version
    }

    public func requestSetup(_ request: MCPSetupRequest) throws {
        try prepareSoftwareDirectories()
        let lock = try MCPManagementLock(root.appendingPathComponent("setup-request.lock"))
        defer { lock.release() }
        try writeManaged(JSONEncoder().encode(request), to: root.appendingPathComponent("setup-request.json"))
    }

    public func consumeSetupRequest() throws -> MCPSetupRequest? {
        let url = root.appendingPathComponent("setup-request.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let lock = try MCPManagementLock(root.appendingPathComponent("setup-request.lock"))
        defer { lock.release() }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = try JSONDecoder().decode(MCPSetupRequest.self, from: readManaged(url, limit: 4_096))
        try FileManager.default.removeItem(at: url)
        guard abs(request.createdAt.timeIntervalSinceNow) <= 300 else { return nil }
        return request
    }

    static func hash(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 100 * 1_024 * 1_024 else { throw MCPAccessError.configuration }
        return SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    func readManaged(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= limit else { throw MCPAccessError.configuration }
        return try Data(contentsOf: url)
    }
    private func writeManaged(_ data: Data, to url: URL) throws {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw MCPAccessError.configuration }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
