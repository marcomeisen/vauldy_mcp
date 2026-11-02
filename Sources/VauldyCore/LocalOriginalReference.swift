import Foundation
import CryptoKit
import Darwin

public enum LocalOriginalStorage: Sendable { case managedCopy, referenced }
public enum LocalOriginalState: String, Codable, Sendable { case available, unavailable, changed }
public enum LocalOriginalError: String, Error, LocalizedError, Sendable {
    case unavailable, changed, scopedAccessRequired
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Das Original ist nicht erreichbar oder der Dateizugriff fehlt. Der gespeicherte Dokumenteintrag bleibt erhalten."
        case .changed: "Das Original wurde verändert. Gespeicherter Text und Basisanalyse gehören zum früheren Inhalt. Bitte die neue Fassung ausdrücklich importieren."
        case .scopedAccessRequired: "Für dieses Original wird ein zeitlich begrenzter Dateizugriff benötigt."
        }
    }
    var state: LocalOriginalState { self == .changed ? .changed : .unavailable }
}

/// Private local authority, never an MCP output. No path fallback after a failed bookmark.
public struct LocalOriginalReference: Codable, Equatable, Sendable {
    public let version: Int
    public let bookmark: Data
    public let lastKnownPath: String
    public let identity: String
    public static func capture(_ file: URL, excluding root: URL) throws -> Self {
        let access = LocalOriginalAccess(url: file)
        defer { access.close() }
        try access.requireOutside(root)
        _ = try access.readData()
        do {
            let bookmark = try file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            let reference = Self(version: 1, bookmark: bookmark, lastKnownPath: file.standardizedFileURL.path,
                                 identity: try access.fileIdentity())
            let reopened = try reference.open(excluding: root); defer { reopened.close() }
            guard try reopened.fileIdentity() == reference.identity else { throw LocalOriginalError.changed }
            return reference
        } catch let error as LocalOriginalError { throw error }
        catch { throw LocalOriginalError.unavailable }
    }
    public func open(excluding root: URL) throws -> LocalOriginalAccess {
        guard version == 1, !bookmark.isEmpty, bookmark.count <= 65_536,
              lastKnownPath.utf8.count <= 8_192, identity.count <= 100 else { throw LocalOriginalError.unavailable }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let access = LocalOriginalAccess(url: url)
            do { try access.requireOutside(root); return access }
            catch { access.close(); throw error }
        } catch let error as LocalOriginalError { throw error }
        catch { throw LocalOriginalError.unavailable }
    }
}

/// Scope lasts through native OCR or Quick Look, including joined cancellation.
public final class LocalOriginalAccess: @unchecked Sendable {
    public let url: URL
    private let scoped: Bool
    private let lock = NSLock()
    private var closed = false
    init(url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
    deinit { close() }
    func requireOutside(_ root: URL) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let store = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard url.isFileURL, path != store, !path.hasPrefix(store + "/") else { throw LocalOriginalError.unavailable }
    }
    private func descriptor() throws -> Int32 {
        lock.lock(); let active = !closed; lock.unlock()
        guard active, url.isFileURL else { throw LocalOriginalError.unavailable }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalOriginalError.unavailable }
        return fd
    }
    func fileIdentity() throws -> String {
        let fd = try descriptor(); defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw LocalOriginalError.unavailable }
        return "\(info.st_dev):\(info.st_ino)"
    }
    public func readData() throws -> Data {
        let fd = try descriptor()
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw LocalOriginalError.unavailable }
        guard before.st_size <= LocalDocumentStore.maximumOriginalBytes else { throw LocalImportError.fileTooLarge }
        let data: Data
        do { data = try file.read(upToCount: LocalDocumentStore.maximumOriginalBytes + 1) ?? Data() }
        catch { throw LocalOriginalError.unavailable }
        guard data.count <= LocalDocumentStore.maximumOriginalBytes else { throw LocalImportError.fileTooLarge }
        guard !data.isEmpty else { throw LocalImportError.invalidDocument }
        guard data.count == Int(before.st_size) else { throw LocalOriginalError.changed }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw LocalOriginalError.changed }
        return data
    }
    func verify(hash: String) throws {
        guard Self.hash(try readData()) == hash else { throw LocalOriginalError.changed }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
