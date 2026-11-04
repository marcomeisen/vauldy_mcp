import AppKit
import QuickLook
import SwiftUI
import VauldyCore
import VauldyMCPRuntime

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                Label("Vauldy", systemImage: "externaldrive.badge.checkmark")
                    .font(.title2.weight(.semibold)).padding(.horizontal, 12).padding(.top, 18)
                List(MCPSetupSection.allCases, id: \.self, selection: Binding<MCPSetupSection?>(
                    get: { model.section }, set: { if let section = $0 { model.navigate(section) } })) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }.listStyle(.sidebar)
                Label("Auf diesem Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(16)
            }.navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if model.busy { ProgressView("Wird lokal verarbeitet …").controlSize(.small) }
                    if !model.managementError.isEmpty { SetupNotice(text: model.managementError, warning: true) }
                    switch model.section {
                    case .overview: overview
                    case .connections: connections
                    case .documents: SetupDocumentsView(model: model)
                    case .folders: SetupFoldersView(model: model)
                    case .oauth: SetupOAuthView(model: model)
                    case .settings: SetupSettingsView(model: model)
                    }
                    if model.importing { SetupImportProgress(model: model) }
                    if !model.message.isEmpty { SetupNotice(text: model.message, warning: model.failure) }
                }.padding(28).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Vauldy · MCP")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Verbindung hinzufügen", systemImage: "plus", action: model.newConnection).disabled(model.busy) } }
        .frame(minWidth: 860, minHeight: 640)
        .sheet(item: $model.inventoryWorkflow) { workflow in InventoryWorkflowView(model: workflow) }
        .sheet(isPresented: $model.showingInstallation) { SoftwareInstallationWizard(model: model) }
        .sheet(isPresented: $model.showingSetup) { SetupWizardView(model: model) }
        .sheet(item: $model.diagnosisProfile) { profile in SetupDiagnosisView(model: model, profileID: profile.connectionID) }
        .alert("Dokumentzugriff fortsetzen?", isPresented: Binding(get: { model.resumeCandidate != nil }, set: { if !$0 { model.resumeCandidate = nil } })) {
            if let profile = model.resumeCandidate {
                Button("Zugriff fortsetzen") { model.setAccess(true, profile: profile); model.resumeCandidate = nil }
            }
            Button("Abbrechen", role: .cancel) { model.resumeCandidate = nil }
        } message: {
            if let profile = model.resumeCandidate {
                Text("\(profile.connectionName) darf wieder auf \(SetupText.documents(profile.allowedDocumentIDs.count)) zugreifen. Empfänger und gespeicherte Auswahl bleiben unverändert; neue Importe werden nicht freigegeben.")
            }
        }
        .alert("Verbindung löschen?", isPresented: Binding(get: { model.removalCandidate != nil }, set: { if !$0 { model.removalCandidate = nil } })) {
            if let profile = model.removalCandidate {
                Button("Verbindung löschen", role: .destructive) { model.removeConnection(profile); model.removalCandidate = nil }
            }
            Button("Abbrechen", role: .cancel) { model.removalCandidate = nil }
        } message: {
            if let profile = model.removalCandidate {
                Text("„\(profile.connectionName)“ wird entfernt und ihr Dokumentzugriff gesperrt. Ein passender Client-Eintrag wird entfernt. Deine Dokumente bleiben erhalten; der deaktivierte Verbindungsverlauf bleibt lokal archiviert.")
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
            Text(model.section.title).font(.largeTitle.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
    private var subtitle: String {
        switch model.section {
        case .overview: "Alles Wichtige zu deinem lokalen MCP-Zugang."
        case .connections: "Dokumentzugriff für jeden Chatbot einzeln verwalten."
        case .documents: "Prüfe, welche Inhalte dein Chatbot erhalten darf."
        case .folders: "Automatisch lokal importieren. Dokumente separat freigeben."
        case .oauth: "Sicher verbinden und Dokumentzugriff bestätigen. Ohne API-Schlüssel."
        case .settings: "Software, Datenschutz und lokale Diagnose."
        }
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
            if let profile = model.activeConnection { SetupConnectionCard(model: model, profile: profile, expanded: true) }
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Deine Dokumente im Blick").font(.headline); Spacer(); Text("\(SetupText.documents(model.documents.count)) lokal").foregroundStyle(.secondary) }
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "tray").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(SetupText.documents(model.unsharedCount)) ohne Auswahl für diesen Chatbot")
                        Text("Neue Importe bleiben gesperrt. Du entscheidest einzeln über den Dokumentzugriff.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Dokumente prüfen") { model.showDocuments(unselected: true) }
                }
                Divider()
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.watchedFolders.contains(where: \.enabled) ? "Ordnerüberwachung aktiviert" : "Ordnerüberwachung pausiert oder nicht eingerichtet")
                        Text("\(SetupText.documents(model.pendingCount)) in Verarbeitung. Importe und MCP-Verbindungen laufen unabhängig.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Ordner verwalten") { model.section = .folders }
                }
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
            if model.connections.isEmpty { Text("Noch keine gespeicherte Verbindung. Wähle „Verbindung hinzufügen“, um einen Chatbot einzurichten.").foregroundStyle(.secondary) }
            ForEach(model.connections, id: \.connectionID) { profile in SetupConnectionCard(model: model, profile: profile) }
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
                Label(status.serverLabel, systemImage: status.running ? "checkmark.circle" : "clock")
                Label("\(SetupText.documents(profile.allowedDocumentIDs.count)) ausgewählt", systemImage: "doc.on.doc")
                Label(profile.enabled ? "Zugriff freigegeben" : "Zugriff gesperrt", systemImage: profile.enabled ? "checkmark.shield" : "lock.shield")
            }.font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if profile.enabled {
                    Button("Dokumentzugriff pausieren") { model.setAccess(false, profile: profile) }.disabled(model.accessChanges.contains(profile.connectionID))
                } else {
                    Button("Dokumentzugriff fortsetzen") { model.resumeCandidate = profile }.buttonStyle(.borderedProminent).disabled(profile.allowedDocumentIDs.isEmpty || model.accessChanges.contains(profile.connectionID))
                }
                Button("Dokumente bearbeiten") { model.edit(profile) }
                Button("Verbindung prüfen") { model.checkConnection(profile) }
            }
            HStack(alignment: .top) {
                Label("Neue Dokumente werden nie automatisch für diesen Chatbot freigegeben.", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Verbindung löschen", role: .destructive) { model.removalCandidate = profile }
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
            .textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
    }
}

struct SetupImportProgress: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = model.importProgress {
                Text("\(progress.stage) · \(progress.completedPages)/\(progress.totalPages) Seiten").font(.callout)
                if progress.totalPages > 0 { ProgressView(value: Double(progress.completedPages), total: Double(progress.totalPages)) }
            } else { ProgressView("Lokaler Import wird vorbereitet …") }
            HStack { Text("Dokumentzugriffe bleiben während des Imports verwaltbar.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Import abbrechen", action: model.cancelImport) }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension MCPAccessProfile: Identifiable { public var id: UUID { connectionID } }
