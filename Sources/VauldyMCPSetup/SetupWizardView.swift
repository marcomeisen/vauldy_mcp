import SwiftUI
import VauldyMCPRuntime

struct SetupWizardView: View {
    @ObservedObject var model: SetupModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdvanced = false
    private let steps = ["Chatbot", "Dokumente", "Verbindung"]
    private var existing: MCPAccessProfile? {
        MCPDesktopClient(rawValue: model.clientSelection).flatMap { model.existingConnection(for: $0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Chatbot verbinden").font(.title.weight(.semibold))
            HStack(spacing: 18) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                    Label(title, systemImage: index < model.setupStep ? "checkmark.circle.fill" : "\(index + 1).circle")
                        .foregroundStyle(index == model.setupStep ? Color.accentColor : .secondary).font(.callout)
                }
            }
            Divider()
            if model.setupStep == 1 && model.importing { SetupImportProgress(model: model) }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if model.busy { ProgressView("Wird lokal vorbereitet …").controlSize(.small) }
                        switch model.setupStep {
                        case 0: client
                        case 1:
                            Text("Wähle die Dokumente für diesen Chatbot.").font(.headline)
                            Text("Du kannst mit einem unverfänglichen Beispieldokument beginnen. Importierte Dokumente erhalten noch keine Freigabe.").foregroundStyle(.secondary)
                            if !model.importing { SetupImportStatusView(model: model) }
                            SetupDocumentSource(model: model)
                            SetupDocumentList(model: model)
                                                default: completion
                        }
                        if !model.message.isEmpty { SetupNotice(text: model.message, warning: model.failure) }
                    }.padding(2)
                }.onChange(of: model.shownImportDocumentIDs) { _, ids in
                    if ids != nil { scroll.scrollTo(SetupDocumentList.scrollAnchor, anchor: .top) }
                }
            }
            Divider()
            HStack {
                Button(model.setupStep == 2 ? "Fertig" : "Assistent schließen") { dismiss() }.disabled(model.busy)
                if model.importing { Text("Der Import läuft beim Schließen weiter.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.setupStep > 0 && model.setupStep < 2 { Button("Zurück") { model.setupStep -= 1 }.disabled(model.busy || model.importing) }
                switch model.setupStep {
                case 0:
                    if let existing {
                        Button("Bestehende Verbindung verwalten") { model.activeConnectionID = existing.connectionID; model.section = .connections; dismiss() }.buttonStyle(.borderedProminent)
                    } else { Button("Dokumente auswählen") { model.setupStep = 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                case 1: Button("Dokumente auswählen", action: model.prepareNewGrant).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.documents.isEmpty || model.busy || model.importing)
                default: EmptyView()
                }
            }
        }.padding(28).frame(width: 800, height: 660).interactiveDismissDisabled(model.busy)
        .sheet(item: $model.inventoryWorkflow) { workflow in InventoryWorkflowView(model: workflow) }
    }
    private var client: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welchen Chatbot möchtest du verbinden?").font(.title2.weight(.semibold))
            Text("Für jeden Chatbot speichert Vauldy eine eigene Dokumentauswahl. Bestehende Verbindungen bleiben erhalten.").foregroundStyle(.secondary)
            ForEach([("oauth-chatgpt", "ChatGPT", "Mit deinem Konto anmelden. Vauldy verbindet den Mac ausgehend."),
                     ("oauth-claude", "Claude", "Verbindung über einen vom Betreiber bereitgestellten HTTPS-Anschluss.")], id: \.0) { choice in
                Button {
                    model.clientSelection = choice.0
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.clientSelection == choice.0 ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.1).font(.headline)
                            Text(choice.2).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(model.clientSelection == choice.0 ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("\(choice.1), \(choice.2)")
                .accessibilityAddTraits(model.clientSelection == choice.0 ? .isSelected : [])
            }
            DisclosureGroup("Erweitert · lokaler oder manueller Anschluss", isExpanded: $showingAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Für Chatbots mit lokalem MCP-Host oder eigener Konfiguration.").font(.callout).foregroundStyle(.secondary)
                    ForEach(MCPDesktopClient.allCases, id: \.rawValue) { client in
                        Button {
                            model.clientSelection = client.rawValue
                        } label: {
                            Label(client.title, systemImage: model.clientSelection == client.rawValue ? "checkmark.circle.fill" : "circle")
                        }.accessibilityAddTraits(model.clientSelection == client.rawValue ? .isSelected : [])
                    }
                    Button {
                        model.clientSelection = "manual"
                    } label: {
                        Label("Anderer Chatbot · manuelle Konfiguration", systemImage: model.clientSelection == "manual" ? "checkmark.circle.fill" : "circle")
                    }.accessibilityAddTraits(model.clientSelection == "manual" ? .isSelected : [])
                }.padding(.top, 8)
            }
            .onAppear { showingAdvanced = !model.clientSelection.hasPrefix("oauth-") }
            if let client = MCPDesktopClient(rawValue: model.clientSelection), let existing = model.existingConnection(for: client) {
                SetupNotice(text: "Für diesen Chatbot ist bereits „\(existing.connectionName)“ eingetragen. Ein bestehender Eintrag wird nicht ersetzt. Verwende „Verbindungen“, um ihn zu bearbeiten.", warning: true)
            }
            TextField("Name der Verbindung (optional)", text: $model.connectionName).textFieldStyle(.roundedBorder)
            Text(model.clientSelection == "oauth-chatgpt" ? "Empfohlen für ChatGPT: Nach der Dokumentauswahl meldest du dich im Browser an. Du gibst keinen API-Schlüssel ein." : model.clientSelection == "oauth-claude" ? "Für Claude: Der Betreiber muss zuerst einen erreichbaren HTTPS-Anschluss einrichten. Danach bestätigst du den Dokumentzugriff auf diesem Mac." : "Für einen lokalen MCP-Host. Die Einrichtung im Chatbot kann zusätzliche Schritte erfordern.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var completion: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Verbindung vorbereitet", systemImage: "checkmark.circle").font(.title2.weight(.semibold))
            Text(model.registrationMessage)
            if let profile = model.activeConnection, profile.connectionKind == .oauth {
                Text("Die gespeicherte Dokumentauswahl allein aktiviert noch keinen Zugriff im Chatbot.")
                Button(model.clientSelection == "oauth-chatgpt" ? "ChatGPT-Anmeldung öffnen" : "OAuth-Verbindung öffnen") { model.relayProfileID = profile.connectionID; model.section = .oauth; dismiss() }.buttonStyle(.borderedProminent)
            } else if let profile = model.activeConnection {
                SetupStatusBadge(text: model.state(for: profile).headline, tone: model.state(for: profile).tone)
                if model.probing.contains(profile.connectionID) { ProgressView("Lokaler Protokolltest läuft …") }
                if let result = model.probeResults[profile.connectionID] {
                    Text(result.summary).foregroundStyle(result.compatible ? .green : .orange)
                    Text(result.nextStep).font(.caption)
                }
                if let error = model.probeErrors[profile.connectionID] { SetupNotice(text: error, warning: true) }
                Text("Aktiviere Vauldy in deinem Chatbot und frage nach einem ausgewählten Dokument. Erst eine Anfrage aus dem Chatbot bestätigt dessen Nutzung. Falls er bereits geöffnet ist, starte seine Vauldy-Verbindung neu.").foregroundStyle(.secondary)
                Text("Der lokale Test prüft nur das MCP-Protokoll und die Freigabe auf diesem Mac.").font(.caption).foregroundStyle(.secondary)
                Button("Konfiguration kopieren") { model.copyConfiguration(for: profile) }
            }
        }
    }
}
