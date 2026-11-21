import AppKit
import QuickLook
import SwiftUI
import VauldyCore
import VauldyMCPRuntime

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @State private var showingPendingApproval = false
    @State private var showingSharing = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                Label("Vauldy", systemImage: "externaldrive.badge.checkmark")
                    .font(.title2.weight(.semibold)).padding(.horizontal, 12).padding(.top, 18)
                List(selection: Binding<MCPSetupSection?>(
                    get: { showingSharing ? nil : model.section == .folders ? .documents : model.section == .oauth ? .connections : model.section },
                    set: { if let section = $0 { showingSharing = false; model.navigate(section) } })) {
                    ForEach([MCPSetupSection.overview, .documents], id: \.self) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                    Button { showingSharing = true } label: {
                        Label("Freigaben", systemImage: "checkmark.shield")
                    }.buttonStyle(.plain)
                        .listRowBackground(showingSharing ? Color.accentColor.opacity(0.12) : Color.clear)
                    ForEach([MCPSetupSection.connections, .settings], id: \.self) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }.listStyle(.sidebar)
                Label("Auf diesem Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(16)
            }.navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if model.busy { ProgressView("Wird lokal verarbeitet …").controlSize(.small) }
                        if !model.managementError.isEmpty { SetupNotice(text: model.managementError, warning: true) }
                        if !model.message.isEmpty {
                            SetupNotice(text: model.message, warning: model.failure)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.failure ? Color.orange.opacity(0.12) : Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityIdentifier("setup-message")
                        }
                        SetupImportStatusView(model: model)
                        if !model.oauthPending.isEmpty { pendingApprovalBanner }
                        if showingSharing { sharing }
                        else { switch model.section {
                        case .overview: overview
                        case .connections: connections
                        case .documents: SetupDocumentsView(model: model)
                        case .folders:
                            Button("Zur Dokumentliste") { model.navigate(.documents) }
                            SetupFoldersView(model: model)
                        case .oauth: connections
                        case .settings: SetupSettingsView(model: model)
                        } }
                    }.padding(28).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }.background(Color(nsColor: .windowBackgroundColor))
                .onChange(of: model.shownImportDocumentIDs) { _, ids in
                    if ids != nil { scroll.scrollTo(SetupDocumentList.scrollAnchor, anchor: .top) }
                }
            }
        }
        .navigationTitle("Vauldy")
        .tint(Color(red: 0.09, green: 0.35, blue: 0.42))
        .onChange(of: model.section) { _, _ in showingSharing = false }
        .onChange(of: model.message) { _, message in
            if !message.isEmpty {
                NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                     userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Chatbot verbinden", systemImage: "plus", action: model.newConnection).disabled(model.busy) } }
        .frame(minWidth: 860, minHeight: 640)
        .sheet(item: Binding(get: { model.showingSetup ? nil : model.inventoryWorkflow }, set: { model.inventoryWorkflow = $0 })) { workflow in InventoryWorkflowView(model: workflow) }
        .sheet(isPresented: $model.showingInstallation, onDismiss: model.installationWizardDismissed) {
            SoftwareInstallationWizard(model: model)
        }
        .sheet(isPresented: $model.showingSetup) { SetupWizardView(model: model) }
        .sheet(isPresented: $showingPendingApproval) {
            ScrollViewReader { scroll in
                ScrollView {
                    SetupOAuthView(model: model)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { scroll.scrollTo("oauth-pending-requests", anchor: .top) }
            }
            .frame(minWidth: 680, minHeight: 520)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button("Schließen") { showingPendingApproval = false }
                }.padding(16).background(.regularMaterial)
            }
        }
        .sheet(item: $model.diagnosisProfile) { profile in SetupDiagnosisView(model: model, profileID: profile.connectionID) }
        .alert("Dokumentzugriff fortsetzen?", isPresented: Binding(get: { model.resumeCandidate != nil }, set: { if !$0 { model.resumeCandidate = nil } })) {
            if let profile = model.resumeCandidate {
                Button("Zugriff fortsetzen") { model.setAccess(true, profile: profile); model.resumeCandidate = nil }
            }
            Button("Abbrechen", role: .cancel) { model.resumeCandidate = nil }
        } message: {
            if let profile = model.resumeCandidate {
                Text("\(profile.connectionName) darf wieder auf \(SetupText.documents(profile.allowedDocumentIDs.count)) zugreifen. Chatbot und gespeicherte Auswahl bleiben unverändert; neue Importe werden nicht freigegeben.")
            }
        }
        .alert("Verbindung löschen?", isPresented: Binding(get: { model.removalCandidate != nil }, set: { if !$0 { model.removalCandidate = nil } })) {
            if let profile = model.removalCandidate {
                Button("Verbindung löschen", role: .destructive) { model.removeConnection(profile); model.removalCandidate = nil }
            }
            Button("Abbrechen", role: .cancel) { model.removalCandidate = nil }
        } message: {
            if let profile = model.removalCandidate {
                Text("„\(profile.connectionName)“ wird entfernt und ihr Dokumentzugriff gesperrt. Der passende Eintrag im Chatbot wird entfernt. Deine Dokumente bleiben erhalten; der deaktivierte Verbindungsverlauf bleibt lokal archiviert.")
            }
        }
        .quickLookPreview($model.previewURL)
        .onChange(of: model.previewURL) { _, url in
            if url == nil { model.previewAccess?.close(); model.previewAccess = nil }
        }
        .confirmationDialog("Geprüfte Kopien durch Originalverweise ersetzen?", isPresented: $model.showingOriginalMigration, titleVisibility: .visible) {
            Button("Geprüfte Kopien entfernen", role: .destructive) { model.applyOriginalMigration() }
            Button("Abbrechen", role: .cancel) { model.originalMigration = nil }
        } message: {
            Text("\(model.originalMigration?.report.eligibleDocuments ?? 0) Kopien stimmen vollständig mit erreichbaren Originalen überein. Vor dem Entfernen werden Zugriff und Inhalt erneut geprüft. Originaldateien bleiben unverändert; nicht geprüfte Kopien bleiben erhalten.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(showingSharing ? "Freigaben" : model.section == .oauth ? "Verbindungen" : model.section == .folders ? "Dokumente · Ordner" : model.section.title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
    private var subtitle: String {
        if showingSharing { return "Bestimme für jeden Chatbot, welche Dokumente er lesen darf." }
        return switch model.section {
        case .overview: "Deine Dokumente, Freigaben und nächsten Schritte."
        case .connections: "Dokumentzugriff für jeden Chatbot einzeln verwalten."
        case .documents: "Dateien und Ordner hinzufügen, Text prüfen und Originale verwalten."
        case .folders: "Ordner einmalig importieren oder automatisch überwachen."
        case .oauth: "Sicher verbinden und Dokumentzugriff bestätigen. Ohne API-Schlüssel."
        case .settings: "Software, Datenschutz und lokale Diagnose."
        }
    }

    private var pendingApprovalBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.oauthPending.count) offene \(model.oauthPending.count == 1 ? "Verbindungsanfrage" : "Verbindungsanfragen")")
                    .font(.headline)
                Text("Prüfe die Anfrage und bestätige nur einen Verbindungsvorgang, den du selbst gestartet hast.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Freigaben bestätigen") { showingPendingApproval = true }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("\(model.oauthPending.count) offene Verbindungsanfragen prüfen")
                .accessibilityIdentifier("oauth-pending-open")
        }
        .padding(16)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var overview: some View {
        if model.connections.isEmpty && model.managementError.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                if model.software?.state == .notInstalled {
                    Image(systemName: "arrow.down.circle").font(.system(size: 36)).foregroundStyle(.blue)
                    Text("Vauldy auf diesem Mac einrichten").font(.title2.weight(.semibold))
                    Text("Installiere zuerst die lokale Software. Danach kannst du einen Chatbot verbinden oder Vauldy ohne Verbindung nutzen.").foregroundStyle(.secondary)
                    Button("Installation starten") { model.showingInstallation = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                        .accessibilityIdentifier("software-installation-open")
                } else if model.software == nil {
                    ProgressView("Installationsstatus wird geprüft …").controlSize(.small)
                } else {
                    softwareBanner
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 36)).foregroundStyle(.blue)
                    Text("Verbinde deinen ersten Chatbot.").font(.title2.weight(.semibold))
                    Text("Wähle einen Chatbot und die Dokumente, die er lesen darf. Vauldy bereitet die Inhalte lokal auf diesem Mac vor.").foregroundStyle(.secondary)
                    Button("Chatbot verbinden", action: model.newConnection).buttonStyle(.borderedProminent)
                    Text("Du kannst zuerst ein unverfängliches Beispieldokument ausprobieren.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 22)
        } else {
            softwareBanner
            if !model.connections.isEmpty { SetupConnectionPicker(model: model) }
            if let profile = model.activeConnection {
                SetupNextStepView(model: model, profile: profile)
                SetupConnectionCard(model: model, profile: profile)
            }
            HStack {
                Text("\(SetupText.documents(model.documents.count)) auf diesem Mac")
                Spacer()
                Button("Dokumente hinzufügen") { model.navigate(.documents) }
                Button("Ordner verwalten") { model.section = .folders }
            }
            Label("Originale und Texterkennung bleiben auf diesem Mac.", systemImage: "internaldrive").font(.callout).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var softwareBanner: some View {
        if model.software?.state == .updateAvailable || model.software?.state == .notInstalled {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.software?.state == .notInstalled ? "Serverprogramme noch nicht installiert" : "Softwareupdate verfügbar").font(.headline)
                    Text("Die App und die installierten Programme sind noch nicht auf demselben Stand.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Software ansehen") { model.section = .settings }
            }.padding(16).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button("Mit Claude verbinden") {
                model.newConnection()
                model.clientSelection = MCPDesktopClient.claude.rawValue
            }.disabled(model.busy)
            if model.connections.isEmpty { Text("Noch keine gespeicherte Verbindung. Wähle „Chatbot verbinden“, um einen Chatbot einzurichten.").foregroundStyle(.secondary) }
            ForEach(model.connections, id: \.connectionID) { profile in SetupConnectionCard(model: model, profile: profile) }
            DisclosureGroup("Anmeldung und Verbindungshilfe\(model.oauthPending.isEmpty ? "" : " · \(model.oauthPending.count) offen")", isExpanded: Binding(get: { model.section == .oauth || !model.oauthPending.isEmpty }, set: { model.section = $0 ? .oauth : .connections })) {
                SetupOAuthView(model: model)
            }
        }
    }
    private var sharing: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.connections.isEmpty {
                ContentUnavailableView("Noch keine Verbindung", systemImage: "checkmark.shield",
                    description: Text("Verbinde einen Chatbot und wähle anschließend seine Dokumente aus."))
                Button("Chatbot verbinden", action: model.newConnection).buttonStyle(.borderedProminent)
            } else {
                SetupConnectionPicker(model: model)
                if let profile = model.activeConnection {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(profile.connectionName).font(.title2.weight(.semibold))
                            Spacer()
                            SetupStatusBadge(text: profile.enabled ? "Zugriff aktiv" : "Zugriff pausiert",
                                tone: profile.enabled ? .good : .attention)
                        }
                        Text("\(SetupText.documents(profile.allowedDocumentIDs.count)) derzeit freigegeben")
                        Text("Neue Importe bleiben für diesen Chatbot zunächst gesperrt. Du kannst alle freigabefähigen Treffer gemeinsam auswählen und die genaue Liste vor dem Speichern prüfen.")
                            .foregroundStyle(.secondary)
                        Button("Dokumente auswählen und Freigabe prüfen") { model.startInventoryWorkflow(profile: profile) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.importing)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

struct SetupConnectionCard: View {
    @ObservedObject var model: SetupModel
    let profile: MCPAccessProfile
    var expanded = false
    private var status: MCPConnectionState { model.state(for: profile) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right").font(.title2).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.connectionName.isEmpty ? "Mein Chatbot" : profile.connectionName).font(.headline)
                    Text(model.bindingLabel(profile)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                SetupStatusBadge(text: status.headline, tone: status.tone)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    Text(status.headline).font(.title2.weight(.semibold))
                    Text(status.explanation).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 20) {
                Label(model.relayState.paired && model.relayState.profileID == profile.connectionID ? (model.relayRunning ? "Mac-Dienst läuft" : "Mac-Dienst gestoppt") : status.serverLabel, systemImage: status.running ? "checkmark.circle" : "clock")
                Label("\(SetupText.documents(profile.allowedDocumentIDs.count)) freigegeben", systemImage: "doc.on.doc")
                Label(profile.enabled ? "Zugriff freigegeben" : "Zugriff gesperrt", systemImage: profile.enabled ? "checkmark.shield" : "lock.shield")
            }.font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if profile.enabled {
                    Button("Dokumentzugriff pausieren") { model.setAccess(false, profile: profile) }
                        .accessibilityLabel("Dokumentzugriff für \(profile.connectionName) pausieren")
                        .disabled(model.accessChanges.contains(profile.connectionID))
                } else {
                    Button("Dokumentzugriff fortsetzen") { model.resumeCandidate = profile }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Dokumentzugriff für \(profile.connectionName) fortsetzen")
                        .disabled(profile.allowedDocumentIDs.isEmpty || model.accessChanges.contains(profile.connectionID))
                }
                Button("Freigabe bearbeiten") { model.startInventoryWorkflow(profile: profile) }
                    .accessibilityLabel("Freigabe für \(profile.connectionName) bearbeiten")
                Button("Verbindung prüfen") { model.showConnectionHelp(profile) }
                    .accessibilityLabel("Verbindung mit \(profile.connectionName) prüfen")
            }
            HStack(alignment: .top) {
                Label("Neue Dokumente werden nie automatisch für diesen Chatbot freigegeben.", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Verbindung löschen", role: .destructive) { model.removalCandidate = profile }
                    .accessibilityLabel("Verbindung mit \(profile.connectionName) löschen")
                    .disabled(model.busy || model.accessChanges.contains(profile.connectionID))
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

struct SetupStatusBadge: View {
    let text: String
    let tone: MCPConnectionState.Tone
    private var color: Color {
        switch tone { case .good: .green; case .neutral: .secondary; case .attention: .orange; case .unknown: .orange }
    }
    var body: some View { Text(text).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(color).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6)) }
}

struct SetupNotice: View {
    let text: String
    var warning = false
    var body: some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
            .font(.callout).foregroundStyle(warning ? Color.orange : .secondary)
            .textSelection(.enabled)
            .accessibilityLabel(warning ? "Warnung: \(text)" : text)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

extension MCPAccessProfile: Identifiable { public var id: UUID { connectionID } }
