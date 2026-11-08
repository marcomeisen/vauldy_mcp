import Foundation
import Darwin
import Testing
@testable import VauldyCore

@Suite("R3 explicit SQLite record store pilot")
struct SQLiteDocumentStorePilotTests {
    @Test func legacyImportPointUpdatesRestartBackupAndRestore() throws {
        try withPilotFixture { root in
            let json = root.appendingPathComponent("documents.json")
            let original = (0..<100).map { VaultDocument(title: "Beleg \($0)", sourceName: "synthetic.pdf", ocrText: String(repeating: "Versicherung 49,99 EUR\n", count: 500)) }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode(original); try bytes.write(to: json)
            let source = FileVaultSnapshotSource(fileURL: json), documents = try source.loadDocuments()
            let directory = root.appendingPathComponent("pilot")
            let store = try SQLiteDocumentStorePilot(directory: directory, create: true)
            try store.importJSON(source)
            #expect(try store.count == 100)
            let before = try #require(try store.document(id: documents[0].id))
            #expect(before == documents[0])
            let backup = try store.backup(toNewDirectory: root.appendingPathComponent("backup"))
            let backupBytes = try Data(contentsOf: backup.file)
            var edited = before; edited.ocrText = "Aktualisierte Versicherung"
            try store.replace(edited, ifCurrent: before)
            let restarted = try SQLiteDocumentStorePilot(directory: directory)
            #expect(try restarted.document(id: before.id) == edited)
            #expect(try restarted.document(id: documents[1].id) == documents[1])
            #expect(throws: SQLiteDocumentStorePilot.Failure.conflict) { try restarted.replace(before, ifCurrent: before) }
            let restored = try backup.backup(toNewDirectory: root.appendingPathComponent("restored"))
            #expect(try restored.document(id: before.id) == before)
            #expect(try Data(contentsOf: backup.file) == backupBytes)
            let exported = root.appendingPathComponent("export.json")
            try restored.exportJSON(toNewFile: exported)
            let roundTrip = try FileVaultSnapshotSource(fileURL: exported).loadDocuments()
            #expect(Dictionary(uniqueKeysWithValues: roundTrip.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) }))
            #expect(throws: (any Error).self) { try store.exportJSON(toNewFile: json) }
            #expect(try Data(contentsOf: json) == bytes)
            #expect(try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func malformedOrDuplicateImportRollsBackVisitedRecords() throws {
        try withPilotFixture { root in
            let store = try SQLiteDocumentStorePilot(directory: root.appendingPathComponent("pilot"), create: true)
            let json = root.appendingPathComponent("documents.json")
            let document = VaultDocument(title: "Synthetisch", sourceName: "synthetic.pdf")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode([document])
            for value in [Data(bytes.dropLast()) + Data(",null]".utf8), try encoder.encode([document, document])] {
                try value.write(to: json)
                #expect(throws: VaultSnapshotError.invalidFormat) { try store.importJSON(FileVaultSnapshotSource(fileURL: json)) }
                #expect(try store.count == 0)
            }
            try bytes.write(to: json); try store.importJSON(FileVaultSnapshotSource(fileURL: json))
            #expect(throws: SQLiteDocumentStorePilot.Failure.nonempty) { try store.importJSON(FileVaultSnapshotSource(fileURL: json)) }
            #expect(try store.count == 1)
        }
    }

    @Test func processCrashRollsBackUncommittedRecordMutation() throws {
        try withPilotFixture { root in
            let directory = root.appendingPathComponent("pilot")
            let store = try SQLiteDocumentStorePilot(directory: directory, create: true)
            let document = VaultDocument(title: "Synthetisch", sourceName: "synthetic.pdf", ocrText: "Versicherung vor Abbruch")
            try store.replace(document, ifCurrent: nil)
            let before = try store.document(id: document.id)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
                import sqlite3,sys,time
                db=sqlite3.connect(sys.argv[1]); db.execute('BEGIN IMMEDIATE')
                db.execute("UPDATE records SET payload=?", (b'not committed',))
                sys.stdout.write('1'); sys.stdout.flush(); time.sleep(60)
                """, store.file.path]
            process.standardOutput = output
            try process.run()
            defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
            #expect(output.fileHandleForReading.readData(ofLength: 1) == Data("1".utf8))
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            #expect(process.terminationReason == .uncaughtSignal)
            let reopened = try SQLiteDocumentStorePilot(directory: directory)
            #expect(try reopened.document(id: document.id) == before)
            #expect(try reopened.count == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAULDY_R3_STORAGE_REPORT"] != nil))
    func largeSyntheticStorageComparison() throws {
        try withPilotFixture { root in
            let json = root.appendingPathComponent("documents.json")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            FileManager.default.createFile(atPath: json.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let file = try FileHandle(forWritingTo: json)
            try file.write(contentsOf: Data("[".utf8))
            var firstID: UUID?
            for index in 0..<500 {
                let document = VaultDocument(title: "Beleg \(index)", sourceName: "synthetic.pdf",
                    ocrText: String(repeating: "Versicherung mit monatlicher Zahlung. ", count: 6000))
                if firstID == nil { firstID = document.id }
                if index > 0 { try file.write(contentsOf: Data(",".utf8)) }
                try file.write(contentsOf: encoder.encode(document))
            }
            try file.write(contentsOf: Data("]".utf8)); try file.close()
            let store = try SQLiteDocumentStorePilot(directory: root.appendingPathComponent("pilot"), create: true)
            let start = Date()
            try store.importJSON(FileVaultSnapshotSource(fileURL: json))
            let importMS = -start.timeIntervalSinceNow * 1000
            let id = try #require(firstID)
            var readMS: [Double] = [], writeMS: [Double] = [], jsonWriteMS: [Double] = []
            for index in 0..<25 {
                let readStart = Date()
                let before = try #require(try store.document(id: id))
                readMS.append(-readStart.timeIntervalSinceNow * 1000)
                var changed = before; changed.title = "Version \(index)"
                let writeStart = Date(); try store.replace(changed, ifCurrent: before)
                writeMS.append(-writeStart.timeIntervalSinceNow * 1000)
            }
            // Explicit full JSON rewrite control; no customer files and no original copies.
            for index in 0..<3 {
                let start = Date()
                var documents = try FileVaultSnapshotSource(fileURL: json).loadDocuments()
                documents[0].title = "Version \(index)"
                try encoder.encode(documents).write(to: json, options: .atomic)
                jsonWriteMS.append(-start.timeIntervalSinceNow * 1000)
            }
            let report: [String: Any] = ["documents": 500,
                "snapshotBytes": try FileManager.default.attributesOfItem(atPath: json.path)[.size]!,
                "sqliteImportMS": importMS, "pointReadMS": readMS, "pointWriteMS": writeMS,
                "fullJSONReadRewriteMS": jsonWriteMS,
                "scope": "Storage only; explicit SQLite pilot; JSON control excludes backup rotation; not an MCP or customer acceptance"]
            let output = try #require(ProcessInfo.processInfo.environment["VAULDY_R3_STORAGE_REPORT"])
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            #expect(try store.count == 500)
        }
    }

    @Test func refusesExistingCreationAndSymlinkOrPublicDirectory() throws {
        try withPilotFixture { root in
            let directory = root.appendingPathComponent("pilot")
            let store = try SQLiteDocumentStorePilot(directory: directory, create: true)
            #expect(throws: SQLiteDocumentStorePilot.Failure.unsafePath) { try SQLiteDocumentStorePilot(directory: directory, create: true) }
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
            #expect(throws: SQLiteDocumentStorePilot.Failure.unsafePath) { try SQLiteDocumentStorePilot(directory: link) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            #expect(throws: SQLiteDocumentStorePilot.Failure.unsafePath) { try SQLiteDocumentStorePilot(directory: directory) }
            #expect(try store.count == 0)
        }
    }
}

private func withPilotFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-r3-pilot-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }; try body(root)
}
