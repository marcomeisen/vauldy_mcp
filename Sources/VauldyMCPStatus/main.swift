import AppKit
import VauldyCore
import VauldyMCPRuntime

@main enum VauldyMCPStatusMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.dropFirst().elementsEqual(["--version"]) {
            print("vauldy-mcp-status \(MCPBuild.version)")
            return
        }
        guard args.count == 3, args[1] == "--root", args[2].hasPrefix("/") else { return }
        let root = URL(fileURLWithPath: args[2])
        guard let presence = try? MCPProcessPresence(root: root, menu: true) else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = StatusDelegate(root: root); app.delegate = delegate
        withExtendedLifetime((presence, delegate)) { app.run() }
    }
}

@MainActor private final class StatusDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let installation: MCPInstallation
    private var store: LocalDocumentStore { .init(root: installation.root.appendingPathComponent("vault", isDirectory: true)) }
    private var item: NSStatusItem?
    private var refreshTask: Task<Void, Never>?
    private var profiles: [MCPAccessProfile] = []
    private var servers: [MCPServerInstance]?
    private var folders: [LocalWatchedFolder] = []
    private var workerRunning = false
    private var folderError = false
    private var managementError = false
    private var reading = false
    private var tracking = false
    private var lastFoldersRead = Date.distantPast
    init(root: URL) { installation = .init(root: root) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item; item.button?.title = " Vauldy …"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu; rebuildMenu()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { refreshTask?.cancel() }
    func menuWillOpen(_ menu: NSMenu) { tracking = true; Task { await refresh() } }
    func menuDidClose(_ menu: NSMenu) { tracking = false; rebuildMenu() }
    private func refresh() async {
        guard !reading else { return }; reading = true; defer { reading = false }
        let installer = installation
        do {
            if try MCPProcessPresence.menuStopRequested(root: installer.root) { NSApp.terminate(nil); return }
            profiles = try await Task.detached { try installer.profiles().sorted { $0.connectionName < $1.connectionName } }.value
            servers = await Task.detached { try? MCPProcessPresence.serverInstances(root: installer.root) }.value
            managementError = false
        } catch { managementError = true; servers = nil }
        if Date().timeIntervalSince(lastFoldersRead) > 10 {
            lastFoldersRead = Date()
            do {
                folders = try await LocalWatchedFolderStore(store: store).folders()
                workerRunning = try await LocalImportWorker(store: store, executable: installer.localCLIURL).status().running
                folderError = false
            } catch { folderError = true }
        }
        let good = !managementError && !profiles.isEmpty && profiles.allSatisfy(\.enabled) && states.allSatisfy { $0.running && !$0.restartRequired }
        item?.button?.title = good ? " Vauldy ✓" : " Vauldy"
        item?.button?.image = NSImage(systemSymbolName: good ? "checkmark.shield" : (profiles.contains(where: { !$0.enabled }) ? "pause.circle" : "circle.dotted"), accessibilityDescription: title)
        item?.button?.contentTintColor = good ? .systemGreen : .labelColor
        item?.button?.toolTip = "Vauldy · " + title
        item?.button?.setAccessibilityLabel("Vauldy · " + title)
        if !tracking { rebuildMenu() }
    }
    private var states: [MCPConnectionState] { profiles.map { .init(profile: $0, instances: servers) } }
    private var title: String {
        if managementError || servers == nil { return "Status prüfen" }
        if profiles.isEmpty { return "Noch nicht eingerichtet" }
        if states.contains(where: \.restartRequired) { return "Neustart erforderlich" }
        let enabled = profiles.filter(\.enabled).count
        if enabled == 0 { return "Dokumentzugriff pausiert" }
        if enabled < profiles.count { return "Teilweise pausiert" }
        if states.contains(where: { !$0.serverKnown }) { return "Serverstatus prüfen" }
        return states.contains(where: \.running) ? "Dokumentzugriff aktiv" : "Wartet auf Chatbot"
    }
    private func rebuildMenu() {
        guard let menu = item?.menu else { return }; menu.removeAllItems()
        menu.addItem(disabled("Vauldy · " + title))
        menu.addItem(disabled(servers.map { instances in
            let count = instances.filter { !$0.diagnostic }.count
            return count == 1 ? "1 laufender MCP-Serverprozess" : "\(count) laufende MCP-Serverprozesse"
        } ?? "Prozessstatus nicht verfügbar"))
        menu.addItem(.separator())
        for profile in profiles {
            let state = MCPConnectionState(profile: profile, instances: servers)
            let row = NSMenuItem(title: String(profile.connectionName.prefix(55)) + " · " + state.headline, action: nil, keyEquivalent: "")
            row.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.headline)
            let sub = NSMenu(); row.submenu = sub
            sub.addItem(disabled(state.serverLabel)); sub.addItem(disabled(profile.allowedDocumentIDs.count == 1 ? "1 Dokument freigegeben" : "\(profile.allowedDocumentIDs.count) Dokumente freigegeben")); sub.addItem(disabled(state.accessLabel))
            sub.addItem(.separator())
            sub.addItem(action(profile.enabled ? "Dokumentzugriff pausieren" : "Dokumentzugriff fortsetzen …", #selector(toggleAccess(_:)), value: profile))
            sub.addItem(action("Freigabe bearbeiten …", #selector(editDocuments(_:)), value: profile.connectionID))
            sub.addItem(action("Verbindung prüfen …", #selector(diagnose(_:)), value: profile.connectionID)); menu.addItem(row)
        }
        if managementError { menu.addItem(disabled("Verbindungen konnten nicht vollständig gelesen werden.")) }
        menu.addItem(action("Vauldy öffnen", #selector(openOverview), key: "o"))
        menu.addItem(action("Verbindungen verwalten …", #selector(openConnections)))
        menu.addItem(action("Dokumente prüfen …", #selector(openDocuments))); menu.addItem(.separator())
        let row = NSMenuItem(title: folderError ? "Ordnerüberwachung · Status prüfen" : "Ordnerüberwachung · \(folders.filter(\.enabled).count) aktiviert", action: nil, keyEquivalent: "")
        let sub = NSMenu(); row.submenu = sub
        sub.addItem(disabled(workerRunning ? "Lokaler Importdienst läuft" : "Lokaler Importdienst ist gestoppt"))
        for folder in folders {
            let name = String(URL(fileURLWithPath: folder.path).lastPathComponent.prefix(60))
            let entry = action((folder.enabled ? "Pausieren: " : "Fortsetzen: ") + name, #selector(toggleFolder(_:)), value: folder)
            entry.toolTip = folder.path; sub.addItem(entry)
        }
        sub.addItem(.separator()); sub.addItem(action("Ordner verwalten …", #selector(openFolders)))
        sub.addItem(disabled("Neue Importe erhalten keine Chatbot-Freigabe.")); menu.addItem(row)
        menu.addItem(.separator()); menu.addItem(action("Software & Einstellungen …", #selector(openSettings)))
        menu.addItem(action("Lokalen Vauldy-Ordner öffnen", #selector(openFolder))); menu.addItem(.separator())
        menu.addItem(action("Statusanzeige beenden", #selector(quit), key: "q")); menu.addItem(disabled("Beendet keine Server oder Importe."))
    }
    private func action(_ title: String, _ selector: Selector, value: Any? = nil, key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: key); row.target = self; row.representedObject = value; return row
    }
    private func disabled(_ title: String) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: ""); row.isEnabled = false; return row
    }
    private func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true); let alert = NSAlert(); alert.messageText = "Vauldy"; alert.informativeText = text; alert.runModal()
    }
    @objc private func toggleAccess(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? MCPAccessProfile else { return }
        if !profile.enabled {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = "Dokumentzugriff fortsetzen?"
            let count = profile.allowedDocumentIDs.count
            alert.informativeText = "\(profile.connectionName) erhält wieder Zugriff auf \(count == 1 ? "1 Dokument" : "\(count) Dokumente"). Die gespeicherte Auswahl bleibt unverändert. Neue Importe werden nicht freigegeben."
            alert.addButton(withTitle: "Zugriff fortsetzen"); alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let installer = installation
        Task {
            do { _ = try await Task.detached { try installer.setAccess(!profile.enabled, for: profile.connectionID, expectedRevision: profile.revision) }.value }
            catch { showError((error as? LocalizedError)?.errorDescription ?? "Der Zugriff konnte nicht geändert werden. Bitte erneut laden.") }
            await refresh()
        }
    }
    @objc private func toggleFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? LocalWatchedFolder else { return }
        Task {
            do {
                try await LocalWatchedFolderStore(store: store).setEnabled(!folder.enabled, id: folder.id)
                if !folder.enabled { try await LocalImportWorker(store: store, executable: installation.localCLIURL).start() }
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Ordnerüberwachung konnte nicht geändert werden.") }
            lastFoldersRead = .distantPast; await refresh()
        }
    }
    private func open(_ section: MCPSetupSection, id: UUID? = nil, diagnose: Bool = false, editGrant: Bool = false) {
        do {
            try installation.requestSetup(.init(section: section, connectionID: id, diagnose: diagnose, editGrant: editGrant))
            let enclosing = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard let app = [installation.setupAppURL, enclosing].first(where: { Bundle(url: $0)?.bundleIdentifier == "com.marcomeisen.vauldy.mcp-setup" }) else { throw MCPAccessError.configuration }
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            if installation.root.resolvingSymlinksInPath().path != MCPInstallation().root.resolvingSymlinksInPath().path {
                config.arguments = ["--setup-root", installation.root.path, "--section", section.rawValue]
            }
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                if error != nil { Task { @MainActor in self.showError("Die Verwaltungs-App konnte nicht geöffnet werden.") } }
            }
        } catch { showError("Die Verwaltungs-App fehlt oder ist nicht lesbar. Öffne die vollständige „Vauldy MCP Einrichtung.app“ aus dem MCP-Paket.") }
    }
    @objc private func openOverview() { open(.overview) }
    @objc private func openConnections() { open(.connections) }
    @objc private func openDocuments() { open(.documents) }
    @objc private func openFolders() { open(.folders) }
    @objc private func openSettings() { open(.settings) }
    @objc private func editDocuments(_ sender: NSMenuItem) { open(.documents, id: sender.representedObject as? UUID, editGrant: true) }
    @objc private func diagnose(_ sender: NSMenuItem) { open(.connections, id: sender.representedObject as? UUID, diagnose: true) }
    @objc private func openFolder() { NSWorkspace.shared.open(installation.root) }
    @objc private func quit() { NSApp.terminate(nil) }
}
