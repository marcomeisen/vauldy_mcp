import SwiftUI
import VauldyMCPRuntime

struct SetupWizardView: View {
    @ObservedObject var model: SetupModel
    @Environment(\.dismiss) private var dismiss
    private let steps = ["Chatbot", "Dokumente", "Freigabe", "Verbindung prüfen"]
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.busy { ProgressView("Wird lokal vorbereitet …").controlSize(.small) }
                    switch model.setupStep {
                    case 0: client
                    case 1:
                        Text("Wähle die Dokumente für diesen Chatbot.").font(.headline)
                        Text("Du kannst mit einem unverfänglichen Beispieldokument beginnen. Importierte Dokumente erhalten noch keine Freigabe.").foregroundStyle(.secondary)
                        SetupDocumentSource(model: model)
                        SetupDocumentList(model: model)
                    case 2: consent
                    default: completion
                    }
                    if !model.message.isEmpty { SetupNotice(text: model.message, warning: model.failure) }
                }.padding(2)
            }
            Divider()
            HStack {
                Button(model.setupStep == 3 ? "Fertig" : "Abbrechen") { dismiss() }.disabled(model.busy)
                Spacer()
                if model.setupStep > 0 && model.setupStep < 3 { Button("Zurück") { model.setupStep -= 1 }.disabled(model.busy) }
                switch model.setupStep {
                case 0:
                    if let existing {
                        Button("Bestehende Verbindung verwalten") { model.activeConnectionID = existing.connectionID; model.section = .connections; dismiss() }.buttonStyle(.borderedProminent)
                    } else { Button("Dokumente auswählen") { model.setupStep = 1 }.buttonStyle(.borderedProminent) }
                case 1: Button("Freigabe prüfen") { model.setupStep = 2 }.buttonStyle(.borderedProminent).disabled(model.selectedReadableCount == 0 || model.busy || model.importing)
                case 2: Button("Freigeben und einrichten", action: model.finishSetup).buttonStyle(.borderedProminent).disabled(!model.acknowledged || model.busy)
                default: EmptyView()
                }
            }
        }.padding(28).frame(width: 800, height: 660).interactiveDismissDisabled(model.busy)
    }
    private var client: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welchen Chatbot möchtest du verbinden?").font(.title2.weight(.semibold))
            Text("Für jeden Chatbot speichert Vauldy eine eigene Dokumentauswahl. Bestehende Verbindungen bleiben erhalten.").foregroundStyle(.secondary)
            Picker("Chatbot", selection: $model.clientSelection) {
                Text("ChatGPT · mit deinem Konto anmelden").tag("oauth-chatgpt")
                Text("Claude · OAuth-Verbindung").tag("oauth-claude")
                ForEach(MCPDesktopClient.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                Text("Anderer Chatbot · manuell").tag("manual")
            }.pickerStyle(.radioGroup)
            if let client = MCPDesktopClient(rawValue: model.clientSelection), let existing = model.existingConnection(for: client) {
                SetupNotice(text: "Für diesen Chatbot ist bereits „\(existing.connectionName)“ eingetragen. Ein bestehender Eintrag wird nicht ersetzt. Verwende „Verbindungen“, um ihn zu bearbeiten.", warning: true)
            }
            TextField("Name der Verbindung (optional)", text: $model.connectionName).textFieldStyle(.roundedBorder)
            Text(model.clientSelection == "oauth-chatgpt" ? "Nach der Dokumentauswahl meldest du dich im Browser mit deinem ChatGPT-Konto an. Der Mac verbindet sich ausgehend; du gibst keinen API- oder Runtime-Schlüssel ein." : model.clientSelection == "oauth-claude" ? "Claude nutzt Standard-OAuth. Der Betreiber benötigt einen erreichbaren HTTPS-Anschluss; du bestätigst den Dokumentzugriff lokal." : "Dieser Anschluss gilt für einen lokalen MCP-Host. Für normale ChatGPT-Chats wähle die Anmeldung mit deinem Konto.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var consent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Prüfe deine Freigabe.").font(.title2.weight(.semibold))
            LabeledContent("Empfänger", value: model.clientSelection == "oauth-chatgpt" ? "ChatGPT" : model.clientSelection == "oauth-claude" ? "Claude" : MCPDesktopClient(rawValue: model.clientSelection)?.title ?? "Dein manuell verbundener Chatbot")
            LabeledContent("Auswahl", value: model.selectedReadableCount == 1 ? "1 lesbares Dokument" : "\(model.selectedReadableCount) lesbare Dokumente")
            ForEach(model.documents.filter { model.selected.contains($0.id) }, id: \.id) { Text($0.title).font(.callout) }
            Text("Dein Chatbot kann Inhalte aus diesen Dokumenten lesen und an seinen Cloud-Anbieter übertragen. Die Freigabe gilt nur für diese Auswahl. Neue Importe bleiben gesperrt.").foregroundStyle(.secondary)
            Toggle("Ich erlaube die Weitergabe der ausgewählten Dokumentinhalte an diesen Chatbot und gegebenenfalls dessen Cloud-Anbieter.", isOn: $model.acknowledged)
            Text("Du kannst den Zugriff jederzeit unter „Verbindungen“ oder im Statusmenü pausieren.").font(.callout).foregroundStyle(.secondary)
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
                if model.probeResults[profile.connectionID] != nil { Label("Lokaler MCP-Test erfolgreich", systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let error = model.probeErrors[profile.connectionID] { SetupNotice(text: error, warning: true) }
                Text("Aktiviere Vauldy in deinem Chatbot und frage nach einem ausgewählten Dokument. Erst eine Anfrage aus dem Chatbot bestätigt dessen Nutzung. Falls er bereits geöffnet ist, starte seine Vauldy-Verbindung neu.").foregroundStyle(.secondary)
                Text("Der lokale Test prüft nur das MCP-Protokoll und die Freigabe auf diesem Mac.").font(.caption).foregroundStyle(.secondary)
                Button("Konfiguration kopieren") { model.copyConfiguration(for: profile) }
            }
        }
    }
}
