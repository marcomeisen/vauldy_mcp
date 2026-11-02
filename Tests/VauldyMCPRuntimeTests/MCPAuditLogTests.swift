import Foundation
import Testing
@testable import VauldyMCPRuntime

@Suite("Local MCP audit log")
struct MCPAuditLogTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-audit-test-\(UUID())")
    }
    @Test func typedRecordsArePrivateAndCorrelateRequests() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = MCPAuditLog(directory: directory)
        let request = UUID()
        try log.append(.requestStarted, operation: .init(tool: "secret query alice@example.com"), request: request)
        try log.append(.requestFailed, operation: .unknown, request: request, code: .invalidArguments, durationMS: 12)
        let entries = try log.readVerified()
        #expect(entries.count == 2)
        #expect(entries.map(\.record.request) == [request, request])
        #expect(entries[1].previousHash == entries[0].hash)
        let bytes = try Data(contentsOf: log.currentFile)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("secret query"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("alice@example.com"))
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: log.currentFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func boundedRotationPreservesVerifiableRetainedHistory() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = MCPAuditLog(directory: directory, maxBytes: 4096, archives: 2)
        for _ in 0..<60 { try log.append(.toolsListed, count: 3) }
        let records = try log.readVerified()
        #expect(records.count < 60)
        #expect(records.last?.record.sequence == 60)
        #expect((records.first?.record.sequence ?? 0) > 1)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        #expect(files.count <= 3)
        for file in files { #expect(try Data(contentsOf: file).count <= 4096) }
    }
    @Test func emptyCurrentFileContinuesTheArchivedChain() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = MCPAuditLog(directory: directory)
        try log.append(.serverStarted)
        try FileManager.default.moveItem(at: log.currentFile, to: directory.appendingPathComponent("audit.1.jsonl"))
        try Data().write(to: log.currentFile)
        try log.append(.toolsListed)
        #expect(try log.readVerified().map(\.record.sequence) == [1, 2])
    }
    @Test func modifiedAndIncompleteRecordsAreDetectedWithoutRepair() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = MCPAuditLog(directory: directory)
        try log.append(.serverStarted)
        let original = try Data(contentsOf: log.currentFile)
        var text = String(decoding: original, as: UTF8.self)
        text = text.replacingOccurrences(of: "serverStarted", with: "serverStopped")
        try Data(text.utf8).write(to: log.currentFile)
        #expect(throws: MCPAuditLog.AuditError.self) { try log.readVerified() }
        #expect(throws: MCPAuditLog.AuditError.self) { try log.append(.serverStarted) }
        try original.dropLast().write(to: log.currentFile)
        #expect(throws: MCPAuditLog.AuditError.self) { try log.append(.serverStarted) }
    }
    @Test func concurrentWritersKeepEveryRecordAndSequence() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { try MCPAuditLog(directory: directory).append(.requestStarted, operation: .status, request: UUID()) }
            }
            try await group.waitForAll()
        }
        let records = try MCPAuditLog(directory: directory).readVerified()
        #expect(records.count == 20)
        #expect(records.map(\.record.sequence) == Array(1...20))
    }
    @Test func symlinkCannotRedirectAnAuditWrite() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("foreign")
        try Data("untouched".utf8).write(to: foreign)
        let log = MCPAuditLog(directory: directory.appendingPathComponent("logs"))
        try FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: log.currentFile, withDestinationURL: foreign)
        #expect(throws: MCPAuditLog.AuditError.self) { try log.append(.serverStarted) }
        #expect(try Data(contentsOf: foreign) == Data("untouched".utf8))
    }
    @Test func revocationPersistsEvenIfLoggingIsBlocked() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let installation = MCPInstallation(root: directory)
        let profile = MCPAccessProfile(vaultPath: "/unused/documents.json", allowedDocumentIDs: [UUID()], enabled: true, acknowledgedCloudDisclosure: true)
        let url = installation.profileURL(profile.connectionID)
        try FileMCPProfileSource(url: url).save(profile)
        try Data("not a directory".utf8).write(to: MCPAuditLog(profileURL: url).directory)
        #expect(throws: (any Error).self) { try installation.revoke(profile.connectionID) }
        #expect(try !FileMCPProfileSource(url: url).load().enabled)
    }
}
