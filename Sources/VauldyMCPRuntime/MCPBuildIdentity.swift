import Foundation
import MachO

/// Linker UUID of the actual executable, including old processes after on-disk replacement.
/// This is a build identifier, not a signature, source commit or proof of trust.
public enum MCPBuildIdentity {
    public static let running: String? = {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64,
              header.pointee.sizeofcmds <= 16 * 1_024 * 1_024 else { return nil }
        return parse(Data(bytes: header, count: 32 + Int(header.pointee.sizeofcmds)))
    }()

    public static func read(_ file: URL) -> String? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 256 * 1_024 * 1_024,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return parse(data)
    }

    // Accept thin 64-bit Mach-O and the current architecture in a universal binary.
    static func parse(_ data: Data) -> String? {
        func word(_ offset: Int, big: Bool = false) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let bytes = (0..<4).map { UInt32(data[offset + $0]) }
            return big ? bytes.reduce(0) { ($0 << 8) | $1 } : bytes.reversed().reduce(0) { ($0 << 8) | $1 }
        }
        var start = 0, end = data.count
        if let magic = word(0, big: true), magic == 0xcafebabe || magic == 0xcafebabf {
            guard let count = word(4, big: true), count <= 32,
                  let header = _dyld_get_image_header(0) else { return nil }
            let wide = magic == 0xcafebabf, width = wide ? 32 : 20
            var found = false
            for index in 0..<Int(count) {
                let base = 8 + index * width
                guard let cpu = word(base, big: true) else { return nil }
                if cpu != UInt32(bitPattern: header.pointee.cputype) { continue }
                guard let offset = word(base + (wide ? 12 : 8), big: true),
                      let size = word(base + (wide ? 20 : 12), big: true),
                      !wide || (word(base + 8, big: true) == 0 && word(base + 16, big: true) == 0),
                      Int(offset) <= data.count, Int(size) <= data.count - Int(offset) else { return nil }
                start = Int(offset); end = start + Int(size); found = true; break
            }
            guard found else { return nil }
        }
        guard word(start) == MH_MAGIC_64, let count = word(start + 16), count <= 4096,
              let length = word(start + 20), start + 32 <= end, Int(length) <= end - start - 32 else { return nil }
        var cursor = start + 32
        let commandsEnd = cursor + Int(length)
        for _ in 0..<count {
            guard cursor <= commandsEnd - 8, let command = word(cursor), let size = word(cursor + 4),
                  size >= 8, Int(size) <= commandsEnd - cursor else { return nil }
            if command == LC_UUID {
                guard size == 24 else { return nil }
                return "macho." + data[(cursor + 8)..<(cursor + 24)].map { String(format: "%02x", $0) }.joined()
            }
            cursor += Int(size)
        }
        return nil
    }

    public static func fromProtocolVersion(_ version: String) -> String? {
        let parts = version.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let value = String(parts[1])
        guard value.hasPrefix("macho."), value.count == 38,
              value.dropFirst(6).allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }
}

public struct MCPBuildInformation: Codable, Sendable {
    public let productVersion: String
    public let buildID: String?
    public let softwareCompatibilityEpoch: Int
    public let documentStorage: String
    public let supportedDocumentStorage: [String]
    public let tools: [String]
    public init(tools: [String] = []) {
        productVersion = MCPBuild.version; buildID = MCPBuildIdentity.running
        softwareCompatibilityEpoch = MCPBuild.softwareCompatibilityEpoch
        documentStorage = "json-snapshot"; supportedDocumentStorage = ["json-snapshot", "sqlite-v2"]; self.tools = tools.sorted()
    }
}

public enum MCPToolRequirements {
    public static let baseline: Set<String> = ["get_vault_status", "list_documents", "search_documents", "read_document"]
    public static let current: Set<String> = ["get_vault_status", "list_documents", "search_documents", "read_document",
        "get_topic_overview", "extract_document_fields", "compare_contract_versions", "get_deadline_overview", "get_document_inventory"]
}
