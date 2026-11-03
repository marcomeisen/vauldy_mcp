import Foundation
import Darwin
import VauldyRelay
import VauldyMCPRuntime

/// One persistent stdio server retains source-bound handles and cursors. Only its
/// existing audited, privacy-checked tool results may cross the relay boundary.

@main enum RelayMain {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4, ["--provision", "--run", "--manage"].contains(args[1]), args[2] == "--root", args[3].hasPrefix("/") else { exit(64) }
        let installation = MCPInstallation(root: URL(fileURLWithPath: args[3]))
        let store = RelayCredentialStore(installation: installation)
        do {
            try RelayKeychainInteraction.configure(allow: false)
            if args[1] == "--manage" {
                let request = try RelayUIInput.request(from: .standardInput)
                try RelayKeychainInteraction.configure(allow: request.operation.allowsUserInteraction)
                let parent = getppid()
                let watchdog: Task<Void, Never>? = request.operation.allowsUserInteraction ? Task.detached {
                    do {
                        for _ in 0..<3000 {
                            try await Task.sleep(for: .milliseconds(100))
                            if getppid() != parent || kill(parent, 0) != 0 { Foundation.exit(1) }
                        }
                        Foundation.exit(1)
                    } catch { }
                } : nil
                defer { watchdog?.cancel() }
                let response = await RelayUIManager.handle(request, installation: installation)
                try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response)); return
            }
            if args[1] == "--provision" {
                let data = try FileHandle.standardInput.read(upToCount: 16001) ?? Data()
                struct Provision: Decodable { let origin: String; let serviceToken: String }
                guard data.count <= 16000 else { throw RelayFailure.credentials }
                let p = try JSONDecoder().decode(Provision.self, from: data)
                guard p.origin == RelayCredentials.origin, (20...12000).contains(p.serviceToken.utf8.count), !p.serviceToken.contains(where: \.isNewline) else { throw RelayFailure.credentials }
                try store.provision(serviceToken: p.serviceToken)
                print("Private Verbindung eingerichtet. Keine Dokumentfreigabe verändert."); return
            }
            let service = RelayService(installation: installation), lease = try service.lease()
            defer { withExtendedLifetime(lease) {} }
            guard var credentials = try store.load() else { throw RelayFailure.notProvisioned }
            if credentials.paired, let next = credentials.pendingDeviceToken {
                _ = try credentials.validatedProfile(installation: installation)
                try await RelayClient(credentials: credentials).rotate(nextToken: next)
                try store.completeDeviceRotation(expectedToken: credentials.deviceToken, nextToken: next)
                guard let fresh = try store.load() else { throw RelayFailure.credentials }
                credentials = fresh
            }
            // This pending state is created only after the native owner confirms
            // an exact existing profile revision. Browser SSO alone grants nothing.
            while !credentials.paired && !service.stopRequested {
                if let complete = try await RelayClient(credentials: credentials).finish() {
                    try store.completePairing(expectedID: credentials.pairID, completed: complete)
                    credentials = complete; break
                }
                try await Task.sleep(for: .seconds(2))
            }
            guard !service.stopRequested else { return }
            let profile = try credentials.validatedProfile(installation: installation)
            let local = try await RelayLocalMCP(installation: installation, profile: profile)
            defer { local.close() }
            let client = RelayClient(credentials: credentials)
            var failures = 0
            while !service.stopRequested {
                guard let current = try store.load(), current.paired, current.deviceToken == credentials.deviceToken else { throw RelayFailure.signInRequired }
                _ = try credentials.validatedProfile(installation: installation)
                do {
                    if let job = try await client.poll() {
                        let request = try client.decode(job: job)
                        _ = try credentials.validatedProfile(installation: installation)
                        let result = try await local.call(request)
                        guard !service.stopRequested, let current = try store.load(), current.deviceToken == credentials.deviceToken else { throw RelayFailure.signInRequired }
                        _ = try credentials.validatedProfile(installation: installation)
                        try await client.result(job: job, data: result)
                    }
                    failures = 0; try await Task.sleep(for: .milliseconds(750))
                } catch RelayFailure.signInRequired { try store.clearDevice(expectedToken: credentials.deviceToken); throw RelayFailure.signInRequired }
                catch {
                    failures += 1
                    // Never replay a claimed request. Its caller gets a timeout.
                    if !local.isRunning { throw RelayFailure.unavailable }
                    try await Task.sleep(for: .seconds(min(10, failures * 2)))
                }
            }
        } catch { FileHandle.standardError.write(Data("Vauldy relay unavailable; open setup.\n".utf8)); exit(1) }
    }
}
