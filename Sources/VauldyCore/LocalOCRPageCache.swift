import Foundation
import CryptoKit

/// Derived local data only. Bounded, versioned, and never a source of synthetic confidence.
struct LocalOCRPageCache {
    let directory: URL
    let identity: String
    static let configuration = "ocr-v14-consistent-line-review-" + ProcessInfo.processInfo.operatingSystemVersionString
    init(root: URL, file: URL, configuration: String = Self.configuration) throws {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: LocalDocumentStore.maximumOriginalBytes + 1) ?? Data()
        guard bytes.count <= LocalDocumentStore.maximumOriginalBytes else { throw LocalImportError.fileTooLarge }
        identity = SHA256.hash(data: bytes + Data((file.pathExtension + configuration).utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(identity, isDirectory: true)
        for url in [root, directory] {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LocalImportError.storageUnavailable }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        // Prune only known derived directories. Never follow symlinks or touch originals.
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.count == 64 && $0.lastPathComponent.allSatisfy { "0123456789abcdef".contains($0) } }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for entry in entries.dropFirst(31) where entry != directory {
            if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false { try? FileManager.default.removeItem(at: entry) }
        }
    }
    private struct Entry: Codable { let identity: String; let page: LocalOCRPage }
    func load(page: Int) -> LocalOCRPage? {
        let file = directory.appendingPathComponent("\(page).json")
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 1_100_000,
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Entry.self, from: data),
              value.identity == identity, value.page.info.page == page,
              value.page.info.method != .unreadable, !value.page.info.needsReview else { return nil }
        return value.page
    }
    func save(_ page: LocalOCRPage) throws {
        guard page.info.method != .unreadable, !page.info.needsReview else { return }
        let file = directory.appendingPathComponent("\(page.info.page).json")
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LocalImportError.storageUnavailable }
        let data = try JSONEncoder().encode(Entry(identity: identity, page: page))
        guard data.count <= 1_100_000 else { return }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
