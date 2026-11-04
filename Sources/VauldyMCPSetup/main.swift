import AppKit
import SwiftUI
import Foundation
import VauldyMCPRuntime

@main
@MainActor
enum VauldyMCPSetupMain {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--version"]) {
            print("vauldy-mcp-setup \(MCPBuild.version)")
            return
        }
        VauldyMCPSetupApp.main()
    }
}

@MainActor
struct VauldyMCPSetupApp: App {
    @NSApplicationDelegateAdaptor(SetupDelegate.self) var delegate
    @StateObject private var model = SetupModel()
    var body: some Scene {
        Window("Vauldy · MCP", id: "main") {
            SetupView(model: model)
                .onOpenURL { url in
                    guard url.scheme == "vauldy-mcp", url.host == "oauth", url.query == nil else { return }
                    model.section = .oauth
                    Task { await model.refreshOAuth() }
                }
        }
        .defaultSize(width: 1020, height: 760)
        .windowResizability(.contentMinSize)
    }
}

final class SetupDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil) }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
