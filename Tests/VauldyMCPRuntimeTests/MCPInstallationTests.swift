import Foundation
import Testing
@testable import VauldyMCPRuntime

@Suite("Local MCP installation")
struct MCPInstallationTests {
    @Test func installationIsPrivateExplicitAndRevocable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-install-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("source-binary")
        try Data("test executable".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let installer = MCPInstallation(root: root.appendingPathComponent("Application Support with spaces"))
        let grant = MCPAccessProfile(vaultPath: root.appendingPathComponent("documents.json").path,
                                     allowedDocumentIDs: [UUID()], enabled: true, acknowledgedCloudDisclosure: true)
        let configURL = try installer.install(binary: binary, profile: grant)
        let config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        let servers = try #require(config["mcpServers"] as? [String: [String: Any]])
        #expect(servers["vauldy"]?["command"] as? String == installer.binaryURL.path)
        #expect(servers["vauldy"]?["args"] as? [String] == ["--profile", installer.profileURL(grant.connectionID).path])
        let attrs = try FileManager.default.attributesOfItem(atPath: installer.profileURL(grant.connectionID).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try installer.profiles().count == 1)
        try installer.revoke(grant.connectionID)
        let revoked = try FileMCPProfileSource(url: installer.profileURL(grant.connectionID)).load()
        #expect(!revoked.enabled)
        #expect(revoked.revision != grant.revision)
        #expect(!FileManager.default.fileExists(atPath: grant.vaultPath))
    }

    @Test func enabledProfileRequiresExplicitDisclosureAndDocumentSelection() throws {
        var grant = MCPAccessProfile(vaultPath: "/unused/documents.json", enabled: true)
        #expect(throws: MCPAccessError.notAuthorized) { try grant.validate() }
        grant.acknowledgedCloudDisclosure = true
        #expect(throws: MCPAccessError.notAuthorized) { try grant.validate() }
        grant.allowedDocumentIDs = [UUID()]
        try grant.validate()
    }
}
