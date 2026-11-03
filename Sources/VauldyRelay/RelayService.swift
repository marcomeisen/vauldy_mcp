import Foundation
import Darwin
import VauldyMCPRuntime

public struct RelayService: Sendable {
    public let installation: MCPInstallation
    public init(installation: MCPInstallation) { self.installation = installation }
    public var root: URL { installation.root.appendingPathComponent("relay", isDirectory: true) }
    private var lock: URL { root.appendingPathComponent("agent.lock") }
    private var stop: URL { root.appendingPathComponent("agent.stop") }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for url in [root, lock, stop] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK, info.st_uid == getuid() else { throw RelayFailure.credentials }
            } else if errno != ENOENT { throw RelayFailure.credentials }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public var isRunning: Bool {
        let fd = Darwin.open(lock.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
    public var stopRequested: Bool { FileManager.default.fileExists(atPath: stop.path) }
    public func requestStop() throws { try prepare(); try Data().write(to: stop, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stop.path) }
    public func start(executable: URL) throws {
        try prepare(); if isRunning { return }
        if FileManager.default.fileExists(atPath: stop.path) { try FileManager.default.removeItem(at: stop) }
        let p = Process(); p.executableURL = executable; p.arguments = ["--run", "--root", installation.root.path]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
    }
    public func lease() throws -> RelayLease { try prepare(); return try RelayLease(url: lock) }
}
public final class RelayLease: @unchecked Sendable {
    private let fd: Int32
    init(url: URL) throws {
        fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw RelayFailure.credentials }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw RelayFailure.unavailable }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}
