import Foundation
import Logging
import MCP

/// Swift MCP SDK 0.12.1 models experimental client capabilities as String values.
/// MCP permits arbitrary JSON values. Ignore unsupported experimental extensions;
/// this read-only server does not implement any of them.
actor InitializationCompatibilityTransport: Transport {
    private let base: StdioTransport
    nonisolated let logger: Logger

    init(base: StdioTransport = StdioTransport()) {
        self.base = base
        self.logger = base.logger
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let task = Task {
            do {
                for try await data in await base.receive() {
                    continuation.yield(Self.compatibleInitialization(data))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func compatibleInitialization(_ data: Data) -> Data {
        guard var request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              request["method"] as? String == "initialize",
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              experimental.values.contains(where: { !($0 is String) }) else { return data }
        capabilities["experimental"] = experimental.filter { $0.value is String }
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? data
    }
}
