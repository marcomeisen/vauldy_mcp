import Foundation
import MCP
import VauldyMCPRuntime
import VauldyMCPProtocol
import VauldyOAuth

actor HTTPRouter {
    let configuration: VauldyOAuth.OAuthConfiguration
    let store: OAuthStore
    private let web: OAuthWebService
    private struct Session {
        let grant: UUID
        let transport: StatelessHTTPServerTransport
        let server: Server
        let presence: MCPProcessPresence
        var used: Date
        var inFlight: Set<String> = []
    }
    private var sessions: [String: Session] = [:]
    init(store: OAuthStore, configuration: VauldyOAuth.OAuthConfiguration) {
        self.store = store; self.configuration = configuration; web = .init(store: store, configuration: configuration)
    }
    func handle(_ request: OAuthWebRequest) async -> OAuthWebResponse {
        let origin = request.header("origin")
        let trusted = [configuration.origin, "https://chatgpt.com", "https://claude.ai", "https://claude.com"]
        guard origin == nil || trusted.contains(origin!),
              let host = request.header("host"),
              [URL(string: configuration.origin)!.host! + (URL(string: configuration.origin)!.port.map { ":\($0)" } ?? ""), "127.0.0.1:\(configuration.port)"].contains(host.lowercased()),
              request.header("authorization")?.contains(",") != true else { return .json(["error": "invalid_request"], status: 403) }
        guard let target = URLComponents(string: request.target), target.scheme == nil, target.host == nil else { return .json(["error": "invalid_request"], status: 400) }
        if target.path != "/mcp" { return await web.handle(request) }
        guard target.query == nil else { return .json(["error": "invalid_request"], status: 400) }
        let auth = (request.header("authorization") ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard auth.count == 2, auth[0].lowercased() == "bearer", auth[1].count == 43 else { return unauthorized() }
        let token = String(auth[1])
        do {
            let owner = try store.authorize(token)
            await prune()
            if request.method == "GET" { return .init(status: 405, headers: ["Allow": "POST, DELETE"]) }
            let transport: StatelessHTTPServerTransport
            let server: Server
            let id: String
            if let existing = request.header("mcp-session-id") {
                guard var session = sessions[existing], session.grant == owner.grantID else { return .json(["error": "session_not_found"], status: 404) }
                session.used = Date(); sessions[existing] = session
                if let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any], object["method"] as? String == "initialize" {
                    return .json(["error": "already_initialized"], status: 400)
                }
                id = existing; transport = session.transport; server = session.server
            } else {
                guard request.method == "POST", let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      object["method"] as? String == "initialize", sessions.count < 32,
                      sessions.values.filter({ $0.grant == owner.grantID }).count < 4 else { return .json(["error": "session_required"], status: 400) }
                id = UUID().uuidString
                transport = StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(), ProtocolVersionValidator()]))
                let source = OAuthProfileSource(store: store, grantID: owner.grantID)
                let audit = MCPAuditLog(profileURL: owner.profileURL)
                try audit.append(.serverStarted)
                let presence = try MCPProcessPresence(root: store.installation.root, connectionID: owner.profileID)
                server = await VauldyMCPServerFactory.make(profile: source, audit: audit) { presence.recordRequest() }
                try await server.start(transport: InitializationCompatibilityTransport(base: transport, oauthMetadata: true))
                sessions[id] = .init(grant: owner.grantID, transport: transport, server: server, presence: presence, used: Date())
            }
            if request.method == "DELETE" {
                sessions.removeValue(forKey: id); await server.stop()
                return .init()
            }
            let rpcID: String?
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any], let value = json["id"] {
                let identifier = String(describing: value)
                guard identifier.utf8.count <= 128, sessions[id]?.inFlight.contains(identifier) == false else {
                    return .json(["error": "duplicate_or_invalid_id"], status: 400)
                }
                rpcID = identifier; sessions[id]?.inFlight.insert(identifier)
            } else { rpcID = nil }
            defer { if let rpcID { sessions[id]?.inFlight.remove(rpcID) } }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(30)); await transport.disconnect() } catch {}
            }
            defer { deadline.cancel() }
            let response = await transport.handleRequest(.init(method: request.method, headers: request.headers, body: request.body.isEmpty ? nil : request.body, path: "/mcp"))
            let body = response.bodyData ?? Data()
            guard body.count <= 262144 else { throw OAuthFailure.temporarilyUnavailable }
            // Revocation/expiry/profile changes during processing suppress every outgoing byte.
            let current = try store.authorize(token)
            guard current.grantID == owner.grantID else { throw OAuthFailure.invalidToken }
            if request.method == "DELETE" || response.statusCode >= 400 && request.header("mcp-session-id") == nil {
                sessions.removeValue(forKey: id); await server.stop()
            }
            var headers = response.headers; headers["Mcp-Session-Id"] = id
            return .init(status: response.statusCode, headers: headers, body: body)
        } catch {
            return unauthorized()
        }
    }
    private func unauthorized() -> OAuthWebResponse { .json(["error": "invalid_token"], status: 401, headers: ["WWW-Authenticate": web.challenge]) }
    private func prune() async {
        let expired = sessions.filter { Date().timeIntervalSince($0.value.used) > 600 }
        for (id, session) in expired { sessions.removeValue(forKey: id); await session.server.stop() }
    }
    func stop() async { for session in sessions.values { await session.server.stop() }; sessions.removeAll() }
}
