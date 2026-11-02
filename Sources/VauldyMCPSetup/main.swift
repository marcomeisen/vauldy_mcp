import AppKit
import SwiftUI
import VauldyMCPRuntime

@main
@MainActor
struct VauldyMCPSetupApp: App {
    @NSApplicationDelegateAdaptor(SetupDelegate.self) var delegate
    @StateObject private var model = SetupModel()
    var body: some Scene {
        Window("Vauldy · MCP", id: "main") {
            SetupView(model: model)
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
