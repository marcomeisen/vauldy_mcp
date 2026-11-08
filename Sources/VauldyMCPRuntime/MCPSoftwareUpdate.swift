import Darwin
import Foundation
import Security

public enum MCPUpdateError: LocalizedError, Equatable {
    case signature, compatibility, unexpectedSoftwareEntry, changedCompanionFiles, downgrade, noRollback, interrupted, startup

    public var errorDescription: String? {
        switch self {
        case .signature: "Die Signatur oder Integrität des Softwarepakets konnte nicht bestätigt werden."
        case .compatibility: "Das Softwarepaket passt nicht zur lokalen Installation oder zum Datenformat. Öffne die aktuelle vollständige Vauldy-Einrichtung und aktualisiere daraus. Bei einem Rückweg nur die geprüfte Vorversion verwenden; Profile und Bestand nicht löschen."
        case .unexpectedSoftwareEntry: "Der lokale Programmordner enthält fremde oder unsichere Einträge. Die Software wurde nicht gewechselt."
        case .changedCompanionFiles: "Die Begleitdateien im lokalen Programmordner stimmen nicht überein. Die Software wurde nicht gewechselt."
        case .downgrade: "Für eine ältere Version verwende die gesicherte Vorversion."
        case .noRollback: "Es ist keine geprüfte Vorversion verfügbar."
        case .startup: "Der lokale Server hat die Startprüfung nicht bestanden."
        case .interrupted: "Der Programmsatz konnte nicht gewechselt werden. Bitte prüfe die Software erneut."
        }
    }
}

extension MCPInstallation {
    static let setupBundleName = "Vauldy MCP Einrichtung.app"
    var softwareDirectory: URL { binaryURL.deletingLastPathComponent() }

    /// Activates a complete signed bundle from a private copy. The stable bin paths are preserved.
    @discardableResult
    public func updateSoftware(fromApp app: URL, allowAdHoc: Bool = false) throws -> String {
        try prepareSoftwareDirectories()
        let lock = try MCPManagementLock(root.appendingPathComponent("software-update.lock"))
        defer { lock.release() }
        let trust = try MCPUpdateTrust(allowAdHoc: allowAdHoc)
        let prior = try softwareGeneration()
        let slot = UUID()
        let staging = softwareSlot(slot)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: staging) } }

        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let stagedApp = staging.appendingPathComponent(Self.setupBundleName)
        try MCPRelease.checkTree(app)
        try FileManager.default.copyItem(at: app, to: stagedApp)
        let release = try MCPRelease(app: stagedApp, trust: trust)
        let installedVersion = try prior?.version ?? recordedSoftwareVersion()
        if let installedVersion {
            guard let version = MCPRelease.versionParts(installedVersion) else { throw MCPUpdateError.compatibility }
            guard !release.versionParts.lexicographicallyPrecedes(version) else { throw MCPUpdateError.downgrade }
        }
        if let prior {
            let current = try checkedGeneration(in: softwareDirectory, state: prior, trust: trust, allowPreviousEpoch: true)
            if current.signature == release.signature {
                try probeSoftware(binaryURL, release)
                removeObsoleteSlots(keeping: prior.previous)
                return release.version
            }
        } else if FileManager.default.fileExists(atPath: binaryURL.path) {
            _ = try trust.validate(binaryURL)
        }
        for file in try softwareCompanionFiles(in: softwareDirectory).values {
            _ = try Self.hash(file)
            try FileManager.default.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
        }
        for product in MCPRelease.installedProducts {
            try FileManager.default.copyItem(at: release.resources.appendingPathComponent(product),
                                             to: staging.appendingPathComponent(product))
        }
        let generation = MCPSoftwareGeneration(version: release.version, signature: release.signature,
                                               previous: prior == nil ? nil : slot)
        try writeSoftwareGeneration(generation, in: staging)
        try probeSoftware(staging.appendingPathComponent("vauldy-mcp"), release)
        try syncSoftwareTree(staging)
        guard try softwareCompanionFilesMatch(staging) else { throw MCPUpdateError.changedCompanionFiles }
        try exchangeSoftware(with: staging)
        retained = true
        do {
            try probeSoftware(binaryURL, release)
        } catch {
            try exchangeSoftware(with: staging)
            retained = false
            throw error
        }
        removeObsoleteSlots(keeping: generation.previous)
        return release.version
    }

    /// A rollback can only use the authenticated and compatible generation retained by activation.
    @discardableResult
    public func rollbackSoftware(allowAdHoc: Bool = false) throws -> String {
        try prepareSoftwareDirectories()
        let lock = try MCPManagementLock(root.appendingPathComponent("software-update.lock"))
        defer { lock.release() }
        guard let current = try softwareGeneration(), let slot = current.previous else { throw MCPUpdateError.noRollback }
        let previousDirectory = softwareSlot(slot)
        guard let previous = try softwareGeneration(in: previousDirectory) else { throw MCPUpdateError.noRollback }
        let trust = try MCPUpdateTrust(allowAdHoc: allowAdHoc)
        let release = try checkedGeneration(in: previousDirectory, state: previous, trust: trust)
        guard let currentVersion = MCPRelease.versionParts(current.version),
              !currentVersion.lexicographicallyPrecedes(release.versionParts) else { throw MCPUpdateError.compatibility }
        try probeSoftware(previousDirectory.appendingPathComponent("vauldy-mcp"), release)
        guard try softwareCompanionFilesMatch(previousDirectory) else { throw MCPUpdateError.changedCompanionFiles }
        if previous.previous != nil {
            try writeSoftwareGeneration(.init(version: previous.version, signature: previous.signature, previous: nil),
                                        in: previousDirectory)
            try syncSoftwareFile(previousDirectory)
        }
        try exchangeSoftware(with: previousDirectory)
        do { try probeSoftware(binaryURL, release) }
        catch {
            try exchangeSoftware(with: previousDirectory)
            throw error
        }
        removeObsoleteSlots(keeping: nil)
        return release.version
    }

    var hasSoftwareRollback: Bool {
        guard let state = try? softwareGeneration(), let slot = state.previous else { return false }
        let directory = softwareSlot(slot)
        guard (try? softwareGeneration(in: directory)) != nil,
              let data = try? readManaged(directory.appendingPathComponent(Self.setupBundleName + "/Contents/Resources/release.json"), limit: 16_384),
              let manifest = try? JSONDecoder().decode(MCPRelease.Manifest.self, from: data) else { return false }
        return manifest.softwareCompatibilityEpoch == MCPBuild.softwareCompatibilityEpoch
    }

    private func softwareSlot(_ id: UUID) -> URL {
        root.appendingPathComponent(".software-slot-" + id.uuidString, isDirectory: true)
    }

    private func exchangeSoftware(with slot: URL) throws {
        guard renameatx_np(AT_FDCWD, softwareDirectory.path, AT_FDCWD, slot.path, UInt32(RENAME_SWAP)) == 0
        else { throw MCPUpdateError.interrupted }
        // Both names share a parent. Failure to flush after the commit cannot undo the exchange.
        try? syncSoftwareFile(root)
    }

    private func removeObsoleteSlots(keeping id: UUID?) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let prefix = ".software-slot-"
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            guard let slot = UUID(uuidString: String(entry.lastPathComponent.dropFirst(prefix.count))),
                  entry.lastPathComponent == softwareSlot(slot).lastPathComponent, slot != id else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func softwareGeneration(in directory: URL? = nil) throws -> MCPSoftwareGeneration? {
        let dir = directory ?? softwareDirectory
        let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false else { return nil }
        let url = dir.appendingPathComponent(MCPSoftwareGeneration.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try readManaged(url, limit: 4_096)
        return try JSONDecoder().decode(MCPSoftwareGeneration.self, from: data)
    }

    private func writeSoftwareGeneration(_ state: MCPSoftwareGeneration, in directory: URL) throws {
        let url = directory.appendingPathComponent(MCPSoftwareGeneration.fileName)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try syncSoftwareFile(url)
    }

    private func checkedGeneration(in directory: URL, state: MCPSoftwareGeneration,
                                   trust: MCPUpdateTrust, allowPreviousEpoch: Bool = false) throws -> MCPRelease {
        _ = try softwareCompanionFiles(in: directory)
        let release = try MCPRelease(app: directory.appendingPathComponent(Self.setupBundleName), trust: trust, allowPreviousEpoch: allowPreviousEpoch)
        guard release.version == state.version, release.signature == state.signature else { throw MCPUpdateError.signature }
        for product in MCPRelease.installedProducts {
            let installed = directory.appendingPathComponent(product)
            let source = release.resources.appendingPathComponent(product)
            if product == MCPStatusApp.bundleName {
                try MCPRelease.checkTree(installed)
                guard try trust.validate(installed, identifier: MCPRelease.statusIdentifier)
                        == trust.validate(source, identifier: MCPRelease.statusIdentifier) else { throw MCPUpdateError.signature }
            } else {
                guard try Self.hash(installed) == Self.hash(source) else { throw MCPUpdateError.signature }
            }
        }
        return release
    }

    private func softwareCompanionFiles(in directory: URL) throws -> [String: URL] {
        let owned = Set(MCPRelease.installedProducts + [Self.setupBundleName,
                                                         MCPSoftwareGeneration.fileName])
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        let backupPrefix = "vauldy-mcp.before-init-compatibility-"
        var companions: [String: URL] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            let properties = try entry.resourceValues(forKeys: keys)
            guard properties.isSymbolicLink == false else { throw MCPUpdateError.unexpectedSoftwareEntry }
            if owned.contains(name) { continue }
            guard properties.isRegularFile == true else { throw MCPUpdateError.unexpectedSoftwareEntry }
            // Finder may recreate this file at any time. It is not part of the program set.
            if name == ".DS_Store" { continue }
            let date = name.utf8.dropFirst(backupPrefix.utf8.count)
            let isLegacyBackup = name.hasPrefix(backupPrefix) && date.count == 8 && date.allSatisfy { (48...57).contains($0) }
            guard name == "tunnel-client" || isLegacyBackup else { throw MCPUpdateError.unexpectedSoftwareEntry }
            companions[name] = entry
        }
        return companions
    }

    private func softwareCompanionFilesMatch(_ other: URL) throws -> Bool {
        let current = try softwareCompanionFiles(in: softwareDirectory)
        let candidate = try softwareCompanionFiles(in: other)
        guard current.count == candidate.count else { return false }
        let fm = FileManager.default
        for (name, file) in current {
            guard let copy = candidate[name], try Self.hash(file) == Self.hash(copy),
                  try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                      == fm.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber
            else { return false }
        }
        return true
    }

    private func probeSoftware(_ binary: URL, _ release: MCPRelease) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-update-probe-\(UUID())")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let vault = temp.appendingPathComponent("snapshot.json")
        try Data("[]".utf8).write(to: vault)
        let profile = temp.appendingPathComponent("profile.json")
        try FileMCPProfileSource(url: profile).save(.init(vaultPath: vault.path, enabled: false))
        guard let result = try? MCPLocalProbe.run(binary: binary, profile: profile, expectedVersion: release.version),
              result.serverVersion == release.version,
              release.serverBuildID == nil || result.serverBuildID == release.serverBuildID,
              release.declaredTools == nil || result.discoveredTools == release.declaredTools?.sorted(),
              !result.accessEnabled, result.grantedDocuments == 0 else { throw MCPUpdateError.startup }
    }

    private func syncSoftwareTree(_ directory: URL) throws {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw MCPUpdateError.interrupted
        }
        for case let entry as URL in entries { try syncSoftwareFile(entry) }
        try syncSoftwareFile(directory)
    }

    private func syncSoftwareFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw MCPUpdateError.interrupted }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw MCPUpdateError.interrupted }
    }
}

struct MCPSoftwareGeneration: Codable {
    static let fileName = ".vauldy-generation.json"
    let version: String
    let signature: Data
    let previous: UUID?
}

private struct MCPRelease {
    static let setupIdentifier = "com.marcomeisen.vauldy.mcp-setup"
    static let statusIdentifier = "com.marcomeisen.vauldy.mcp-status"
    static let installedProducts = ["vauldy-mcp", "vauldy-local", "vauldy-mcp-http", "vauldy-relay", MCPStatusApp.bundleName]
    let version: String
    let versionParts: [Int]
    let signature: Data
    let resources: URL
    let serverBuildID: String?
    let declaredTools: [String]?

    fileprivate struct Manifest: Decodable {
        let manifestVersion: Int
        let productVersion: String
        let softwareCompatibilityEpoch: Int
        let serverBuildID: String?
        let tools: [String]?
    }

    init(app: URL, trust: MCPUpdateTrust, allowPreviousEpoch: Bool = false) throws {
        try Self.checkTree(app)
        signature = try trust.validate(app, identifier: Self.setupIdentifier)
        resources = app.appendingPathComponent("Contents/Resources")
        let manifestURL = resources.appendingPathComponent("release.json")
        let manifestData = try FileHandle(forReadingFrom: manifestURL)
        defer { try? manifestData.close() }
        guard let data = try manifestData.read(upToCount: 16_385), data.count <= 16_384,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.manifestVersion == 1,
              (manifest.softwareCompatibilityEpoch == MCPBuild.softwareCompatibilityEpoch
                || (allowPreviousEpoch && MCPBuild.softwareCompatibilityEpoch == 2 && manifest.softwareCompatibilityEpoch == 1)),
              let parts = Self.versionParts(manifest.productVersion),
              let bundle = Bundle(url: app), bundle.bundleIdentifier == Self.setupIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "vauldy-mcp-setup",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == manifest.productVersion
        else { throw MCPUpdateError.compatibility }
        serverBuildID = manifest.serverBuildID; declaredTools = manifest.tools
        if let serverBuildID {
            guard serverBuildID == MCPBuildIdentity.read(resources.appendingPathComponent("vauldy-mcp")),
                  let declaredTools, declaredTools.count <= 128, Set(declaredTools).count == declaredTools.count,
                  MCPToolRequirements.baseline.isSubset(of: Set(declaredTools)) else { throw MCPUpdateError.compatibility }
        } else if declaredTools != nil { throw MCPUpdateError.compatibility }
        version = manifest.productVersion
        versionParts = parts
        for name in Self.installedProducts {
            let url = resources.appendingPathComponent(name)
            if name == MCPStatusApp.bundleName {
                guard let status = Bundle(url: url), status.bundleIdentifier == Self.statusIdentifier,
                      status.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "vauldy-mcp-status",
                      status.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
                else { throw MCPUpdateError.compatibility }
                _ = try trust.validate(url, identifier: Self.statusIdentifier)
            } else {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                      FileManager.default.isExecutableFile(atPath: url.path) else { throw MCPUpdateError.compatibility }
                _ = try trust.validate(url)
            }
        }
    }

    static func versionParts(_ version: String) -> [Int]? {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard fields.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }),
              numbers.map(String.init).joined(separator: ".") == version else { return nil }
        return numbers
    }

    static func checkTree(_ app: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let root = try app.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink == false else { throw MCPUpdateError.compatibility }
        var unreadable = false
        guard let entries = FileManager.default.enumerator(at: app, includingPropertiesForKeys: Array(keys),
                                                            errorHandler: { _, _ in unreadable = true; return false })
        else { throw MCPUpdateError.compatibility }
        var count = 0
        var bytes = 0
        for case let entry as URL in entries {
            let value = try entry.resourceValues(forKeys: keys)
            count += 1
            bytes += value.fileSize ?? 0
            guard value.isSymbolicLink == false, value.isRegularFile == true || value.isDirectory == true,
                  count <= 512, bytes <= 300 * 1_024 * 1_024 else { throw MCPUpdateError.compatibility }
        }
        guard !unreadable else { throw MCPUpdateError.compatibility }
    }
}

private struct MCPUpdateTrust {
    private let team: String?
    private static let strict = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode))

    init(allowAdHoc: Bool) throws {
        var running: SecCode?
        var ownCode: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &ownCode) == errSecSuccess, let ownCode
        else { throw MCPUpdateError.signature }
        let info = try Self.signingInfo(ownCode)
        team = info[kSecCodeInfoTeamIdentifier as String] as? String
        if let team {
            guard team.utf8.count == 10,
                  team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
                  SecStaticCodeCheckValidity(ownCode, Self.strict, try Self.requirement(team: team, identifier: nil)) == errSecSuccess
            else { throw MCPUpdateError.signature }
        } else {
            guard allowAdHoc, Self.isAdHoc(info) else { throw MCPUpdateError.signature }
        }
    }

    func validate(_ url: URL, identifier: String? = nil) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
        else { throw MCPUpdateError.signature }
        let requirement = try team.map { try Self.requirement(team: $0, identifier: identifier) }
        guard SecStaticCodeCheckValidity(code, Self.strict, requirement) == errSecSuccess
        else { throw MCPUpdateError.signature }
        let info = try Self.signingInfo(code)
        guard team != nil || Self.isAdHoc(info),
              identifier == nil || info[kSecCodeInfoIdentifier as String] as? String == identifier,
              let signature = info[kSecCodeInfoUnique as String] as? Data
        else { throw MCPUpdateError.signature }
        return signature
    }

    private static func requirement(team: String, identifier: String?) throws -> SecRequirement {
        // Developer ID Application requirement per Apple TN3127, pinned to this updater's team.
        var expression = """
        anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "\(team)"
        """
        if let identifier { expression += " and identifier \"\(identifier)\"" }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement
        else { throw MCPUpdateError.signature }
        return requirement
    }

    private static func signingInfo(_ code: SecStaticCode) throws -> [String: Any] {
        var dictionary: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, flags, &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any] else { throw MCPUpdateError.signature }
        return info
    }

    private static func isAdHoc(_ info: [String: Any]) -> Bool {
        guard let flags = info[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return flags.uint32Value & 0x0002 != 0 // CS_ADHOC in the CodeDirectory
    }
}
