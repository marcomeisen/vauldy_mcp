import Darwin
import Foundation

public struct MCPLocalProbeResult: Codable, Sendable {
    public let completedAt: Date
    public let accessEnabled: Bool
    public let grantedDocuments: Int
    public let serverVersion: String
    public let discoveredTools: [String]
}

/// A real, content-free stdio handshake. This is explicitly a local diagnostic, never a host/cloud proof.
public enum MCPLocalProbe {
    public static func run(binary: URL, profile: URL, timeout: TimeInterval = 12) throws -> MCPLocalProbeResult {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw MCPAccessError.configuration }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-probe-\(UUID())")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let output = stage.appendingPathComponent("responses.jsonl")
        try Data().write(to: output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        let input = Pipe()
        let process = Process(); process.executableURL = binary; process.arguments = ["--profile", profile.path]
        process.standardInput = input; process.standardOutput = writer; process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(["VAULDY_MCP_DIAGNOSTIC": "1"]) { _, new in new }
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { process.terminate() }
            let forced = Date().addingTimeInterval(1)
            while process.isRunning && Date() < forced { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(max(2, min(timeout, 30)))
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(_ id: Int) throws -> [String: Any] {
            while process.isRunning && Date() < deadline {
                let length = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard length <= 256_000 else { throw MCPAccessError.tooLarge }
                for line in try Data(contentsOf: output).split(separator: 10) {
                    guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          value["id"] as? Int == id else { continue }
                    guard value["error"] == nil, let result = value["result"] as? [String: Any] else { throw MCPAccessError.unavailable }
                    return result
                }
                Thread.sleep(forTimeInterval: 0.03)
            }
            throw MCPAccessError.unavailable
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:] as [String: String],
            "clientInfo": ["name": "Vauldy local diagnostic", "version": MCPBuild.version]]])
        let initialized = try response(1)
        guard let server = initialized["serverInfo"] as? [String: Any], let version = server["version"] as? String,
              version == MCPBuild.version else { throw MCPAccessError.unavailable }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": [:] as [String: String]])
        let discovery = try response(3)
        guard let tools = discovery["tools"] as? [[String: Any]] else { throw MCPAccessError.unavailable }
        let names = tools.compactMap { $0["name"] as? String }.sorted()
        guard Set(names) == ["get_vault_status", "list_documents", "search_documents", "read_document"] else { throw MCPAccessError.unavailable }
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_vault_status", "arguments": [:] as [String: String]]])
        let result = try response(2)
        guard result["isError"] as? Bool != true, let content = result["structuredContent"] as? [String: Any],
              let granted = content["grantedDocumentCount"] as? Int else { throw MCPAccessError.unavailable }
        return MCPLocalProbeResult(completedAt: Date(), accessEnabled: content["access"] as? String == "explicit-document-grants", grantedDocuments: granted, serverVersion: version, discoveredTools: names)
    }
}
