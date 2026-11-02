import Foundation
import Testing
@testable import VauldyMCPRuntime

@Suite("MCP access and software management")
struct MCPManagementTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-management-\(UUID())")
        let installer: MCPInstallation
        let binary: URL
        var profile: MCPAccessProfile
        init() throws {
            installer = .init(root: root.appendingPathComponent("installed"))
            binary = root.appendingPathComponent("server")
            profile = .init(vaultPath: root.appendingPathComponent("documents.json").path, allowedDocumentIDs: [UUID(), UUID()], enabled: false, acknowledgedCloudDisclosure: true)
            profile.desktopClient = .claude
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            _ = try installer.install(binary: binary, profile: profile)
        }
        var path: URL { installer.profileURL(profile.connectionID) }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func updatesPreserveExactPausedGrantsAndClientConfiguration() throws {
        let f = try Fixture(), registrar = MCPClientRegistration(home: f.root.appendingPathComponent("client"))
        let config = registrar.configurationURL(for: .claude)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"preferences\":{\"theme\":\"dark\"}}".utf8); try bytes.write(to: config)
        let original = try Data(contentsOf: f.path)
        #expect(try f.installer.softwareStatus(availableBinary: f.binary).state == .current)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: f.binary)
        #expect(try f.installer.softwareStatus(availableBinary: f.binary).state == .updateAvailable)
        try f.installer.updateSoftware(binary: f.binary)
        #expect(try f.installer.softwareStatus(availableBinary: f.binary).state == .current)
        #expect(try Data(contentsOf: f.path) == original)
        #expect(try Data(contentsOf: config) == bytes)
        #expect(try f.installer.profiles().first?.desktopClient == .claude)
    }

    @Test func selectionPreservesPauseAndExpansionRequiresFreshConsent() throws {
        let f = try Fixture(), ids = f.profile.allowedDocumentIDs.union([UUID()])
        #expect(throws: MCPAccessError.notAuthorized) { try f.installer.updateSelection(ids, for: f.profile.connectionID, expectedRevision: f.profile.revision) }
        let saved = try f.installer.updateSelection(ids, for: f.profile.connectionID, expectedRevision: f.profile.revision, acknowledgedDisclosure: true)
        #expect(!saved.enabled && saved.allowedDocumentIDs == ids && saved.desktopClient == .claude)
        let resumed = try f.installer.setAccess(true, for: saved.connectionID, expectedRevision: saved.revision)
        #expect(resumed.enabled && resumed.allowedDocumentIDs == ids && resumed.acknowledgedCloudDisclosure)
        let empty = try f.installer.updateSelection([], for: resumed.connectionID, expectedRevision: resumed.revision)
        #expect(!empty.enabled)
        #expect(throws: MCPAccessError.notAuthorized) { try f.installer.setAccess(true, for: empty.connectionID) }
    }

    @Test func staleSelectionCannotUndoPauseFromAnotherWindow() throws {
        let f = try Fixture()
        let active = try f.installer.setAccess(true, for: f.profile.connectionID)
        let paused = try f.installer.setAccess(false, for: active.connectionID, expectedRevision: active.revision)
        #expect(throws: MCPAccessError.stale) { try f.installer.updateSelection(active.allowedDocumentIDs, for: active.connectionID, expectedRevision: active.revision) }
        #expect(try FileMCPProfileSource(url: f.path).load() == paused)
    }

    @Test func firstExplicitSelectionCanConsentWithoutResumingDraft() throws {
        let f = try Fixture()
        var draft = f.profile; draft.allowedDocumentIDs = []; draft.acknowledgedCloudDisclosure = false
        try FileMCPProfileSource(url: f.path).save(draft)
        let updated = try f.installer.updateSelection([UUID()], for: draft.connectionID, expectedRevision: draft.revision, acknowledgedDisclosure: true)
        #expect(!updated.enabled && updated.acknowledgedCloudDisclosure)
        #expect(try f.installer.setAccess(true, for: updated.connectionID, expectedRevision: updated.revision).enabled)
    }

    @Test func missingOrChangedManagementBundleRequiresSoftwareUpdate() throws {
        let f = try Fixture(), app = f.root.appendingPathComponent("Setup.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.marcomeisen.vauldy.mcp-setup", "CFBundleExecutable": "vauldy-mcp-setup", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macos.appendingPathComponent("vauldy-mcp-setup")
        try Data("first UI".utf8).write(to: executable)
        #expect(try f.installer.softwareStatus(availableBinary: f.binary, setupApp: app).state == .updateAvailable)
        let before = try Data(contentsOf: f.path)
        try f.installer.updateSoftware(binary: f.binary, setupApp: app)
        #expect(try f.installer.softwareStatus(availableBinary: f.binary, setupApp: app).state == .current)
        try Data("new UI, same server".utf8).write(to: executable)
        #expect(try f.installer.softwareStatus(availableBinary: f.binary, setupApp: app).state == .updateAvailable)
        #expect(try Data(contentsOf: f.path) == before)
    }

    @Test func legacyProfilesAndPausedClientBindingsRemainReadableWithoutWrites() throws {
        let f = try Fixture(), registrar = MCPClientRegistration(home: f.root.appendingPathComponent("client"))
        var active = f.profile; active.enabled = true
        try FileMCPProfileSource(url: f.path).save(active)
        try registrar.register(.claude, binary: f.installer.binaryURL, profile: f.path)
        try f.installer.setAccess(false, for: active.connectionID)
        let config = registrar.configurationURL(for: .claude), bytes = try Data(contentsOf: config)
        #expect(try registrar.binding(.claude, binary: f.installer.binaryURL, profile: f.path) == .registered)
        #expect(try registrar.binding(.claude, binary: f.binary, profile: f.path) == .conflict)
        #expect(try Data(contentsOf: config) == bytes)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.path)) as? [String: Any])
        object.removeValue(forKey: "desktopClient")
        try JSONSerialization.data(withJSONObject: object).write(to: f.path)
        #expect(try FileMCPProfileSource(url: f.path).load().desktopClient == nil)
        #expect(try registrar.binding(.claude, binary: f.installer.binaryURL, profile: f.path) == .registered)
    }

    @Test func diagnosticsNeverImplyARealChatbotConnection() throws {
        let f = try Fixture()
        let diagnostic = try MCPProcessPresence(root: f.installer.root, connectionID: f.profile.connectionID, diagnostic: true)
        defer { diagnostic.stop() }
        diagnostic.recordRequest()
        let observed = try MCPProcessPresence.serverInstances(root: f.installer.root)
        #expect(observed.count == 1 && observed.first?.diagnostic == true && observed.first?.lastRequestAt != nil)
        var active = f.profile; active.enabled = true
        let state = MCPConnectionState(profile: active, instances: observed)
        #expect(!state.running && !state.requestObserved && state.headline == "Wartet auf Chatbot")
        let host = try MCPProcessPresence(root: f.installer.root, connectionID: active.connectionID)
        defer { host.stop() }
        host.recordRequest()
        let running = MCPConnectionState(profile: active, instances: try MCPProcessPresence.serverInstances(root: f.installer.root))
        #expect(running.running && running.requestObserved && !running.restartRequired)
        #expect(!MCPConnectionState(profile: MCPAccessProfile(vaultPath: "/other"), instances: observed).running)
    }

    @Test func oldOrUnattributedServersAndPausedAccessAreReportedSeparately() throws {
        let f = try Fixture(); var profile = f.profile; profile.enabled = true
        let old = MCPServerInstance(connectionID: profile.connectionID, version: "0.6.0")
        #expect(MCPConnectionState(profile: profile, instances: [old]).restartRequired)
        #expect(!MCPConnectionState(profile: profile, instances: [.init()]).serverKnown)
        profile.enabled = false
        let paused = MCPConnectionState(profile: profile, instances: [old])
        #expect(paused.running && paused.headline == "Dokumentzugriff pausiert")
    }

    @Test func menuNavigationIsTypedOneShotAndDoesNotChangeGrants() throws {
        let f = try Fixture(), original = try Data(contentsOf: f.path)
        try f.installer.requestSetup(.init(section: .documents, connectionID: f.profile.connectionID, diagnose: true))
        let request = try #require(try f.installer.consumeSetupRequest())
        #expect(request.section == .documents && request.connectionID == f.profile.connectionID && request.diagnose == true)
        #expect(try f.installer.consumeSetupRequest() == nil)
        var expired = MCPSetupRequest(section: .settings); expired.createdAt = Date().addingTimeInterval(-301)
        try f.installer.requestSetup(expired)
        #expect(try f.installer.consumeSetupRequest() == nil)
        #expect(try Data(contentsOf: f.path) == original)
    }
}
