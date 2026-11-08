import Foundation
import CryptoKit
import Darwin
import SQLite3

/// Local transactional record store. Selected only by explicitly created format-3 stores.
/// All operations must be serialized by the owner. No originals, profiles or credentials live here.
package protocol DocumentRecordStorage: AnyObject {
    func document(id: UUID) throws -> VaultDocument?
    func replace(_ document: VaultDocument, ifCurrent expected: VaultDocument?) throws
}

package final class SQLiteDocumentStore: DocumentRecordStorage {
    package enum Failure: Error { case sqlite, unsafePath, incompatible, conflict, corrupt, nonempty, tooLarge }
    private static let applicationID: Int32 = 0x56445031
    private static let maximumRecordBytes = 8 * 1_024 * 1_024
    private static let maximumProjectionBytes = 512
    private static let projectionSchema = """
        CREATE TABLE IF NOT EXISTS record_projection_v1(
            id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, digest BLOB NOT NULL
        ) WITHOUT ROWID;
        CREATE TRIGGER IF NOT EXISTS project_record_insert AFTER INSERT ON records
            BEGIN DELETE FROM record_projection_v1 WHERE id=new.id; END;
        CREATE TRIGGER IF NOT EXISTS project_record_update AFTER UPDATE ON records
            BEGIN DELETE FROM record_projection_v1 WHERE id=old.id OR id=new.id; END;
        CREATE TRIGGER IF NOT EXISTS project_record_delete AFTER DELETE ON records
            BEGIN DELETE FROM record_projection_v1 WHERE id=old.id; END;
        CREATE TRIGGER IF NOT EXISTS projection_insert AFTER INSERT ON record_projection_v1
            BEGIN UPDATE generation SET token=hex(randomblob(32)); END;
        CREATE TRIGGER IF NOT EXISTS projection_update AFTER UPDATE ON record_projection_v1
            BEGIN UPDATE generation SET token=hex(randomblob(32)); END;
        CREATE TRIGGER IF NOT EXISTS projection_delete AFTER DELETE ON record_projection_v1
            BEGIN UPDATE generation SET token=hex(randomblob(32)); END;
        """
    package struct Projection: Codable, Sendable {
        package let fingerprint: Data
        package let metadata: VaultIndexProjection
    }
    private final class Connection {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }
    private let connection: Connection
    private var database: OpaquePointer { connection.handle }
    package let directory: URL
    package var file: URL { directory.appendingPathComponent("records.sqlite") }

    package init(directory: URL, create: Bool = false, readOnly: Bool = false) throws {
        // Creation is exclusive; an existing directory is never initialized or migrated.
        if create {
            guard mkdir(directory.path, S_IRWXU) == 0 else { throw Failure.unsafePath }
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              let resolved = realpath(directory.path, nil) else { throw Failure.unsafePath }
        self.directory = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
        let file = self.directory.appendingPathComponent("records.sqlite")
        if create {
            let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw Failure.unsafePath }; close(fd)
        }
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        for suffix in ["-journal", "-wal", "-shm"] {
            let path = file.path + suffix
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                      info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
            } else if errno != ENOENT { throw Failure.unsafePath }
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }; throw Failure.sqlite
        }
        connection = Connection(handle)
        sqlite3_busy_timeout(database, 1_000)
        try execute("PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY; PRAGMA synchronous=FULL;")
        if create {
            try execute("""
                PRAGMA page_size=4096; PRAGMA journal_mode=DELETE; PRAGMA application_id=\(Self.applicationID); PRAGMA user_version=2;
                CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, digest BLOB NOT NULL,
                    content_hash TEXT, original_path TEXT, original_identity TEXT, import_state TEXT) WITHOUT ROWID;
                CREATE INDEX records_hash ON records(content_hash);
                CREATE INDEX records_path ON records(original_path);
                CREATE INDEX records_identity ON records(original_identity);
                CREATE INDEX records_state ON records(import_state);
                CREATE TABLE generation(singleton INTEGER PRIMARY KEY CHECK(singleton=1), token TEXT NOT NULL);
                INSERT INTO generation VALUES(1, hex(randomblob(32)));
                CREATE TRIGGER records_insert AFTER INSERT ON records BEGIN UPDATE generation SET token=hex(randomblob(32)); END;
                CREATE TRIGGER records_update AFTER UPDATE ON records BEGIN UPDATE generation SET token=hex(randomblob(32)); END;
                CREATE TRIGGER records_delete AFTER DELETE ON records BEGIN UPDATE generation SET token=hex(randomblob(32)); END;
                """)
            try execute(Self.projectionSchema)
            try execute(Self.searchSchema)
            try execute(Self.rankSchema)
        }
        guard try scalar("PRAGMA application_id") == Int(Self.applicationID),
              try scalar("PRAGMA user_version") == 2, try scalar("PRAGMA page_size") == 4096 else { throw Failure.incompatible }
        if !readOnly { try execute("PRAGMA max_page_count=262144") } // 1 GiB until R3d load acceptance.
        guard try scalar("SELECT count(*) FROM sqlite_schema WHERE type='trigger' AND name IN ('records_insert','records_update','records_delete')") == 3 else { throw Failure.incompatible }
        _ = try generation
    }

    package var count: Int { get throws { try scalar("SELECT count(*) FROM records") } }

    private var hasProjections: Bool { get throws {
        try scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='record_projection_v1'") == 1
    } }

    /// A missing projection for an existing granted row means a legacy writer was used.
    /// Fall back to the checked full record path rather than treating it as a missing document.
    package func projections(ids: Set<UUID>) throws -> [UUID: Projection]? {
        try execute("BEGIN")
        defer { try? execute("ROLLBACK") }
        guard try hasProjections else { return nil }
        let statement = try prepare("SELECT payload,digest FROM record_projection_v1 WHERE id=?")
        defer { sqlite3_finalize(statement) }
        let exists = try prepare("SELECT 1 FROM records WHERE id=?")
        defer { sqlite3_finalize(exists) }
        let decoder = JSONDecoder()
        var rows: [UUID: Projection] = [:]
        for id in ids {
            try Task.checkCancellation()
            sqlite3_reset(statement)
            try bind(id.uuidString, to: statement, at: 1)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let bytes = try verifiedBytes(statement, payload: 0, digest: 1, limit: Self.maximumProjectionBytes)
                let row = try decoder.decode(Projection.self, from: bytes)
                guard row.metadata.isValid, row.fingerprint.count == 32 else { throw Failure.corrupt }
                rows[id] = row
            case SQLITE_DONE:
                sqlite3_reset(exists)
                try bind(id.uuidString, to: exists, at: 1)
                switch sqlite3_step(exists) {
                case SQLITE_ROW: return nil
                case SQLITE_DONE: break
                default: throw Failure.sqlite
                }
            default: throw Failure.sqlite
            }
        }
        return rows
    }

    /// Explicit backfill. Keep the source payloads intact and publish the complete projection
    /// set in one transaction. At most one decoded document is needed at a time.
    package func rebuildProjections() throws {
        try transaction {
            try execute(Self.projectionSchema)
            try execute(Self.searchSchema)
            try execute(Self.rankSchema)
            try execute("DELETE FROM record_projection_v1; DELETE FROM search_terms_v1; DELETE FROM search_indexed_v1; DELETE FROM rank_projection_v1")
            let statement = try prepare("SELECT id,payload,digest FROM records")
            defer { sqlite3_finalize(statement) }
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw Failure.sqlite }
                let document = try decode(statement, payload: 1, digest: 2)
                guard let id = sqlite3_column_text(statement, 0),
                      String(cString: id) == document.id.uuidString else { throw Failure.corrupt }
                try writeProjection(document)
                try writeSearchIndex(document)
            }
        }
    }

    package func document(id: UUID) throws -> VaultDocument? {
        let statement = try prepare("SELECT payload,digest FROM records WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw Failure.sqlite }
        let document = try decode(statement, payload: 0, digest: 1)
        guard document.id == id else { throw Failure.corrupt }
        return document
    }

    /// Random commit token is changed by SQL triggers in the same transaction as every row mutation.
    /// This also detects writers using SQL directly, and works with rollback journals or WAL.
    package var generation: String { get throws {
        let statement = try prepare("SELECT token FROM generation WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw Failure.corrupt }
        let token = String(cString: text)
        guard token.count == 64, token.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { throw Failure.corrupt }
        return token
    } }

    package func documents(ids: Set<UUID>? = nil) throws -> [VaultDocument] {
        try execute("BEGIN")
        do {
            let result: [VaultDocument]
            if let ids { result = try ids.sorted { $0.uuidString < $1.uuidString }.compactMap { try document(id: $0) } }
            else { result = try select("SELECT id,payload,digest FROM records ORDER BY id") }
            try execute("COMMIT"); return result
        } catch { try? execute("ROLLBACK"); throw error }
    }

    package func importCandidates(hash: String, reference: LocalOriginalReference?) throws -> [VaultDocument] {
        try select("SELECT id,payload,digest FROM records WHERE content_hash=? OR original_path=? OR original_identity=? ORDER BY id",
                   values: [hash, reference?.lastKnownPath ?? "<none>", reference?.identity ?? "<none>"])
    }

    package func recognizingDocuments() throws -> [VaultDocument] {
        try select("SELECT id,payload,digest FROM records WHERE import_state=? ORDER BY id", values: ["recognizing"])
    }

    /// The LocalDocumentStore writer lease serializes read/modify/write across processes.
    /// Only changed rows are written; untouched payloads and IDs stay byte-for-byte intact.
    package func save(_ documents: [VaultDocument]) throws {
        try transaction {
            for value in documents {
                let prior = try document(id: value.id)
                if prior != value { try insert(value, replacing: prior != nil) }
            }
            guard try count <= VaultStorageLimits.importedDocuments else { throw LocalStoreCapacityError.documentCount }
        }
    }
    package func validate(_ document: VaultDocument) throws { _ = try encode(document) }

    private func select(_ sql: String, values: [String] = []) throws -> [VaultDocument] {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, to: statement, at: Int32(index + 1)) }
        var documents: [VaultDocument] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return documents }
            guard result == SQLITE_ROW else { throw Failure.sqlite }
            let value = try decode(statement, payload: 1, digest: 2)
            guard let id = sqlite3_column_text(statement, 0), String(cString: id) == value.id.uuidString else { throw Failure.corrupt }
            documents.append(value)
        }
    }

    /// Reject unknown payload fields before a typed migration could silently discard them.
    package func validateForMigration() throws {
        let statement = try prepare("SELECT payload,digest FROM records")
        defer { sqlite3_finalize(statement) }
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw Failure.sqlite }
            let value = try decode(statement, payload: 0, digest: 1)
            guard let pointer = sqlite3_column_blob(statement, 0) else { throw Failure.corrupt }
            let bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            try LocalStorageMigration.requirePreservedJSON(bytes, encode(value))
        }
    }

    /// Compare-and-swap prevents stale analysis from overwriting another committed version.
    package func replace(_ document: VaultDocument, ifCurrent expected: VaultDocument?) throws {
        try transaction {
            let current = try self.document(id: document.id)
            guard current == expected else { throw Failure.conflict }
            try insert(document, replacing: current != nil)
        }
    }

    /// Explicit additive import into an EMPTY pilot. Original JSON and its backup are never written.
    /// Any malformed or duplicate record rolls back the whole import, including already visited rows.
    package func importJSON(_ source: FileVaultSnapshotSource) throws {
        try transaction {
            guard try count == 0 else { throw Failure.nonempty }
            try source.visitDocuments { try insert($0, replacing: false) }
        }
    }

    /// SQLite's online backup includes only a consistent committed state. Restore uses this same
    /// operation into a NEW directory; no in-place rollback over a live store is exposed.
    package func backup(toNewDirectory destination: URL) throws -> SQLiteDocumentStore {
        // Keep the destination connection in a separate scope so ALL SQLite handles are closed
        // before cleaning a residual SHM file in this exclusively created, unpublished directory.
        func copyBackup() throws {
            let target = try SQLiteDocumentStore(directory: destination, create: true)
            guard let backup = sqlite3_backup_init(target.database, "main", database, "main") else { throw Failure.sqlite }
            let result = sqlite3_backup_step(backup, -1)
            let finished = sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE, finished == SQLITE_OK else { throw Failure.sqlite }
            try target.execute("PRAGMA journal_mode=DELETE")
        }
        try copyBackup()
        let file = destination.appendingPathComponent("records.sqlite")
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let header = try handle.read(upToCount: 32) ?? Data()
        guard header.count == 32, header[18] == 1, header[19] == 1,
              !FileManager.default.fileExists(atPath: file.path + "-wal"),
              !FileManager.default.fileExists(atPath: file.path + "-journal") else { throw Failure.sqlite }
        let shm = file.path + "-shm"
        var info = stat()
        if lstat(shm, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & 0o077 == 0, unlink(shm) == 0 else { throw Failure.unsafePath }
        } else if errno != ENOENT { throw Failure.unsafePath }
        return try SQLiteDocumentStore(directory: destination)
    }

    /// Export is explicit and refuses an existing destination. Legacy 128 MiB readers remain safe.
    package func exportJSON(toNewFile destination: URL) throws {
        let staging = directory.appendingPathComponent(".export-" + UUID().uuidString)
        let fd = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: staging) }
        let statement = try prepare("SELECT id,payload,digest FROM records ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var bytes = 2, first = true
        try handle.write(contentsOf: Data("[".utf8))
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Failure.sqlite }
            let document = try decode(statement, payload: 1, digest: 2)
            guard let id = sqlite3_column_text(statement, 0), String(cString: id) == document.id.uuidString else { throw Failure.corrupt }
            let payload = try encode(document)
            bytes += payload.count + (first ? 0 : 1)
            guard bytes <= VaultStorageLimits.snapshotBytes else { throw Failure.tooLarge }
            if !first { try handle.write(contentsOf: Data(",".utf8)) }; first = false
            try handle.write(contentsOf: payload)
        }
        try handle.write(contentsOf: Data("]".utf8)); try handle.synchronize(); try handle.close()
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private func insert(_ document: VaultDocument, replacing: Bool) throws {
        let payload = try encode(document), digest = Data(SHA256.hash(data: payload))
        let statement = try prepare(replacing
            ? "UPDATE records SET payload=?,digest=?,content_hash=?,original_path=?,original_identity=?,import_state=? WHERE id=?"
            : "INSERT INTO records(payload,digest,content_hash,original_path,original_identity,import_state,id) VALUES(?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(payload, to: statement, at: 1); try bind(digest, to: statement, at: 2)
        try bind(document.localImport?.contentHash ?? "", to: statement, at: 3)
        try bind(document.localImport?.originalReference?.lastKnownPath ?? "", to: statement, at: 4)
        try bind(document.localImport?.originalReference?.identity ?? "", to: statement, at: 5)
        try bind(document.localImport?.state.rawValue ?? "", to: statement, at: 6)
        try bind(document.id.uuidString, to: statement, at: 7)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.sqlite }
        if try hasProjections {
            // Use the persisted representation so Date rounding cannot break a later handle.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode(VaultDocument.self, from: payload)
            try writeProjection(persisted)
            if try hasSearchIndex { try writeSearchIndex(persisted) }
        }
    }

    package static func documentFingerprint(_ document: VaultDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(document)))
    }

    private func writeProjection(_ document: VaultDocument) throws {
        let row = Projection(fingerprint: try Self.documentFingerprint(document),
                             metadata: VaultSourceState(document).projection(for: document))
        let bytes = try JSONEncoder().encode(row)
        guard bytes.count <= Self.maximumProjectionBytes else { throw Failure.tooLarge }
        let statement = try prepare("INSERT INTO record_projection_v1(id,payload,digest) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(document.id.uuidString, to: statement, at: 1)
        try bind(bytes, to: statement, at: 2)
        try bind(Data(SHA256.hash(data: bytes)), to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.sqlite }
    }
    private func encode(_ document: VaultDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumRecordBytes else { throw Failure.tooLarge }; return data
    }
    private func decode(_ statement: OpaquePointer, payload: Int32, digest: Int32) throws -> VaultDocument {
        let bytes = try verifiedBytes(statement, payload: payload, digest: digest, limit: Self.maximumRecordBytes)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VaultDocument.self, from: bytes)
    }

    private func verifiedBytes(_ statement: OpaquePointer, payload: Int32, digest: Int32, limit: Int) throws -> Data {
        let size = Int(sqlite3_column_bytes(statement, payload))
        guard size > 0, size <= limit, sqlite3_column_bytes(statement, digest) == 32,
              let data = sqlite3_column_blob(statement, payload), let hash = sqlite3_column_blob(statement, digest) else { throw Failure.corrupt }
        let bytes = Data(bytes: data, count: size)
        guard Data(SHA256.hash(data: bytes)) == Data(bytes: hash, count: 32) else { throw Failure.corrupt }
        return bytes
    }
    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.sqlite }; return statement
    }
    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.sqlite }; return Int(sqlite3_column_int64(statement, 0))
    }
    private func bind(_ data: Data, to statement: OpaquePointer, at position: Int32) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK else { throw Failure.sqlite }
    }
    private func bind(_ value: String, to statement: OpaquePointer, at position: Int32) throws {
        guard sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw Failure.sqlite }
    }
}

// Source compatibility for the isolated R3 pilot tests; no on-disk v1 conversion.
package typealias SQLiteDocumentStorePilot = SQLiteDocumentStore

extension SQLiteDocumentStore {
    package enum SearchPredicate {
        case exact([String])
        case substring([String])
        case ranked([String])
    }

    private static let searchSchema = """
        CREATE TABLE IF NOT EXISTS search_terms_v1(
            kind INTEGER NOT NULL, term TEXT NOT NULL, doc INTEGER NOT NULL,
            PRIMARY KEY(kind,term,doc)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS search_terms_by_id_v1 ON search_terms_v1(doc);
        CREATE TABLE IF NOT EXISTS search_indexed_v1(id TEXT PRIMARY KEY NOT NULL);
        CREATE TRIGGER IF NOT EXISTS invalidate_search_insert AFTER INSERT ON records BEGIN
            DELETE FROM search_terms_v1 WHERE doc=(SELECT rowid FROM search_indexed_v1 WHERE id=new.id);
            DELETE FROM search_indexed_v1 WHERE id=new.id;
        END;
        CREATE TRIGGER IF NOT EXISTS invalidate_search_update AFTER UPDATE ON records BEGIN
            DELETE FROM search_terms_v1 WHERE doc IN (SELECT rowid FROM search_indexed_v1 WHERE id=old.id OR id=new.id);
            DELETE FROM search_indexed_v1 WHERE id=old.id OR id=new.id;
        END;
        CREATE TRIGGER IF NOT EXISTS invalidate_search_delete AFTER DELETE ON records BEGIN
            DELETE FROM search_terms_v1 WHERE doc=(SELECT rowid FROM search_indexed_v1 WHERE id=old.id);
            DELETE FROM search_indexed_v1 WHERE id=old.id;
        END;
        """

    private var hasSearchIndex: Bool {
        get throws { try scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='search_indexed_v1'") == 1 }
    }

    private func writeSearchIndex(_ document: VaultDocument) throws {
        // Leave room under the record-store page limit. Oversize and unindexed rows
        // stay eligible through the checked document path.
        let pages = try scalar("PRAGMA page_count") - scalar("PRAGMA freelist_count")
        guard pages < 229_376, document.ocrText.utf8.count <= 512 * 1024 else { return }
        var vocabulary: [Data: VaultSearchVocabulary] = [:]
        func terms(_ field: String) -> VaultSearchVocabulary {
            let bytes = Data(field.utf8)
            if let existing = vocabulary[bytes] { return existing }
            let result = VaultSearchVocabulary(field)
            vocabulary[bytes] = result
            return result
        }

        var exact: Set<String> = [], substrings: Set<String> = [], ranked: Set<String> = []
        for field in VaultDocumentFilter.searchableFields(document) {
            let fieldTerms = terms(field)
            exact.formUnion(fieldTerms.words)
            substrings.formUnion(fieldTerms.foldedChunks)
            substrings.formUnion(fieldTerms.normalizedChunks)
        }
        let rankFields = LocalVault.rankedSearchFields(document).map { field, weight in
            let fieldTerms = terms(field)
            ranked.formUnion(fieldTerms.words)
            ranked.formUnion(fieldTerms.normalizedChunks)
            return VaultRankProjection.Field(weight: weight, counts: fieldTerms.counts,
                                             normalizedChunks: fieldTerms.normalizedChunks)
        }
        let keys = [Set(exact.map(\.precomposedStringWithCanonicalMapping)), substrings, ranked]
        guard keys.reduce(0, { $0 + $1.count }) <= 4_096,
              keys.reduce(0, { $0 + $1.reduce(0, { $0 + $1.utf8.count }) }) <= 96 * 1024,
              keys.allSatisfy({ !$0.contains(where: { $0.utf8.contains(0) }) }) else { return }
        let ready = try prepare("INSERT INTO search_indexed_v1(id) VALUES(?)")
        defer { sqlite3_finalize(ready) }
        try bind(document.id.uuidString, to: ready, at: 1)
        guard sqlite3_step(ready) == SQLITE_DONE else { throw Failure.sqlite }

        let insert = try prepare("INSERT INTO search_terms_v1(kind,term,doc) VALUES(?,?,?)")
        defer { sqlite3_finalize(insert) }
        guard sqlite3_bind_int64(insert, 3, sqlite3_last_insert_rowid(database)) == SQLITE_OK else {
            throw Failure.sqlite
        }
        for (kind, terms) in keys.enumerated() {
            guard sqlite3_bind_int(insert, 1, Int32(kind)) == SQLITE_OK else { throw Failure.sqlite }
            for term in terms {
                try Task.checkCancellation()
                try bind(term, to: insert, at: 2)
                guard sqlite3_step(insert) == SQLITE_DONE, sqlite3_reset(insert) == SQLITE_OK else { throw Failure.sqlite }
            }
        }
        try writeRankProjection(document, fields: rankFields)
    }

    private static let rankSchema = """
        CREATE TABLE IF NOT EXISTS rank_projection_v1(
            id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, digest BLOB NOT NULL
        ) WITHOUT ROWID;
        CREATE TRIGGER IF NOT EXISTS invalidate_rank_insert AFTER INSERT ON records BEGIN
            DELETE FROM rank_projection_v1 WHERE id=new.id;
        END;
        CREATE TRIGGER IF NOT EXISTS invalidate_rank_update AFTER UPDATE ON records BEGIN
            DELETE FROM rank_projection_v1 WHERE id=old.id OR id=new.id;
        END;
        CREATE TRIGGER IF NOT EXISTS invalidate_rank_delete AFTER DELETE ON records BEGIN
            DELETE FROM rank_projection_v1 WHERE id=old.id;
        END;
        """

    private var hasRankProjection: Bool {
        get throws { try scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='rank_projection_v1'") == 1 }
    }

    private static let maximumRankProjectionBytes = 16 * 1024

    private func writeRankProjection(_ document: VaultDocument, fields: [VaultRankProjection.Field]) throws {
        guard try hasRankProjection else { return }
        let projection = VaultRankProjection(importedAt: document.importedAt, searchable: document.isSearchable, fields: fields)
        let bytes = try JSONEncoder().encode(projection)
        guard bytes.count <= Self.maximumRankProjectionBytes else { return }
        let statement = try prepare("INSERT INTO rank_projection_v1(id,payload,digest) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(document.id.uuidString, to: statement, at: 1)
        try bind(bytes, to: statement, at: 2)
        try bind(Data(SHA256.hash(data: bytes)), to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.sqlite }
    }

    package func rankScores(ids: [UUID], term: String)
        throws -> (scores: [VaultRankScore], uncovered: [UUID]) {
        try execute("BEGIN")
        defer { try? execute("ROLLBACK") }
        guard try hasRankProjection else { return ([], ids) }
        let statement = try prepare("SELECT payload,digest FROM rank_projection_v1 WHERE id=?")
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        var scores: [VaultRankScore] = [], uncovered: [UUID] = []
        for id in ids {
            try Task.checkCancellation()
            sqlite3_reset(statement)
            try bind(id.uuidString, to: statement, at: 1)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let bytes = try verifiedBytes(statement, payload: 0, digest: 1, limit: Self.maximumRankProjectionBytes)
                let row = try decoder.decode(VaultRankProjection.self, from: bytes)
                guard row.isValid else { throw Failure.corrupt }
                if row.searchable {
                    let score = row.score(term: term)
                    if score > 0 { scores.append(.init(id: id, score: score, date: row.importedAt)) }
                }
            case SQLITE_DONE: uncovered.append(id)
            default: throw Failure.sqlite
            }
        }
        return (scores, uncovered)
    }

    /// All returned IDs are intersected with the current selection before leaving storage.
    /// Exact and substring predicates are complete for indexed rows. Ranked predicates
    /// deliberately return a superset to be scored against the source.
    package func searchSelection(_ predicate: SearchPredicate, allowed: Set<UUID>)
        throws -> (matches: Set<UUID>, uncovered: Set<UUID>)? {
        try execute("BEGIN")
        defer { try? execute("ROLLBACK") }
        guard try hasSearchIndex else { return nil }
        let covered = try prepare("SELECT id FROM search_indexed_v1")
        defer { sqlite3_finalize(covered) }
        var uncovered = allowed
        try visitIDs(covered) { uncovered.remove($0) }
        var matches: Set<UUID> = []
        switch predicate {
        case .exact(let terms):
            for (offset, term) in terms.enumerated() {
                let ids = try postingIDs(kind: 0, term: term.precomposedStringWithCanonicalMapping, allowed: allowed)
                if offset == 0 { matches = ids } else { matches.formIntersection(ids) }
                if matches.isEmpty { break }
            }
        case .substring(let terms):
            matches = try substringIDs(kind: 1, terms: terms, allowed: allowed)
        case .ranked(let terms):
            matches = try substringIDs(kind: 2, terms: terms, allowed: allowed)
        }
        matches.subtract(uncovered)
        return (matches, uncovered)
    }

    private func substringIDs(kind: Int32, terms: [String], allowed: Set<UUID>) throws -> Set<UUID> {
        guard !terms.isEmpty else { return [] }
        let vocabulary = try prepare("SELECT DISTINCT term FROM search_terms_v1 WHERE kind=?")
        defer { sqlite3_finalize(vocabulary) }
        guard sqlite3_bind_int(vocabulary, 1, kind) == SQLITE_OK else { throw Failure.sqlite }
        var matches: Set<UUID> = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(vocabulary)
            if result == SQLITE_DONE { return matches }
            guard result == SQLITE_ROW, let value = sqlite3_column_text(vocabulary, 0) else { throw Failure.corrupt }
            let term = String(cString: value)
            if terms.contains(where: { term.contains($0) }) {
                matches.formUnion(try postingIDs(kind: kind, term: term, allowed: allowed))
                if matches.count == allowed.count { return matches }
            }
        }
    }

    private func postingIDs(kind: Int32, term: String, allowed: Set<UUID>) throws -> Set<UUID> {
        let posting = try prepare("SELECT i.id FROM search_terms_v1 t JOIN search_indexed_v1 i ON i.rowid=t.doc WHERE t.kind=? AND t.term=?")
        defer { sqlite3_finalize(posting) }
        guard sqlite3_bind_int(posting, 1, kind) == SQLITE_OK else { throw Failure.sqlite }
        try bind(term, to: posting, at: 2)
        var result: Set<UUID> = []
        try visitIDs(posting) { if allowed.contains($0) { result.insert($0) } }
        return result
    }

    private func visitIDs(_ statement: OpaquePointer, _ visit: (UUID) -> Void) throws {
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: value)) else { throw Failure.corrupt }
            visit(id)
        }
    }
}
