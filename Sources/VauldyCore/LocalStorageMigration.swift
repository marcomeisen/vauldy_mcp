import Foundation
import CryptoKit
import Darwin

/// Explicit local maintenance. No profile, watcher, credential or external original is written.
/// A published result contains a verified backup and a separately usable new vault.
public struct LocalStorageMigration: Sendable {
    public enum Format: String, Codable, Sendable { case json, sqlite, same }
    public enum Failure: String, LocalizedError {
        case unsafePath, incompatible, busy, changed, capacity, verification
        public var errorDescription: String? {
            switch self {
            case .unsafePath: "Migration benötigt einen privaten eigenen Bestand und ein neues, getrenntes Zielverzeichnis."
            case .incompatible: "Unbekanntes oder nicht verlustfrei übertragbares Speicherformat. Es wurde kein Bestand umgeschaltet."
            case .busy: "Bitte den lokalen Worker beenden und offene Importe abschließen, bevor der Bestand übertragen wird."
            case .changed: "Der Bestand hat sich seit der Vorschau geändert. Bitte eine neue Vorschau erstellen."
            case .capacity: "Die Übertragung überschreitet die Speichergrenze oder es fehlt freier Platz am Ziel."
            case .verification: "Die Prüfung von Backup, Dokumenten oder Originalkopien ist fehlgeschlagen. Der bisherige Bestand bleibt erhalten."
            }
        }
    }
    public struct Preview: Codable, Sendable {
        public let sourceFormat: Format
        public let targetFormat: Format
        public let documents: Int
        public let originalCopies: Int
        public let referencedDocuments: Int
        public let estimatedRequiredBytes: Int64
        public let fingerprint: String
    }
    public struct Result: Codable, Sendable {
        public let vaultPath: String
        public let backupPath: String
        public let documents: Int
        public let verified: Bool
        public let profilesChanged: Bool
    }
    private struct Manifest: Codable {
        var version = 1
        let files: [String: String]
    }
    private struct Inventory {
        let documents: [VaultDocument]
        let format: Format
        let files: [String: String]
        let bytes: Int64
        let generation: String?
        let token: String
    }
    public let source: URL
    private let allowPending: Bool
    private let availableBytes: @Sendable (URL) throws -> UInt64
    public init(source: URL) { self.source = source.standardizedFileURL; allowPending = false; availableBytes = Self.availableCapacity }
    package init(source: URL, availableBytes: @escaping @Sendable (URL) throws -> UInt64) {
        self.source = source; self.availableBytes = availableBytes; allowPending = false
    }
    private init(stagingSource: URL) { source = stagingSource; allowPending = true; availableBytes = Self.availableCapacity }
    private static func availableCapacity(_ parent: URL) throws -> UInt64 {
        var volume = statfs()
        guard statfs(parent.path, &volume) == 0 else { throw Failure.capacity }
        return UInt64(volume.f_bavail) * UInt64(volume.f_bsize)
    }

    public func preview(format: Format) throws -> Preview {
        try withFrozenSource {
            let inventory = try inspect()
            return try preview(inventory, format: format)
        }
    }

    /// Existing destinations are refused, including empty directories. The preview token is mandatory.
    /// Backup verification precedes conversion. Only a completely verified directory is published.
    public func transfer(to destination: URL, format: Format, expected: String, restoringBackup: Bool = false) throws -> Result {
        try withFrozenSource {
            if restoringBackup { try verifyBackup(source) }
            let inventory = try inspect(), plan = try preview(inventory, format: format)
            guard plan.fingerprint == expected else { throw Failure.changed }
            let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            try directory(parent, privateOnly: false)
            let target = parent.appendingPathComponent(destination.lastPathComponent)
            let sourcePath = source.resolvingSymlinksInPath().path
            guard !destination.lastPathComponent.isEmpty, destination.lastPathComponent != ".", destination.lastPathComponent != "..",
                  target.path != sourcePath, !target.path.hasPrefix(sourcePath + "/"), !exists(target) else { throw Failure.unsafePath }
            let available = try availableBytes(parent)
            guard available >= UInt64(plan.estimatedRequiredBytes) else { throw Failure.capacity }
            let staging = parent.appendingPathComponent(".vauldy-transfer-" + UUID().uuidString)
            guard mkdir(staging.path, S_IRWXU) == 0 else { throw Failure.unsafePath }
            // On failure or crash keep evidence in the private staging directory. No destructive cleanup
            // or recursive removal is attempted. A retry must use a fresh output directory.
            let pending = staging.appendingPathComponent("INCOMPLETE")
            try write(Data("Not published; do not use as a vault.\n".utf8), pending)
            let backup = staging.appendingPathComponent("backup"), vault = staging.appendingPathComponent("vault")
            try clone(inventory, to: backup)
            try verifyBackup(backup)
            let backupInventory = try LocalStorageMigration(stagingSource: backup).inspect()
            try compare(inventory.documents, backupInventory.documents)
            if plan.targetFormat == inventory.format {
                try LocalStorageMigration(stagingSource: backup).clone(backupInventory, to: vault)
                try FileManager.default.removeItem(at: vault.appendingPathComponent("backup-manifest.json"))
            } else if plan.targetFormat == .sqlite {
                _ = try LocalDocumentStore.createSQLite(at: vault)
                let database = try SQLiteDocumentStore(directory: vault.appendingPathComponent("sqlite"))
                try database.importJSON(FileVaultSnapshotSource(fileURL: backup.appendingPathComponent("documents.json")))
                try copyOriginals(from: backup, inventory: backupInventory, to: vault)
            } else {
                guard mkdir(vault.path, S_IRWXU) == 0 else { throw Failure.unsafePath }
                let database = try SQLiteDocumentStore(directory: backup.appendingPathComponent("sqlite"), readOnly: true)
                try database.exportJSON(toNewFile: vault.appendingPathComponent("documents.json"))
                try copyOriginals(from: backup, inventory: backupInventory, to: vault)
                // Format 2 supports all original references; incompatible older writers refuse it.
                try write(Data("{\"kind\":\"vauldy-local-core\",\"version\":2}".utf8), vault.appendingPathComponent("store.json"))
                try write(Data(), vault.appendingPathComponent("writer.lock"))
            }
            let converted = try LocalStorageMigration(stagingSource: vault).inspect()
            try compare(inventory.documents, converted.documents)
            guard originalFiles(inventory.files) == originalFiles(converted.files),
                  try inspect().token == inventory.token else { throw Failure.changed }
            try verifyBackup(backup)
            let result = Result(vaultPath: target.appendingPathComponent(plan.targetFormat == .sqlite ? "vault/sqlite/records.sqlite" : "vault/documents.json").path,
                                backupPath: target.appendingPathComponent("backup").path,
                                documents: inventory.documents.count, verified: true, profilesChanged: false)
            try write(JSONEncoder().encode(result), staging.appendingPathComponent("receipt.json"))
            try synchronizeTree(staging)
            // Final destinations never overwrite an existing tree, even if it appeared after preflight.
            guard renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw Failure.unsafePath }
            try syncDirectory(parent)
            // Marker remains until publication and durability checks complete. Readers reject pending vaults.
            try FileManager.default.removeItem(at: target.appendingPathComponent("INCOMPLETE"))
            try syncDirectory(target)
            return result
        }
    }

    private func preview(_ inventory: Inventory, format: Format) throws -> Preview {
        let target = format == .same ? inventory.format : format
        let encoded = try encode(inventory.documents)
        if target == .sqlite {
            for document in inventory.documents {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                guard try encoder.encode(document).count <= 8 * 1_024 * 1_024 else { throw Failure.capacity }
            }
        }
        guard inventory.documents.count <= VaultStorageLimits.importedDocuments else { throw Failure.capacity }
        if target == .json, encoded.count > VaultStorageLimits.snapshotBytes { throw Failure.capacity }
        // Conservative bound includes source backup, target, SQLite journals/index overhead and reserve.
        let estimate = inventory.bytes * 4 + Int64(encoded.count) * 4 + 64 * 1_024 * 1_024
        if target == .sqlite, encoded.count > 256 * 1_024 * 1_024 { throw Failure.capacity }
        let token = hash(Data((inventory.token + ":" + target.rawValue).utf8))
        return Preview(sourceFormat: inventory.format, targetFormat: target, documents: inventory.documents.count,
                       originalCopies: originalFiles(inventory.files).count,
                       referencedDocuments: inventory.documents.filter { $0.localImport?.originalReference != nil }.count,
                       estimatedRequiredBytes: estimate, fingerprint: token)
    }

    private func withFrozenSource<T>(recoveringActivation: Bool = false, _ operation: () throws -> T) throws -> T {
        try directory(source)
        guard recoveringActivation || !exists(source.appendingPathComponent("SQLITE_ACTIVATION_PENDING")) else { throw Failure.busy }
        // Read the marker before opening locks: never initialize an arbitrary directory.
        _ = try marker(source)
        var leases: [LocalWorkerLease] = []
        defer { leases.forEach { $0.release() } }
        for path in ["worker/worker.lock", "ocr.lock", "writer.lock"] {
            let url = source.appendingPathComponent(path)
            if path.hasPrefix("worker/"), exists(source.appendingPathComponent("worker")) { try directory(source.appendingPathComponent("worker")) }
            if exists(url) {
                try regular(url)
                do { leases.append(try LocalWorkerLease(url: url, create: false)) }
                catch { throw Failure.busy }
            } else if path == "writer.lock" { throw Failure.incompatible }
        }
        return try operation()
    }

    private func inspect() throws -> Inventory {
        try directory(source)
        let format = try marker(source)
        let snapshot = source.appendingPathComponent(format == .sqlite ? "sqlite/records.sqlite" : "documents.json")
        let database = format == .sqlite ? try SQLiteDocumentStore(directory: source.appendingPathComponent("sqlite"), readOnly: true) : nil
        try regular(snapshot)
        let generation = try database?.generation
        try database?.validateForMigration()
        let documents = try database?.documents() ?? FileVaultSnapshotSource(fileURL: snapshot).loadDocuments()
        guard documents.allSatisfy({ $0.localImport != nil }) else { throw Failure.incompatible }
        guard !documents.contains(where: { $0.localImport?.state == .queued || $0.localImport?.state == .recognizing }) else { throw Failure.busy }
        let worker = source.appendingPathComponent("worker")
        if exists(worker) {
            try directory(worker)
            let jobs = try FileManager.default.contentsOfDirectory(atPath: worker.path).filter { $0.hasSuffix(".json") }
            guard jobs.count <= 5_000 else { throw Failure.busy }
            for name in jobs {
                let job = try JSONSerialization.jsonObject(with: read(worker.appendingPathComponent(name), limit: 160_000)) as? [String: Any]
                guard job?["state"] as? String == "finished" else { throw Failure.busy }
            }
        }
        var files: [String: String] = [:], bytes: Int64 = 0
        func add(_ relative: String) throws {
            let url = source.appendingPathComponent(relative); let data = try read(url)
            files[relative] = hash(data); bytes += Int64(data.count)
        }
        try add("store.json")
        if format == .json {
            try losslessJSON(snapshot, documents: documents)
            try add("documents.json")
            if exists(source.appendingPathComponent("documents.backup.json")) { try add("documents.backup.json") }
        } else {
            // Never hash/copy a live main SQLite file without its committed WAL state.
            files["sqlite-generation"] = generation
            try regular(snapshot)
            let mainSize = (try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? NSNumber)?.int64Value ?? 0
            bytes += max(mainSize, Int64(try encode(documents).count))
        }
        let originals = source.appendingPathComponent("originals")
        if exists(originals) {
            try directory(originals)
            let names = try FileManager.default.contentsOfDirectory(atPath: originals.path).sorted()
            guard names.count <= 40_000 else { throw Failure.capacity }
            for name in names {
                let url = originals.appendingPathComponent(name)
                let stem = url.deletingPathExtension().lastPathComponent
                guard stem.count == 64, stem.allSatisfy({ "0123456789abcdef".contains($0) }),
                      LocalDocumentStore.supportedExtensions.contains(url.pathExtension) else { throw Failure.unsafePath }
                let data = try read(url, limit: LocalDocumentStore.maximumOriginalBytes)
                guard hash(data) == stem else { throw Failure.verification }
                files["originals/" + name] = hash(data); bytes += Int64(data.count)
            }
        }
        for document in documents {
            let metadata = document.localImport!
            if metadata.originalReference == nil {
                guard files["originals/\(metadata.contentHash).\(metadata.fileExtension)"] == metadata.contentHash else { throw Failure.verification }
            }
        }
        guard try database?.generation == generation else { throw Failure.changed }
        let serial = try JSONSerialization.data(withJSONObject: files, options: [.sortedKeys])
        let token = hash(serial + Data(source.resolvingSymlinksInPath().path.utf8) + (try encode(documents)))
        return Inventory(documents: documents, format: format, files: files, bytes: bytes, generation: generation, token: token)
    }

    private func clone(_ inventory: Inventory, to target: URL) throws {
        guard mkdir(target.path, S_IRWXU) == 0 else { throw Failure.unsafePath }
        if inventory.format == .sqlite {
            let database = try SQLiteDocumentStore(directory: source.appendingPathComponent("sqlite"), readOnly: true)
            _ = try database.backup(toNewDirectory: target.appendingPathComponent("sqlite"))
        } else {
            for name in ["documents.json", "documents.backup.json"] where inventory.files[name] != nil {
                try write(read(source.appendingPathComponent(name)), target.appendingPathComponent(name))
            }
        }
        try copyOriginals(from: source, inventory: inventory, to: target)
        try write(read(source.appendingPathComponent("store.json")), target.appendingPathComponent("store.json"))
        try write(Data(), target.appendingPathComponent("writer.lock"))
        let files = try backupFiles(target)
        try write(JSONEncoder().encode(Manifest(files: files)), target.appendingPathComponent("backup-manifest.json"))
    }
    private func copyOriginals(from origin: URL, inventory: Inventory, to target: URL) throws {
        let selected = originalFiles(inventory.files)
        if !selected.isEmpty { guard mkdir(target.appendingPathComponent("originals").path, S_IRWXU) == 0 else { throw Failure.unsafePath } }
        for (path, digest) in selected {
            try Task.checkCancellation()
            let data = try read(origin.appendingPathComponent(path), limit: LocalDocumentStore.maximumOriginalBytes)
            guard hash(data) == digest else { throw Failure.changed }
            try write(data, target.appendingPathComponent(path))
        }
    }
    private func verifyBackup(_ root: URL) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: read(root.appendingPathComponent("backup-manifest.json"), limit: 16 * 1_024 * 1_024))
        guard manifest.version == 1, try backupFiles(root) == manifest.files else { throw Failure.verification }
    }
    private func backupFiles(_ root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        func walk(_ directoryURL: URL, prefix: String) throws {
            try directory(directoryURL)
            let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).sorted()
            guard names.count <= 40_008 else { throw Failure.capacity }
            for name in names {
                if prefix.isEmpty, !["writer.lock", "backup-manifest.json", "store.json", "documents.json", "documents.backup.json", "originals", "sqlite"].contains(name) { throw Failure.verification }
                if prefix == "sqlite/", name != "records.sqlite" { throw Failure.verification }
                if prefix.isEmpty && ["writer.lock", "backup-manifest.json"].contains(name) { continue }
                let path = prefix + name, url = directoryURL.appendingPathComponent(name)
                if path == "sqlite" || path == "originals" { try walk(url, prefix: path + "/") }
                else { files[path] = try fileHash(url) }
            }
        }
        try walk(root, prefix: ""); return files
    }
    private func compare(_ a: [VaultDocument], _ b: [VaultDocument]) throws {
        guard Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: b.map { ($0.id, $0) }) else { throw Failure.verification }
    }
    private func losslessJSON(_ file: URL, documents: [VaultDocument]) throws {
        try Self.requirePreservedJSON(read(file), encode(documents))
    }
    package static func requirePreservedJSON(_ input: Data, _ output: Data) throws {
        let original = try JSONSerialization.jsonObject(with: input)
        let encoded = try JSONSerialization.jsonObject(with: output)
        func preserved(_ a: Any, _ b: Any) -> Bool {
            if let a = a as? [String: Any], let b = b as? [String: Any] { return a.allSatisfy { key, value in b[key].map { preserved(value, $0) } ?? false } }
            if let a = a as? [Any], let b = b as? [Any] { return a.count == b.count && zip(a,b).allSatisfy { preserved($0,$1) } }
            return (a as? NSObject)?.isEqual(b) == true
        }
        guard preserved(original, encoded) else { throw Failure.incompatible }
    }
    private func marker(_ root: URL) throws -> Format {
        let value = try JSONSerialization.jsonObject(with: read(root.appendingPathComponent("store.json"), limit: 4096)) as? [String: Any]
        guard let value, Set(value.keys) == ["kind", "version"], value["kind"] as? String == "vauldy-local-core",
              let version = value["version"] as? Int, (1...4).contains(version),
              (allowPending || !exists(root.deletingLastPathComponent().appendingPathComponent("INCOMPLETE"))) else { throw Failure.incompatible }
        return version >= 3 ? .sqlite : .json
    }
    private func originalFiles(_ files: [String: String]) -> [String: String] { files.filter { $0.key.hasPrefix("originals/") } }
    private func encode(_ documents: [VaultDocument]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(documents)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    private func directory(_ url: URL, privateOnly: Bool = true) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              !privateOnly || (info.st_uid == getuid() && info.st_mode & 0o077 == 0) else { throw Failure.unsafePath }
    }
    private func regular(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
    }
    private func read(_ url: URL, limit: Int = VaultStorageLimits.snapshotBytes) throws -> Data {
        try regular(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        guard try handle.seekToEnd() <= limit else { throw Failure.capacity }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.capacity }; return data
    }
    private func fileHash(_ url: URL) throws -> String {
        try regular(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        guard try handle.seekToEnd() <= 1_024 * 1_024 * 1_024 else { throw Failure.capacity }
        try handle.seek(toOffset: 0)
        var digest = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation(); digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func write(_ data: Data, _ url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize()
    }
    private func synchronizeTree(_ root: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            var info = stat(); guard lstat(url.path, &info) == 0 else { throw Failure.verification }
            if info.st_mode & S_IFMT == S_IFDIR { try synchronizeTree(url) }
            else { let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close() }
        }
        try syncDirectory(root)
    }
    private func syncDirectory(_ root: URL) throws {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unsafePath }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.verification }
    }
}

extension LocalStorageMigration {
    public struct Activation: Codable, Sendable {
        public let storage: String
        public let vaultPath: String
        public let backupPath: String
        public let documents: Int
        public let verified: Bool
        public let profilesChanged: Bool
    }
    private struct PendingActivation: Codable {
        var version = 1
        let prepared: String
        let sourceHash: String
        let marker: Data
        let staging: String
        let archive: String
    }
    private var activationPending: URL { source.appendingPathComponent("SQLITE_ACTIVATION_PENDING") }

    /// Promote a verified additive transfer at the existing root. Format 4 excludes old
    /// writers and explicitly routes existing logical JSON grants to this SQLite store.
    public func activateSQLite(from prepared: URL, expected: String) throws -> Activation {
        try activateSQLite(from: prepared, expected: expected, checkpoint: { _ in })
    }

    package func activateSQLite(from prepared: URL, expected: String,
                                checkpoint: (String) throws -> Void) throws -> Activation {
        try withFrozenSource {
            let original = try inspect(), plan = try preview(original, format: .sqlite)
            guard original.format == .json, plan.fingerprint == expected else { throw Failure.changed }
            try directory(prepared)
            guard !exists(prepared.appendingPathComponent("INCOMPLETE")),
                  !exists(source.appendingPathComponent("sqlite")),
                  !prepared.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/") else { throw Failure.unsafePath }
            let backup = prepared.appendingPathComponent("backup"), ready = prepared.appendingPathComponent("vault")
            try verifyBackup(backup)
            let backed = try LocalStorageMigration(source: backup).inspect()
            let converted = try LocalStorageMigration(source: ready).inspect()
            guard backed.format == .json, converted.format == .sqlite else { throw Failure.incompatible }
            try compare(original.documents, backed.documents)
            try compare(original.documents, converted.documents)
            guard originalFiles(original.files) == originalFiles(backed.files),
                  originalFiles(original.files) == originalFiles(converted.files),
                  original.files["documents.json"] == backed.files["documents.json"],
                  original.files["store.json"] == backed.files["store.json"] else { throw Failure.verification }
            let token = UUID().uuidString
            let pending = PendingActivation(prepared: prepared.resolvingSymlinksInPath().path,
                sourceHash: original.files["documents.json"]!, marker: try read(source.appendingPathComponent("store.json")),
                staging: ".sqlite-activation-" + token, archive: "activation-source-" + token)
            let archive = prepared.appendingPathComponent(pending.archive)
            guard mkdir(archive.path, S_IRWXU) == 0 else { throw Failure.unsafePath }
            try write(pending.marker, archive.appendingPathComponent("store.json"))
            try write(JSONEncoder().encode(pending), activationPending)
            try syncDirectory(source)
            do {
                let database = try SQLiteDocumentStore(directory: ready.appendingPathComponent("sqlite"), readOnly: true)
                let copied = try database.backup(toNewDirectory: source.appendingPathComponent(pending.staging))
                try compare(original.documents, copied.documents())
                try synchronizeTree(source.appendingPathComponent(pending.staging))
                try checkpoint("prepared")
                guard try inspect().token == original.token else { throw Failure.changed }
                guard renamex_np(source.appendingPathComponent(pending.staging).path,
                                 source.appendingPathComponent("sqlite").path, UInt32(RENAME_EXCL)) == 0 else { throw Failure.unsafePath }
                for name in ["documents.json", "documents.backup.json"] where original.files[name] != nil {
                    guard try fileHash(source.appendingPathComponent(name)) == original.files[name],
                          renamex_np(source.appendingPathComponent(name).path, archive.appendingPathComponent(name).path,
                                     UInt32(RENAME_EXCL)) == 0 else { throw Failure.changed }
                }
                try syncDirectory(archive)
                // Atomic marker replacement is the commit point. Pending blocks new readers
                // throughout; older v1-v3 writers reject format 4 rather than recreate JSON.
                try LocalDocumentStore(root: source).privateWrite(Data("{\"kind\":\"vauldy-local-core\",\"version\":4}".utf8),
                                                                to: source.appendingPathComponent("store.json"))
                try syncDirectory(source)
                try checkpoint("marker-published")
                let active = try SQLiteDocumentStore(directory: source.appendingPathComponent("sqlite"), readOnly: true)
                try active.validateForMigration()
                try compare(original.documents, active.documents())
                try verifyBackup(backup)
                let result = Activation(storage: "sqlite", vaultPath: source.appendingPathComponent("sqlite/records.sqlite").path,
                    backupPath: backup.path, documents: original.documents.count, verified: true, profilesChanged: false)
                try write(JSONEncoder().encode(result), archive.appendingPathComponent("activation-receipt.json"))
                try synchronizeTree(archive)
                try FileManager.default.removeItem(at: activationPending)
                try syncDirectory(source)
                return result
            } catch {
                let failure = error
                // If rollback itself fails, pending remains and all current access fails closed.
                _ = try rollbackActivation(pending)
                throw failure
            }
        }
    }

    /// Explicit recovery only. Never restores over later changes to either backend.
    public func recoverSQLiteActivation() throws -> Activation {
        try withFrozenSource(recoveringActivation: true) {
            let pending = try JSONDecoder().decode(PendingActivation.self, from: read(activationPending, limit: 16_384))
            return try rollbackActivation(pending)
        }
    }

    private func rollbackActivation(_ pending: PendingActivation) throws -> Activation {
        guard pending.version == 1, pending.staging.hasPrefix(".sqlite-activation-"),
              UUID(uuidString: String(pending.staging.dropFirst(".sqlite-activation-".count))) != nil,
              pending.archive.hasPrefix("activation-source-"),
              UUID(uuidString: String(pending.archive.dropFirst("activation-source-".count))) != nil else { throw Failure.verification }
        let prepared = URL(fileURLWithPath: pending.prepared), backup = prepared.appendingPathComponent("backup")
        try directory(prepared); try verifyBackup(backup)
        guard hash(try read(backup.appendingPathComponent("store.json"))) == hash(pending.marker),
              hash(try read(backup.appendingPathComponent("documents.json"))) == pending.sourceHash else { throw Failure.verification }
        let original = try LocalStorageMigration(source: backup).inspect()
        if try marker(source) == .sqlite {
            let active = try SQLiteDocumentStore(directory: source.appendingPathComponent("sqlite"), readOnly: true)
            try compare(original.documents, active.documents()) // Preserve unexpected later SQL edits.
        }
        for name in ["documents.json", "documents.backup.json"] where original.files[name] != nil {
            let url = source.appendingPathComponent(name)
            if exists(url) { guard try fileHash(url) == original.files[name] else { throw Failure.changed } }
            else { try write(read(backup.appendingPathComponent(name)), url) }
        }
        let archive = prepared.appendingPathComponent(pending.archive)
        try directory(archive)
        for name in ["sqlite", pending.staging] where exists(source.appendingPathComponent(name)) {
            try directory(source.appendingPathComponent(name))
            guard renamex_np(source.appendingPathComponent(name).path,
                             archive.appendingPathComponent("retained-sqlite-" + UUID().uuidString).path,
                             UInt32(RENAME_EXCL)) == 0 else { throw Failure.unsafePath }
        }
        try LocalDocumentStore(root: source).privateWrite(pending.marker, to: source.appendingPathComponent("store.json"))
        try compare(original.documents, inspect().documents)
        try syncDirectory(source); try syncDirectory(archive)
        try FileManager.default.removeItem(at: activationPending)
        try syncDirectory(source)
        return Activation(storage: "json-snapshot", vaultPath: source.appendingPathComponent("documents.json").path,
                          backupPath: backup.path, documents: original.documents.count, verified: true, profilesChanged: false)
    }
}
