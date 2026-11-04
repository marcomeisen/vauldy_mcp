import Foundation
import MCP
import VauldyMCPRuntime
import VauldyMCPProtocol

@main
enum VauldyMCPMain {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 2 && arguments[1] == "--version" {
            print("vauldy-mcp \(MCPBuild.version)"); return
        }
        let experimentalSQLiteIndex = arguments.count == 4 && arguments[3] == "--experimental-sqlite-index"
        guard (arguments.count == 3 || experimentalSQLiteIndex),
              arguments[1] == "--profile", arguments[2].hasPrefix("/") else {
            diagnostic(.configuration)
            FileHandle.standardError.write(Data("Aufruf: vauldy-mcp --profile /absoluter/pfad/profile.json [--experimental-sqlite-index]\n".utf8))
            Foundation.exit(64)
        }
        let profileURL = URL(fileURLWithPath: arguments[2])
        let profile = FileMCPProfileSource(url: profileURL)
        let audit = MCPAuditLog(profileURL: profileURL)
        do { try audit.append(.serverStarted) }
        catch { diagnostic(.auditUnavailable); Foundation.exit(1) }
        let isDiagnostic = ProcessInfo.processInfo.environment["VAULDY_MCP_DIAGNOSTIC"] == "1"
        let root = MCPProcessPresence.root(forProfile: profileURL)
        let presence: MCPProcessPresence?
        do { presence = try MCPProcessPresence(root: root, connectionID: try? profile.load().connectionID, diagnostic: isDiagnostic) }
        catch {
            presence = nil
            FileHandle.standardError.write(Data("Vauldy MCP: statusUnavailable\n".utf8))
        }
        defer { presence?.stop() }
        let server = await VauldyMCPServerFactory.make(profile: profile, audit: audit,
                                                       experimentalSQLiteIndex: experimentalSQLiteIndex) {
            presence?.recordRequest()
        }
        do {
            // Keep the SDK's default no-op logger: SDK metadata can contain untrusted request text.
            try await server.start(transport: InitializationCompatibilityTransport())
            // Installed servers share one detached observer. Raw development/wire-test binaries stay headless.
            let executable = URL(fileURLWithPath: arguments[0]).standardizedFileURL
            if !isDiagnostic, executable.deletingLastPathComponent().lastPathComponent == "bin",
               executable.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() == root.resolvingSymlinksInPath() {
                do { try MCPStatusApp.launch(root: root, beside: executable) }
                catch { FileHandle.standardError.write(Data("Vauldy MCP: statusMenuUnavailable\n".utf8)) }
            }
            await server.waitUntilCompleted()
            await server.stop()
            try audit.append(.serverStopped)
        } catch {
            diagnostic(.transportError)
            try? audit.append(.serverStopped, code: .transportError)
            Foundation.exit(1)
        }
    }
}

private func diagnostic(_ code: MCPAuditLog.Code, request: UUID? = nil) {
    FileHandle.standardError.write(Data(("Vauldy MCP: \(code.rawValue)\n").utf8))
}
