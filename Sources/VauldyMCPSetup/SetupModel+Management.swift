import AppKit
import SwiftUI
import VauldyCore
import VauldyMCPRuntime

enum SetupDocumentFilter: String, CaseIterable {
    case all, selected, unselected, review, pending
    var title: String {
        switch self {
        case .all: "Alle Dokumente"
        case .selected: "Ausgewählt"
        case .unselected: "Nicht ausgewählt"
        case .review: "Texterkennung prüfen"
        case .pending: "In Verarbeitung"
        }
    }
}

extension SetupModel {
    var filteredDocuments: [VaultDocument] {
        documents.filter { document in
            let matches = documentSearch.isEmpty || document.title.localizedCaseInsensitiveContains(documentSearch) || document.sourceName.localizedCaseInsensitiveContains(documentSearch)
            guard matches else { return false }
            switch documentFilter {
            case .all: return true
            case .selected: return selected.contains(document.id)
            case .unselected: return !selected.contains(document.id)
            case .review: return ["needsReview", "failed", "stale"].contains(document.baseAnalysisStatus) || (document.localImport.map { [.partial, .failed, .interrupted, .cancelled].contains($0.state) } ?? false)
            case .pending: return document.localImport?.state == .queued || document.localImport?.state == .recognizing
            }
        }
    }
    var selectedReadableCount: Int { documents.filter { selected.contains($0.id) && $0.isSearchable }.count }
    var selectableDocumentIDs: Set<UUID> { Set(documents.filter(\.isSearchable).map(\.id)) }
    var allReadableDocumentsSelected: Bool {
        let ids = selectableDocumentIDs
        return !ids.isEmpty && ids.isSubset(of: selected)
    }

    func selectAllDocuments() {
        guard !busy, editing != nil || showingSetup else { return }
        selected.formUnion(selectableDocumentIDs)
        acknowledged = false
        documentSearch = ""
        documentFilter = .all
    }

    func clearDocumentSelection() {
        guard !busy, editing != nil || showingSetup else { return }
        selected.removeAll()
        acknowledged = false
    }

    func setDocumentSelected(_ value: Bool, id: UUID) {
        guard !busy else { return }
        if value { selected.insert(id) } else { selected.remove(id) }
        acknowledged = false
    }

    var selectionChanged: Bool { editing.map { selected != $0.allowedDocumentIDs } ?? false }
    var selectionExpandsAccess: Bool { editing.map { !selected.isSubset(of: $0.allowedDocumentIDs) } ?? false }
    var pendingCount: Int { documents.filter { $0.localImport?.state == .queued || $0.localImport?.state == .recognizing }.count }
    var unsharedCount: Int { documents.filter { !(activeConnection?.allowedDocumentIDs.contains($0.id) ?? false) }.count }

    func state(for profile: MCPAccessProfile) -> MCPConnectionState {
        MCPConnectionState(profile: profile, instances: instances, binding: profile.connectionKind == .oauth ? nil : bindings[profile.connectionID])
    }
    func client(for profile: MCPAccessProfile) -> MCPDesktopClient? { profile.connectionKind == .oauth ? nil : resolvedClients[profile.connectionID] ?? profile.desktopClient }
    func existingConnection(for client: MCPDesktopClient) -> MCPAccessProfile? {
        connections.first { resolvedClients[$0.connectionID] == client && bindings[$0.connectionID] == .registered }
    }
    func bindingLabel(_ profile: MCPAccessProfile) -> String {
        if profile.connectionKind == .oauth {
            return oauthConnections.contains { $0.profileID == profile.connectionID && !$0.revoked } ? "OAuth-Freigabe aktiv" : "Dokumentauswahl bereit · OAuth noch nicht verbunden"
        }
        return switch bindings[profile.connectionID] {
        case .registered: "Im Chatbot eingetragen"
        case .notRegistered: "Noch nicht im Chatbot eingetragen"
        case .conflict: "Client-Zuordnung prüfen"
        case .unavailable, nil: profile.desktopClient == nil ? "Manueller Anschluss · noch nicht bestätigt" : "Client-Zuordnung noch nicht bestätigt"
        }
    }

    func startMonitoring() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--section"), index + 1 < args.count,
           let requested = MCPSetupSection(rawValue: args[index + 1]) { section = requested }
        monitoring = Task { [weak self] in
            guard let self else { return }
            await refreshManagement(checkBindings: true)
            // Opening connection management is observational. Starting folder imports
            // remains an explicit action in the folder view or import commands.
            await refreshWatchedFolders()
            if documents.isEmpty { try? await refreshLocalDocuments() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await refreshManagement()
                if Date().timeIntervalSince(lastFoldersRefresh) > 10 {
                    lastFoldersRefresh = Date()
                    await refreshWatchedFolders()
                }
            }
        }
    }

    func refreshManagement(checkBindings: Bool = false) async {
        guard !refreshingManagement else { return }
        refreshingManagement = true
        defer { refreshingManagement = false }
        let installer = installation
        do {
            let loaded = try await Task.detached { try installer.profiles() }.value
            connections = loaded.sorted { $0.connectionName.localizedStandardCompare($1.connectionName) == .orderedAscending }
            if !connections.contains(where: { $0.connectionID == activeConnectionID }) { activeConnectionID = connections.first?.connectionID }
            instances = await Task.detached { try? MCPProcessPresence.serverInstances(root: installer.root) }.value
            managementError = ""
            await refreshOAuth()
            if let binary = bundledBinary {
                let stamp = try? installer.binaryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if software == nil || stamp != lastInstalledStamp {
                    let local = localExecutable, status = bundledStatusApp, setup = Bundle.main.bundleURL
                    software = try await Task.detached { try installer.softwareStatus(availableBinary: binary, localCLI: local, statusApp: status, setupApp: setup) }.value
                    lastInstalledStamp = stamp
                }
            }
            if let request = try installer.consumeSetupRequest() {
                section = request.section
                if let id = request.connectionID, let profile = connections.first(where: { $0.connectionID == id }) {
                    activeConnectionID = id
                    if section == .documents { edit(profile) }
                    if request.diagnose == true { checkConnection(profile) }
                } else if section == .documents { showDocuments() }
                NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            if checkBindings || Date().timeIntervalSince(lastBindingsCheck) > 30 {
                lastBindingsCheck = Date()
                await refreshBindings()
            }
        } catch { managementError = (error as? LocalizedError)?.errorDescription ?? "Der Verwaltungsstatus konnte nicht vollständig gelesen werden. Bitte erneut prüfen." }
    }

    func refreshBindings() async {
        let registrar = registration, installer = installation, profiles = connections
        let results = await Task.detached {
            var states: [UUID: MCPClientBinding] = [:], clients: [UUID: MCPDesktopClient] = [:]
            for profile in profiles {
                if profile.connectionKind == .oauth { continue }
                var fallback: MCPClientBinding = .unavailable
                let candidates = profile.desktopClient.map { [$0] } ?? MCPDesktopClient.allCases
                for client in candidates {
                    let binding = (try? registrar.binding(client, binary: installer.binaryURL, profile: installer.profileURL(profile.connectionID))) ?? .unavailable
                    if binding == .registered { states[profile.connectionID] = binding; clients[profile.connectionID] = client; break }
                    if binding == .conflict || binding == .notRegistered { fallback = binding }
                }
                if states[profile.connectionID] == nil { states[profile.connectionID] = fallback }
            }
            return (states, clients)
        }.value
        bindings = results.0; resolvedClients = results.1
    }

    func navigate(_ section: MCPSetupSection) {
        self.section = section
        if section == .documents { showDocuments() }
    }
    func showDocuments(unselected: Bool = false) {
        documentFilter = unselected ? .unselected : .all
        documentSearch = ""
        if let profile = activeConnection { edit(profile) }
        else { section = .documents; openLocalStore() }
    }
    func edit(_ profile: MCPAccessProfile) {
        activeConnectionID = profile.connectionID; section = .documents
        load(URL(fileURLWithPath: profile.vaultPath), profile: profile)
    }

    func newConnection() {
        guard !busy else { return }
        editing = nil; selected = []; acknowledged = false; configuration = nil
        registrationMessage = ""; connectionName = ""; setupStep = 0
        documentFilter = .all; documentSearch = ""
        clientSelection = "oauth-chatgpt"
        showingSetup = true; failure = false; message = ""
        if documents.isEmpty { openLocalStore() }
    }

    func setAccess(_ enabled: Bool, profile: MCPAccessProfile) {
        guard !accessChanges.contains(profile.connectionID) else { return }
        accessChanges.insert(profile.connectionID)
        let installer = installation
        Task {
            defer { accessChanges.remove(profile.connectionID) }
            do {
                _ = try await Task.detached { try installer.setAccess(enabled, for: profile.connectionID, expectedRevision: profile.revision) }.value
                message = enabled ? "Dokumentzugriff für \(profile.connectionName) fortgesetzt. Empfänger und Auswahl bleiben unverändert." : "Dokumentzugriff pausiert. Server und lokale Importe können weiterlaufen."
                failure = false
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Der Dokumentzugriff konnte nicht geändert werden. Bitte die Verbindung erneut laden.") }
            await refreshManagement()
        }
    }

    func removeConnection(_ profile: MCPAccessProfile) {
        guard !busy, !accessChanges.contains(profile.connectionID) else { return }
        accessChanges.insert(profile.connectionID)
        let installer = installation, registrar = registration
        Task {
            defer { accessChanges.remove(profile.connectionID) }
            do {
                let clientCleanupIncomplete = try await Task.detached {
                    try installer.removeConnection(profile.connectionID, expectedRevision: profile.revision)
                    var incomplete = false
                    for client in MCPDesktopClient.allCases {
                        do { _ = try registrar.unregister(client, binary: installer.binaryURL, profile: installer.profileURL(profile.connectionID)) }
                        catch { incomplete = true }
                    }
                    return incomplete
                }.value
                if editing?.connectionID == profile.connectionID { editing = nil; selected = []; acknowledged = false }
                probeResults.removeValue(forKey: profile.connectionID); probeErrors.removeValue(forKey: profile.connectionID)
                bindings.removeValue(forKey: profile.connectionID); resolvedClients.removeValue(forKey: profile.connectionID)
                message = "Verbindung gelöscht und Zugriff gesperrt. Deine Dokumente bleiben erhalten."
                if clientCleanupIncomplete { message += " Ein Client-Eintrag konnte nicht automatisch entfernt werden. Bitte im Chatbot prüfen." }
                failure = clientCleanupIncomplete
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Verbindung konnte nicht entfernt werden. Bitte neu laden.") }
            await refreshManagement()
        }
    }

    func saveSelection() {
        guard !busy, let profile = editing else { return }
        busy = true
        let installer = installation, ids = selected, disclosure = acknowledged
        Task {
            defer { busy = false }
            do {
                let updated = try await Task.detached { try installer.updateSelection(ids, for: profile.connectionID, expectedRevision: profile.revision, acknowledgedDisclosure: disclosure) }.value
                editing = updated; acknowledged = false
                message = updated.enabled ? "Dokumentauswahl gespeichert." : "Dokumentauswahl gespeichert. Der Dokumentzugriff bleibt pausiert."
                failure = false
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Auswahl konnte nicht gespeichert werden.") }
            await refreshManagement()
        }
    }

    func updateSoftware() {
        guard !busy, let binary = bundledBinary else { return }
        busy = true
        message = "Software wird lokal aktualisiert …"; failure = false
        let installer = installation, local = localExecutable, status = bundledStatusApp, setup = Bundle.main.bundleURL
        Task {
            do {
                try await Task.detached { try installer.updateSoftware(binary: binary, localCLI: local, statusApp: status, setupApp: setup) }.value
                await restartStatusMenu()
                software = nil
                message = "Software aktualisiert. Freigaben und pausierte Zugriffe bleiben erhalten. Bereits laufende Vauldy-Verbindungen bitte im Chatbot neu starten."
                failure = false
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Das Softwareupdate ist fehlgeschlagen. Bitte erneut versuchen.") }
            busy = false
            await refreshManagement()
        }
    }

    func finishSetup() {
        guard !busy, acknowledged, selectedReadableCount > 0, let vaultURL, let binary = bundledBinary else { return }
        let ids = selected.intersection(Set(documents.filter(\.isSearchable).map(\.id)))
        let isOAuth = clientSelection.hasPrefix("oauth-")
        let chosenClient = MCPDesktopClient(rawValue: clientSelection.replacingOccurrences(of: "oauth-", with: ""))
        let client = isOAuth ? nil : chosenClient
        var profile = MCPAccessProfile(vaultPath: vaultURL.path, allowedDocumentIDs: ids, enabled: true, acknowledgedCloudDisclosure: true)
        profile.desktopClient = client
        profile.connectionKind = isOAuth ? .oauth : .local
        let title = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.connectionName = title.isEmpty || title == "Mein MCP-Client" ? (chosenClient.map { isOAuth ? ($0 == .chatgpt ? "ChatGPT" : "Claude") : $0.title } ?? "Mein Chatbot") : String(title.prefix(80))
        let final = profile, installer = installation, registrar = registration
        let local = localExecutable, status = bundledStatusApp, setup = Bundle.main.bundleURL
        busy = true; failure = false; message = "Verbindung wird lokal eingerichtet …"
        Task {
            do {
                configuration = try await Task.detached { try installer.install(binary: binary, profile: final, localCLI: local, statusApp: status, setupApp: setup) }.value
                await restartStatusMenu()
                activeConnectionID = final.connectionID; editing = final
                if isOAuth {
                    configuration = nil
                    registrationMessage = chosenClient == .chatgpt ? "Dokumentauswahl gespeichert. Öffne jetzt die ChatGPT-Anmeldung und verbinde deinen Mac über dein Konto." : "Dokumentauswahl gespeichert. Verbinde Claude über OAuth und bestätige die passende Anfrage in Vauldy."
                } else if let client {
                    do {
                        _ = try await Task.detached { try registrar.register(client, binary: installer.binaryURL, profile: installer.profileURL(final.connectionID)) }.value
                        registrationMessage = "Im Chatbot eingetragen. Eine erste Anfrage muss noch aus dem Chatbot erfolgen."
                    } catch { registrationMessage = "Freigabe gespeichert; der Client-Eintrag konnte nicht angelegt werden. " + ((error as? LocalizedError)?.errorDescription ?? "Bitte Zuordnung prüfen.") }
                } else { registrationMessage = "Konfiguration vorbereitet. Verbinde deinen Chatbot mit der exportierten Konfiguration." }
                setupStep = 3; software = nil
                message = "Die Verbindung wurde vorbereitet. Der lokale Test bestätigt noch keine Anfrage aus deinem Chatbot."
                await refreshManagement(checkBindings: true)
                if !isOAuth { checkConnection(final, present: false) }
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Verbindung konnte nicht eingerichtet werden.") }
            busy = false
        }
    }

    func checkConnection(_ profile: MCPAccessProfile, present: Bool = true) {
        if profile.connectionKind == .oauth { activeConnectionID = profile.connectionID; section = .oauth; Task { await refreshOAuth() }; return }
        if present { diagnosisProfile = profile }
        guard !probing.contains(profile.connectionID) else { return }
        probing.insert(profile.connectionID); probeErrors[profile.connectionID] = nil
        let installer = installation
        Task {
            do {
                let result = try await Task.detached { try MCPLocalProbe.run(binary: installer.binaryURL, profile: installer.profileURL(profile.connectionID)) }.value
                probeResults[profile.connectionID] = result
            } catch { probeErrors[profile.connectionID] = (error as? LocalizedError)?.errorDescription ?? "Der lokale MCP-Test ist fehlgeschlagen. Bitte Software und Freigabe prüfen." }
            probing.remove(profile.connectionID)
            await refreshManagement(checkBindings: true)
        }
    }

    func reconnect(_ profile: MCPAccessProfile) {
        guard let client = client(for: profile), profile.enabled else { return }
        let installer = installation, registrar = registration
        Task {
            do {
                _ = try await Task.detached { try registrar.register(client, binary: installer.binaryURL, profile: installer.profileURL(profile.connectionID)) }.value
                message = "Client-Eintrag geprüft. Starte die Vauldy-Verbindung im Chatbot bei Bedarf neu."
                failure = false
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Der Client-Eintrag konnte nicht angelegt werden.") }
            await refreshManagement(checkBindings: true)
        }
    }

    func preview(_ document: VaultDocument) {
        guard vaultURL == localStore.snapshotURL else { return }
        Task {
            do {
                let access = try await localStore.openOriginal(for: document.id)
                previewAccess?.close(); previewAccess = access; previewURL = access.url
            } catch {
                showError((error as? LocalizedError)?.errorDescription ?? "Die Originaldatei konnte nicht geöffnet werden.")
                try? await refreshLocalDocuments()
            }
        }
    }

    func copyConfiguration(for profile: MCPAccessProfile) {
        do {
            let data = try installation.configurationData(profile.connectionID)
            guard let value = String(data: data, encoding: .utf8) else { throw MCPAccessError.configuration }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            message = "Konfiguration kopiert. Sie enthält lokale Programmpfade, aber keine Dokumentinhalte oder Zugangsdaten."
            failure = false
        } catch { showError("Die Konfiguration konnte nicht kopiert werden.") }
    }

    func restartStatusMenu() async {
        do {
            _ = try MCPProcessPresence.requestMenuStop(root: installation.root)
            for _ in 0..<40 {
                if try !MCPProcessPresence.menuIsRunning(root: installation.root) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard try !MCPProcessPresence.menuIsRunning(root: installation.root) else { throw MCPAccessError.unavailable }
            try MCPStatusApp.launch(root: installation.root, beside: installation.binaryURL)
            statusMenuFailure = ""
        } catch { statusMenuFailure = "Die neue Statusanzeige konnte nicht gestartet werden. Beende die bisherige Anzeige über ihr Menü und öffne die Statusanzeige unter Einstellungen erneut." }
    }
}
