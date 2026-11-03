import Foundation
import Logging
import MCP

/// Swift MCP SDK 0.12.1 models experimental client capabilities as String values.
/// MCP permits arbitrary JSON values. Ignore unsupported experimental extensions;
/// this read-only server does not implement any of them.
public actor InitializationCompatibilityTransport: Transport {
    private let base: any Transport
    private let oauthMetadata: Bool
    public nonisolated let logger: Logger

    public init(base: any Transport = StdioTransport(), oauthMetadata: Bool = false) {
        self.base = base
        self.oauthMetadata = oauthMetadata
        self.logger = Logger(label: "vauldy.mcp.compatibility", factory: { _ in SwiftLogNoOpLogHandler() })
    }

    public func connect() async throws { try await base.connect() }
    public func disconnect() async { await base.disconnect() }
    public func send(_ data: Data) async throws {
        var output = data
        if oauthMetadata, var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var result = object["result"] as? [String: Any], var tools = result["tools"] as? [[String: Any]] {
            let schemes: [[String: Any]] = [["type": "oauth2", "scopes": ["documents:read"]]]
            for index in tools.indices {
                tools[index]["securitySchemes"] = schemes
                var meta = tools[index]["_meta"] as? [String: Any] ?? [:]; meta["securitySchemes"] = schemes; tools[index]["_meta"] = meta
            }
            result["tools"] = tools; object["result"] = result
            output = try JSONSerialization.data(withJSONObject: object)
        }
        try await base.send(output)
    }

    public func receive() -> AsyncThrowingStream<Data, any Error> {
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
