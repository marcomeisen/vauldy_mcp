// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VauldyMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VauldyDocumentCore", targets: ["VauldyDocumentCore"]),
        .library(name: "VauldyCore", targets: ["VauldyCore"]),
        .library(name: "VauldyDocumentIntelligence", targets: ["VauldyDocumentIntelligence"]),
        .library(name: "VauldyPrivacy", targets: ["VauldyPrivacy"]),
        .library(name: "VauldyMCPRuntime", targets: ["VauldyMCPRuntime"]),
        .executable(name: "vauldy-relay", targets: ["VauldyRelayAgent"]),
        .executable(name: "vauldy-mcp-http", targets: ["VauldyMCPHTTP"]),
        .executable(name: "vauldy-mcp", targets: ["VauldyMCPServer"]),
        .executable(name: "vauldy-research-mcp", targets: ["VauldyResearchMCP"]),
        .executable(name: "vauldy-local", targets: ["VauldyLocalCLI"]),
        .executable(name: "vauldy-mcp-setup", targets: ["VauldyMCPSetup"]),
        .executable(name: "vauldy-mcp-status", targets: ["VauldyMCPStatus"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        )
    ],
    targets: [
        .target(name: "VauldyDocumentIntelligence"),
        .target(name: "VauldyDocumentCore"),
        .target(name: "VauldyCore", dependencies: ["VauldyDocumentCore", "VauldyDocumentIntelligence"]),
        .target(name: "VauldyDemoDocuments"),
        .executableTarget(name: "VauldyLocalCLI", dependencies: ["VauldyCore", "VauldyDemoDocuments", "VauldyMCPRuntime", "VauldyOAuth"]),
        .target(name: "VauldyPrivacy"),
        .target(name: "VauldyRelay", dependencies: ["VauldyMCPRuntime", "VauldyCore"]),
        .executableTarget(name: "VauldyRelayAgent", dependencies: ["VauldyRelay", "VauldyMCPRuntime"]),
        .target(name: "VauldyOAuth", dependencies: ["VauldyMCPRuntime"]),
        .target(name: "VauldyMCPProtocol", dependencies: ["VauldyMCPRuntime", "VauldyCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "VauldyMCPHTTP", dependencies: ["VauldyOAuth", "VauldyMCPProtocol", .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio")]),
        .target(name: "VauldyMCPRuntime", dependencies: ["VauldyCore", "VauldyDocumentCore", "VauldyPrivacy"]),
        .executableTarget(name: "VauldyMCPSetup", dependencies: ["VauldyMCPRuntime", "VauldyCore", "VauldyDemoDocuments", "VauldyOAuth", "VauldyRelay"]),
        .executableTarget(name: "VauldyMCPStatus", dependencies: ["VauldyMCPRuntime", "VauldyCore"]),
        .executableTarget(name: "VauldyResearchMCP", dependencies: [
            "VauldyMCPRuntime", "VauldyMCPProtocol", .product(name: "MCP", package: "swift-sdk"),
        ]),
        .executableTarget(
            name: "VauldyMCPServer",
            dependencies: [
                "VauldyMCPProtocol",
                "VauldyMCPRuntime",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "VauldyMCPRuntimeTests",
            dependencies: ["VauldyMCPRuntime", "VauldyCore", "VauldyPrivacy", "VauldyDemoDocuments", "VauldyDocumentIntelligence", "VauldyOAuth", "VauldyRelay"],
            resources: [.process("Fixtures")]
        )
    ]
)
