import Darwin
import Foundation

public struct MCPLocalProbeResult: Codable, Sendable {
    public let completedAt: Date
    public let accessEnabled: Bool
    public let grantedDocuments: Int
    public let serverVersion: String
    public let discoveredTools: [String]
    public let serverBuildID: String?
    public let protocolServerVersion: String
    public let missingTools: [String]
    public let compatible: Bool
    public let buildVerified: Bool
    public var summary: String {
        if !compatible { return "Lokaler Server antwortet, benötigt aber ein Softwareupdate." }
        if !accessEnabled { return "Lokales Protokoll bereit; Dokumentzugriff ist pausiert." }
        return "Lokaler Protokolltest erfolgreich"
    }
    public var nextStep: String {
        if !missingTools.isEmpty { return "Software aus der aktuellen Einrichtung aktualisieren und die Vauldy-Verbindung im Chatbot neu starten. Fehlende Werkzeuge: " + missingTools.joined(separator: ", ") }
        if !compatible { return "Softwarestand prüfen, aktuelle Programme installieren und die Verbindung im Chatbot neu starten." }
        if !accessEnabled { return "Gewünschte Dokumentauswahl lokal prüfen und den Zugriff bewusst aktivieren." }
        return "Die gewünschte Anfrage im Chatbot testen. Dieser lokale Test bestätigt keine externe Chatverbindung."
    }
}

public enum MCPLocalProbeError: LocalizedError, Equatable {
    case missingBinary, launch, timeout, exited, protocolMismatch, invalidResponse, discovery, vaultUnavailable
    public var errorDescription: String? {
        switch self {
        case .missingBinary: "Der lokale Server fehlt oder ist nicht ausführbar. Installiere die Programme über Einstellungen → Software aktualisieren."
        case .launch: "Der lokale Server konnte nicht starten. Prüfe das Softwarepaket und seine macOS-Freigabe."
        case .timeout: "Der lokale Server antwortet nicht rechtzeitig. Prüfe laufenden Import und Softwarestand und wiederhole den Test."
        case .exited: "Der lokale Server wurde vor Abschluss des Tests beendet. Prüfe Softwarepaket und lokale Diagnose."
        case .protocolMismatch: "Der Server verwendet ein anderes MCP-Protokoll. Aktualisiere die lokalen Programme."
        case .invalidResponse: "Der Server liefert keine gültige Diagnoseantwort. Prüfe den installierten Softwarestand."
        case .discovery: "Die Werkzeugliste ist unvollständig oder ungültig. Aktualisiere die lokalen Programme und verbinde den Chatbot erneut."
        case .vaultUnavailable: "Der Server antwortet, kann den lokalen Bestand aber nicht prüfen. Prüfe Bestand und Freigabe in der Einrichtung; dieser Test prüft keine Cloud-Anmeldung."
        }
    }
}

/// A real, content-free stdio handshake. This is explicitly a local diagnostic, never a host/cloud proof.
public enum MCPLocalProbe {
    public static func run(binary: URL, profile: URL, timeout: TimeInterval = 12, expectedVersion: String = MCPBuild.version) throws -> MCPLocalProbeResult {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw MCPLocalProbeError.missingBinary }
        let expectedBuildID = MCPBuildIdentity.read(binary)
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
        do { try process.run() } catch { throw MCPLocalProbeError.launch }
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
            while Date() < deadline {
                let length = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard length <= 256_000 else { throw MCPLocalProbeError.invalidResponse }
                for line in try Data(contentsOf: output).split(separator: 10) {
                    guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          value["id"] as? Int == id else { continue }
                    guard value["error"] == nil, let result = value["result"] as? [String: Any] else { throw MCPLocalProbeError.invalidResponse }
                    return result
                }
                if !process.isRunning { throw MCPLocalProbeError.exited }
                Thread.sleep(forTimeInterval: 0.03)
            }
            throw MCPLocalProbeError.timeout
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:] as [String: String],
            "clientInfo": ["name": "Vauldy local diagnostic", "version": MCPBuild.version]]])
        let initialized = try response(1)
        guard initialized["protocolVersion"] as? String == "2025-11-25" else { throw MCPLocalProbeError.protocolMismatch }
        guard let server = initialized["serverInfo"] as? [String: Any], server["name"] as? String == "vauldy",
              let reportedVersion = server["version"] as? String, reportedVersion.utf8.count <= 128 else { throw MCPLocalProbeError.invalidResponse }
        let version = String(reportedVersion.split(separator: "+", maxSplits: 1).first ?? "")
        let buildID = MCPBuildIdentity.fromProtocolVersion(reportedVersion)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        var names: [String] = [], cursor: String?, seenCursors = Set<String>()
        for page in 0..<16 {
            var parameters: [String: String] = [:]
            if let cursor { parameters["cursor"] = cursor }
            try send(["jsonrpc": "2.0", "id": 3 + page, "method": "tools/list", "params": parameters])
            let discovery = try response(3 + page)
            guard let tools = discovery["tools"] as? [[String: Any]] else { throw MCPLocalProbeError.discovery }
            for tool in tools {
                guard let name = tool["name"] as? String, !name.isEmpty, name.utf8.count <= 80,
                      name.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0) }),
                      !names.contains(name), names.count < 128 else { throw MCPLocalProbeError.discovery }
                names.append(name)
            }
            if let next = discovery["nextCursor"] {
                guard let next = next as? String, !next.isEmpty, next.utf8.count <= 4096,
                      seenCursors.insert(next).inserted else { throw MCPLocalProbeError.discovery }
                cursor = next
            } else { cursor = nil; break }
        }
        guard cursor == nil, MCPToolRequirements.baseline.isSubset(of: Set(names)) else { throw MCPLocalProbeError.discovery }
        let missing = MCPToolRequirements.current.subtracting(names).sorted()
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_vault_status", "arguments": [:] as [String: String]]])
        let result = try response(2)
        guard result["isError"] as? Bool != true, let content = result["structuredContent"] as? [String: Any],
              let granted = content["grantedDocumentCount"] as? Int else { throw MCPLocalProbeError.vaultUnavailable }
        let buildVerified = buildID != nil && buildID == expectedBuildID && MCPBuildIdentity.read(binary) == expectedBuildID
        return MCPLocalProbeResult(completedAt: Date(), accessEnabled: content["access"] as? String == "explicit-document-grants", grantedDocuments: granted, serverVersion: version, discoveredTools: names.sorted(),
            serverBuildID: buildID, protocolServerVersion: reportedVersion, missingTools: missing,
            compatible: version == expectedVersion && missing.isEmpty && buildVerified, buildVerified: buildVerified)
    }
}
