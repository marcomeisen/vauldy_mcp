import Foundation
import Darwin

public struct MCPServerInstance: Codable, Equatable, Sendable {
    public var connectionID: UUID?
    public var version: String?
    public var diagnostic: Bool
    public var lastRequestAt: Date?
    public init(connectionID: UUID? = nil, version: String? = nil, diagnostic: Bool = false, lastRequestAt: Date? = nil) {
        self.connectionID = connectionID; self.version = version; self.diagnostic = diagnostic; self.lastRequestAt = lastRequestAt
    }
}

/// Content-free, local process liveness. The OS releases flock even after SIGKILL; no heartbeat/PID guesswork.
public final class MCPProcessPresence: @unchecked Sendable {
    public enum PresenceError: Error { case unavailable, alreadyRunning }
    private let mutex = NSLock()
    private var descriptor: Int32
    private let url: URL
    private var instance: MCPServerInstance?

    public static func root(forProfile profile: URL) -> URL {
        let connection = profile.deletingLastPathComponent()
        if UUID(uuidString: connection.lastPathComponent) != nil,
           connection.deletingLastPathComponent().lastPathComponent == "connections" {
            return connection.deletingLastPathComponent().deletingLastPathComponent()
        }
        // Standalone/custom profiles, including tests, never write to the user's installed root.
        return connection
    }

    public init(root: URL, menu: Bool = false, connectionID: UUID? = nil, diagnostic: Bool = false) throws {
        let directory = try Self.prepare(root)
        let registry = try Self.open(directory.appendingPathComponent("registry.lock"), create: true)
        defer { close(registry) }
        guard flock(registry, LOCK_EX) == 0 else { throw PresenceError.unavailable }
        defer { flock(registry, LOCK_UN) }
        // Remove only our own unlocked, UUID-named markers. Never touch profiles, logs or originals.
        for marker in try Self.markers(directory) where try !Self.isLocked(marker) {
            try FileManager.default.removeItem(at: marker)
            let metadata = marker.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
        }
        url = directory.appendingPathComponent(menu ? "menu.lock" : UUID().uuidString + ".server")
        descriptor = try Self.open(url, create: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw PresenceError.alreadyRunning
        }
        if menu {
            let stop = directory.appendingPathComponent("menu-stop")
            if FileManager.default.fileExists(atPath: stop.path) { try FileManager.default.removeItem(at: stop) }
        } else if let connectionID {
            instance = MCPServerInstance(connectionID: connectionID, version: MCPBuild.version, diagnostic: diagnostic)
            do { try writeInstance() }
            catch { stop(); throw error }
        }
    }

    public func recordRequest() {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0, instance != nil else { return }
        instance?.lastRequestAt = Date()
        try? writeInstance()
    }
    private func writeInstance() throws {
        let destination = url.deletingPathExtension().appendingPathExtension("json")
        guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw PresenceError.unavailable }
        try JSONEncoder().encode(instance).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func stop() {
        mutex.lock(); defer { mutex.unlock() }
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
            // Keep the fixed menu lock inode for the next menu process.
            if url.pathExtension == "server" {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
            }
        }
    }
    deinit { stop() }

    public static func serverCount(root: URL) throws -> Int {
        let directory = root.appendingPathComponent("runtime-status", isDirectory: true)
        guard try directoryExists(directory) else { return 0 }
        return try markers(directory).reduce(0) { try $0 + (isLocked($1) ? 1 : 0) }
    }

    /// Local operational metadata only; never serialized by a document MCP tool.
    public static func serverInstances(root: URL) throws -> [MCPServerInstance] {
        let directory = root.appendingPathComponent("runtime-status", isDirectory: true)
        guard try directoryExists(directory) else { return [] }
        var instances: [MCPServerInstance] = []
        for marker in try markers(directory) where try isLocked(marker) {
            let metadata = marker.deletingPathExtension().appendingPathExtension("json")
            var instance = MCPServerInstance()
            if FileManager.default.fileExists(atPath: metadata.path) {
                let values = try metadata.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2_048 else { throw PresenceError.unavailable }
                instance = try JSONDecoder().decode(MCPServerInstance.self, from: Data(contentsOf: metadata))
                guard (instance.version?.utf8.count ?? 0) <= 64 else { throw PresenceError.unavailable }
            }
            if try isLocked(marker) { instances.append(instance) }
        }
        return instances
    }

    public static func menuIsRunning(root: URL) throws -> Bool {
        let directory = root.appendingPathComponent("runtime-status", isDirectory: true)
        guard try directoryExists(directory) else { return false }
        return try isLocked(directory.appendingPathComponent("menu.lock"))
    }

    @discardableResult
    public static func requestMenuStop(root: URL) throws -> Bool {
        guard try menuIsRunning(root: root) else { return false }
        let fd = try open(root.appendingPathComponent("runtime-status/menu-stop"), create: true)
        close(fd)
        return true
    }

    public static func menuStopRequested(root: URL) throws -> Bool {
        let url = root.appendingPathComponent("runtime-status/menu-stop")
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw PresenceError.unavailable
        }
        let fd = try open(url, create: false)
        close(fd)
        return true
    }

    private static func markers(_ directory: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard entries.count <= 514 else { throw PresenceError.unavailable }
        return entries.filter { $0.pathExtension == "server" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }

    private static func prepare(_ root: URL) throws -> URL {
        for directory in [root, root.appendingPathComponent("runtime-status", isDirectory: true)] {
            if try !directoryExists(directory) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            // A custom profile may live in an existing user folder. Only our own status directory is tightened.
            if directory.path != root.path {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        }
        return root.appendingPathComponent("runtime-status", isDirectory: true)
    }

    private static func directoryExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw PresenceError.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw PresenceError.unavailable }
        return true
    }

    private static func open(_ url: URL, create: Bool) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PresenceError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size == 0 else {
            close(fd); throw PresenceError.unavailable
        }
        return fd
    }

    private static func isLocked(_ url: URL) throws -> Bool {
        let fd: Int32
        do { fd = try open(url, create: false) }
        catch {
            // A server may remove its marker between enumeration and open.
            var info = stat()
            if lstat(url.path, &info) != 0 && errno == ENOENT { return false }
            throw error
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        guard errno == EWOULDBLOCK else { throw PresenceError.unavailable }
        return true
    }
}

/// Launches only our packaged companion, detached from stdio. One observer per installation root.
public enum MCPStatusApp {
    public static let bundleName = "Vauldy MCP Status.app"
    @discardableResult
    public static func launch(root: URL, beside executable: URL) throws -> Bool {
        if try MCPProcessPresence.menuIsRunning(root: root) { return false }
        let bundle = executable.deletingLastPathComponent().appendingPathComponent(bundleName)
        let binary = bundle.appendingPathComponent("Contents/MacOS/vauldy-mcp-status")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw MCPProcessPresence.PresenceError.unavailable }
        let process = Process(); process.executableURL = binary
        process.arguments = ["--root", root.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        return true
    }
}
