import SwiftUI
import VauldyCore
import VauldyMCPRuntime

extension SetupModel {
    func refreshLocalChoices() {
        guard let profile = activeConnection else { localChoices = [:]; return }
        do {
            localChoices = try MCPLocalDocumentChoices(installation: installation).load(for: profile.connectionID)
            localChoicesError = ""
        } catch {
            localChoices = [:]
            localChoicesError = "Deine Entscheidung „Nur lokal behalten“ konnte nicht geladen werden. Versuche es erneut."
        }
    }
    func isKeptLocal(_ document: VaultDocument) -> Bool {
        activeConnection?.allowedDocumentIDs.contains(document.id) != true
            && localChoices[document.id] == MCPLocalDocumentChoices.fingerprint(document)
    }
    var pendingGrantDocuments: [VaultDocument] {
        guard let profile = activeConnection, LocalDocumentStore.resolvedSnapshotURL(URL(fileURLWithPath: profile.vaultPath)) == vaultURL else { return [] }
        return documents.filter(needsGrantDecision)
    }
    func needsGrantDecision(_ document: VaultDocument) -> Bool {
        guard let profile = activeConnection else { return false }
        return !profile.allowedDocumentIDs.contains(document.id) && !isKeptLocal(document)
            && document.isSearchable && document.localImport?.state != .queued && document.localImport?.state != .recognizing
            && document.localImport?.originalState != .changed && document.localImport?.originalState != .unavailable
    }
    var unavailableGrantedDocuments: [VaultDocument] {
        guard let profile = activeConnection, LocalDocumentStore.resolvedSnapshotURL(URL(fileURLWithPath: profile.vaultPath)) == vaultURL else { return [] }
        return documents.filter {
            activeConnection?.allowedDocumentIDs.contains($0.id) == true
                && ($0.localImport?.originalState == .changed || $0.localImport?.originalState == .unavailable)
        }
    }
    func documentSharingLabel(_ document: VaultDocument) -> String {
        if showingSetup { return "Auf diesem Mac" }
        guard let profile = activeConnection, LocalDocumentStore.resolvedSnapshotURL(URL(fileURLWithPath: profile.vaultPath)) == vaultURL else { return "Auf diesem Mac" }
        if profile.allowedDocumentIDs.contains(document.id) { return "Für \(profile.connectionName) freigegeben" }
        if isKeptLocal(document) { return "Für \(profile.connectionName) nur lokal behalten" }
        return "Freigabe für \(profile.connectionName) ausstehend"
    }
    func keepPendingLocal() {
        guard !busy, let profile = activeConnection else { return }
        do {
            let candidates = pendingGrantDocuments
            try MCPLocalDocumentChoices(installation: installation).keepLocal(candidates, for: profile)
            refreshLocalChoices()
            message = "\(candidates.count) Dokumente für \(profile.connectionName) nur lokal behalten. Du kannst sie später unter Dokumente freigeben."
            failure = false
        } catch { showError(error.localizedDescription) }
    }
    func showConnectionHelp(_ profile: MCPAccessProfile) {
        activeConnectionID = profile.connectionID
        refreshLocalChoices()
        checkConnection(profile)
    }
}

struct SetupNextStepView: View {
    @ObservedObject var model: SetupModel
    let profile: MCPAccessProfile
    private var paired: Bool { model.relayState.paired && model.relayState.profileID == profile.connectionID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dein nächster Schritt").font(.headline)
            if !model.managementError.isEmpty || !model.localChoicesError.isEmpty {
                Text(model.localChoicesError.isEmpty ? "Der aktuelle Zustand konnte nicht vollständig ermittelt werden." : model.localChoicesError)
                Button("Status erneut prüfen") { Task { await model.refreshManagement(checkBindings: true); model.refreshLocalChoices() } }
            } else if profile.connectionKind == .oauth && model.relayState.keychainNeedsApproval {
                Text("Der Verbindungsstatus benötigt deine Bestätigung im macOS-Schlüsselbund.")
                Button("Schlüsselbundzugriff bestätigen") { model.section = .oauth }.buttonStyle(.borderedProminent)
            } else if profile.enabled && paired && (!model.relayRunning || model.relayState.grantNeedsUpdate) {
                Text(model.relayState.grantNeedsUpdate ? "Bestätige die geänderte Dokumentauswahl für ChatGPT." : "Die ChatGPT-Verbindung benötigt deine Hilfe.")
                Button(model.relayState.grantNeedsUpdate ? "Freigabe bearbeiten" : "Verbindung wiederherstellen") {
                    if model.relayState.grantNeedsUpdate { model.startInventoryWorkflow(profile: profile) }
                    else { model.section = .oauth }
                }.buttonStyle(.borderedProminent)
            } else if !profile.enabled {
                Text("Der Dokumentzugriff für \(profile.connectionName) ist pausiert.")
                Button("Dokumentzugriff fortsetzen") { model.resumeCandidate = profile }
                    .disabled(profile.allowedDocumentIDs.isEmpty || model.accessChanges.contains(profile.connectionID))
                Button("Freigabe bearbeiten") { model.startInventoryWorkflow(profile: profile) }
            } else if model.state(for: profile).restartRequired || model.bindings[profile.connectionID] == .conflict || model.bindings[profile.connectionID] == .notRegistered {
                Text(model.state(for: profile).explanation)
                Button("Verbindung wiederherstellen") { model.showConnectionHelp(profile) }.buttonStyle(.borderedProminent)
            } else if profile.connectionKind == .oauth && !paired && !model.oauthConnections.contains(where: { $0.profileID == profile.connectionID && !$0.revoked }) {
                Text("Schließe die Anmeldung für \(profile.connectionName) ab.")
                Button("Anmeldung fortsetzen") { model.relayProfileID = profile.connectionID; model.section = .oauth }.buttonStyle(.borderedProminent)
            } else if !model.unavailableGrantedDocuments.isEmpty {
                Text("\(model.unavailableGrantedDocuments.count) freigegebene Originale sind verändert oder nicht erreichbar.")
                Text("Diese Dokumente sind derzeit nicht im Chat nutzbar.").foregroundStyle(.secondary)
                Button("Originalzugriff wiederherstellen") { model.startInventoryWorkflow(profile: profile, sources: true) }.buttonStyle(.borderedProminent)
            } else if model.importing || model.pendingCount > 0 {
                Text("Neue Dokumente werden eingelesen. Danach kannst du sie für \(profile.connectionName) auswählen.")
                Text("\(profile.allowedDocumentIDs.count) Dokumente sind bereits freigegeben.").foregroundStyle(.secondary)
            } else if !model.pendingGrantDocuments.isEmpty {
                Text("\(model.pendingGrantDocuments.count) Dokumente warten auf deine Entscheidung für \(profile.connectionName).")
                HStack {
                    Button("Dokumente auswählen") { model.startInventoryWorkflow(profile: profile, newDocuments: true) }.buttonStyle(.borderedProminent)
                    Button("Nur lokal behalten", action: model.keepPendingLocal)
                }
            } else {
                Text("Deine Dokumentauswahl ist gespeichert.")
                Text("\(profile.allowedDocumentIDs.count) Dokumente sind für \(profile.connectionName) freigegeben. Stelle deine nächste Frage im Chatbot.").foregroundStyle(.secondary)
            }
            let reviewCount = model.documents.filter { SetupDocumentGuidance($0).needsTextReview }.count
            if reviewCount > 0 {
                Button("Prüfhinweise für \(reviewCount) Dokumente ansehen") {
                    model.showDocuments()
                    model.documentFilter = .ocrReview
                }
            }
            if let checkedAt = model.originalsCheckedAt {
                Text("Originalzugriff zuletzt geprüft \(checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.busy || model.importing)
    }
}


struct SetupConnectionPicker: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        Picker("Verbindung", selection: Binding(get: { model.activeConnectionID }, set: { id in
            if let profile = model.connections.first(where: { $0.connectionID == id }) {
                model.activeConnectionID = id
                model.refreshLocalChoices()
                model.load(URL(fileURLWithPath: profile.vaultPath), profile: profile)
            }
        })) {
            ForEach(model.connections, id: \.connectionID) { profile in
                Text(profile.connectionName).tag(Optional(profile.connectionID))
            }
        }.disabled(model.busy || model.importing)
    }
}
