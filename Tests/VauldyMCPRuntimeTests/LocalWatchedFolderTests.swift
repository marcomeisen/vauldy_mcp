import Foundation
import Darwin
import Testing
@testable import VauldyCore

@Suite("Standalone watched folders")
struct LocalWatchedFolderTests {
    @Test func multipleFoldersPersistAndConcurrentChangesAreRetained() async throws {
        try await fixture { root, store in
            let a = try directory(root, "a"), b = try directory(root, "b")
            let registry = LocalWatchedFolderStore(store: store)
            async let first = registry.add([a]); async let second = registry.add([b], recursive: true)
            _ = try await (first, second)
            let folders = try await registry.folders()
            #expect(folders.count == 2)
            let original = try #require(folders.first { $0.path == a.path })
            let updated = try await registry.add([a, a], recursive: true)
            #expect(updated.count == 2)
            #expect(updated.first { $0.path == a.path }?.id == original.id)
            try await registry.setEnabled(false, id: original.id)
            #expect(try await registry.folders().first { $0.id == original.id }?.enabled == false)
            try await registry.remove(original.id)
            #expect(try await registry.folders().map(\.path) == [b.path])
            let permissions = try FileManager.default.attributesOfItem(atPath: store.root.appendingPathComponent("watched-folders.json").path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
    }

    @Test func rejectsVaultOverlapMissingFoldersAndDamagedConfiguration() async throws {
        try await fixture { root, store in
            let registry = LocalWatchedFolderStore(store: store)
            for url in [store.root, root, store.root.appendingPathComponent("originals"), root.appendingPathComponent("missing")] {
                await #expect(throws: LocalWatchError.invalidFolder) { try await registry.add([url]) }
            }
            let source = try directory(root, "source")
            try await registry.add([source])
            let config = store.root.appendingPathComponent("watched-folders.json")
            let damaged = Data("broken".utf8); try damaged.write(to: config)
            await #expect(throws: LocalWatchError.invalidConfiguration) { try await registry.add([source]) }
            #expect(try Data(contentsOf: config) == damaged)
            try FileManager.default.removeItem(at: config)
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: root.appendingPathComponent("absent.json"))
            await #expect(throws: LocalWatchError.invalidConfiguration) { try await registry.folders() }
        }
    }

    @Test func stableFilesRecursionChangesAndSymlinks() async throws {
        try await fixture { root, store in
            let source = try directory(root, "source"), nested = try directory(source, "nested")
            let outside = try directory(root, "outside")
            let a = source.appendingPathComponent("a.PDF"), b = nested.appendingPathComponent("b.png")
            try Data("first".utf8).write(to: a); try Data("nested".utf8).write(to: b)
            try Data("ignored".utf8).write(to: source.appendingPathComponent("notes.txt"))
            let secret = outside.appendingPathComponent("secret.pdf"); try Data("not selected".utf8).write(to: secret)
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.pdf"), withDestinationURL: secret)
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked-folder"), withDestinationURL: outside)
            let registry = LocalWatchedFolderStore(store: store)
            let folders = try await registry.add([source])
            let monitor = LocalWatchedFolderMonitor(store: store), collector = WatchCollector()
            let submit: @Sendable (URL) async throws -> Void = { await collector.add($0) }
            #expect(await monitor.scan(folders, submit: submit).first?.submitted == 0)
            // A growing file needs another stable observation.
            try Data("first changed".utf8).write(to: a)
            #expect(await monitor.scan(folders, submit: submit).first?.submitted == 0)
            #expect(await monitor.scan(folders, submit: submit).first?.submitted == 1)
            _ = await monitor.scan(folders, submit: submit)
            #expect(await collector.paths == [a.path])
            let recursive = try await registry.add([source, nested], recursive: true)
            _ = await monitor.scan(recursive, submit: submit)
            _ = await monitor.scan(recursive, submit: submit)
            #expect(await collector.paths == [a.path, b.path])
            try Data("new version of first".utf8).write(to: a)
            _ = await monitor.scan(recursive, submit: submit)
            _ = await monitor.scan(recursive, submit: submit)
            #expect(await collector.paths == [a.path, b.path, a.path])
            for folder in recursive { try await registry.setEnabled(false, id: folder.id) }
            _ = await monitor.scan(try await registry.folders(), submit: submit)
            #expect(await collector.paths.count == 3)
        }
    }

    @Test func unavailableFolderDoesNotPreventOtherFolderAndFailedSubmitRetries() async throws {
        try await fixture { root, store in
            let a = try directory(root, "a"), b = try directory(root, "b")
            let registry = LocalWatchedFolderStore(store: store)
            let folders = try await registry.add([a,b])
            try FileManager.default.removeItem(at: a)
            let file = b.appendingPathComponent("b.pdf"); try Data("fixture".utf8).write(to: file)
            let monitor = LocalWatchedFolderMonitor(store: store)
            _ = await monitor.scan(folders) { _ in }
            let failed = await monitor.scan(folders) { _ in throw LocalImportError.workerBusy }
            #expect(failed[0].issue == .unavailable)
            #expect(failed[1].issue == .importFailed)
            let recovered = await monitor.scan(folders) { _ in }
            #expect(recovered[1].submitted == 1)
        }
    }

    @Test func workerWatchesPastIdleDeduplicatesAndStopsWithoutDeletingImports() async throws {
        try await fixture { root, store in
            let a = try directory(root, "a"), b = try directory(root, "b")
            let folders = try await LocalWatchedFolderStore(store: store).add([a,b])
            let worker = LocalImportWorker(store: store, executable: URL(fileURLWithPath: "/usr/bin/false"))
            let server = Task { try await worker.serve(idleSeconds: 2, ocr: WatchFixtureOCR(), watchInterval: 0.1) }
            defer { server.cancel() }
            let first = a.appendingPathComponent("a.pdf"), duplicate = b.appendingPathComponent("duplicate.pdf")
            try Data("same bytes".utf8).write(to: first); try Data("same bytes".utf8).write(to: duplicate)
            try await waitUntil { try await store.documents().filter { $0.localImport?.state == .completed }.count == 1 }
            try await Task.sleep(for: .milliseconds(2_100))
            #expect(try await worker.status().running)
            #expect(try await store.documents().count == 1)
            try Data("changed bytes".utf8).write(to: first)
            try await waitUntil { try await store.documents().filter { $0.localImport?.state == .completed }.count == 2 }
            for folder in folders { try await LocalWatchedFolderStore(store: store).remove(folder.id) }
            try await waitUntil { try await worker.watchStatus().isEmpty }
            try Data("after removal".utf8).write(to: b.appendingPathComponent("later.pdf"))
            try await server.value
            #expect(try await worker.status().running == false)
            #expect(try await store.documents().count == 2)
        }
    }
}

private actor WatchCollector {
    var paths: [String] = []
    func add(_ url: URL) { paths.append(url.path) }
}
private struct WatchFixtureOCR: LocalDocumentOCR {
    func recognize(file: URL, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalOCRResult {
        .init(pages: [.init(info: .init(page: 1, method: .embeddedText), text: "Synthetic watch fixture")])
    }
}
private func directory(_ root: URL, _ name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let pointer = try #require(realpath(url.path, nil))
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
}
private func fixture(_ body: (URL, LocalDocumentStore) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-watch-test-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalDocumentStore(root: root.appendingPathComponent("vault"))
    _ = try await store.documents()
    try await body(root, store)
}
private func waitUntil(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<200 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw LocalImportError.interrupted
}
