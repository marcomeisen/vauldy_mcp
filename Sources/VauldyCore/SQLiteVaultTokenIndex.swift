import Foundation
import SQLite3

/// Derived FTS5 state. Owned by one runtime actor and never written to the vault or disk.
package final class SQLiteVaultTokenIndex {
    private enum IndexError: Error { case sqlite, tokenTooLarge, duplicateID }
    private struct Entry {
        let rowID: Int64
        let fingerprint: Data
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    private let database: OpaquePointer
    private var entries: [UUID: Entry] = [:]
    private var nextRowID: Int64 = 1

    package init() throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw IndexError.sqlite
        }
        let schema = """
            PRAGMA temp_store = MEMORY;
            PRAGMA page_size = 4096;
            PRAGMA max_page_count = 8192;
            CREATE VIRTUAL TABLE tokens USING fts5(body, tokenize='ascii', detail=none, columnsize=0);
            """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw IndexError.sqlite
        }
        database = connection
    }

    deinit { sqlite3_close(database) }

    /// Apply only added, edited and removed records. The Swift mirror changes after SQL commits.
    @discardableResult
    package func reconcile(_ records: [(document: VaultDocument, fingerprint: Data)]) throws -> Int {
        let retained = Set(records.map { $0.document.id })
        guard retained.count == records.count else { throw IndexError.duplicateID }
        var next = entries
        var rowID = nextRowID
        var changes = 0
        let remove = try prepare("DELETE FROM tokens WHERE rowid = ?")
        defer { sqlite3_finalize(remove) }
        let insert = try prepare("INSERT INTO tokens(rowid, body) VALUES (?, ?)")
        defer { sqlite3_finalize(insert) }
        try execute("BEGIN")
        do {
            for (id, entry) in entries where !retained.contains(id) {
                try Task.checkCancellation()
                try delete(row: entry.rowID, statement: remove)
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
                } else {
                    row = rowID
                    rowID += 1
                }
                let tokens = try VaultDocumentFilter.wholeTokens(in: document).map(Self.sqliteToken).joined(separator: " ")
                try check(sqlite3_bind_int64(insert, 1, row))
                try bind(tokens, to: insert, at: 2)
                try finish(insert)
                next[document.id] = Entry(rowID: row, fingerprint: fingerprint)
                changes += 1
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        entries = next
        nextRowID = rowID
        return changes
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
        let bytes = term.precomposedStringWithCanonicalMapping.utf8
        guard bytes.count <= 4_096 else { throw IndexError.tokenTooLarge }
        var encoded: [UInt8] = [116] // Alphabetic prefix keeps every token unambiguous in MATCH.
        encoded.reserveCapacity(1 + 2 * bytes.count)
        for byte in bytes {
            encoded.append(hexDigits[Int(byte >> 4)])
            encoded.append(hexDigits[Int(byte & 15)])
        }
        return String(decoding: encoded, as: UTF8.self)
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
