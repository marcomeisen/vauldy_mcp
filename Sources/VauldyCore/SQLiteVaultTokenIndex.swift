import Foundation
import CryptoKit
import SQLite3

/// Derived FTS5 state. The owner serializes disk access and provides the authoritative fingerprints.
package final class SQLiteVaultTokenIndex {
    private enum IndexError: Error { case sqlite, tokenTooLarge, duplicateID }
    private struct Entry {
        let rowID: Int64
        let fingerprint: Data
        let projection: VaultIndexProjection?
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    private final class Connection {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }
    private let connection: Connection
    private var database: OpaquePointer { connection.handle }
    private var entries: [UUID: Entry] = [:]
    private var nextRowID: Int64 = 1

    private static let schemaVersion: Int64 = 1
    private static let applicationID: Int64 = 0x564D4350
    private static let schema = """
        PRAGMA page_size = 4096;
        PRAGMA application_id = 1447904080;
        PRAGMA user_version = 1;
        CREATE VIRTUAL TABLE tokens USING fts5(body, tokenize='ascii', detail=none, columnsize=0);
        CREATE TABLE inventory(rowid INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
                               fingerprint TEXT NOT NULL, projection TEXT, payload_digest TEXT NOT NULL);
        CREATE TABLE state(singleton INTEGER PRIMARY KEY CHECK(singleton = 1), scope TEXT NOT NULL,
                           generation TEXT NOT NULL);
        """

    package init(file: URL? = nil, scope: String? = nil, create: Bool = true, validate: Bool = true) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(file?.path ?? ":memory:", &connection, flags, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw IndexError.sqlite
        }
        let configuration = """
            PRAGMA temp_store = MEMORY;
            PRAGMA trusted_schema = OFF;
            PRAGMA synchronous = FULL;
            PRAGMA secure_delete = ON;
            """
        guard sqlite3_exec(connection, configuration, nil, nil, nil) == SQLITE_OK,
              !create || sqlite3_exec(connection, Self.schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw IndexError.sqlite
        }
        self.connection = Connection(connection)
        try execute(file == nil ? "PRAGMA max_page_count = 8192" : "PRAGMA max_page_count = 16384")
        if let scope {
            if create {
                let statement = try prepare("INSERT INTO state VALUES (1, ?, '')")
                defer { sqlite3_finalize(statement) }
                try bind(scope, to: statement, at: 1)
                try finish(statement)
            } else {
                try load(scope: scope, validate: validate)
            }
        }
    }

    /// Apply only added, edited and removed records. The Swift mirror changes after SQL commits.
    @discardableResult
    package func reconcile(_ records: [(document: VaultDocument, fingerprint: Data)],
                           generation: Data? = nil,
                           project: ((VaultDocument) -> VaultIndexProjection)? = nil) throws -> Int {
        let retained = Set(records.map { $0.document.id })
        guard retained.count == records.count else { throw IndexError.duplicateID }
        var next = entries
        var rowID = nextRowID
        var changes = 0
        let remove = try prepare("DELETE FROM tokens WHERE rowid = ?")
        defer { sqlite3_finalize(remove) }
        let insert = try prepare("INSERT INTO tokens(rowid, body) VALUES (?, ?)")
        defer { sqlite3_finalize(insert) }
        let removeInventory = try prepare("DELETE FROM inventory WHERE rowid = ?")
        defer { sqlite3_finalize(removeInventory) }
        let insertInventory = try prepare("INSERT INTO inventory(rowid, id, fingerprint, projection, payload_digest) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(insertInventory) }
        let nextGeneration = generation?.base64EncodedString()
        if nextGeneration != nil, storedGeneration == nextGeneration, entries.count == records.count,
           records.allSatisfy({ entries[$0.document.id]?.fingerprint == $0.fingerprint }) { return 0 }
        try execute("BEGIN IMMEDIATE")
        do {
            for (id, entry) in entries where !retained.contains(id) {
                try Task.checkCancellation()
                try delete(row: entry.rowID, statement: remove)
                try delete(row: entry.rowID, statement: removeInventory)
                next.removeValue(forKey: id)
                changes += 1
            }
            for (document, fingerprint) in records {
                try Task.checkCancellation()
                let existing = entries[document.id]
                if existing?.fingerprint == fingerprint { continue }
                let row: Int64
                if let existing {
                    row = existing.rowID
                    try delete(row: row, statement: remove)
                    try delete(row: row, statement: removeInventory)
                } else {
                    row = rowID
                    rowID += 1
                }
                let tokens = try VaultDocumentFilter.wholeTokens(in: document).map(Self.sqliteToken).joined(separator: " ")
                try check(sqlite3_bind_int64(insert, 1, row))
                try bind(tokens, to: insert, at: 2)
                try finish(insert)
                let projection = project?(document)
                try check(sqlite3_bind_int64(insertInventory, 1, row))
                try bind(document.id.uuidString, to: insertInventory, at: 2)
                try bind(fingerprint.base64EncodedString(), to: insertInventory, at: 3)
                let encoded = try projection.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                if let encoded {
                    try bind(encoded, to: insertInventory, at: 4)
                } else {
                    try check(sqlite3_bind_null(insertInventory, 4))
                }
                try bind(Self.payloadDigest(tokens, encoded ?? ""), to: insertInventory, at: 5)
                try finish(insertInventory)
                next[document.id] = Entry(rowID: row, fingerprint: fingerprint, projection: projection)
                changes += 1
            }
            if let nextGeneration {
                let statement = try prepare("UPDATE state SET generation = ? WHERE singleton = 1")
                defer { sqlite3_finalize(statement) }
                try bind(nextGeneration, to: statement, at: 1)
                try finish(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        entries = next
        nextRowID = rowID
        storedGeneration = nextGeneration
        return changes
    }

    private var storedGeneration: String?

    package var projections: [UUID: VaultIndexProjection] {
        entries.compactMapValues(\.projection)
    }

    private func load(scope: String, validate: Bool) throws {
        if validate {
            guard try scalarText("PRAGMA journal_mode") == "delete",
                  try scalarInteger("PRAGMA application_id") == Self.applicationID,
                  try scalarInteger("PRAGMA user_version") == Self.schemaVersion,
                  try scalarText("PRAGMA quick_check") == "ok" else { throw IndexError.sqlite }
            try execute("INSERT INTO tokens(tokens) VALUES ('integrity-check')")
        }
        let state = try prepare("SELECT scope, generation FROM state WHERE singleton = 1")
        defer { sqlite3_finalize(state) }
        guard sqlite3_step(state) == SQLITE_ROW, text(state, 0) == scope,
              let generation = text(state, 1), Data(base64Encoded: generation)?.count == 32,
              sqlite3_step(state) == SQLITE_DONE else { throw IndexError.sqlite }
        let sql = validate
            ? "SELECT inventory.rowid, id, fingerprint, projection, payload_digest, tokens.body FROM inventory JOIN tokens ON tokens.rowid = inventory.rowid"
            : "SELECT rowid, id, fingerprint, projection, payload_digest, NULL FROM inventory"
        let inventory = try prepare(sql)
        defer { sqlite3_finalize(inventory) }
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(inventory)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, entries.count < 20_000,
                  let id = text(inventory, 1).flatMap(UUID.init(uuidString:)), entries[id] == nil,
                  let fingerprint = text(inventory, 2).flatMap({ Data(base64Encoded: $0) }), fingerprint.count == 32,
                  let encoded = text(inventory, 3), encoded.utf8.count <= 512,
                  let projection = try? JSONDecoder().decode(VaultIndexProjection.self, from: Data(encoded.utf8)),
                  projection.isValid else { throw IndexError.sqlite }
            if validate {
                guard let tokens = text(inventory, 5), text(inventory, 4) == Self.payloadDigest(tokens, encoded)
                else { throw IndexError.sqlite }
            }
            let row = sqlite3_column_int64(inventory, 0)
            guard row > 0, row < Int64.max - 20_000 else { throw IndexError.sqlite }
            entries[id] = Entry(rowID: row, fingerprint: fingerprint, projection: projection)
            nextRowID = max(nextRowID, row + 1)
        }
        if validate {
            guard try scalarInteger("SELECT count(*) FROM tokens") == entries.count,
                  try scalarInteger("SELECT count(*) FROM inventory") == entries.count else { throw IndexError.sqlite }
            var hash = SHA256()
            for id in entries.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let entry = entries[id] else { throw IndexError.sqlite }
                hash.update(data: entry.fingerprint)
            }
            guard Data(hash.finalize()).base64EncodedString() == generation else { throw IndexError.sqlite }
        }
        storedGeneration = generation
    }

    private func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw IndexError.sqlite }
        return text(statement, 0)
    }

    private func scalarInteger(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw IndexError.sqlite }
        return sqlite3_column_int64(statement, 0)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    package func matchingIDs(for query: String) throws -> Set<UUID> {
        let requested = Set(VaultDocumentFilter.tokens(query))
        guard !requested.isEmpty else { return [] }
        let expression = try requested.map(Self.sqliteToken).sorted().joined(separator: " AND ")
        let statement = try prepare("SELECT rowid FROM tokens WHERE tokens MATCH ?")
        defer { sqlite3_finalize(statement) }
        try bind(expression, to: statement, at: 1)
        var rows: Set<Int64> = []
        while true {
            try Task.checkCancellation()
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.insert(sqlite3_column_int64(statement, 0))
            case SQLITE_DONE: return Set(entries.compactMap { rows.contains($0.value.rowID) ? $0.key : nil })
            default: throw IndexError.sqlite
            }
        }
    }

    /// Encode Swift's canonical token equality independently of SQLite's Unicode segmentation.
    private static func sqliteToken(_ term: String) throws -> String {
        let normalized = term.precomposedStringWithCanonicalMapping.utf8
        guard normalized.count <= 4_096 else { throw IndexError.tokenTooLarge }
        let bytes = SHA256.hash(data: Data(normalized))
        var encoded: [UInt8] = [116] // Alphabetic prefix keeps every token unambiguous in MATCH.
        encoded.reserveCapacity(33)
        for byte in bytes.prefix(16) {
            encoded.append(hexDigits[Int(byte >> 4)])
            encoded.append(hexDigits[Int(byte & 15)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func payloadDigest(_ body: String, _ projection: String) -> String {
        var hash = SHA256()
        hash.update(data: Data(body.utf8))
        hash.update(data: Data([0]))
        hash.update(data: Data(projection.utf8))
        return Data(hash.finalize()).base64EncodedString()
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        guard let statement else { throw IndexError.sqlite }
        return statement
    }

    private func bind(_ text: String, to statement: OpaquePointer, at position: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(sqlite3_bind_text(statement, position, text, -1, transient))
    }

    private func delete(row: Int64, statement: OpaquePointer) throws {
        try check(sqlite3_bind_int64(statement, 1, row))
        try finish(statement)
    }

    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw IndexError.sqlite }
        try check(sqlite3_reset(statement))
    }

    private func check(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw IndexError.sqlite }
    }
}


/// Compact state only. These values never contain document text, local paths or privacy mappings.
package struct VaultIndexProjection: Codable, Equatable, Sendable {
    package let processingStatus: String
    package let sourceCoverage: String
    package let analysisStatus: String
    package let searchable: Bool

    package init(processingStatus: String, sourceCoverage: String, analysisStatus: String, searchable: Bool) {
        self.processingStatus = processingStatus
        self.sourceCoverage = sourceCoverage
        self.analysisStatus = analysisStatus
        self.searchable = searchable
    }

    var isValid: Bool {
        ["source-ready", "pending", "failed", "needs-review", "unknown"].contains(processingStatus)
        && ["original-changed-stored-ocr-is-historical", "original-unavailable-stored-ocr-retained",
            "all-declared-pages-have-ocr-text", "all-declared-pages-processed", "incomplete-or-unknown"].contains(sourceCoverage)
        && ["completed", "needsReview", "failed", "stale", "unavailable", "not-analyzed"].contains(analysisStatus)
    }
}
