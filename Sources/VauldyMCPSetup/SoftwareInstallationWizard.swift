import SwiftUI
import VauldyMCPRuntime

struct SoftwareInstallationWizard: View {
    private enum Phase {
        case review, installing, failed(String), complete(String)
    }

    @ObservedObject var model: SetupModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .review

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Vauldy auf diesem Mac installieren")
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 18) {
                step("Prüfen", number: 1)
                step("Installieren", number: 2)
                step("Fertig", number: 3)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .review:
                        details
                    case .installing:
                        ProgressView("Vauldy prüft das Paket und startet den lokalen Server zur Kontrolle.")
                    case .failed(let error):
                        SetupNotice(text: error, warning: true)
                        details
                    case .complete(let version):
                        Label("Vauldy \(version) ist installiert", systemImage: "checkmark.circle.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("software-installation-complete")
                        Text("Der lokale Server hat den Starttest bestanden.")
                        Text("Weiter mit „Chatbot verbinden“: Der nächste Assistent führt dich durch Chatbot-Auswahl, Dokumentimport und Freigabe. Du entscheidest, welche Dokumente der Chatbot lesen darf.")
                            .foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            Divider()
            HStack {
                switch phase {
                case .installing:
                    EmptyView()
                case .complete:
                    Button("Später einrichten") { model.finishInstallation(connectChatbot: false) }
                        .accessibilityIdentifier("software-installation-later")
                    Spacer()
                    Button("Chatbot verbinden") { model.finishInstallation(connectChatbot: true) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("software-installation-connect")
                case .review, .failed:
                    Button("Abbrechen") { dismiss() }
                    Spacer()
                    Button(isRetry ? "Erneut versuchen" : "Installieren", action: install)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                        .accessibilityIdentifier("software-installation-confirm")
                }
            }
        }
        .padding(28)
        .frame(width: 620, height: 450)
        .interactiveDismissDisabled(currentStep == 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Version", value: MCPBuild.version)
            LabeledContent("Installationsort") {
                Text(model.installation.root.path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/",
                    options: .anchored))
                    .font(.callout)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            Label("Die Software wird aus diesem Paket auf deinem Mac installiert und lokal getestet.", systemImage: "internaldrive")
            Label("Du kannst die Software ohne Konto einrichten. Dokumentfreigaben erteilst du später selbst.", systemImage: "lock.shield")
        }
    }

    private var currentStep: Int {
        switch phase {
        case .review, .failed: 1
        case .installing: 2
        case .complete: 3
        }
    }

    private var isRetry: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func step(_ title: String, number: Int) -> some View {
        Label(title, systemImage: number < currentStep ? "checkmark.circle.fill" : "\(number).circle")
            .foregroundStyle(number == currentStep ? Color.accentColor : .secondary)
            .font(.callout)
            .accessibilityAddTraits(number == currentStep ? .isSelected : [])
    }

    private func install() {
        phase = .installing
        Task {
            do {
                phase = .complete(try await model.installLocalSoftware())
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription
                                ?? "Vauldy konnte nicht installiert werden. Prüfe das Paket und versuche es erneut.")
            }
        }
    }
}
