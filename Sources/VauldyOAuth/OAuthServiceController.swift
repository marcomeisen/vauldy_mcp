import Foundation
import Darwin

public final class OAuthServiceLease: @unchecked Sendable {
    private let fd: Int32
    public init(store: OAuthStore) throws {
        fd = try store.locked {
            let file = store.root.appendingPathComponent("service.lock")
            try store.refuseLink(file)
            let value = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard value >= 0 else { throw OAuthFailure.temporarilyUnavailable }
            guard flock(value, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(value); throw OAuthFailure.temporarilyUnavailable }
            return value
        }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}
public struct OAuthServiceController: Sendable {
    public let store: OAuthStore
    public init(store: OAuthStore) { self.store = store }
    public func isRunning() -> Bool {
        let file = store.root.appendingPathComponent("service.lock")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
    public func start(executable: URL) async throws {
        guard let config = try store.configuration(), executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw OAuthFailure.invalidConfiguration }
        if !isRunning() {
            try store.locked {
                let stop = store.root.appendingPathComponent("service.stop"); try store.refuseLink(stop)
                if FileManager.default.fileExists(atPath: stop.path) { try FileManager.default.removeItem(at: stop) }
            }
            let process = Process(); process.executableURL = executable; process.arguments = ["--root", store.installation.root.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        }
        for _ in 0..<30 {
            try Task.checkCancellation()
            if isRunning() {
                let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/.well-known/oauth-protected-resource")!); request.timeoutInterval = 1
                if let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], json["resource"] as? String == config.resource { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw OAuthFailure.temporarilyUnavailable
    }
    public func stop() throws { try store.locked { try store.write(Data(), to: store.root.appendingPathComponent("service.stop")) } }
    public var stopRequested: Bool { FileManager.default.fileExists(atPath: store.root.appendingPathComponent("service.stop").path) }
}
