import Foundation
import CryptoKit
import Security
import Darwin
import VauldyMCPRuntime

public enum RelayFailure: LocalizedError {
    case unavailable, notProvisioned, signInRequired, changedGrant, credentials, ownerApprovalRequired
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Die ChatGPT-Verbindung ist derzeit nicht erreichbar. Bitte erneut versuchen."
        case .notProvisioned: "Die private ChatGPT-Verbindung wurde auf diesem Mac noch nicht eingerichtet."
        case .signInRequired: "Bitte in Vauldy erneut mit ChatGPT anmelden."
        case .changedGrant: "Die lokale Dokumentfreigabe hat sich geändert. Bitte den Zugriff erneut bestätigen."
        case .ownerApprovalRequired: "Bitte den Schlüsselbundzugriff einmal bewusst in Vauldy bestätigen. Die Verbindung bleibt gespeichert."
        case .credentials: "Die geschützte Verbindungsablage ist nicht verfügbar."
        }
    }
}

public struct RelayCredentials: Codable, Sendable {
    public static let origin = "https://vauldy-private-connector.brightibex15.chatgpt.site"
    public var serviceToken: String
    public var deviceToken: String?
    public var pendingDeviceToken: String?
    public var privateKey: Data?
    public var pairID: String?
    public var verifier: String?
    public var pairingExpires: Date?
    public var profileID: UUID?
    public var revision: UUID?
    public var profileFingerprint: String?
    public var paired = false
    public init(serviceToken: String) { self.serviceToken = serviceToken }
    public static func fingerprint(_ p: MCPAccessProfile) throws -> String {
        let value: [String: Any] = ["version": p.version, "revision": p.revision.uuidString,
            "id": p.connectionID.uuidString, "name": p.connectionName, "kind": p.connectionKind?.rawValue ?? "",
            "client": p.desktopClient?.rawValue ?? "", "enabled": p.enabled, "vault": p.vaultPath,
            "documents": p.allowedDocumentIDs.map(\.uuidString).sorted(), "cloud": p.acknowledgedCloudDisclosure]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }
    public func validatedProfile(installation: MCPInstallation) throws -> URL {
        guard paired, let profileID, let revision else { throw RelayFailure.signInRequired }
        let url = installation.profileURL(profileID)
        let p = try FileMCPProfileSource(url: url).load()
        guard p.enabled, p.acknowledgedCloudDisclosure, p.revision == revision, try profileFingerprint == Self.fingerprint(p) else { throw RelayFailure.changedGrant }
        return url
    }
}

/// Separate per installation (including test roots). No secrets in configuration files.
public struct RelayCredentialStore: Sendable {
    public let installation: MCPInstallation
    private let persistence: any RelayCredentialPersistence
    public init(installation: MCPInstallation) {
        self.installation = installation
        let account = SHA256.hash(data: Data(installation.root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        persistence = SystemRelayCredentialPersistence(account: account)
    }
    init(installation: MCPInstallation, persistence: any RelayCredentialPersistence) {
        self.installation = installation; self.persistence = persistence
    }
    public func load(interactive: Bool = false) throws -> RelayCredentials? {
        guard let data = try persistence.read(allowUserInteraction: interactive) else { return nil }
        guard data.count < 16000, let c = try? JSONDecoder().decode(RelayCredentials.self, from: data) else { throw RelayFailure.credentials }
        return c
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let service = RelayService(installation: installation); try service.prepare()
        let fd = Darwin.open(service.root.appendingPathComponent("credentials.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw RelayFailure.credentials }; defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw RelayFailure.credentials }; defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func saveUnlocked(_ c: RelayCredentials) throws {
        try persistence.write(JSONEncoder().encode(c))
    }
    public func save(_ c: RelayCredentials) throws { try locked { try saveUnlocked(c) } }
    public func provision(serviceToken: String) throws {
        try locked {
            var c = try load() ?? RelayCredentials(serviceToken: serviceToken)
            c.serviceToken = serviceToken; try saveUnlocked(c)
        }
    }
    public func completePairing(expectedID: String?, completed: RelayCredentials) throws {
        try locked {
            guard expectedID != nil, completed.paired, completed.deviceToken != nil, let current = try load(), current.pairID == expectedID, current.deviceToken == completed.deviceToken else { throw RelayFailure.signInRequired }
            _ = try completed.validatedProfile(installation: installation)
            try saveUnlocked(completed)
        }
    }
    public func prepareDeviceRotation() throws -> RelayCredentials {
        try locked {
            guard var c = try load(), c.paired, c.deviceToken != nil else { throw RelayFailure.signInRequired }
            _ = try c.validatedProfile(installation: installation)
            if c.pendingDeviceToken == nil { c.pendingDeviceToken = RelayCrypto.token(); try saveUnlocked(c) }
            return c
        }
    }
    public func completeDeviceRotation(expectedToken: String?, nextToken: String) throws {
        try locked {
            guard var c = try load(), c.paired, c.deviceToken == expectedToken, c.pendingDeviceToken == nextToken else { throw RelayFailure.signInRequired }
            _ = try c.validatedProfile(installation: installation)
            c.deviceToken = nextToken; c.pendingDeviceToken = nil; try saveUnlocked(c)
        }
    }
    public func clearDevice(expectedToken: String? = nil) throws {
        try locked {
            guard let c = try load() else { return }
            if let expectedToken, c.deviceToken != expectedToken { return }
            try saveUnlocked(.init(serviceToken: c.serviceToken))
        }
    }
}

public enum RelayCrypto {
    public static func token() -> String { (0..<32).map { _ in UInt8.random(in: 0...255) }.withUnsafeBytes { Data($0).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
    public static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString() }
    public static func key(privateKey: Data, publicKey: String, id: String) throws -> SymmetricKey {
        guard let raw = Data(base64Encoded: publicKey), raw.count == 65 else { throw RelayFailure.unavailable }
        let secret = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey).sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: raw))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(id.utf8), sharedInfo: Data("VauldyRelay-v1".utf8), outputByteCount: 32)
    }
    public static func seal(_ data: Data, key: SymmetricKey, aad: String) throws -> String {
        try AES.GCM.seal(data, using: key, authenticating: Data(aad.utf8)).combined!.base64EncodedString()
    }
    public static func open(_ cipher: String, key: SymmetricKey, aad: String) throws -> Data {
        guard cipher.utf8.count <= 250000, let data = Data(base64Encoded: cipher) else { throw RelayFailure.unavailable }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(aad.utf8))
    }
}
