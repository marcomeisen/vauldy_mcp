public enum MCPBuild {
    public static let version = "0.13.0"
    public static var protocolVersion: String { version + "+" + (MCPBuildIdentity.running ?? "unidentified") }
    // Bump when persisted data, audit, credentials or process IPC stop being rollback-compatible.
    public static let softwareCompatibilityEpoch = 1
}
