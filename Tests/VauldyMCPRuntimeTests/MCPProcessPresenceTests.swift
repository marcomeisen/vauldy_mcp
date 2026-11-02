import Foundation
import Testing
@testable import VauldyMCPRuntime

@Suite("MCP menu process presence")
struct MCPProcessPresenceTests {
    @Test func aggregatesLiveServersAndIgnoresStaleMarkers() throws {
        try fixture { root in
            #expect(try MCPProcessPresence.serverCount(root: root) == 0)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime-status").path))
            let first = try MCPProcessPresence(root: root), second = try MCPProcessPresence(root: root)
            #expect(try MCPProcessPresence.serverCount(root: root) == 2)
            let stale = root.appendingPathComponent("runtime-status/\(UUID()).server")
            try Data().write(to: stale)
            #expect(try MCPProcessPresence.serverCount(root: root) == 2)
            first.stop()
            #expect(try MCPProcessPresence.serverCount(root: root) == 1)
            second.stop(); second.stop()
            #expect(try MCPProcessPresence.serverCount(root: root) == 0)
            let next = try MCPProcessPresence(root: root)
            defer { next.stop() }
            #expect(!FileManager.default.fileExists(atPath: stale.path))
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("runtime-status"), includingPropertiesForKeys: nil)
            #expect(try files.allSatisfy { try Data(contentsOf: $0).isEmpty })
        }
    }

    @Test func onlyOneMenuPerRootAndIndependentInstallations() throws {
        try fixture { root in
            let menu = try MCPProcessPresence(root: root, menu: true)
            #expect(try MCPProcessPresence.menuIsRunning(root: root))
            #expect(throws: MCPProcessPresence.PresenceError.alreadyRunning) { try MCPProcessPresence(root: root, menu: true) }
            #expect(try MCPProcessPresence.menuIsRunning(root: root))
            #expect(try MCPProcessPresence.serverCount(root: root) == 0)
            let other = try MCPProcessPresence(root: root.appendingPathComponent("other"), menu: true)
            defer { other.stop() }
            #expect(try MCPProcessPresence.requestMenuStop(root: root))
            #expect(try MCPProcessPresence.menuStopRequested(root: root))
            #expect(try !MCPProcessPresence.menuStopRequested(root: root.appendingPathComponent("other")))
            menu.stop()
            #expect(try !MCPProcessPresence.menuIsRunning(root: root))
            #expect(try MCPProcessPresence.menuIsRunning(root: root.appendingPathComponent("other")))
            let restarted = try MCPProcessPresence(root: root, menu: true)
            #expect(try !MCPProcessPresence.menuStopRequested(root: root))
            restarted.stop()
        }
    }

    @Test func refusesSymlinksAndDamagedMarkersWithoutOverwriting() throws {
        try fixture { root in
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let directory = root.appendingPathComponent("runtime-status")
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
            #expect(throws: MCPProcessPresence.PresenceError.unavailable) { try MCPProcessPresence(root: root) }
            #expect(throws: MCPProcessPresence.PresenceError.unavailable) { try MCPProcessPresence.serverCount(root: root) }
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let privateFile = outside.appendingPathComponent("keep.txt")
            let bytes = Data("keep".utf8); try bytes.write(to: privateFile)
            let marker = directory.appendingPathComponent("\(UUID()).server")
            try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: privateFile)
            #expect(throws: MCPProcessPresence.PresenceError.unavailable) { try MCPProcessPresence.serverCount(root: root) }
            #expect(try Data(contentsOf: privateFile) == bytes)
            try FileManager.default.removeItem(at: marker)
            try bytes.write(to: marker)
            #expect(throws: MCPProcessPresence.PresenceError.unavailable) { try MCPProcessPresence.serverCount(root: root) }
            #expect(try Data(contentsOf: marker) == bytes)
        }
    }

    @Test func derivesInstalledAndCustomRootsWithoutUsingDefaultHome() {
        let root = URL(fileURLWithPath: "/isolated/installation")
        let installed = root.appendingPathComponent("connections/\(UUID())/profile.json")
        #expect(MCPProcessPresence.root(forProfile: installed).path == root.path)
        let standalone = root.appendingPathComponent("custom/profile.json")
        #expect(MCPProcessPresence.root(forProfile: standalone).path == root.appendingPathComponent("custom").path)
    }

    @Test func customProfileParentKeepsItsPermissions() throws {
        try fixture { root in
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            let presence = try MCPProcessPresence(root: root)
            defer { presence.stop() }
            let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
            let statusMode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("runtime-status").path)[.posixPermissions] as? NSNumber
            #expect(rootMode?.intValue == 0o755)
            #expect(statusMode?.intValue == 0o700)
        }
    }

    @Test func installsAndUpdatesCompanionWithoutChangingGrants() throws {
        try fixture { root in
            let source = root.appendingPathComponent(MCPStatusApp.bundleName)
            let macos = source.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "com.marcomeisen.vauldy.mcp-status", "CFBundleExecutable": "vauldy-mcp-status", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: source.appendingPathComponent("Contents/Info.plist"))
            let binary = macos.appendingPathComponent("vauldy-mcp-status")
            try Data("first version".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            let installer = MCPInstallation(root: root.appendingPathComponent("installed"))
            let grant = MCPAccessProfile(vaultPath: root.appendingPathComponent("documents.json").path, allowedDocumentIDs: [UUID()], enabled: true, acknowledgedCloudDisclosure: true)
            _ = try installer.install(binary: binary, profile: grant, statusApp: source)
            let installedBinary = installer.statusAppURL.appendingPathComponent("Contents/MacOS/vauldy-mcp-status")
            #expect(try Data(contentsOf: installedBinary) == Data("first version".utf8))
            let before = try FileMCPProfileSource(url: installer.profileURL(grant.connectionID)).load()
            try Data("second version".utf8).write(to: binary)
            _ = try installer.install(binary: binary, profile: grant, statusApp: source)
            #expect(try Data(contentsOf: installedBinary) == Data("second version".utf8))
            #expect(try FileMCPProfileSource(url: installer.profileURL(grant.connectionID)).load() == before)
            #expect(!FileManager.default.fileExists(atPath: grant.vaultPath))
        }
    }
}

private func fixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-menu-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
