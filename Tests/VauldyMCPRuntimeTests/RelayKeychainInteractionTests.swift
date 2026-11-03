import Foundation
import Testing
import VauldyMCPRuntime
@testable import VauldyRelay

private final class SyntheticRelayPersistence: RelayCredentialPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Bool] = []
    private var writes = 0
    let data: Data
    let denies: Bool
    init(denies: Bool) throws {
        self.denies = denies
        var c = RelayCredentials(serviceToken: "PRIVATE-synthetic-service")
        c.paired = true; c.deviceToken = "PRIVATE-synthetic-device"
        data = try JSONEncoder().encode(c)
    }
    func read(allowUserInteraction: Bool) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; reads.append(allowUserInteraction)
        if denies { throw RelayFailure.ownerApprovalRequired }
        return data
    }
    func write(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; writes += 1 }
    var observations: ([Bool], Int) { lock.lock(); defer { lock.unlock() }; return (reads, writes) }
}

@Suite("Explicit keychain authorization")
struct RelayKeychainInteractionTests {
    private func installation() -> MCPInstallation {
        .init(root: FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-keychain-synthetic-" + UUID().uuidString))
    }
    @Test func onlyExplicitAuthorizationCanOpenSystemUI() {
        for operation in [RelayUIRequest.Operation.status, .begin, .start, .disconnect, .rotate, .updateGrant, .authorize] {
            #expect(operation.allowsUserInteraction == (operation == .authorize))
        }
        #expect(RelayUIRequest.Operation.authorize.timeoutSeconds == 300)
        #expect(RelayUIRequest.Operation.status.timeoutSeconds == 5)
    }
    @Test(arguments: [RelayUIRequest.Operation.status, .begin, .start, .authorize])
    func denialReadsOnceAndPreservesSavedConnection(operation: RelayUIRequest.Operation) async throws {
        let persistence = try SyntheticRelayPersistence(denies: true), install = installation()
        defer { try? FileManager.default.removeItem(at: install.root) }
        let response = await RelayUIManager.handle(.init(operation), store: .init(installation: install, persistence: persistence)) {
            Issue.record("Denied authorization must not retry or verify"); return .init(state: .init())
        }
        #expect(persistence.observations.0 == [operation == .authorize])
        #expect(persistence.observations.1 == 0)
        #expect(response.state.keychainNeedsApproval && response.state.provisioned)
        #expect(response.authorizationURL == nil && response.error != nil)
        #expect(!String(decoding: try JSONEncoder().encode(response), as: UTF8.self).contains("PRIVATE-"))
    }
    @Test(arguments: [true, false])
    func authorizationVerifiesFreshNoninteractiveAccess(backgroundAllowed: Bool) async throws {
        let persistence = try SyntheticRelayPersistence(denies: false), install = installation()
        defer { try? FileManager.default.removeItem(at: install.root) }
        let response = await RelayUIManager.handle(.init(.authorize), store: .init(installation: install, persistence: persistence)) {
            var state = RelayUIState(); state.provisioned = true; state.keychainNeedsApproval = !backgroundAllowed
            return .init(state: state)
        }
        #expect(persistence.observations.0 == [true] && persistence.observations.1 == 0)
        #expect(response.state.keychainNeedsApproval == !backgroundAllowed)
        #expect((response.error == nil) == backgroundAllowed)
        #expect(response.state.paired)
    }
    @Test func automaticRefreshStopsAfterDenialErrorOrWhileBusy() {
        for approved in [false, true] {
            for error in [false, true] {
                #expect(!RelayStatusRefreshPolicy.shouldRefresh(approvalNeeded: approved, hasError: error, busy: true, explicit: true))
                #expect(RelayStatusRefreshPolicy.shouldRefresh(approvalNeeded: approved, hasError: error, busy: false, explicit: false) == (!approved && !error))
                #expect(RelayStatusRefreshPolicy.shouldRefresh(approvalNeeded: approved, hasError: error, busy: false, explicit: true))
            }
        }
    }
    @Test func cancellationTerminatesAuthorizationHelper() async throws {
        let install = installation()
        defer { try? FileManager.default.removeItem(at: install.root) }
        let helper = install.root.appendingPathComponent("bin/vauldy-relay")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A synthetic helper stands in for a blocked Security call. No real keychain access.
        try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let start = Date()
        let task = Task { try await RelayUIControl(installation: install).request(.init(.authorize)) }
        try await Task.sleep(for: .milliseconds(200)); task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled helper must not succeed") }
        catch is CancellationError { }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
