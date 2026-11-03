import CryptoKit
import Darwin
import Foundation

/// Local, bounded diagnostics. No API accepts free-form messages, queries, document text or paths.
/// Hash chaining detects damage within retained records; it is not a tamper-proof external audit store.
public struct MCPAuditLog: Sendable {
    public enum Event: String, Codable, Sendable {
        case serverStarted, serverStopped, toolsListed, requestStarted, responsePrepared, requestFailed
        case profileSaved, profilePaused, profileRemoved, clientRegistered
    }
    public enum Operation: String, Codable, Sendable {
        case status, search, list, read, unknown, chatgpt, claude
        public init(tool: String) {
            switch tool {
            case "get_vault_status": self = .status
            case "search_documents": self = .search
            case "list_documents": self = .list
            case "read_document": self = .read
            default: self = .unknown
            }
        }
    }
    public enum Code: String, Codable, Sendable {
        case configuration, notAuthorized, invalidArguments, unavailable, privacy, stale, tooLarge
        case cancelled, internalError, auditUnavailable, transportError
        public init(error: any Error) {
            if let access = error as? MCPAccessError {
                switch access {
                case .configuration: self = .configuration
                case .notAuthorized: self = .notAuthorized
                case .invalidArguments: self = .invalidArguments
                case .unavailable: self = .unavailable
                case .privacy: self = .privacy
                case .stale: self = .stale
                case .tooLarge: self = .tooLarge
                }
            } else if error is CancellationError { self = .cancelled }
            else if error is AuditError { self = .auditUnavailable }
            else { self = .internalError }
        }
    }
    public enum AuditError: LocalizedError {
        case unavailable, damaged
        public var errorDescription: String? {
            switch self {
            case .unavailable: "Das lokale Audit-Protokoll ist nicht schreibbar. Bitte Speicherplatz und Zugriffsrechte prüfen. Es wurden keine Dokumentinhalte ausgegeben."
            case .damaged: "Das lokale Audit-Protokoll ist beschädigt oder seine Prüfkette unterbrochen. Bitte die Dateien zur Diagnose sichern."
            }
        }
    }
    public struct Record: Codable, Sendable {
        public let version: Int
        public let serviceVersion: String
        public let sequence: Int
        public let timestamp: String
        public let session: UUID
        public let event: Event
        public let operation: Operation?
        public let request: UUID?
        public let code: Code?
        public let durationMS: Int?
        public let count: Int?
        public let revision: UUID?
        public let documentHandles: [UUID]
    }
    public struct Entry: Codable, Sendable {
        public let record: Record
        public let previousHash: String
        public let hash: String
    }
    private struct Payload: Encodable { let record: Record; let previousHash: String }
    public let directory: URL
    public let session: UUID
    private let maxBytes: Int
    private let archives: Int
    private struct FileState: Equatable { let url: URL; let version: MCPFileVersion }
    private final class VerifiedState: @unchecked Sendable {
        let lock = NSLock()
        var files: [FileState]?
        var last: Entry?
        var verifications = 0
    }
    private let verified = VerifiedState()
    var fullVerificationCount: Int {
        verified.lock.lock(); defer { verified.lock.unlock() }; return verified.verifications
    }

    public init(directory: URL, session: UUID = UUID(), maxBytes: Int = 1_048_576, archives: Int = 4) {
        self.directory = directory
        self.session = session
        self.maxBytes = max(4_096, min(maxBytes, 1_048_576))
        self.archives = max(1, min(archives, 4))
    }
    public init(profileURL: URL) {
        self.init(directory: profileURL.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true))
    }
    public var currentFile: URL { directory.appendingPathComponent("audit.jsonl") }
    private func archive(_ number: Int) -> URL { directory.appendingPathComponent("audit.\(number).jsonl") }

    public func append(_ event: Event, operation: Operation? = nil, request: UUID? = nil, code: Code? = nil,
                       durationMS: Int? = nil, count: Int? = nil, revision: UUID? = nil, documentHandles: [UUID] = []) throws {
        do {
            try locked {
                verified.lock.lock(); defer { verified.lock.unlock() }
                do {
                let files = try existingFiles()
                let states = try fileStates(files)
                let last: Entry?
                if verified.files == states { last = verified.last }
                else {
                    let entries = try files.flatMap { try self.entries(in: $0) }
                    try validateSequence(entries)
                    guard try fileStates(files) == states else { throw AuditError.damaged }
                    last = entries.last
                    if let trusted = verified.last {
                        guard let last, last.record.sequence >= trusted.record.sequence,
                              last.record.sequence != trusted.record.sequence || last.hash == trusted.hash else { throw AuditError.damaged }
                    }
                    verified.verifications += 1
                }
                guard (last?.record.sequence ?? 0) < Int.max else { throw AuditError.damaged }
                let timestamp = ISO8601DateFormatter(); timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let record = Record(version: 1, serviceVersion: MCPBuild.version, sequence: (last?.record.sequence ?? 0) + 1,
                                    timestamp: timestamp.string(from: Date()), session: session, event: event,
                                    operation: operation, request: request, code: code,
                                    durationMS: durationMS.map { max(0, min($0, 86_400_000)) },
                                    count: count.map { max(0, min($0, 20_000)) }, revision: revision,
                                    documentHandles: Array(documentHandles.prefix(10)))
                let previous = last?.hash ?? String(repeating: "0", count: 64)
                let entry = Entry(record: record, previousHash: previous, hash: try digest(record, previous: previous))
                var line = try encoder().encode(entry); line.append(10)
                if FileManager.default.fileExists(atPath: currentFile.path) {
                    let size = try currentFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    if size + line.count > maxBytes { try rotate() }
                }
                try validatePath(currentFile)
                let fd = Darwin.open(currentFile.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw AuditError.unavailable }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { throw AuditError.unavailable }
                try handle.write(contentsOf: line); try handle.synchronize()
                verified.files = try fileStates(existingFiles()); verified.last = entry
                } catch { verified.files = nil; throw error }
            }
        } catch let error as AuditError { throw error }
        catch { throw AuditError.unavailable }
    }

    /// Validates the retained window, oldest first. Rotation intentionally discards older history.
    public func readVerified() throws -> [Entry] {
        try locked {
            let all = try existingFiles().flatMap { try entries(in: $0) }
            try validateSequence(all)
            return all
        }
    }

    private func fileStates(_ files: [URL]) throws -> [FileState] {
        try files.map { try validatePath($0); return FileState(url: $0, version: try MCPFileVersion($0)) }
    }
    private func validateSequence(_ entries: [Entry]) throws {
        for (previous, next) in zip(entries, entries.dropFirst()) {
            guard next.previousHash == previous.hash, next.record.sequence == previous.record.sequence + 1 else { throw AuditError.damaged }
        }
    }

    private func entries(in url: URL) throws -> [Entry] {
        try validatePath(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maxBytes + 4096 else { throw AuditError.damaged }
        let data = try Data(contentsOf: url)
        guard data.isEmpty || data.last == 10 else { throw AuditError.damaged }
        var result: [Entry] = []
        for line in data.split(separator: 10) {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)), entry.record.version == 1,
                  entry.hash == (try digest(entry.record, previous: entry.previousHash)),
                  entry.previousHash.count == 64, entry.record.sequence > 0 else { throw AuditError.damaged }
            if let previous = result.last {
                guard entry.previousHash == previous.hash, entry.record.sequence == previous.record.sequence + 1 else { throw AuditError.damaged }
            }
            result.append(entry)
        }
        return result
    }
    private func existingFiles() throws -> [URL] {
        try (Array((1...archives).reversed()).map(archive) + [currentFile]).filter {
            try validatePath($0)
            return FileManager.default.fileExists(atPath: $0.path)
        }
    }
    private func rotate() throws {
        let fm = FileManager.default
        for number in stride(from: archives, through: 1, by: -1) {
            let destination = archive(number)
            try validatePath(destination)
            let source = number == 1 ? currentFile : archive(number - 1)
            try validatePath(source)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: destination) }
        }
    }
    private func digest(_ record: Record, previous: String) throws -> String {
        SHA256.hash(data: try encoder().encode(Payload(record: record, previousHash: previous)))
            .map { String(format: "%02x", $0) }.joined()
    }
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    private func validatePath(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AuditError.unavailable }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        // The profile's parent is the explicit trusted local destination; never follow linked log files.
        try validatePath(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = Darwin.open(directory.appendingPathComponent("audit.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AuditError.unavailable }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AuditError.unavailable }
        return try body()
    }
}
