// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VauldyMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VauldyCore", targets: ["VauldyCore"]),
        .library(name: "VauldyDocumentIntelligence", targets: ["VauldyDocumentIntelligence"]),
        .library(name: "VauldyPrivacy", targets: ["VauldyPrivacy"]),
        .library(name: "VauldyMCPRuntime", targets: ["VauldyMCPRuntime"]),
        .executable(name: "vauldy-mcp", targets: ["VauldyMCPServer"]),
        .executable(name: "vauldy-local", targets: ["VauldyLocalCLI"]),
        .executable(name: "vauldy-mcp-setup", targets: ["VauldyMCPSetup"]),
        .executable(name: "vauldy-mcp-status", targets: ["VauldyMCPStatus"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        )
    ],
    targets: [
        .target(name: "VauldyDocumentIntelligence"),
        .target(name: "VauldyCore", dependencies: ["VauldyDocumentIntelligence"]),
        .target(name: "VauldyDemoDocuments"),
        .executableTarget(name: "VauldyLocalCLI", dependencies: ["VauldyCore", "VauldyDemoDocuments", "VauldyMCPRuntime"]),
        .target(name: "VauldyPrivacy"),
        .target(name: "VauldyMCPRuntime", dependencies: ["VauldyCore", "VauldyPrivacy"]),
        .executableTarget(name: "VauldyMCPSetup", dependencies: ["VauldyMCPRuntime", "VauldyCore", "VauldyDemoDocuments"]),
        .executableTarget(name: "VauldyMCPStatus", dependencies: ["VauldyMCPRuntime", "VauldyCore"]),
        .executableTarget(
            name: "VauldyMCPServer",
            dependencies: [
                "VauldyMCPRuntime",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "VauldyMCPRuntimeTests",
            dependencies: ["VauldyMCPRuntime", "VauldyCore", "VauldyPrivacy", "VauldyDemoDocuments", "VauldyDocumentIntelligence"],
            resources: [.process("Fixtures")]
        )
    ]
)
