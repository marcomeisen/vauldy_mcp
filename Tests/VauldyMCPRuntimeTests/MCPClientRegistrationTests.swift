import Foundation
import Testing
@testable import VauldyMCPRuntime

@Suite("Desktop client registration")
struct MCPClientRegistrationTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-register-test-\(UUID())").resolvingSymlinksInPath()
        let installer: MCPInstallation
        let registrar: MCPClientRegistration
        let profile: MCPAccessProfile
        var profileURL: URL { installer.profileURL(profile.connectionID) }
        init() throws {
            installer = MCPInstallation(root: root.appendingPathComponent("Vauldy with spaces"))
            registrar = MCPClientRegistration(home: root.appendingPathComponent("Client home"))
            profile = MCPAccessProfile(vaultPath: root.appendingPathComponent("documents.json").path,
                                       allowedDocumentIDs: [UUID()], enabled: true, acknowledgedCloudDisclosure: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let binary = root.appendingPathComponent("binary")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            _ = try installer.install(binary: binary, profile: profile)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func seed(_ text: String, client: MCPDesktopClient) throws -> URL {
            let url = registrar.configurationURL(for: client)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
        func register(_ client: MCPDesktopClient) throws -> Bool {
            try registrar.register(client, binary: installer.binaryURL, profile: profileURL)
        }
    }

    @Test func claudePreservesSettingsBacksUpAndIsIdempotent() throws {
        let f = try Fixture()
        let original = #"{"preferences":{"theme":"dark"},"mcpServers":{"existing":{"command":"other","env":{"TOKEN":"test-only"}}}}"#
        let config = try f.seed(original, client: .claude)
        let grant = try Data(contentsOf: f.profileURL)
        #expect(try f.register(.claude))
        let bytes = try Data(contentsOf: config)
        let parsed = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((parsed["preferences"] as? [String: String])?["theme"] == "dark")
        let servers = try #require(parsed["mcpServers"] as? [String: [String: Any]])
        #expect(servers["existing"]?["command"] as? String == "other")
        #expect((servers["existing"]?["env"] as? [String: String])?["TOKEN"] == "test-only")
        #expect(servers["vauldy"]?["args"] as? [String] == ["--profile", f.profileURL.path])
        #expect(try !f.register(.claude))
        #expect(try Data(contentsOf: config) == bytes)
        #expect(try Data(contentsOf: f.profileURL) == grant)
        let backups = try FileManager.default.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".vauldy-backup-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == Data(original.utf8))
        for url in [config] + backups {
            #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test(arguments: ["{broken", "[]", #"{"mcpServers":[]}"#, #"{"mcpServers":{"vauldy":{"command":"another"}}}"#])
    func claudeRejectsInvalidOrConflictingConfig(text: String) throws {
        let f = try Fixture(); let url = try f.seed(text, client: .claude)
        #expect(throws: (any Error).self) { try f.register(.claude) }
        #expect(try Data(contentsOf: url) == Data(text.utf8))
    }

    @Test func missingConfigIsCreatedAndRevokedProfileCannotRegister() throws {
        let f = try Fixture()
        #expect(try f.register(.claude))
        try f.installer.revoke(f.profile.connectionID)
        #expect(throws: MCPAccessError.notAuthorized) { try f.register(.claude) }
    }

    @Test func symbolicLinkIsNeverReplacedOrFollowed() throws {
        let f = try Fixture()
        let url = try f.seed("{}", client: .claude)
        let target = f.root.appendingPathComponent("foreign.json")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(throws: MCPRegistrationError.self) { try f.register(.claude) }
        #expect(try Data(contentsOf: target) == Data("{}".utf8))
    }

    @Test(.enabled(if: MCPClientRegistration.findChatGPTCLI(home: FileManager.default.homeDirectoryForCurrentUser) != nil))
    func chatGPTUsesRealClientParserAndPreservesOriginalBytes() throws {
        let f = try Fixture()
        let original = "# Keep user comments and unknown settings\nmodel = \"example\"\n[desktop]\nexample = true\n[mcp_servers.other]\ncommand = \"/example with spaces\"\nargs = [\"--test\"]\n"
        let url = try f.seed(original, client: .chatgpt)
        #expect(try f.register(.chatgpt))
        let updated = try Data(contentsOf: url)
        #expect(updated.starts(with: Data(original.utf8)))
        #expect(try !f.register(.chatgpt))
        #expect(try Data(contentsOf: url) == updated)
        // Another approved profile must not silently replace the first grant.
        var other = f.profile; other.connectionID = UUID()
        let otherURL = f.installer.profileURL(other.connectionID)
        try FileMCPProfileSource(url: otherURL).save(other)
        #expect(throws: MCPRegistrationError.self) {
            try f.registrar.register(.chatgpt, binary: f.installer.binaryURL, profile: otherURL)
        }
        #expect(try Data(contentsOf: url) == updated)
    }

    @Test(.enabled(if: MCPClientRegistration.findChatGPTCLI(home: FileManager.default.homeDirectoryForCurrentUser) != nil))
    func chatGPTRejectsInvalidTOMLWithoutWriting() throws {
        let f = try Fixture(); let url = try f.seed("this is not valid TOML", client: .chatgpt)
        let before = try Data(contentsOf: url)
        #expect(throws: MCPRegistrationError.self) { try f.register(.chatgpt) }
        #expect(try Data(contentsOf: url) == before)
    }
}
