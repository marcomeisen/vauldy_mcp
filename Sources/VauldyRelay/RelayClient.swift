import Foundation
import CryptoKit
import VauldyMCPRuntime

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct RelayJob: Decodable, Sendable {
    public let id: String
    public let public_key: String
    public let request: String
    public let expires: Int
}
public struct RelayClient: Sendable {
    public let credentials: RelayCredentials
    public init(credentials: RelayCredentials) { self.credentials = credentials }
    public func request(_ path: String, body: Data) async throws -> (Data, Int) {
        guard path.hasPrefix("/api/"), !path.contains(".."), body.count <= 256000 else { throw RelayFailure.unavailable }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let req = try preparedRequest(path, body: body)
        let (data, response) = try await session.data(for: req)
        guard data.count <= 256000, let response = response as? HTTPURLResponse else { throw RelayFailure.unavailable }
        if response.statusCode == 401 || response.statusCode == 403 { throw RelayFailure.signInRequired }
        guard (200...299).contains(response.statusCode) else { throw RelayFailure.unavailable }
        return (data, response.statusCode)
    }
    // Credentials belong only in the TLS-protected request body. Custom headers
    // can be retained by infrastructure request logs, even without app logging.
    func preparedRequest(_ path: String, body: Data) throws -> URLRequest {
        guard path.hasPrefix("/api/"), !path.contains(".."), body.count <= 256000 else { throw RelayFailure.unavailable }
        var req = URLRequest(url: URL(string: RelayCredentials.origin + path)!); req.httpMethod = "POST"; req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + credentials.serviceToken, forHTTPHeaderField: "OAI-Sites-Authorization")
        if path.hasPrefix("/api/device/") {
            guard let token = credentials.deviceToken,
                  var value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw RelayFailure.signInRequired }
            value["deviceToken"] = token
            req.httpBody = try JSONSerialization.data(withJSONObject: value)
        } else { req.httpBody = body }
        guard (req.httpBody?.count ?? 0) <= 256000 else { throw RelayFailure.unavailable }
        return req

    }
    public func rotate(nextToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["nextDeviceToken": nextToken])
        let (data, _) = try await request("/api/device/rotate", body: body)
        struct Rotated: Decodable { let rotated: Bool }
        guard try JSONDecoder().decode(Rotated.self, from: data).rotated else { throw RelayFailure.unavailable }
    }
    public func start(profile: MCPAccessProfile) async throws -> (RelayCredentials, URL) {
        try profile.validate()
        guard profile.enabled, profile.acknowledgedCloudDisclosure else { throw MCPAccessError.notAuthorized }
        let key = P256.KeyAgreement.PrivateKey(), verifier = RelayCrypto.token()
        let body = try JSONSerialization.data(withJSONObject: ["challenge": RelayCrypto.challenge(verifier), "publicKey": key.publicKey.x963Representation.base64EncodedString()])
        let (data, _) = try await request("/api/pair/start", body: body)
        struct Start: Decodable { let id: String; let url: URL }
        let result = try JSONDecoder().decode(Start.self, from: data)
        guard result.id.count <= 100, result.url.scheme == "https", result.url.host == URL(string: RelayCredentials.origin)!.host,
              result.url.path == "/pair", result.url.user == nil, result.url.password == nil, result.url.port == nil else { throw RelayFailure.unavailable }
        var c = RelayCredentials(serviceToken: credentials.serviceToken)
        c.privateKey = key.rawRepresentation; c.deviceToken = RelayCrypto.token(); c.verifier = verifier; c.pairID = result.id
        c.pairingExpires = Date().addingTimeInterval(600); c.profileID = profile.connectionID; c.revision = profile.revision; c.profileFingerprint = try RelayCredentials.fingerprint(profile)
        return (c, result.url)
    }
    public func finish() async throws -> RelayCredentials? {
        guard let id = credentials.pairID, let verifier = credentials.verifier, let token = credentials.deviceToken,
              let expires = credentials.pairingExpires, expires > Date() else { throw RelayFailure.signInRequired }
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "verifier": verifier, "deviceToken": token])
        let (data, status) = try await request("/api/pair/finish", body: body)
        if status == 202 { return nil }
        struct Finished: Decodable { let paired: Bool }
        guard try JSONDecoder().decode(Finished.self, from: data).paired else { throw RelayFailure.unavailable }
        var c = credentials; c.paired = true; c.verifier = nil; c.pairID = nil; c.pairingExpires = nil; return c
    }
    public func poll() async throws -> RelayJob? {
        let (data, _) = try await request("/api/device/poll", body: Data("{}".utf8))
        struct Poll: Decodable { let job: RelayJob? }
        return try JSONDecoder().decode(Poll.self, from: data).job
    }
    public func disconnect() async throws { _ = try await request("/api/device/disconnect", body: Data("{}".utf8)) }
    public func result(job: RelayJob, data: Data) async throws {
        guard let privateKey = credentials.privateKey, data.count <= 180000, job.expires > Int(Date().timeIntervalSince1970) else { throw RelayFailure.unavailable }
        let key = try RelayCrypto.key(privateKey: privateKey, publicKey: job.public_key, id: job.id)
        let cipher = try RelayCrypto.seal(data, key: key, aad: job.id + ":response")
        _ = try await request("/api/device/result", body: JSONSerialization.data(withJSONObject: ["id": job.id, "result": cipher]))
    }
    public func decode(job: RelayJob) throws -> Data {
        guard UUID(uuidString: job.id) != nil, let privateKey = credentials.privateKey,
              job.expires > Int(Date().timeIntervalSince1970), job.expires <= Int(Date().timeIntervalSince1970) + 65 else { throw RelayFailure.unavailable }
        let data = try RelayCrypto.open(job.request, key: RelayCrypto.key(privateKey: privateKey, publicKey: job.public_key, id: job.id), aad: job.id + ":request")
        guard data.count <= 16000, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(obj.keys) == ["method", "params"], obj["method"] as? String == "tools/call",
              let p = obj["params"] as? [String: Any], let name = p["name"] as? String,
              ["get_vault_status", "list_documents", "search_documents", "read_document", "get_topic_overview", "extract_document_fields", "compare_contract_versions", "get_deadline_overview", "get_document_inventory"].contains(name) else { throw RelayFailure.unavailable }
        return data
    }
}
