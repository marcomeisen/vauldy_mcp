import Foundation
import CryptoKit
import VauldyCore

/// Local presentation preferences. These values never authorize document access.
public struct MCPLocalDocumentChoices: Sendable {
    public let installation: MCPInstallation
    public init(installation: MCPInstallation) { self.installation = installation }

    public static func fingerprint(_ document: VaultDocument) -> String {
        document.localImport?.contentHash
            ?? SHA256.hash(data: Data(document.ocrText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func load(for connectionID: UUID) throws -> [UUID: String] {
        let url = file(for: connectionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])).isSymbolicLink != true,
              ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 4_000_000 else { throw MCPAccessError.configuration }
        return try JSONDecoder().decode([UUID: String].self, from: Data(contentsOf: url))
    }

    public func keepLocal(_ documents: [VaultDocument], for profile: MCPAccessProfile) throws {
        let directory = installation.profileURL(profile.connectionID).deletingLastPathComponent()
        let lock = try MCPManagementLock(directory.appendingPathComponent("local-choices.lock"))
        defer { lock.release() }
        let current = try FileMCPProfileSource(url: installation.profileURL(profile.connectionID)).load()
        guard current.revision == profile.revision else { throw MCPAccessError.stale }
        var choices = try load(for: profile.connectionID)
        for document in documents where !current.allowedDocumentIDs.contains(document.id) {
            choices[document.id] = Self.fingerprint(document)
        }
        guard choices.count <= 20_000 else { throw MCPAccessError.tooLarge }
        let url = file(for: profile.connectionID)
        try JSONEncoder().encode(choices).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func file(for connectionID: UUID) -> URL {
        installation.profileURL(connectionID).deletingLastPathComponent().appendingPathComponent("local-choices.json")
    }
}
