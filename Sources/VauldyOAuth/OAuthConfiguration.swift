import Foundation
import VauldyMCPRuntime

public enum OAuthProvider: String, Codable, Sendable, CaseIterable {
    case chatgpt, claude
    public var title: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    public static func provider(for url: URL) -> Self? {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil, url.query == nil else { return nil }
        switch url.host?.lowercased() {
        case "chatgpt.com": return .chatgpt
        case "claude.ai", "claude.com": return .claude
        default: return nil
        }
    }
}
public enum OAuthFailure: String, Error, LocalizedError, Sendable {
    case invalidRequest = "invalid_request", invalidClient = "invalid_client", invalidGrant = "invalid_grant"
    case unsupportedGrantType = "unsupported_grant_type"
    case invalidScope = "invalid_scope", accessDenied = "access_denied", temporarilyUnavailable = "temporarily_unavailable"
    case invalidToken = "invalid_token", invalidConfiguration = "invalid_configuration"
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Der OAuth-Dienst ist nicht eingerichtet. Eine öffentliche HTTPS-Adresse ist erforderlich."
        case .accessDenied: "Die Verbindung wurde nicht freigegeben oder wurde widerrufen."
        case .temporarilyUnavailable: "Die lokale Verbindungsverwaltung ist vorübergehend nicht verfügbar."
        default: "Die OAuth-Anfrage ist ungültig oder abgelaufen. Bitte die Verbindung erneut starten."
        }
    }
}
public struct OAuthConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let origin: String
    public let port: Int
    public var resource: String { origin + "/mcp" }
    public init(origin: String, port: Int = 48731) throws {
        guard let u = URL(string: origin), u.scheme == "https", let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              ["", "/"].contains(u.path), (1024...65535).contains(port),
              !origin.contains("\n"), !origin.contains("\r"), origin.count <= 2048 else { throw OAuthFailure.invalidConfiguration }
        var normalized = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        normalized.scheme = "https"; normalized.host = host.lowercased(); normalized.path = ""
        if normalized.port == 443 { normalized.port = nil }
        self.version = 1; self.origin = normalized.string!; self.port = port
    }
    public func validate() throws {
        guard version == 1, try Self(origin: origin, port: port) == self else { throw OAuthFailure.invalidConfiguration }
    }
}
public struct OAuthPendingRequest: Codable, Sendable {
    public let id: UUID
    public let provider: OAuthProvider
    public let redirectURI: String
    public let createdAt: Date
    public let expiresAt: Date
    public let confirmation: String
}
public struct OAuthConnection: Codable, Sendable {
    public let id: UUID
    public let provider: OAuthProvider
    public let profileID: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let revoked: Bool
}
public struct OAuthTokenResponse: Encodable, Sendable {
    public let access_token: String
    public let token_type = "Bearer"
    public let expires_in = 900
    public let refresh_token: String
    public let scope = "documents:read"
}
public struct OAuthAuthorization: Sendable {
    public let grantID: UUID
    public let provider: OAuthProvider
    public let profileID: UUID
    public let profileRevision: UUID
    public let profileURL: URL
}
public struct OAuthClient: Codable, Sendable {
    public let id: String
    public let provider: OAuthProvider
    public let redirectURIs: [String]
    public let createdAt: Date
    public let metadata: Bool
}
struct OAuthPending: Codable, Sendable {
    var info: OAuthPendingRequest
    var browserHash: String
    var clientID: String
    var challenge: String
    var state: String
    var scope: String
    var profileID: UUID?
    var revision: UUID?
    var rejected = false
    var wrappedCode: Data?
    var codeHash: String?
    var codeExpires: Date?
    var consumed = false
    var issuedGrantID: UUID?
}
struct OAuthGrant: Codable, Sendable {
    var id: UUID
    var clientID: String
    var provider: OAuthProvider
    var profileID: UUID
    var revision: UUID
    var accessHash: String
    var accessExpires: Date
    var refreshHash: String
    var usedRefreshHashes: [String] = []
    var createdAt: Date
    var expiresAt: Date
    var revoked = false
}
struct OAuthDatabase: Codable, Sendable {
    var version = 1
    var clients: [OAuthClient] = []
    var pending: [OAuthPending] = []
    var grants: [OAuthGrant] = []
}
