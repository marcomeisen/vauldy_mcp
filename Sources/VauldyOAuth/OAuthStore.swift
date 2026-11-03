import Foundation
import CryptoKit
import Security
import Darwin
import VauldyMCPRuntime

/// Private authority on the Mac. Remote HTTP never exposes approval or configuration methods.
public struct OAuthStore: Sendable {
    public let installation: MCPInstallation
    public var root: URL { installation.root.appendingPathComponent("oauth", isDirectory: true) }
    public init(installation: MCPInstallation) { self.installation = installation }
    public func configuration() throws -> OAuthConfiguration? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return try locked {
            let url = root.appendingPathComponent("service.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let config = try JSONDecoder().decode(OAuthConfiguration.self, from: read(url, limit: 8192))
            try config.validate(); return config
        }
    }
    /// Operator setup, only from trusted CLI/UI. Never changes a document or an existing profile.
    public func configure(_ config: OAuthConfiguration) throws {
        try config.validate()
        try locked {
            let url = root.appendingPathComponent("service.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try JSONDecoder().decode(OAuthConfiguration.self, from: read(url, limit: 8192))
                guard existing == config else { throw OAuthFailure.invalidConfiguration }
                return
            }
            try write(JSONEncoder().encode(config), to: url)
        }
    }
    func locked<T>(_ body: () throws -> T) throws -> T {
        do {
            // Refuse links at every owned ancestor, including installation and OAuth root.
            for url in [installation.root, root] {
                try refuseLink(url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let fd = Darwin.open(root.appendingPathComponent("oauth.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw OAuthFailure.temporarilyUnavailable }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw OAuthFailure.temporarilyUnavailable }
            defer { flock(fd, LOCK_UN) }
            return try body()
        } catch let e as OAuthFailure { throw e }
        catch { throw OAuthFailure.temporarilyUnavailable }
    }
    func database() throws -> OAuthDatabase {
        let file = root.appendingPathComponent("credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let value = try JSONDecoder().decode(OAuthDatabase.self, from: read(file, limit: 4 * 1024 * 1024))
        guard value.version == 1, value.clients.count <= 256, value.pending.count <= 128, value.grants.count <= 512 else { throw OAuthFailure.temporarilyUnavailable }
        return value
    }
    func save(_ database: OAuthDatabase) throws {
        let data = try JSONEncoder().encode(database)
        guard data.count <= 4 * 1024 * 1024 else { throw OAuthFailure.temporarilyUnavailable }
        try write(data, to: root.appendingPathComponent("credentials.json"))
    }
    func prune(_ database: inout OAuthDatabase, now: Date) {
        database.pending.removeAll { $0.info.expiresAt < now }
        database.grants.removeAll { $0.expiresAt < now }
        let active = Set(database.pending.map(\.clientID) + database.grants.map(\.clientID))
        database.clients.removeAll { !active.contains($0.id) && now.timeIntervalSince($0.createdAt) > 86400 }
    }
    func key() throws -> SymmetricKey {
        let file = root.appendingPathComponent("authorization.key")
        if FileManager.default.fileExists(atPath: file.path) {
            let bytes = try read(file, limit: 32)
            guard bytes.count == 32 else { throw OAuthFailure.temporarilyUnavailable }
            return SymmetricKey(data: bytes)
        }
        let bytes = try Self.randomBytes(); try write(bytes, to: file)
        return SymmetricKey(data: bytes)
    }
    func read(_ file: URL, limit: Int) throws -> Data {
        try refuseLink(file)
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OAuthFailure.temporarilyUnavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size <= limit else { throw OAuthFailure.temporarilyUnavailable }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw OAuthFailure.temporarilyUnavailable }
        return data
    }
    func write(_ data: Data, to file: URL) throws {
        try refuseLink(file)
        let temporary = root.appendingPathComponent(".oauth-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OAuthFailure.temporarilyUnavailable }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temporary.path, file.path) == 0 else { throw OAuthFailure.temporarilyUnavailable }
        let directory = Darwin.open(root.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw OAuthFailure.temporarilyUnavailable }; defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw OAuthFailure.temporarilyUnavailable }
    }
    func refuseLink(_ file: URL) throws {
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw OAuthFailure.temporarilyUnavailable }
        if FileManager.default.fileExists(atPath: file.path), file == root || file == installation.root {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else { throw OAuthFailure.temporarilyUnavailable }
        }
    }
    static func randomBytes() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthFailure.temporarilyUnavailable }
        return Data(bytes)
    }
    public static func randomToken() throws -> String { base64(try randomBytes()) }
    public static func challenge(for verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func profile(_ id: UUID, revision: UUID? = nil) throws -> MCPAccessProfile {
        let value = try FileMCPProfileSource(url: installation.profileURL(id)).load()
        guard value.connectionID == id, value.enabled, value.acknowledgedCloudDisclosure,
              revision == nil || value.revision == revision else { throw OAuthFailure.accessDenied }
        return value
    }
}
