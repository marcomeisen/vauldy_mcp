import Foundation
import CryptoKit
import VauldyMCPRuntime

extension OAuthStore {
    public func register(redirectURIs: [String], clientID: String? = nil, now: Date = Date()) throws -> OAuthClient {
        guard (1...4).contains(redirectURIs.count), Set(redirectURIs).count == redirectURIs.count,
              let first = redirectURIs.first.flatMap(URL.init(string:)).flatMap(OAuthProvider.provider),
              redirectURIs.allSatisfy({ value in
                  guard value.count <= 2048, let u = URL(string: value), OAuthProvider.provider(for: u) == first,
                        !u.path.isEmpty, !value.contains("%"), !u.path.contains(".."), !value.contains("\\") else { return false }
                  return true
              }) else { throw OAuthFailure.invalidClient }
        if let clientID {
            guard let url = URL(string: clientID), OAuthProvider.provider(for: url) == first,
                  clientID.count <= 2048 else { throw OAuthFailure.invalidClient }
        }
        return try locked {
            var db = try database(); prune(&db, now: now)
            if let clientID, let old = db.clients.first(where: { $0.id == clientID }) {
                guard old.redirectURIs == redirectURIs else { throw OAuthFailure.invalidClient }; return old
            }
            guard db.clients.count < 256 else { throw OAuthFailure.temporarilyUnavailable }
            let client = OAuthClient(id: try clientID ?? Self.randomToken(), provider: first, redirectURIs: redirectURIs, createdAt: now, metadata: clientID != nil)
            db.clients.append(client); try save(db); return client
        }
    }
    public func client(_ id: String) throws -> OAuthClient? { try locked { try database().clients.first { $0.id == id } } }

    /// Creates only a pending request. Local native approval is the resource-owner authentication.
    public func begin(_ parameters: [String: String], now: Date = Date()) throws -> (browser: String, request: OAuthPendingRequest) {
        guard let config = try configuration(), parameters["response_type"] == "code",
              parameters["resource"] == config.resource, parameters["code_challenge_method"] == "S256",
              let challenge = parameters["code_challenge"], challenge.count == 43,
              challenge.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let clientID = parameters["client_id"], let redirect = parameters["redirect_uri"],
              let state = parameters["state"], (1...2048).contains(state.utf8.count), !state.contains("\0") else { throw OAuthFailure.invalidRequest }
        guard parameters["scope"] == nil || parameters["scope"] == "documents:read" else { throw OAuthFailure.invalidScope }
        return try locked {
            var db = try database(); prune(&db, now: now)
            guard let client = db.clients.first(where: { $0.id == clientID }), client.redirectURIs.contains(redirect) else { throw OAuthFailure.invalidClient }
            guard db.pending.count < 128 else { throw OAuthFailure.temporarilyUnavailable }
            let browser = try Self.randomToken()
            let confirmation = String(try Self.randomToken().prefix(8)).uppercased()
            let info = OAuthPendingRequest(id: UUID(), provider: client.provider, redirectURI: redirect, createdAt: now,
                                          expiresAt: now.addingTimeInterval(600), confirmation: confirmation)
            db.pending.append(.init(info: info, browserHash: Self.hash(browser), clientID: clientID, challenge: challenge, state: state, scope: "documents:read"))
            try save(db); return (browser, info)
        }
    }
    public func pendingRequests(now: Date = Date()) throws -> [OAuthPendingRequest] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try locked { try database().pending.filter { $0.info.expiresAt > now && !$0.rejected && $0.profileID == nil }.map(\.info) }
    }
    /// Trusted local action only. Rechecks the precise revision displayed by the native UI.
    public func approve(_ id: UUID, profileID: UUID, expectedRevision: UUID, now: Date = Date()) throws {
        try locked {
            var db = try database()
            guard let index = db.pending.firstIndex(where: { $0.info.id == id }), db.pending[index].info.expiresAt > now,
                  !db.pending[index].rejected, db.pending[index].profileID == nil else { throw OAuthFailure.invalidGrant }
            let selected = try profile(profileID, revision: expectedRevision)
            let code = try Self.randomToken()
            db.pending[index].profileID = profileID; db.pending[index].revision = selected.revision
            db.pending[index].codeHash = Self.hash(code); db.pending[index].codeExpires = min(db.pending[index].info.expiresAt, now.addingTimeInterval(120))
            db.pending[index].wrappedCode = try AES.GCM.seal(Data(code.utf8), using: key()).combined
            try save(db)
        }
    }
    public func deny(_ id: UUID) throws {
        try locked {
            var db = try database()
            guard let index = db.pending.firstIndex(where: { $0.info.id == id }) else { throw OAuthFailure.invalidGrant }
            db.pending[index].rejected = true; db.pending[index].wrappedCode = nil; try save(db)
        }
    }
    public enum BrowserResult: Sendable { case waiting(OAuthPendingRequest), redirect(String), expired }
    public func browserResult(_ browser: String, now: Date = Date()) throws -> BrowserResult {
        guard browser.count == 43 else { throw OAuthFailure.invalidRequest }
        return try locked {
            let db = try database()
            guard let pending = db.pending.first(where: { $0.browserHash == Self.hash(browser) }), pending.info.expiresAt > now else { return .expired }
            var redirect = URLComponents(string: pending.info.redirectURI)!
            var fields = [URLQueryItem(name: "state", value: pending.state), URLQueryItem(name: "iss", value: try requiredConfiguration().origin)]
            if pending.rejected { fields.append(.init(name: "error", value: "access_denied")) }
            else if let data = pending.wrappedCode, let expires = pending.codeExpires, expires > now, !pending.consumed {
                let code = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key())
                fields.append(.init(name: "code", value: String(decoding: code, as: UTF8.self)))
            } else if pending.profileID != nil { return .expired }
            else { return .waiting(pending.info) }
            redirect.queryItems = fields
            return .redirect(redirect.string!)
        }
    }
    /// Single-use authorization codes, exact resource/client/redirect binding and mandatory S256 PKCE.
    public func exchange(_ parameters: [String: String], now: Date = Date()) throws -> OAuthTokenResponse {
        guard let config = try configuration(), parameters["resource"] == config.resource,
              let client = parameters["client_id"], client.count <= 2048 else { throw OAuthFailure.invalidRequest }
        guard ["authorization_code", "refresh_token"].contains(parameters["grant_type"] ?? "") else { throw OAuthFailure.unsupportedGrantType }
        if parameters["grant_type"] == "refresh_token" { return try refresh(parameters, client: client, now: now) }
        guard parameters["grant_type"] == "authorization_code", let code = parameters["code"], code.count == 43,
              let verifier = parameters["code_verifier"], (43...128).contains(verifier.count),
              verifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }) else { throw OAuthFailure.invalidGrant }
        return try locked {
            var db = try database(); prune(&db, now: now)
            guard let i = db.pending.firstIndex(where: { $0.codeHash == Self.hash(code) }),
                  !db.pending[i].rejected, db.pending[i].clientID == client,
                  db.pending[i].info.redirectURI == parameters["redirect_uri"], db.pending[i].codeExpires ?? .distantPast > now,
                  db.pending[i].challenge == Self.challenge(for: verifier),
                  let profileID = db.pending[i].profileID, let revision = db.pending[i].revision else { throw OAuthFailure.invalidGrant }
            if db.pending[i].consumed {
                if let grant = db.grants.firstIndex(where: { $0.id == db.pending[i].issuedGrantID }) {
                    db.grants[grant].revoked = true; try save(db)
                }
                throw OAuthFailure.invalidGrant
            }
            _ = try profile(profileID, revision: revision)
            guard db.grants.count < 512 else { throw OAuthFailure.temporarilyUnavailable }
            let access = try Self.randomToken(), refresh = try Self.randomToken()
            let grantID = UUID()
            db.grants.append(.init(id: grantID, clientID: client, provider: db.pending[i].info.provider, profileID: profileID,
                revision: revision, accessHash: Self.hash(access), accessExpires: now.addingTimeInterval(900),
                refreshHash: Self.hash(refresh), createdAt: now, expiresAt: now.addingTimeInterval(30 * 86400)))
            db.pending[i].consumed = true; db.pending[i].wrappedCode = nil; db.pending[i].issuedGrantID = grantID
            try save(db)
            return .init(access_token: access, refresh_token: refresh)
        }
    }
    private func refresh(_ parameters: [String: String], client: String, now: Date) throws -> OAuthTokenResponse {
        guard let refresh = parameters["refresh_token"], refresh.count == 43,
              parameters["scope"] == nil || parameters["scope"] == "documents:read" else { throw OAuthFailure.invalidGrant }
        return try locked {
            var db = try database(); let hash = Self.hash(refresh)
            if let reused = db.grants.firstIndex(where: { $0.clientID == client && $0.usedRefreshHashes.contains(hash) }) {
                db.grants[reused].revoked = true; try save(db); throw OAuthFailure.invalidGrant
            }
            guard let i = db.grants.firstIndex(where: { $0.refreshHash == hash && $0.clientID == client }),
                  !db.grants[i].revoked, db.grants[i].expiresAt > now, db.grants[i].usedRefreshHashes.count < 4096 else { throw OAuthFailure.invalidGrant }
            _ = try profile(db.grants[i].profileID, revision: db.grants[i].revision)
            let access = try Self.randomToken(), replacement = try Self.randomToken()
            db.grants[i].usedRefreshHashes.append(hash); db.grants[i].refreshHash = Self.hash(replacement)
            db.grants[i].accessHash = Self.hash(access); db.grants[i].accessExpires = now.addingTimeInterval(900)
            try save(db); return .init(access_token: access, refresh_token: replacement)
        }
    }
    public func authorize(_ token: String, now: Date = Date()) throws -> OAuthAuthorization {
        guard token.count == 43 else { throw OAuthFailure.invalidToken }
        return try locked {
            let db = try database()
            guard let grant = db.grants.first(where: { $0.accessHash == Self.hash(token) }), !grant.revoked,
                  grant.accessExpires > now, grant.expiresAt > now else { throw OAuthFailure.invalidToken }
            _ = try profile(grant.profileID, revision: grant.revision)
            return .init(grantID: grant.id, provider: grant.provider, profileID: grant.profileID, profileRevision: grant.revision,
                         profileURL: installation.profileURL(grant.profileID))
        }
    }
    public func authorization(forGrant id: UUID, now: Date = Date()) throws -> OAuthAuthorization {
        try locked {
            guard let grant = try database().grants.first(where: { $0.id == id }), !grant.revoked,
                  grant.expiresAt > now else { throw OAuthFailure.invalidToken }
            _ = try profile(grant.profileID, revision: grant.revision)
            return .init(grantID: grant.id, provider: grant.provider, profileID: grant.profileID, profileRevision: grant.revision,
                         profileURL: installation.profileURL(grant.profileID))
        }
    }
    public func connections(now: Date = Date()) throws -> [OAuthConnection] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try locked { try database().grants.filter { $0.expiresAt > now }.map {
            .init(id: $0.id, provider: $0.provider, profileID: $0.profileID, createdAt: $0.createdAt, expiresAt: $0.expiresAt, revoked: $0.revoked || (try? profile($0.profileID, revision: $0.revision)) == nil)
        } }
    }
    public func revoke(connectionID: UUID) throws {
        try locked {
            var db = try database()
            if let i = db.grants.firstIndex(where: { $0.id == connectionID }) { db.grants[i].revoked = true; try save(db) }
        }
    }
    public func revoke(token: String, clientID: String) throws {
        guard token.count <= 256, clientID.count <= 2048 else { throw OAuthFailure.invalidRequest }
        try locked {
            var db = try database(); let hash = Self.hash(token)
            if let i = db.grants.firstIndex(where: { $0.clientID == clientID && ($0.accessHash == hash || $0.refreshHash == hash || $0.usedRefreshHashes.contains(hash)) }) {
                db.grants[i].revoked = true; try save(db)
            }
        }
    }
    func requiredConfiguration() throws -> OAuthConfiguration {
        // Already under the store lock; avoid nested flock acquisition.
        let config = try JSONDecoder().decode(OAuthConfiguration.self, from: read(root.appendingPathComponent("service.json"), limit: 8192))
        try config.validate(); return config
    }
}
/// SDK handlers recheck token and local profile before each response, including mid-request revocation.
public struct OAuthProfileSource: MCPProfileSource {
    public let store: OAuthStore
    public let grantID: UUID
    public init(store: OAuthStore, grantID: UUID) { self.store = store; self.grantID = grantID }
    public func load() throws -> MCPAccessProfile {
        let authorization = try store.authorization(forGrant: grantID)
        return try FileMCPProfileSource(url: authorization.profileURL).load()
    }
}
