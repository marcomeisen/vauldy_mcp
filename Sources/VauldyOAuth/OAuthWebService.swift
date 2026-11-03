import Foundation

public struct OAuthWebRequest: Sendable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data
    public init(method: String, target: String, headers: [String: String], body: Data = Data()) {
        self.method = method; self.target = target; self.headers = headers; self.body = body
    }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}
public struct OAuthWebResponse: Sendable {
    public let status: Int
    public var headers: [String: String]
    public let body: Data
    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
        self.headers["Cache-Control"] = "no-store"
        self.headers["Pragma"] = "no-cache"
        self.headers["Referrer-Policy"] = "no-referrer"
        self.headers["X-Content-Type-Options"] = "nosniff"
        self.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    }
    public static func json(_ value: [String: Any], status: Int = 200, headers: [String: String] = [:]) -> Self {
        var headers = headers; headers["Content-Type"] = "application/json"
        return .init(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)) ?? Data("{}".utf8))
    }
}
/// OAuth routes contain no remote approval action and never load document content.
public struct OAuthWebService: Sendable {
    public let store: OAuthStore
    public let configuration: OAuthConfiguration
    private let metadataLoader: any OAuthClientMetadataLoader
    public init(store: OAuthStore, configuration: OAuthConfiguration, metadataLoader: any OAuthClientMetadataLoader = PublicOAuthClientMetadataLoader()) {
        self.store = store; self.configuration = configuration; self.metadataLoader = metadataLoader
    }
    public var challenge: String { "Bearer resource_metadata=\"\(configuration.origin)/.well-known/oauth-protected-resource\", scope=\"documents:read\"" }
    public func handle(_ request: OAuthWebRequest) async -> OAuthWebResponse {
        do {
            guard request.target.utf8.count <= 8192, request.body.count <= 65536,
                  let target = URLComponents(string: request.target), target.scheme == nil, target.host == nil,
                  !request.target.contains("#") else { throw OAuthFailure.invalidRequest }
            switch (request.method, target.path) {
            case ("GET", "/.well-known/oauth-protected-resource"), ("GET", "/.well-known/oauth-protected-resource/mcp"):
                return .json(["resource": configuration.resource, "authorization_servers": [configuration.origin], "scopes_supported": ["documents:read"], "bearer_methods_supported": ["header"], "resource_name": "Vauldy Dokumente"])
            case ("GET", "/.well-known/oauth-authorization-server"):
                // This service issues connector tokens, not host identity or OpenID ID tokens.
                return .json(["issuer": configuration.origin, "authorization_endpoint": configuration.origin + "/oauth/authorize",
                    "token_endpoint": configuration.origin + "/oauth/token", "registration_endpoint": configuration.origin + "/oauth/register",
                    "revocation_endpoint": configuration.origin + "/oauth/revoke", "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code", "refresh_token"], "token_endpoint_auth_methods_supported": ["none"],
                    "code_challenge_methods_supported": ["S256"], "scopes_supported": ["documents:read"],
                    "authorization_response_iss_parameter_supported": true, "client_id_metadata_document_supported": true])
            case ("POST", "/oauth/register"):
                guard request.header("content-type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
                      let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      let redirects = object["redirect_uris"] as? [String],
                      object["token_endpoint_auth_method"] == nil || object["token_endpoint_auth_method"] as? String == "none",
                      object["grant_types"] == nil || (object["grant_types"] as? [String]).map({ Set($0).isSubset(of: ["authorization_code", "refresh_token"]) && $0.contains("authorization_code") }) == true,
                      object["response_types"] == nil || object["response_types"] as? [String] == ["code"] else { throw OAuthFailure.invalidClient }
                let client = try store.register(redirectURIs: redirects)
                return .json(["client_id": client.id, "client_id_issued_at": Int(client.createdAt.timeIntervalSince1970), "redirect_uris": client.redirectURIs,
                              "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]], status: 201)
            case ("GET", "/oauth/authorize"):
                let fields = try Self.fields(target.queryItems ?? [])
                guard let clientID = fields["client_id"] else { throw OAuthFailure.invalidClient }
                try await resolveClient(clientID)
                let pending = try store.begin(fields)
                return .init(status: 303, headers: ["Location": configuration.origin + "/oauth/continue",
                    "Set-Cookie": "vauldy_oauth=\(pending.browser); Path=/oauth/continue; Secure; HttpOnly; SameSite=Lax; Max-Age=600"])
            case ("GET", "/oauth/continue"):
                let cookies = (request.header("cookie") ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                let matches = cookies.filter { $0.hasPrefix("vauldy_oauth=") }
                guard matches.count == 1 else { throw OAuthFailure.invalidRequest }
                let browser = String(matches[0].dropFirst("vauldy_oauth=".count))
                switch try store.browserResult(browser) {
                case .redirect(let url):
                    return .init(status: 303, headers: ["Location": url, "Set-Cookie": "vauldy_oauth=; Path=/oauth/continue; Secure; HttpOnly; SameSite=Lax; Max-Age=0"])
                case .expired: return Self.html("Verbindung abgelaufen. Bitte im Chatbot erneut verbinden.", status: 410)
                case .waiting(let info):
                    return Self.html("<meta http-equiv=\"refresh\" content=\"2\"><h1>\(info.provider.title) mit Vauldy verbinden</h1><p><a href=\"vauldy-mcp://oauth\">Vauldy auf diesem Mac öffnen</a></p><p>Wähle in der App ChatGPT &amp; Claude.</p><p>Vergleiche die Kennung <strong>\(info.confirmation)</strong> und bestätige dort die gewünschte Dokumentauswahl.</p><p>Dieses Fenster kehrt nach deiner Freigabe automatisch zum Chatbot zurück. Ohne lokale Freigabe erhält niemand Zugriff.</p>")
                }
            case ("POST", "/oauth/token"):
                let fields = try Self.form(request)
                let response = try store.exchange(fields)
                let encoded = try JSONEncoder().encode(response)
                return .init(headers: ["Content-Type": "application/json"], body: encoded)
            case ("POST", "/oauth/revoke"):
                let fields = try Self.form(request)
                guard let token = fields["token"], let client = fields["client_id"] else { throw OAuthFailure.invalidRequest }
                try store.revoke(token: token, clientID: client)
                return .init()
            default: return .json(["error": "not_found"], status: 404)
            }
        } catch let error as OAuthFailure {
            return .json(["error": error.rawValue], status: error == .temporarilyUnavailable ? 503 : (error == .invalidClient ? 401 : 400))
        } catch { return .json(["error": "invalid_request"], status: 400) }
    }
    private func resolveClient(_ id: String) async throws {
        if try store.client(id) != nil { return }
        guard let url = URL(string: id), OAuthProvider.provider(for: url) != nil,
              id.count <= 2048, !id.contains("%"), !url.path.contains("..") else { throw OAuthFailure.invalidClient }
        let data = try await metadataLoader.load(url)
        guard data.count <= 16384 else { throw OAuthFailure.invalidClient }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["client_id"] as? String == id, let redirects = json["redirect_uris"] as? [String] else { throw OAuthFailure.invalidClient }
        let methods = json["token_endpoint_auth_methods_supported"] as? [String] ?? [json["token_endpoint_auth_method"] as? String ?? "none"]
        guard methods.contains("none") else { throw OAuthFailure.invalidClient }
        _ = try store.register(redirectURIs: redirects, clientID: id)
    }
    private static func form(_ request: OAuthWebRequest) throws -> [String: String] {
        guard request.header("content-type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/x-www-form-urlencoded",
              let text = String(data: request.body, encoding: .utf8),
              let components = URLComponents(string: "?" + text.replacingOccurrences(of: "+", with: "%20")) else { throw OAuthFailure.invalidRequest }
        return try fields(components.queryItems ?? [])
    }
    private static func fields(_ items: [URLQueryItem]) throws -> [String: String] {
        guard items.count <= 20 else { throw OAuthFailure.invalidRequest }
        var result: [String: String] = [:]
        for item in items {
            guard item.name.count <= 100, result[item.name] == nil, let value = item.value,
                  value.utf8.count <= 4096 else { throw OAuthFailure.invalidRequest }
            result[item.name] = value
        }
        return result
    }
    private static func html(_ content: String, status: Int = 200) -> OAuthWebResponse {
        .init(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(("<!doctype html><html lang=\"de\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Vauldy verbinden</title><body>" + content + "</body></html>").utf8))
    }
}
public protocol OAuthClientMetadataLoader: Sendable { func load(_ url: URL) async throws -> Data }
public struct PublicOAuthClientMetadataLoader: OAuthClientMetadataLoader {
    public init() {}
    public func load(_ url: URL) async throws -> Data {
        guard OAuthProvider.provider(for: url) != nil, !url.absoluteString.contains("%"), !url.path.contains("..") else { throw OAuthFailure.invalidClient }
        // Public first-party CIMD only. No arbitrary hosts, redirects, credentials or private network SSRF.
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCredentialStorage = nil; settings.httpCookieStorage = nil; settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url == url,
              http.expectedContentLength <= 16384 else { throw OAuthFailure.invalidClient }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16384 else { throw OAuthFailure.invalidClient }; data.append(byte)
        }
        return data
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
