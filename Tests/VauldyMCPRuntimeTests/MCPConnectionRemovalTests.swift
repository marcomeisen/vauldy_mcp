import Foundation
import Testing
import VauldyCore
@testable import VauldyMCPRuntime

@Suite("Connection removal")
struct MCPConnectionRemovalTests {
    @Test func removalRevokesExistingRuntimePreservesVaultAndOtherConnections() async throws {
        try await removalFixture { installer, binary, vault, profile in
            let before = try Data(contentsOf: vault)
            let runtime = ReadOnlyMCPRuntime(profiles: FileMCPProfileSource(url: installer.profileURL(profile.connectionID)))
            let handle = try #require(try await runtime.list().items.first?.document)
            let other = MCPAccessProfile(vaultPath: vault.path, allowedDocumentIDs: profile.allowedDocumentIDs, enabled: true, acknowledgedCloudDisclosure: true)
            _ = try installer.install(binary: binary, profile: other)
            let otherBytes = try Data(contentsOf: installer.profileURL(other.connectionID))
            let archive = try installer.removeConnection(profile.connectionID, expectedRevision: profile.revision)
            #expect(!FileManager.default.fileExists(atPath: installer.profileURL(profile.connectionID).path))
            #expect(try installer.profiles().map(\.connectionID) == [other.connectionID])
            #expect(try !FileMCPProfileSource(url: archive.appendingPathComponent("profile.json")).load().enabled)
            await #expect(throws: MCPAccessError.notAuthorized) { try await runtime.read(document: handle) }
            #expect(try Data(contentsOf: vault) == before)
            #expect(try Data(contentsOf: installer.profileURL(other.connectionID)) == otherBytes)
            // A still-running old server can create only its former audit folder.
            let oldDirectory = installer.profileURL(profile.connectionID).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: oldDirectory.appendingPathComponent("logs"), withIntermediateDirectories: true)
            #expect(try installer.profiles().map(\.connectionID) == [other.connectionID])
            #expect(throws: MCPAccessError.notAuthorized) { try FileMCPProfileSource(url: installer.profileURL(profile.connectionID)).save(profile) }
            #expect(try installer.removeConnection(profile.connectionID, expectedRevision: profile.revision) == archive)
            #expect(throws: MCPAccessError.stale) { try installer.install(binary: binary, profile: profile) }
        }
    }
    @Test func linkedHistoryCannotBeMistakenForCompletedRemoval() async throws {
        try await removalFixture { installer, _, vault, profile in
            let profileURL = installer.profileURL(profile.connectionID)
            let before = try Data(contentsOf: profileURL), original = try Data(contentsOf: vault)
            let external = installer.root.appendingPathComponent("foreign-history")
            let archive = external.appendingPathComponent(profile.connectionID.uuidString).appendingPathComponent("profile.json")
            var disabled = profile; disabled.enabled = false
            try FileMCPProfileSource(url: archive).save(disabled)
            try FileManager.default.createSymbolicLink(at: installer.removedConnectionsURL, withDestinationURL: external)
            #expect(throws: MCPAccessError.configuration) { try installer.removeConnection(profile.connectionID, expectedRevision: profile.revision) }
            #expect(try Data(contentsOf: profileURL) == before && Data(contentsOf: vault) == original)
        }
    }
    @Test func staleRemovalCannotDeleteAChangedGrant() async throws {
        try await removalFixture { installer, _, _, profile in
            let paused = try installer.setAccess(false, for: profile.connectionID, expectedRevision: profile.revision)
            let bytes = try Data(contentsOf: installer.profileURL(profile.connectionID))
            #expect(throws: MCPAccessError.stale) { try installer.removeConnection(profile.connectionID, expectedRevision: profile.revision) }
            #expect(try Data(contentsOf: installer.profileURL(profile.connectionID)) == bytes)
            #expect(try installer.profiles().first == paused)
        }
    }
    @Test func aConnectionDirectoryContainingItsVaultCannotBeMoved() async throws {
        try await removalFixture { installer, _, _, profile in
            var changed = profile
            let vault = installer.profileURL(profile.connectionID).deletingLastPathComponent().appendingPathComponent("documents.json")
            try Data("synthetic data".utf8).write(to: vault)
            changed.vaultPath = vault.path
            try FileMCPProfileSource(url: installer.profileURL(profile.connectionID)).save(changed)
            #expect(throws: MCPAccessError.configuration) { try installer.removeConnection(changed.connectionID, expectedRevision: changed.revision) }
            #expect(try Data(contentsOf: vault) == Data("synthetic data".utf8))
            #expect(try FileMCPProfileSource(url: installer.profileURL(changed.connectionID)).load().enabled)
        }
    }
}

private func removalFixture(_ body: (MCPInstallation, URL, URL, MCPAccessProfile) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-remove-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = root.appendingPathComponent("source-server")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let document = VaultDocument(title: "Synthetischer Beleg", sourceName: "test.pdf", ocrText: "--- Seite 1 ---\nWartung 49,99 EUR.", pageCount: 1)
    let vault = root.appendingPathComponent("documents.json")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([document]).write(to: vault)
    let profile = MCPAccessProfile(vaultPath: vault.path, allowedDocumentIDs: [document.id], enabled: true, acknowledgedCloudDisclosure: true)
    let installer = MCPInstallation(root: root.appendingPathComponent("installation"))
    _ = try installer.install(binary: binary, profile: profile)
    try await body(installer, binary, vault, profile)
}
