import AppKit
import SwiftUI
import VauldyCore
import VauldyMCPRuntime

enum SetupDocumentFilter: String, CaseIterable {
    case all, selected, unselected, localOnly, review, ocrReview, analysisReview, pending
    var title: String {
        switch self {
        case .all: "Alle Dokumente"
        case .selected: "Für diesen Chatbot freigegeben"
        case .unselected: "Freigabe ausstehend"
        case .localOnly: "Nur lokal behalten"
        case .review: "Hinweise zu Text und Original"
        case .ocrReview: "Hinweise zur Texterkennung"
        case .analysisReview: "Unvollständige Basisangaben (optional)"
        case .pending: "In Verarbeitung"
        }
    }
}

extension SetupModel {
    func regenerateTitle(_ document: VaultDocument) {
        guard !busy, !importing, isLocalVault else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let updated = try await LocalBaseAnalysisService(store: localStore).regenerateTitle(documentID: document.id)
                if let index = documents.firstIndex(where: { $0.id == document.id }) { documents[index] = updated }
                failure = false
                message = updated.manualTitle == nil ? "Titel neu bestimmt. Belegzeilen und Chatbot-Freigaben bleiben erhalten." : "Automatischer Titel neu bestimmt. Deine eigene Bezeichnung bleibt erhalten."
            } catch {
                failure = true; message = "Titel konnte nicht aktualisiert werden. Lade den Bestand neu und versuche es erneut."
            }
        }
    }

    /// Re-evaluate only when a source URL changes. Rendering each checkbox
    /// must neither reread the storage marker nor resolve filesystem aliases.
    func updateLocalVaultIdentity() {
        let matches: Bool
        if let vaultURL, let localSnapshotURL {
            matches = vaultURL.standardizedFileURL.resolvingSymlinksInPath().path
                == localSnapshotURL.standardizedFileURL.resolvingSymlinksInPath().path
        } else { matches = false }
        if isLocalVault != matches { isLocalVault = matches }
    }
    func documentDisplayName(_ document: VaultDocument) -> String {
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || ["Dokument", "Freigegebenes Dokument"].contains(title) {
            return document.sourceName.isEmpty ? "Dokument" : document.sourceName
        }
        return title
    }
    func canRetryOCR(_ document: VaultDocument) -> Bool {
        isLocalVault && document.localImport?.originalState == .available
            && document.localImport?.state != .queued && document.localImport?.state != .recognizing
    }
    var visibleOCRDocumentIDs: Set<UUID> { Set(filteredDocuments.filter { canRetryOCR($0) }.map(\.id)) }
    var selectedOCRDocuments: [VaultDocument] { documents.filter { ocrSelected.contains($0.id) } }
    func retrySelectedOCR() {
        let ids = selectedOCRDocuments.map(\.id)
        guard !busy, !importing, !ids.isEmpty else { return }
        importFiles([], retries: ids)
    }

    var filteredDocuments: [VaultDocument] {
        documents.filter { document in
            guard shownImportDocumentIDs?.contains(document.id) ?? true else { return false }
            let matches = documentSearch.isEmpty || document.title.localizedCaseInsensitiveContains(documentSearch) || document.sourceName.localizedCaseInsensitiveContains(documentSearch)
            guard matches else { return false }
            switch documentFilter {
            case .all: return true
            case .selected: return activeConnection?.allowedDocumentIDs.contains(document.id) == true
            case .unselected: return needsGrantDecision(document)
            case .localOnly: return isKeptLocal(document)
            case .review: return (LocalDocumentReview(document)?.quality.reviewCount ?? 0) > 0
            case .ocrReview: return document.localImport.map { [.partial, .failed, .interrupted, .cancelled].contains($0.state) || $0.pages.contains(where: \.needsReview) } ?? false
            case .analysisReview: return ["needsReview", "failed", "stale", "unavailable"].contains(document.baseAnalysisStatus)
            case .pending: return document.localImport?.state == .queued || document.localImport?.state == .recognizing
            }
        }
    }
    func showImportedDocuments(_ ids: Set<UUID>) {
        guard !busy else { return }
        if !showingSetup { section = .documents }
        if !isLocalVault { openLocalStore() }
        shownImportDocumentIDs = ids
        documentSearch = ""
        documentFilter = .all
    }

    var pendingCount: Int { documents.filter { $0.localImport?.state == .queued || $0.localImport?.state == .recognizing }.count }

    func state(for profile: MCPAccessProfile) -> MCPConnectionState {
        MCPConnectionState(profile: profile, instances: instances, binding: profile.connectionKind == .oauth ? nil : bindings[profile.connectionID], expectedBuildID: software?.installedBuildID)
    }
    func client(for profile: MCPAccessProfile) -> MCPDesktopClient? { profile.connectionKind == .oauth ? nil : resolvedClients[profile.connectionID] ?? profile.desktopClient }
    func existingConnection(for client: MCPDesktopClient) -> MCPAccessProfile? {
        connections.first { resolvedClients[$0.connectionID] == client && bindings[$0.connectionID] == .registered }
    }
    func bindingLabel(_ profile: MCPAccessProfile) -> String {
        if relayState.paired && relayState.profileID == profile.connectionID {
            return relayState.grantNeedsUpdate ? "ChatGPT gekoppelt · Auswahlbestätigung erforderlich" : "ChatGPT gekoppelt"
        }
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
            // Offer the wizard once at ordinary first launch. Status polling must not
            // reopen a dismissed sheet or interrupt an explicit management route.
            if !args.contains("--section"), section == .overview,
               managementError.isEmpty, connections.isEmpty,
               software?.state == .notInstalled, !showingSetup, !busy {
                showingInstallation = true
            }
            // Opening connection management is observational. Starting folder imports
            // remains an explicit action in the folder view or import commands.
            await refreshWatchedFolders()
            await refreshRelay()
            refreshLocalChoices()
            if documents.isEmpty {
                if let profile = activeConnection { load(URL(fileURLWithPath: profile.vaultPath), profile: profile) }
                else { try? await refreshLocalDocuments() }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await refreshManagement()
                if Date().timeIntervalSince(lastFoldersRefresh) > 10 {
                    lastFoldersRefresh = Date()
                    await refreshWatchedFolders()
                    await refreshRelay()
                    refreshLocalChoices()
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
            for old in connections where !loaded.contains(old) {
                probeResults.removeValue(forKey: old.connectionID); probeErrors.removeValue(forKey: old.connectionID)
            }
            connections = loaded.sorted { $0.connectionName.localizedStandardCompare($1.connectionName) == .orderedAscending }
            if !connections.contains(where: { $0.connectionID == activeConnectionID }) { activeConnectionID = connections.first?.connectionID }
            instances = await Task.detached { try? MCPProcessPresence.serverInstances(root: installer.root) }.value
            managementError = ""
            await refreshOAuth()
            if let binary = bundledBinary {
                let stamp = try? installer.binaryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let installedBuildID = await Task.detached { MCPBuildIdentity.read(installer.binaryURL) }.value
                if software == nil || stamp != lastInstalledStamp || software?.installedBuildID != installedBuildID {
                    probeResults.removeAll(); probeErrors.removeAll()
                    let local = localExecutable, status = bundledStatusApp, setup = Bundle.main.bundleURL
                    software = try await Task.detached { try installer.softwareStatus(availableBinary: binary, localCLI: local, statusApp: status, setupApp: setup) }.value
                    lastInstalledStamp = stamp
                }
            }
            if !busy && !importing && inventoryWorkflow == nil && !showingSetup, let request = try installer.consumeSetupRequest() {
                section = request.section
                if let id = request.connectionID, let profile = connections.first(where: { $0.connectionID == id }) {
                    activeConnectionID = id
                    refreshLocalChoices()
                    if request.editGrant == true { startInventoryWorkflow(profile: profile) }
                    else if section == .documents { edit(profile) }
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
        if section == .connections { Task { await refreshRelay(); await refreshOAuth() } }
    }
    func showDocuments(unselected: Bool = false) {
        shownImportDocumentIDs = nil
        documentFilter = unselected ? .unselected : .all
        documentSearch = ""
        if let profile = activeConnection { edit(profile) }
        else { section = .documents; openLocalStore() }
    }
    func edit(_ profile: MCPAccessProfile) {
        activeConnectionID = profile.connectionID; section = .documents
        refreshLocalChoices()
        load(URL(fileURLWithPath: profile.vaultPath), profile: profile)
    }

    func newConnection() {
        guard !busy else { return }
        editing = nil; selected = []; acknowledged = false; configuration = nil
        registrationMessage = ""; connectionName = ""; setupStep = 0
        shownImportDocumentIDs = nil; documentFilter = .all; documentSearch = ""
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

    func installLocalSoftware() async throws -> String {
        guard !busy else { throw MCPAccessError.unavailable }
        busy = true
        defer { busy = false }
        let version = try await activateBundledSoftware()
        software = nil
        await refreshManagement()
        return version
    }

    func finishInstallation(connectChatbot: Bool) {
        connectAfterInstallation = connectChatbot
        showingInstallation = false
    }

    func installationWizardDismissed() {
        guard connectAfterInstallation else { return }
        connectAfterInstallation = false
        newConnection()
    }

    private func activateBundledSoftware(rollback: Bool = false) async throws -> String {
        let installer = installation, setup = Bundle.main.bundleURL
        return try await Task.detached {
            if rollback { return try installer.rollbackSoftware(allowAdHoc: true) }
            return try installer.updateSoftware(fromApp: setup, allowAdHoc: true)
        }.value
    }

    func updateSoftware() { changeSoftware(rollback: false) }

    func rollbackSoftware() { changeSoftware(rollback: true) }

    private func changeSoftware(rollback: Bool) {
        guard !busy, bundledBinary != nil else { return }
        busy = true
        message = rollback ? "Vorversion wird geprüft …" : "Software wird lokal aktualisiert …"
        failure = false
        Task {
            do {
                let version = try await activateBundledSoftware(rollback: rollback)
                await restartStatusMenu()
                software = nil
                message = rollback ? "Vorversion \(version) ist aktiv." : "Software \(version) ist aktiv."
                message += " Bitte starte bereits laufende Vauldy-Verbindungen im Chatbot neu."
                failure = false
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Software konnte nicht gewechselt werden.") }
            busy = false
            await refreshManagement()
        }
    }

    func prepareNewGrant() {
        guard !busy, !importing, let vaultURL, let executable = localExecutable else { return }
        let isOAuth = clientSelection.hasPrefix("oauth-")
        let client = MCPDesktopClient(rawValue: clientSelection.replacingOccurrences(of: "oauth-", with: ""))
        var draft = MCPAccessProfile(vaultPath: vaultURL.path)
        draft.connectionKind = isOAuth ? .oauth : .local
        draft.desktopClient = isOAuth ? nil : client
        let name = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = isOAuth ? (client == .chatgpt ? "ChatGPT" : "Claude") : (client?.title ?? "Mein Chatbot")
        draft.connectionName = name.isEmpty ? recipient : String(name.prefix(80))
        let workflow = InventoryWorkflowModel(installation: installation, executable: executable, profile: draft,
            updatesChatGPT: false) { _ in }
        workflow.createConnection = { [weak self] profile, digest in
            guard let self else { throw CancellationError() }
            try await self.finishSetup(profile: profile, digest: digest)
        }
        workflow.step = 1
        inventoryWorkflow = workflow
        workflow.reportOnly()
    }

    func finishSetup(profile: MCPAccessProfile, digest: String) async throws {
        guard let binary = bundledBinary else { throw MCPAccessError.configuration }
        let installer = installation, registrar = registration
        let local = localExecutable, status = bundledStatusApp, setup = Bundle.main.bundleURL
        let snapshot = LocalDocumentStore.resolvedSnapshotURL(URL(fileURLWithPath: profile.vaultPath))
        let store = localStore, localInventory = snapshot == store.snapshotURL
        busy = true
        defer { busy = false }
        configuration = try await Task.detached {
            let install = {
                guard try LocalInventoryFingerprint.snapshot(snapshot) == digest else { throw LocalInventoryError.changed }
                return try installer.install(binary: binary, profile: profile, localCLI: local, statusApp: status, setupApp: setup)
            }
            if localInventory { return try store.withUnchangedInventory(digest, perform: install) }
            return try install()
        }.value
        await restartStatusMenu()
        activeConnectionID = profile.connectionID; editing = profile
        if profile.connectionKind == .oauth {
            configuration = nil
            registrationMessage = "Freigabe gespeichert. Schließe jetzt die Anmeldung für diese Verbindung ab."
        } else if let client = profile.desktopClient {
            do {
                _ = try await Task.detached { try registrar.register(client, binary: installer.binaryURL, profile: installer.profileURL(profile.connectionID)) }.value
                registrationMessage = "Im Chatbot eingetragen. Stelle jetzt eine Frage zu einem freigegebenen Dokument."
            } catch { registrationMessage = "Freigabe gespeichert. Der Eintrag im Chatbot benötigt deine Hilfe unter Verbindungen." }
        } else { registrationMessage = "Freigabe gespeichert. Übertrage die Konfiguration in deinen Chatbot." }
        setupStep = 2; software = nil
        await refreshManagement(checkBindings: true)
        refreshLocalChoices()
        if profile.connectionKind != .oauth { checkConnection(profile, present: false) }
    }

    func checkConnection(_ profile: MCPAccessProfile, present: Bool = true) {
        if profile.connectionKind == .oauth { activeConnectionID = profile.connectionID; section = .oauth; Task { await refreshOAuth() }; return }
        if present { diagnosisProfile = profile }
        guard !probing.contains(profile.connectionID) else { return }
        probing.insert(profile.connectionID); probeErrors[profile.connectionID] = nil; probeResults[profile.connectionID] = nil
        let installer = installation
        Task {
            do {
                let result = try await Task.detached { try MCPLocalProbe.run(binary: installer.binaryURL, profile: installer.profileURL(profile.connectionID)) }.value
                guard connections.first(where: { $0.connectionID == profile.connectionID }) == profile else { throw MCPAccessError.stale }
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
        guard isLocalVault else { return }
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
