import Foundation
import Darwin
import VauldyMCPRuntime

public final class RelayLocalMCP: @unchecked Sendable {
    private let process = Process()
    public var isRunning: Bool { process.isRunning }
    private let gate = NSLock()
    private var busy = false
    private let input = Pipe(), output = Pipe()
    private var sequence = 0
    public init(installation: MCPInstallation, profile: URL) async throws {
        process.executableURL = installation.binaryURL; process.arguments = ["--profile", profile.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
        _ = try await exchange(["method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "vauldy-private-relay", "version": MCPBuild.version]]])
        try input.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n".utf8))
        } catch { close(); throw error }
    }
    deinit { close() }
    public func close() { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
    public func call(_ request: Data) async throws -> Data {
        guard gate.withLock({ if busy { return false }; busy = true; return true }) else { throw RelayFailure.unavailable }
        defer { gate.withLock { busy = false } }
        guard let dict = try JSONSerialization.jsonObject(with: request) as? [String: Any] else { throw RelayFailure.unavailable }
        return try await exchange(dict)
    }
    private func exchange(_ value: [String: Any]) async throws -> Data {
        sequence += 1; let id = sequence
        var request = value; request["jsonrpc"] = "2.0"; request["id"] = id
        var bytes = try JSONSerialization.data(withJSONObject: request); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
        let fd = output.fileHandleForReading.fileDescriptor
        return try await Task.detached { [self] in
            let deadline = Date().addingTimeInterval(40); var data = Data()
            while Date() < deadline {
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let n = Darwin.poll(&pollFD, 1, 250)
                if n < 0 { if errno == EINTR { continue }; throw RelayFailure.unavailable }
                if n == 0 { continue }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd, &chunk, chunk.count)
                guard count > 0 else { throw RelayFailure.unavailable }
                data.append(contentsOf: chunk.prefix(count))
                guard data.count <= 190000 else { throw RelayFailure.unavailable }
                if data.last == 10 {
                    guard let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any], rpc["id"] as? Int == id,
                          let result = rpc["result"] else { throw RelayFailure.unavailable }
                    return try JSONSerialization.data(withJSONObject: result)
                }

            }
            close(); throw RelayFailure.unavailable
        }.value
    }
}
