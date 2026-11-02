import Foundation

/// A removed connection stays revoked even if an old server recreates its log
/// directory or an obsolete UI attempts to save the former grant again.
enum MCPRemovalState {
    static func isRemoved(profileURL: URL) -> Bool {
        let directory = profileURL.deletingLastPathComponent()
        guard profileURL.lastPathComponent == "profile.json",
              directory.deletingLastPathComponent().lastPathComponent == "connections",
              let id = UUID(uuidString: directory.lastPathComponent) else { return false }
        let root = directory.deletingLastPathComponent().deletingLastPathComponent()
        let archive = root.appendingPathComponent("removed-connections", isDirectory: true).appendingPathComponent(id.uuidString)
        return FileManager.default.fileExists(atPath: archive.path)
            || (try? archive.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
