import Foundation
import VauldyOAuth
import VauldyMCPRuntime
@main enum VauldyMCPHTTPMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--version"] { print("vauldy-mcp-http \(MCPBuild.version)"); return }
        guard args.count == 2, args[0] == "--root", args[1].hasPrefix("/") else {
            FileHandle.standardError.write(Data("Aufruf: vauldy-mcp-http --root /installation\n".utf8)); exit(64)
        }
        do {
            let store = OAuthStore(installation: MCPInstallation(root: URL(fileURLWithPath: args[1])))
            guard let config = try store.configuration() else { throw OAuthFailure.invalidConfiguration }
            let lease = try OAuthServiceLease(store: store)
            let router = HTTPRouter(store: store, configuration: config)
            let listener = HTTPListener(router: router, port: config.port)
            let monitor = Task {
                while !Task.isCancelled {
                    if OAuthServiceController(store: store).stopRequested { await listener.stop(); return }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { monitor.cancel(); withExtendedLifetime(lease) {} }
            try await listener.run()
        } catch {
            FileHandle.standardError.write(Data("Vauldy OAuth: service-unavailable\n".utf8)); exit(1)
        }
    }
}
