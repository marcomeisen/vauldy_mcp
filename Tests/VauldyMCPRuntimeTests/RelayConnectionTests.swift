import Foundation
import Testing
import CryptoKit
import VauldyMCPRuntime
@testable import VauldyRelay

@Suite("Keyless ChatGPT relay")
struct RelayConnectionTests {
    @Test func realLocalTransportPreservesHandlesPrivacyAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-relay-wire-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = MCPInstallation(root: root)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = project.appendingPathComponent(".build/debug/vauldy-mcp")
        try FileManager.default.createDirectory(at: installation.binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: server, to: installation.binaryURL)
        let document = UUID(), vault = root.appendingPathComponent("documents.json")
        let bytes = try JSONSerialization.data(withJSONObject: [["id": document.uuidString, "title": "Synthetic insurance", "sourceName": "secret-local-source.pdf", "status": "indexed", "pageCount": 1, "ocrText": "--- Seite 1 ---\nFahrradversicherung 49,99 EUR.\nE-Mail: erika@example.com"]])
        try bytes.write(to: vault)
        var p = MCPAccessProfile(vaultPath: vault.path, allowedDocumentIDs: [document], enabled: true, acknowledgedCloudDisclosure: true)
        let source = FileMCPProfileSource(url: installation.profileURL(p.connectionID)); try source.save(p)
        let child = try await RelayLocalMCP(installation: installation, profile: source.url); defer { child.close() }
        func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let data = try await child.call(JSONSerialization.data(withJSONObject: ["method": "tools/call", "params": ["name": name, "arguments": arguments]]))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let listed = try await call("list_documents", ["includeExcerpts": false])
        let value = try #require(listed["structuredContent"] as? [String: Any])
        let item = try #require((value["items"] as? [[String: Any]])?.first)
        let handle = try #require(item["document"] as? String)
        let read = try await call("read_document", ["document": handle])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: read), as: UTF8.self)
        #expect(!text.contains("erika@example.com") && !text.contains("secret-local-source.pdf"))
        #expect(text.contains("49,99"))
        p.enabled = false; p.revision = UUID(); try source.save(p)
        let denied = try await call("read_document", ["document": handle])
        #expect(denied["isError"] as? Bool == true)
        #expect(try Data(contentsOf: vault) == bytes)
    }
    @Test func deviceAuthenticationNeverUsesURLOrLoggedCustomHeaders() throws {
        var c = RelayCredentials(serviceToken: "synthetic-service")
        c.deviceToken = "synthetic-private-device"; c.pendingDeviceToken = "synthetic-private-pending"
        let client = RelayClient(credentials: c)
        let request = try client.preparedRequest("/api/device/poll", body: Data("{}".utf8))
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers.keys.allSatisfy { $0.lowercased() != "x-vauldy-device" })
        #expect(!headers.values.contains(c.deviceToken!) && !headers.values.contains(c.pendingDeviceToken!))
        #expect(!request.url!.absoluteString.contains("synthetic-private"))
        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let payload = try #require(object as? [String: String])
        #expect(payload["deviceToken"] == c.deviceToken)
        let pairing = try client.preparedRequest("/api/pair/start", body: Data("{}".utf8))
        #expect(String(decoding: pairing.httpBody!, as: UTF8.self) == "{}")
    }
    @Test func nativeUIStateNeverDisclosesCredentialMaterial() throws {
        var c = RelayCredentials(serviceToken: "DO-NOT-DISCLOSE-service")
        c.deviceToken = "DO-NOT-DISCLOSE-device"; c.privateKey = Data("DO-NOT-DISCLOSE-private".utf8)
        c.pendingDeviceToken = "DO-NOT-DISCLOSE-pending"; c.verifier = "DO-NOT-DISCLOSE-verifier"; c.pairID = "public-pair-id"
        let state = RelayUIState(credentials: c, running: true)
        let data = try JSONEncoder().encode(RelayUIResponse(state: state))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("DO-NOT-DISCLOSE") && !text.contains("serviceToken") && !text.contains("privateKey") && !text.contains("verifier"))
        #expect(state.provisioned && state.running && state.pairID == "public-pair-id")
    }
    @Test func webCryptoEnvelopeIsReadableByNativeCryptoKit() throws {
        struct Vector: Decodable { let testOnly: Bool; let privateKey: Data; let publicKey: String; let id: String; let cipher: String }
        let url = try #require(Bundle.module.url(forResource: "relay-webcrypto-vector", withExtension: "json"))
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        #expect(vector.testOnly)
        let key = try RelayCrypto.key(privateKey: vector.privateKey, publicKey: vector.publicKey, id: vector.id)
        let plain = try RelayCrypto.open(vector.cipher, key: key, aad: vector.id + ":request")
        let decoded = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        let params = try #require(decoded["params"] as? [String: Any])
        let args = try #require(params["arguments"] as? [String: Any])
        #expect(args["query"] as? String == "Ärztliche Belege 49,99 €")
    }
    @Test func encryptionBindsDirectionRequestAndDevice() throws {
        let mac = P256.KeyAgreement.PrivateKey(), cloud = P256.KeyAgreement.PrivateKey(), id = UUID().uuidString
        let a = try RelayCrypto.key(privateKey: mac.rawRepresentation, publicKey: cloud.publicKey.x963Representation.base64EncodedString(), id: id)
        let b = try RelayCrypto.key(privateKey: cloud.rawRepresentation, publicKey: mac.publicKey.x963Representation.base64EncodedString(), id: id)
        let plain = Data("synthetic protected result".utf8)
        let cipher = try RelayCrypto.seal(plain, key: a, aad: id + ":response")
        #expect(try RelayCrypto.open(cipher, key: b, aad: id + ":response") == plain)
        #expect(throws: (any Error).self) { try RelayCrypto.open(cipher, key: b, aad: id + ":request") }
        let wrong = try RelayCrypto.key(privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation, publicKey: mac.publicKey.x963Representation.base64EncodedString(), id: id)
        #expect(throws: (any Error).self) { try RelayCrypto.open(cipher, key: wrong, aad: id + ":response") }
        let other = try RelayCrypto.key(privateKey: cloud.rawRepresentation, publicKey: mac.publicKey.x963Representation.base64EncodedString(), id: UUID().uuidString)
        #expect(throws: (any Error).self) { try RelayCrypto.open(cipher, key: other, aad: id + ":response") }
    }
    @Test func pairingDoesNotAuthorizeChangedPausedRemovedOrUnconfirmedProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-relay-grant-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = MCPInstallation(root: root)
        var profile = MCPAccessProfile(vaultPath: root.appendingPathComponent("synthetic.json").path, allowedDocumentIDs: [UUID()], enabled: true, acknowledgedCloudDisclosure: true)
        let source = FileMCPProfileSource(url: installation.profileURL(profile.connectionID)); try source.save(profile)
        let before = try Data(contentsOf: source.url)
        var c = RelayCredentials(serviceToken: "synthetic-service-token")
        c.profileID = profile.connectionID; c.revision = profile.revision; c.profileFingerprint = try RelayCredentials.fingerprint(profile)
        #expect(throws: RelayFailure.signInRequired) { try c.validatedProfile(installation: installation) }
        c.paired = true; #expect(try c.validatedProfile(installation: installation) == source.url)
        #expect(try Data(contentsOf: source.url) == before)
        // A manual writer keeping the old revision must not enlarge the grant either.
        profile.allowedDocumentIDs.insert(UUID()); try source.save(profile)
        #expect(throws: RelayFailure.changedGrant) { try c.validatedProfile(installation: installation) }
        profile.revision = UUID(); try source.save(profile)
        #expect(throws: RelayFailure.changedGrant) { try c.validatedProfile(installation: installation) }
        c.revision = profile.revision; profile.enabled = false; try source.save(profile)
        #expect(throws: RelayFailure.changedGrant) { try c.validatedProfile(installation: installation) }
        try FileManager.default.removeItem(at: source.url)
        #expect(throws: (any Error).self) { try c.validatedProfile(installation: installation) }
    }
    @Test func incomingJobRejectsInvalidMethodExpiredAndWrongEnvelope() throws {
        let mac = P256.KeyAgreement.PrivateKey(), cloud = P256.KeyAgreement.PrivateKey(), id = UUID().uuidString
        let key = try RelayCrypto.key(privateKey: cloud.rawRepresentation, publicKey: mac.publicKey.x963Representation.base64EncodedString(), id: id)
        var c = RelayCredentials(serviceToken: "synthetic-service-token"); c.privateKey = mac.rawRepresentation
        let client = RelayClient(credentials: c)
        func job(_ plain: String, expires: Int = Int(Date().timeIntervalSince1970) + 30) throws -> RelayJob {
            let raw: [String: Any] = ["id": id, "public_key": cloud.publicKey.x963Representation.base64EncodedString(), "request": try RelayCrypto.seal(Data(plain.utf8), key: key, aad: id + ":request"), "expires": expires]
            return try JSONDecoder().decode(RelayJob.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        let valid = "{\"method\":\"tools/call\",\"params\":{\"name\":\"list_documents\",\"arguments\":{}}}"
        #expect(try client.decode(job: job(valid)) == Data(valid.utf8))
        for value in ["{\"method\":\"initialize\",\"params\":{}}", "{\"method\":\"tools/call\",\"params\":{\"name\":\"import_file\"}}", "{\"method\":\"tools/call\",\"params\":{\"name\":\"list_documents\"},\"profile\":\"foreign\"}"] {
            #expect(throws: (any Error).self) { try client.decode(job: job(value)) }
        }
        #expect(throws: (any Error).self) { try client.decode(job: job(valid, expires: 0)) }
    }
    @Test func serviceLeasePreventsDuplicateAgentAndRefusesLinkedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-relay-lease-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RelayService(installation: .init(root: root))
        #expect(!service.isRunning)
        do {
            let lease = try service.lease(); defer { withExtendedLifetime(lease) {} }
            #expect(service.isRunning)
            #expect(throws: RelayFailure.unavailable) { try service.lease() }
            try service.requestStop(); #expect(service.stopRequested)
        }
        #expect(!service.isRunning)
        let stop = service.root.appendingPathComponent("agent.stop")
        try FileManager.default.removeItem(at: stop)
        try FileManager.default.createSymbolicLink(at: stop, withDestinationURL: root.appendingPathComponent("unrelated"))
        #expect(throws: RelayFailure.credentials) { try service.prepare() }
    }
}
