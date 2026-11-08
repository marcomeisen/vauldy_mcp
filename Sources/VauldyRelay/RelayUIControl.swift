import Foundation
import VauldyMCPRuntime
import VauldyCore

/// Safe local UI protocol. Secrets never leave the credential-owning agent.
public struct RelayUIState: Codable, Sendable {
    public var keychainNeedsApproval = false
    public var grantNeedsUpdate = false
    public var supportsGrantUpdate = true
    public var provisioned = false
    public var paired = false
    public var pairID: String?
    public var pairingExpires: Date?
    public var profileID: UUID?
    public var running = false
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case keychainNeedsApproval, grantNeedsUpdate, supportsGrantUpdate, provisioned, paired, pairID, pairingExpires, profileID, running
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keychainNeedsApproval = try c.decodeIfPresent(Bool.self, forKey: .keychainNeedsApproval) ?? false
        grantNeedsUpdate = try c.decodeIfPresent(Bool.self, forKey: .grantNeedsUpdate) ?? false
        supportsGrantUpdate = try c.decodeIfPresent(Bool.self, forKey: .supportsGrantUpdate) ?? false
        provisioned = try c.decodeIfPresent(Bool.self, forKey: .provisioned) ?? false
        paired = try c.decodeIfPresent(Bool.self, forKey: .paired) ?? false
        pairID = try c.decodeIfPresent(String.self, forKey: .pairID)
        pairingExpires = try c.decodeIfPresent(Date.self, forKey: .pairingExpires)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
    }
    init(credentials: RelayCredentials?, running: Bool) {
        provisioned = credentials != nil; paired = credentials?.paired ?? false
        pairID = credentials?.pairID; pairingExpires = credentials?.pairingExpires
        profileID = credentials?.profileID; self.running = running
    }
}
public struct RelayUIRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case status, begin, start, disconnect, rotate, authorize, updateGrant
        public var allowsUserInteraction: Bool { self == .authorize }
        public var timeoutSeconds: TimeInterval { self == .authorize ? 300 : self == .status ? 5 : self == .updateGrant ? 180 : 45 } }
    public var operation: Operation
    public var profileID: UUID?
    public var revision: UUID?
    public var nativeVerification: MCPNativeOriginalVerification?
    public var profileFingerprint: String?
    public var documentIDs: [UUID]?
    public var snapshotDigest: String?
    public var acknowledgedDisclosure: Bool?
    public var acknowledgedReview: Bool?
    public init(_ operation: Operation, profileID: UUID? = nil, revision: UUID? = nil) {
        self.operation = operation; self.profileID = profileID; self.revision = revision
    }
    public init(profileID: UUID, revision: UUID, profileFingerprint: String, documentIDs: Set<UUID>, snapshotDigest: String, nativeVerification: MCPNativeOriginalVerification,
                acknowledgedReview: Bool) {
        operation = .updateGrant; self.profileID = profileID; self.revision = revision; self.profileFingerprint = profileFingerprint
        self.documentIDs = documentIDs.sorted { $0.uuidString < $1.uuidString }; self.snapshotDigest = snapshotDigest
        acknowledgedDisclosure = true; self.acknowledgedReview = acknowledgedReview; self.nativeVerification = nativeVerification
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
        await handle(request, store: RelayCredentialStore(installation: installation)) {
            try await RelayUIControl(installation: installation).request(.init(.status))
        }
    }
    static func handle(_ request: RelayUIRequest, store: RelayCredentialStore,
                       verifyAuthorization: @escaping @Sendable () async throws -> RelayUIResponse) async -> RelayUIResponse {
        let installation = store.installation, service = RelayService(installation: store.installation)
        var url: URL?, problem: String?, snapshot: RelayCredentials?
        var ownerApprovalNeeded = false
        do {
            if request.operation == .disconnect { try service.requestStop() }
            // No redundant reads on errors or after an authorization request.
            let credentials = request.operation == .rotate ? nil : try store.load(interactive: request.operation.allowsUserInteraction)
            snapshot = credentials
            switch request.operation {
            case .status: break
            case .updateGrant:
                guard let credentials, credentials.paired, let id = request.profileID, credentials.profileID == id,
                      let revision = request.revision, let fingerprint = request.profileFingerprint, let requested = request.documentIDs, requested.count <= 20_000,
                      Set(requested).count == requested.count, let digest = request.snapshotDigest,
                      request.acknowledgedDisclosure == true, let verification = request.nativeVerification else { throw RelayFailure.changedGrant }
                let localStore = LocalDocumentStore(root: installation.root.appendingPathComponent("vault"))
                let profile = try FileMCPProfileSource(url: installation.profileURL(id)).load()
                guard profile.revision == revision, try profile.disclosureFingerprint() == fingerprint, LocalDocumentStore.resolvedSnapshotURL(URL(fileURLWithPath: profile.vaultPath)) == localStore.snapshotURL else { throw RelayFailure.changedGrant }
                let report = try await MCPInventoryQualityService(store: localStore).report(using: verification)
                guard report.snapshotDigest == digest else { throw LocalInventoryError.changed }
                try report.validateSelection(Set(requested), acknowledgedReview: request.acknowledgedReview == true)
                try service.requestStop()
                for _ in 0..<100 {
                    if !service.isRunning { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !service.isRunning else { throw RelayFailure.unavailable }
                try Task.checkCancellation()
                let updated = try store.updateGrant(profileID: id, expectedRevision: revision, expectedFingerprint: fingerprint, ids: Set(requested), digest: digest, expectedDeviceToken: credentials.deviceToken)
                snapshot = updated
                let current = try FileMCPProfileSource(url: installation.profileURL(id)).load()
                if current.enabled, !current.allowedDocumentIDs.isEmpty {
                    _ = try updated.validatedProfile(installation: installation)
                    try service.start(executable: installation.root.appendingPathComponent("bin/vauldy-relay"))
                }

            case .authorize:
                guard credentials != nil else { throw RelayFailure.notProvisioned }
                // A fresh, noninteractive process verifies background access. A
                // one-time read approval must not start a new password loop.
                let verified = try await verifyAuthorization()
                guard !verified.state.keychainNeedsApproval, verified.error == nil,
                      verified.state.provisioned else { throw RelayFailure.ownerApprovalRequired }
            case .begin:
                guard let credentials else { throw RelayFailure.notProvisioned }
                guard !credentials.paired, credentials.pairID == nil, let id = request.profileID, let revision = request.revision else { throw RelayFailure.signInRequired }
                let source = FileMCPProfileSource(url: installation.profileURL(id)), profile = try source.load()
                guard profile.revision == revision else { throw RelayFailure.changedGrant }
                let (pending, target) = try await RelayClient(credentials: credentials).start(profile: profile)
                guard try source.load() == profile else { throw RelayFailure.changedGrant }
                try store.save(pending); snapshot = pending; url = target
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
            case .rotate:
                try service.requestStop()
                for _ in 0..<50 {
                    if !service.isRunning { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !service.isRunning else { throw RelayFailure.unavailable }
                let current = try store.prepareDeviceRotation()
                guard let next = current.pendingDeviceToken else { throw RelayFailure.credentials }
                try await RelayClient(credentials: current).rotate(nextToken: next)
                // Confirm invalidation without printing either credential.
                do {
                    _ = try await RelayClient(credentials: current).poll()
                    throw RelayFailure.credentials
                } catch RelayFailure.signInRequired { }
                try store.completeDeviceRotation(expectedToken: current.deviceToken, nextToken: next)
                var updated = current; updated.deviceToken = next; updated.pendingDeviceToken = nil; snapshot = updated
                try service.start(executable: installation.root.appendingPathComponent("bin/vauldy-relay"))
            case .disconnect:
                try store.clearDevice(); snapshot = credentials.map { RelayCredentials(serviceToken: $0.serviceToken) }
                if let credentials, credentials.paired { try await RelayClient(credentials: credentials).disconnect() }
            }
        } catch RelayFailure.ownerApprovalRequired {
            ownerApprovalNeeded = true; problem = RelayFailure.ownerApprovalRequired.errorDescription
        } catch { problem = (error as? LocalizedError)?.errorDescription ?? "Die Verbindung konnte nicht geändert werden." }
        var state = RelayUIState(credentials: snapshot, running: service.isRunning)
        if let c = snapshot, c.paired {
            if let id = c.profileID, let p = try? FileMCPProfileSource(url: installation.profileURL(id)).load() {
                state.grantNeedsUpdate = p.revision != c.revision || (try? RelayCredentials.fingerprint(p)) != c.profileFingerprint
            } else { state.grantNeedsUpdate = true }
        }
        state.keychainNeedsApproval = ownerApprovalNeeded
        if ownerApprovalNeeded { state.provisioned = true }
        return .init(state: state, authorizationURL: url, error: problem)
    }
}

public struct RelayUIControl: Sendable {
    public let installation: MCPInstallation
    public init(installation: MCPInstallation) { self.installation = installation }
    public func request(_ request: RelayUIRequest) async throws -> RelayUIResponse {
        let installation = installation, bytes = try JSONEncoder().encode(request)
        guard bytes.count <= 3_000_000 else { throw RelayFailure.unavailable }
        let task = Task.detached { () async throws -> RelayUIResponse in
            let executable = installation.root.appendingPathComponent("bin/vauldy-relay")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .init(state: .init()) }
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = executable; process.arguments = ["--manage", "--root", installation.root.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() }; try? output.fileHandleForReading.close() }
            try input.fileHandleForWriting.write(contentsOf: bytes); try input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(request.operation.timeoutSeconds)
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
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

public enum RelayStatusRefreshPolicy {
    public static func shouldRefresh(approvalNeeded: Bool, hasError: Bool, busy: Bool, explicit: Bool) -> Bool {
        !busy && (explicit || (!approvalNeeded && !hasError))
    }
}

public enum RelayUIInput {
    /// Pipe reads may return fragments. Decode only after EOF, with a hard bound.
    public static func request(from input: FileHandle) throws -> RelayUIRequest {
        var data = Data()
        while let part = try input.read(upToCount: min(65_536, 3_000_001 - data.count)), !part.isEmpty {
            data.append(part)
            guard data.count <= 3_000_000 else { throw RelayFailure.unavailable }
        }
        return try JSONDecoder().decode(RelayUIRequest.self, from: data)
    }
}
