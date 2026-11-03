import Foundation
import Testing
import VauldyCore
import VauldyMCPRuntime
@testable import VauldyOAuth

@Suite("Provider-independent OAuth connections")
struct OAuthConnectionTests {
    @Test(arguments: OAuthProvider.allCases) func localConsentPKCEAndPersistentAuthorization(provider: OAuthProvider) throws {
        let f = try Fixture(); defer { f.clean() }
        let before = try Data(contentsOf: f.vault)
        let flow = try f.flow(provider)
        #expect(try f.store.pendingRequests().count == 1)
        #expect(try f.store.browserResult(flow.browser).isWaiting)
        #expect(throws: OAuthFailure.invalidGrant) { try f.store.exchange(flow.exchange(code: "not-an-approved-authorization-code")) }
        try f.store.approve(flow.id, profileID: f.profile.connectionID, expectedRevision: f.profile.revision)
        let fields = try flow.exchange(code: f.code(flow.browser))
        #expect(throws: OAuthFailure.invalidGrant) { try f.store.exchange(fields.merging(["code_verifier": String(repeating: "z", count: 43)]) { _, new in new }) }
        let tokens = try f.store.exchange(fields)
        let reloaded = OAuthStore(installation: f.store.installation)
        #expect(try reloaded.authorize(tokens.access_token).provider == provider)
        #expect(try reloaded.authorize(tokens.access_token).profileID == f.profile.connectionID)
        #expect(try Data(contentsOf: f.vault) == before)
        let state = try String(contentsOf: f.store.root.appendingPathComponent("credentials.json"), encoding: .utf8)
        #expect(!state.contains(tokens.access_token) && !state.contains(tokens.refresh_token) && !state.contains(fields["code"]!))
        for name in ["credentials.json", "authorization.key"] {
            let permissions = try FileManager.default.attributesOfItem(atPath: f.store.root.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }
    @Test func wrongResourceRedirectClientAndScopeCannotBorrowConsent() throws {
        let f = try Fixture(); defer { f.clean() }
        let flow = try f.flow(.chatgpt)
        for invalid in [["resource": "https://foreign.example/mcp"], ["redirect_uri": "https://foreign.example/callback"], ["code_challenge_method": "plain"], ["scope": "documents:write"], ["state": ""]] {
            #expect(throws: (any Error).self) { try f.store.begin(flow.authorization.merging(invalid) { _, new in new }) }
        }
        try f.store.approve(flow.id, profileID: f.profile.connectionID, expectedRevision: f.profile.revision)
        let fields = try flow.exchange(code: f.code(flow.browser))
        for invalid in [["resource": "https://foreign.example/mcp"], ["redirect_uri": "https://claude.ai/callback"], ["client_id": "foreign-client"]] {
            #expect(throws: (any Error).self) { try f.store.exchange(fields.merging(invalid) { _, new in new }) }
        }
        #expect(try f.store.exchange(fields).token_type == "Bearer")
    }
    @Test func consumedCodeRevokesItsIssuedGrantOnReplay() throws {
        let f = try Fixture(); defer { f.clean() }
        let flow = try f.flow(.chatgpt)
        try f.store.approve(flow.id, profileID: f.profile.connectionID, expectedRevision: f.profile.revision)
        let fields = try flow.exchange(code: f.code(flow.browser)), tokens = try f.store.exchange(fields)
        #expect(throws: OAuthFailure.invalidGrant) { try f.store.exchange(fields) }
        #expect(throws: OAuthFailure.invalidToken) { try f.store.authorize(tokens.access_token) }
    }
    @Test func refreshRotationReuseAndIndependentProviderRevocation() throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.tokens(.chatgpt), second = try f.tokens(.claude)
        let original = try f.store.authorize(first.access_token)
        let refreshed = try f.store.exchange(["grant_type": "refresh_token", "refresh_token": first.refresh_token, "client_id": first.clientID, "resource": f.resource])
        #expect(try f.store.authorize(refreshed.access_token).grantID == original.grantID)
        #expect(throws: OAuthFailure.invalidToken) { try f.store.authorize(first.access_token) }
        #expect(throws: OAuthFailure.invalidGrant) { try f.store.exchange(["grant_type": "refresh_token", "refresh_token": first.refresh_token, "client_id": first.clientID, "resource": f.resource]) }
        #expect(throws: OAuthFailure.invalidToken) { try f.store.authorize(refreshed.access_token) }
        let remaining = try f.store.authorize(second.access_token)
        try f.store.revoke(connectionID: remaining.grantID)
        #expect(throws: OAuthFailure.invalidToken) { try f.store.authorize(second.access_token) }
        #expect(try FileMCPProfileSource(url: f.store.installation.profileURL(f.profile.connectionID)).load().enabled)
    }
    @Test func profileRevisionPauseRemovalAndExpiryInvalidateTokens() throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.tokens(.chatgpt)
        _ = try f.store.installation.setAccess(false, for: f.profile.connectionID, expectedRevision: f.profile.revision)
        #expect(throws: (any Error).self) { try f.store.authorize(first.access_token) }
        let other = try Fixture(); defer { other.clean() }
        let token = try other.tokens(.claude)
        #expect(throws: OAuthFailure.invalidToken) { try other.store.authorize(token.access_token, now: Date().addingTimeInterval(901)) }
        _ = try other.store.installation.removeConnection(other.profile.connectionID, expectedRevision: other.profile.revision)
        #expect(throws: (any Error).self) { try other.store.authorize(token.access_token) }
    }
    @Test func denialExpiredRequestAndStaleSelectionNeverIssueCode() throws {
        let f = try Fixture(); defer { f.clean() }
        let denied = try f.flow(.claude)
        try f.store.deny(denied.id)
        if case .redirect(let value) = try f.store.browserResult(denied.browser) { #expect(value.contains("error=access_denied")) }
        else { Issue.record("Denied request did not return an OAuth denial") }
        #expect(throws: OAuthFailure.invalidGrant) { try f.store.approve(denied.id, profileID: f.profile.connectionID, expectedRevision: f.profile.revision) }
        let stale = try f.flow(.chatgpt)
        #expect(throws: (any Error).self) { try f.store.approve(stale.id, profileID: f.profile.connectionID, expectedRevision: UUID()) }
        #expect(throws: OAuthFailure.invalidGrant) { try f.store.approve(stale.id, profileID: f.profile.connectionID, expectedRevision: f.profile.revision, now: Date().addingTimeInterval(601)) }
    }
    @Test func registrationsRejectForeignAndMixedProviderRedirects() throws {
        let f = try Fixture(); defer { f.clean() }
        for urls in [["http://claude.ai/callback"], ["https://claude.ai.attacker.example/callback"], ["https://chatgpt.com@attacker.example/callback"], ["https://chatgpt.com/callback?redirect=https://attacker.example"], ["https://chatgpt.com/callback", "https://claude.ai/callback"], ["https://chatgpt.com/%2fcallback"]] {
            #expect(throws: OAuthFailure.invalidClient) { try f.store.register(redirectURIs: urls) }
        }
        #expect(throws: OAuthFailure.invalidClient) { try f.store.register(redirectURIs: ["https://claude.ai/callback"], clientID: "https://chatgpt.com/oauth/client.json") }
    }
    @Test func webMetadataAndRegistrationRequireNoKeyAndNoRemoteApprovalExists() async throws {
        let f = try Fixture(); defer { f.clean() }
        let web = OAuthWebService(store: f.store, configuration: try #require(try f.store.configuration()))
        let metadata = await web.handle(.init(method: "GET", target: "/.well-known/oauth-authorization-server", headers: [:]))
        #expect(metadata.status == 200 && String(decoding: metadata.body, as: UTF8.self).contains("S256"))
        for target in ["/oauth/approve", "/oauth/configure", "/oauth/pending", "/oauth/credentials.json"] {
            #expect(await web.handle(.init(method: "POST", target: target, headers: [:])).status == 404)
        }
        let duplicate = await web.handle(.init(method: "POST", target: "/oauth/token", headers: ["content-type": "application/x-www-form-urlencoded"], body: Data("client_id=first&client_id=second&grant_type=authorization_code".utf8)))
        #expect(duplicate.status == 400)
        let foreign = await web.handle(.init(method: "GET", target: "/oauth/authorize?client_id=https%3A%2F%2F127.0.0.1%2Fclient.json", headers: [:]))
        #expect(foreign.status == 401)
    }
    @Test(arguments: ["valid", "opaque-path", "wrong-id", "foreign-redirect", "wrong-provider", "private-client", "oversize"])
    func publishedClientMetadataIsVerifiedBeforeAnyConsent(variant: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let valid = ["valid", "opaque-path"].contains(variant)
        let clientID = variant == "opaque-path" ? "https://chatgpt.com/oauth/client-metadata" : "https://chatgpt.com/oauth/client.json"
        var object: [String: Any] = ["client_id": variant == "wrong-id" ? "https://chatgpt.com/wrong.json" : clientID,
            "redirect_uris": [variant == "foreign-redirect" ? "https://foreign.example/callback" : variant == "wrong-provider" ? "https://claude.ai/callback" : "https://chatgpt.com/connector_platform_oauth_redirect"],
            "token_endpoint_auth_methods_supported": variant == "private-client" ? ["private_key_jwt"] : ["none", "private_key_jwt"]]
        if variant == "oversize" { object["extra"] = String(repeating: "x", count: 16385) }
        let loader = FixedMetadata(data: try JSONSerialization.data(withJSONObject: object))
        let web = OAuthWebService(store: f.store, configuration: try #require(try f.store.configuration()), metadataLoader: loader)
        var components = URLComponents()
        components.path = "/oauth/authorize"
        components.queryItems = ["response_type": "code", "client_id": clientID, "redirect_uri": "https://chatgpt.com/connector_platform_oauth_redirect", "resource": f.resource, "scope": "documents:read", "state": "preserve", "code_challenge_method": "S256", "code_challenge": OAuthStore.challenge(for: String(repeating: "x", count: 43))].map { .init(name: $0.key, value: $0.value) }
        let result = await web.handle(.init(method: "GET", target: components.string!, headers: [:]))
        #expect(result.status == (valid ? 303 : 401))
        #expect(try f.store.pendingRequests().count == (valid ? 1 : 0))
    }
    @Test func changingAnIssuedProfilesSelectionNeverExpandsOAuthAccess() throws {
        let f = try Fixture(); defer { f.clean() }
        let token = try f.tokens(.chatgpt)
        _ = try f.store.installation.updateSelection([UUID()], for: f.profile.connectionID, expectedRevision: f.profile.revision, acknowledgedDisclosure: true)
        #expect(throws: (any Error).self) { try f.store.authorize(token.access_token) }
        #expect(try f.store.connections().first?.revoked == true)
    }
    @Test func operatorAddressAndOwnershipRemainExplicitAndImmutable() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(try OAuthConfiguration(origin: "https://VAULDY.example.test:443/").origin == "https://vauldy.example.test")
        for invalid in ["http://vauldy.example.test", "https://user:password@vauldy.example.test", "https://vauldy.example.test/path", "https://vauldy.example.test?secret=x", "https://vauldy.example.test/#token"] {
            #expect(throws: OAuthFailure.invalidConfiguration) { try OAuthConfiguration(origin: invalid) }
        }
        #expect(throws: OAuthFailure.invalidConfiguration) { try f.store.configure(OAuthConfiguration(origin: "https://other.example.test")) }
        #expect(try f.store.configuration()?.resource == f.resource)
    }
    @Test func pendingConsentIsBoundedWithoutTouchingGrantsOrVault() throws {
        let f = try Fixture(); defer { f.clean() }
        let bytes = try Data(contentsOf: f.vault)
        let first = try f.flow(.chatgpt)
        for _ in 1..<128 { _ = try f.store.begin(first.authorization) }
        #expect(throws: OAuthFailure.temporarilyUnavailable) { try f.store.begin(first.authorization) }
        #expect(try f.store.connections().isEmpty)
        #expect(try Data(contentsOf: f.vault) == bytes)
    }
    @Test func malformedOrLinkedStateFailsClosedAndCannotOverwriteForeignFiles() throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.tokens(.chatgpt)
        let file = f.store.root.appendingPathComponent("credentials.json")
        let bytes = try Data(contentsOf: file)
        try Data("{corrupt".utf8).write(to: file)
        #expect(throws: OAuthFailure.temporarilyUnavailable) { try f.store.pendingRequests() }
        #expect(try Data(contentsOf: file) == Data("{corrupt".utf8))
        try FileManager.default.removeItem(at: file)
        let foreign = f.root.appendingPathComponent("foreign.json"); try bytes.write(to: foreign)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: foreign)
        #expect(throws: OAuthFailure.temporarilyUnavailable) { try f.store.register(redirectURIs: ["https://claude.ai/callback"]) }
        #expect(try Data(contentsOf: foreign) == bytes)
    }
}
private extension OAuthStore.BrowserResult { var isWaiting: Bool { if case .waiting = self { true } else { false } } }
private struct Flow {
    let id: UUID
    let browser: String
    let authorization: [String: String]
    let verifier: String
    func exchange(code: String) -> [String: String] {
        ["grant_type": "authorization_code", "code": code, "code_verifier": verifier, "client_id": authorization["client_id"]!, "redirect_uri": authorization["redirect_uri"]!, "resource": authorization["resource"]!]
    }
}
private struct TokenFixture { let access_token: String; let refresh_token: String; let clientID: String }
private struct Fixture {
    let root: URL
    let store: OAuthStore
    let profile: MCPAccessProfile
    let vault: URL
    let resource = "https://vauldy.example.test/mcp"
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-oauth-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = OAuthStore(installation: MCPInstallation(root: root.appendingPathComponent("installation")))
        try store.configure(OAuthConfiguration(origin: "https://vauldy.example.test"))
        let document = VaultDocument(title: "Synthetischer Beleg", sourceName: "example.pdf", ocrText: "--- Seite 1 ---\nFahrradwartung 49,99 EUR.", pageCount: 1)
        vault = root.appendingPathComponent("documents.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([document]).write(to: vault)
        profile = MCPAccessProfile(vaultPath: vault.path, allowedDocumentIDs: [document.id], enabled: true, acknowledgedCloudDisclosure: true)
        let installer = store.installation
        let path = installer.profileURL(profile.connectionID)
        try FileMCPProfileSource(url: path).save(profile)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func flow(_ provider: OAuthProvider) throws -> Flow {
        let client = try store.register(redirectURIs: [provider == .chatgpt ? "https://chatgpt.com/connector_platform_oauth_redirect" : "https://claude.ai/api/mcp/auth_callback"])
        let verifier = try OAuthStore.randomToken()
        let fields = ["response_type": "code", "client_id": client.id, "redirect_uri": client.redirectURIs[0], "resource": resource,
                      "scope": "documents:read", "state": "test-state", "code_challenge_method": "S256", "code_challenge": OAuthStore.challenge(for: verifier)]
        let pending = try store.begin(fields)
        return .init(id: pending.request.id, browser: pending.browser, authorization: fields, verifier: verifier)
    }
    func code(_ browser: String) throws -> String {
        guard case .redirect(let value) = try store.browserResult(browser), let components = URLComponents(string: value),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { throw OAuthFailure.invalidGrant }
        #expect(components.queryItems?.contains(where: { $0.name == "iss" && $0.value == "https://vauldy.example.test" }) == true)
        return code
    }
    func tokens(_ provider: OAuthProvider) throws -> TokenFixture {
        let flow = try flow(provider)
        try store.approve(flow.id, profileID: profile.connectionID, expectedRevision: profile.revision)
        let tokens = try store.exchange(flow.exchange(code: code(flow.browser)))
        return .init(access_token: tokens.access_token, refresh_token: tokens.refresh_token, clientID: flow.authorization["client_id"]!)
    }
}

private struct FixedMetadata: OAuthClientMetadataLoader {
    let data: Data
    func load(_ url: URL) async throws -> Data { data }
}
