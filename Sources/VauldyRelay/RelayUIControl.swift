import Foundation
import VauldyMCPRuntime

/// Safe local UI protocol. Secrets never leave the credential-owning agent.
public struct RelayUIState: Codable, Sendable {
    public var provisioned = false
    public var paired = false
    public var pairID: String?
    public var pairingExpires: Date?
    public var profileID: UUID?
    public var running = false
    public init() {}
    init(credentials: RelayCredentials?, running: Bool) {
        provisioned = credentials != nil; paired = credentials?.paired ?? false
        pairID = credentials?.pairID; pairingExpires = credentials?.pairingExpires
        profileID = credentials?.profileID; self.running = running
    }
}
public struct RelayUIRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case status, begin, start, disconnect }
    public var operation: Operation
    public var profileID: UUID?
    public var revision: UUID?
    public init(_ operation: Operation, profileID: UUID? = nil, revision: UUID? = nil) {
        self.operation = operation; self.profileID = profileID; self.revision = revision
    }
}
public struct RelayUIResponse: Codable, Sendable {
    public let state: RelayUIState
    public let authorizationURL: URL?
    public let error: String?
    public init(state: RelayUIState, authorizationURL: URL? = nil, error: String? = nil) {
        self.state = state; self.authorizationURL = authorizationURL; self.error = error
    }
}
public enum RelayUIManager {
    /// Called only by the agent's local --manage command, never exposed over HTTP/MCP.
    public static func handle(_ request: RelayUIRequest, installation: MCPInstallation) async -> RelayUIResponse {
        let store = RelayCredentialStore(installation: installation), service = RelayService(installation: installation)
        var url: URL?, problem: String?
        do {
            let credentials = try store.load()
            switch request.operation {
            case .status: break
            case .begin:
                guard let credentials else { throw RelayFailure.notProvisioned }
                guard !credentials.paired, credentials.pairID == nil, let id = request.profileID, let revision = request.revision else { throw RelayFailure.signInRequired }
                let source = FileMCPProfileSource(url: installation.profileURL(id)), profile = try source.load()
                guard profile.revision == revision else { throw RelayFailure.changedGrant }
                let (pending, target) = try await RelayClient(credentials: credentials).start(profile: profile)
                guard try source.load() == profile else { throw RelayFailure.changedGrant }
                try store.save(pending); url = target
                try service.start(executable: installation.root.appendingPathComponent("bin/vauldy-relay"))
            case .start:
                guard var credentials else { throw RelayFailure.notProvisioned }
                if !credentials.paired {
                    guard credentials.pairID != nil, let expires = credentials.pairingExpires, expires > Date() else { throw RelayFailure.signInRequired }
                    // Validate the confirmed profile without claiming SSO is complete.
                    credentials.paired = true
                }
                _ = try credentials.validatedProfile(installation: installation)
                try service.start(executable: installation.root.appendingPathComponent("bin/vauldy-relay"))
            case .disconnect:
                try service.requestStop(); try store.clearDevice()
                if let credentials, credentials.paired { try await RelayClient(credentials: credentials).disconnect() }
            }
        } catch { problem = (error as? LocalizedError)?.errorDescription ?? "Die Verbindung konnte nicht geändert werden." }
        return .init(state: .init(credentials: try? store.load(), running: service.isRunning), authorizationURL: url, error: problem)
    }
}

public struct RelayUIControl: Sendable {
    public let installation: MCPInstallation
    public init(installation: MCPInstallation) { self.installation = installation }
    public func request(_ request: RelayUIRequest) async throws -> RelayUIResponse {
        let installation = installation, bytes = try JSONEncoder().encode(request)
        return try await Task.detached {
            let executable = installation.root.appendingPathComponent("bin/vauldy-relay")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .init(state: .init()) }
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = executable; process.arguments = ["--manage", "--root", installation.root.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() }; try? output.fileHandleForReading.close() }
            try input.fileHandleForWriting.write(contentsOf: bytes); try input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(25)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            guard !process.isRunning, process.terminationStatus == 0 else { throw RelayFailure.unavailable }
            let data = try output.fileHandleForReading.read(upToCount: 8001) ?? Data()
            guard data.count <= 8000 else { throw RelayFailure.unavailable }
            let response = try JSONDecoder().decode(RelayUIResponse.self, from: data)
            if let url = response.authorizationURL {
                guard url.scheme == "https", url.host == URL(string: RelayCredentials.origin)!.host, url.path == "/pair",
                      url.user == nil, url.password == nil, url.port == nil else { throw RelayFailure.unavailable }
            }
            return response
        }.value
    }
}
