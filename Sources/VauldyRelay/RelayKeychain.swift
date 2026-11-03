import Foundation
import Security

/// One short-lived agent command owns this process-wide policy. Only the explicit
/// authorize operation may display system UI; polling and background work never do.
public enum RelayKeychainInteraction {
    public static func configure(allow: Bool) throws {
        guard SecKeychainSetUserInteractionAllowed(allow) == errSecSuccess else { throw RelayFailure.credentials }
    }
}

protocol RelayCredentialPersistence: Sendable {
    func read(allowUserInteraction: Bool) throws -> Data?
    func write(_ data: Data) throws
}

struct SystemRelayCredentialPersistence: RelayCredentialPersistence {
    let account: String
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.marcomeisen.vauldy.mcp-relay", kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false] }
    func read(allowUserInteraction: Bool) throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = allowUserInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        guard let data = item as? Data else { throw RelayFailure.credentials }
        return data
    }
    func write(_ data: Data) throws {
        let values: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q.merge(values) { _, v in v }; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try Self.check(SecItemAdd(q as CFDictionary, nil))
        } else { try Self.check(status) }
    }
    private static func check(_ status: OSStatus) throws {
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) { throw RelayFailure.ownerApprovalRequired }
        guard status == errSecSuccess else { throw RelayFailure.credentials }
    }
}
