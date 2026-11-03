import SwiftUI
import AppKit
import VauldyRelay
import VauldyMCPRuntime

struct SetupRelayView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        GroupBox("ChatGPT · mit deinem Konto anmelden") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nutze Vauldy in normalen ChatGPT-Chats. Melde dich im Browser mit deinem ChatGPT-Konto an. Du brauchst keinen API- oder Runtime-Schlüssel.")
                Group {
                if model.relayState.keychainNeedsApproval {
                    Text("Die gespeicherte Verbindung benötigt deine Freigabe im macOS-Schlüsselbund. Automatische Abfragen sind angehalten.")
                    Text("Wähle bei der Freigabe für den Vauldy-Verbindungsdienst „Immer erlauben“, damit er im Hintergrund arbeiten kann. „Abbrechen“ lässt die Verbindung gespeichert und öffnet keinen neuen Dialog.").font(.callout).foregroundStyle(.secondary)
                    Button("Schlüsselbundzugriff bestätigen", action: model.authorizeRelay)
                } else if !model.relayState.provisioned {
                    Text("Die private Verbindung muss einmal auf diesem Mac bereitgestellt werden. Dabei werden Zugangsdaten automatisch im Schlüsselbund hinterlegt; Dokumente werden nicht freigegeben.").foregroundStyle(.secondary)
                } else if model.relayState.paired {
                    Text(model.relayRunning ? "Verbindungsdienst auf diesem Mac läuft." : "Verbindungsdienst auf diesem Mac gestoppt.")
                    Text("Der Mac muss eingeschaltet und mit dem Internet verbunden sein. Wähle Vauldy im ChatGPT-Chat als Plugin. Der lokale Dienststatus bestätigt noch keinen Aufruf aus diesem Chat.").font(.callout).foregroundStyle(.secondary)
                    if model.relayState.grantNeedsUpdate { Text("Die Dokumentfreigabe hat sich geändert. Bitte die aktualisierte Auswahl bestätigen; deine Anmeldung bleibt erhalten.").foregroundStyle(.orange) }
                    Button("Bestand und Freigabe aktualisieren …", action: model.startInventoryWorkflow)
                    HStack {
                        if !model.relayRunning { Button("Mac verbinden", action: model.startRelay) }
                        Button("ChatGPT-Verbindung öffnen") { NSWorkspace.shared.open(URL(string: RelayCredentials.origin)!) }
                        Button("Verbindung löschen", role: .destructive, action: model.disconnectRelay)
                    }
                } else if model.relayState.pairID != nil {
                    Text("Anmeldung im Browser abschließen. Der Mac wartet auf deine Bestätigung.")
                    if !model.relayRunning { Button("Anmeldung fortsetzen") { model.resumeRelay() } }
                    Button("Browser öffnen") {
                        if let id = model.relayState.pairID {
                            var c = URLComponents(string: RelayCredentials.origin + "/pair")!; c.queryItems = [.init(name: "id", value: id)]
                            if let url = c.url { NSWorkspace.shared.open(url) }
                        }
                    }
                    Button("Anmeldung abbrechen", role: .cancel, action: model.disconnectRelay)
                } else {
                    Picker("Dokumentauswahl", selection: $model.relayProfileID) {
                        Text("Auswahl wählen").tag(nil as UUID?)
                        ForEach(model.connections.filter { $0.enabled && $0.acknowledgedCloudDisclosure }, id: \.connectionID) { p in
                            Text("\(p.connectionName) · \(p.allowedDocumentIDs.count) Dokumente").tag(p.connectionID as UUID?)
                        }
                    }
                    Button("Mit ChatGPT verbinden") {
                        model.relayApproval = model.connections.first { $0.connectionID == model.relayProfileID }
                    }.buttonStyle(.borderedProminent).disabled(model.relayProfileID == nil)
                    Text("Die Anmeldung öffnet sich im Browser. Nur die hier bestätigte Dokumentauswahl wird verbunden. Neue Importe bleiben gesperrt.").font(.callout).foregroundStyle(.secondary)
                }
                Button("Status aktualisieren") { Task { await model.refreshRelay(explicit: true) } }
                }.disabled(model.busy || model.relayRefreshing)
                if model.relayAuthorizing {
                    ProgressView("Warte auf deine Schlüsselbundfreigabe …")
                    Button("Freigabe abbrechen", role: .cancel, action: model.cancelRelayAuthorization)
                }
                if !model.relayError.isEmpty { SetupNotice(text: model.relayError, warning: true) }
            }.padding(8)
        }
        .task {
            while !Task.isCancelled {
                await model.refreshRelay()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("Dokumentzugriff für ChatGPT bestätigen?", isPresented: Binding(get: { model.relayApproval != nil }, set: { if !$0 { model.relayApproval = nil } }), titleVisibility: .visible) {
            if let p = model.relayApproval { Button("Auswahl bestätigen und anmelden") { model.beginRelay(profile: p); model.relayApproval = nil } }
            Button("Abbrechen", role: .cancel) { model.relayApproval = nil }
        } message: {
            if let p = model.relayApproval { Text("ChatGPT darf die \(p.allowedDocumentIDs.count) Dokumente aus „\(p.connectionName)“ lesen. Angeforderte Inhalte werden auf diesem Mac bereinigt und an ChatGPT übertragen. Originaldateien bleiben lokal. Eine geänderte Auswahl erfordert eine neue Bestätigung.") }
        }
    }
}

extension SetupModel {
    var relayControl: RelayUIControl { .init(installation: installation) }
    func refreshRelay(explicit: Bool = false) async {
        guard !relayRefreshing, RelayStatusRefreshPolicy.shouldRefresh(approvalNeeded: relayState.keychainNeedsApproval, hasError: !relayError.isEmpty, busy: busy, explicit: explicit) else { return }
        relayRefreshing = true; defer { relayRefreshing = false }
        do {
            let r = try await relayControl.request(.init(.status))
            relayState = r.state; relayRunning = r.state.running
            relayError = r.error ?? ""
        } catch { relayError = error.localizedDescription }
    }
    func authorizeRelay() {
        guard !busy, !relayRefreshing else { return }
        busy = true; relayAuthorizing = true; relayError = ""
        relayAuthorizationTask = Task {
            defer { busy = false; relayAuthorizing = false; relayAuthorizationTask = nil }
            do {
                let r = try await relayControl.request(.init(.authorize))
                guard !Task.isCancelled else { return }
                relayState = r.state; relayRunning = r.state.running; relayError = r.error ?? ""
            } catch is CancellationError { }
            catch { relayError = error.localizedDescription }
        }
    }
    func cancelRelayAuthorization() {
        relayAuthorizationTask?.cancel()
        relayError = "Freigabe abgebrochen. Die gespeicherte Verbindung bleibt erhalten."
    }
    func beginRelay(profile: MCPAccessProfile) {
        guard !busy, !relayRefreshing else { return }
        busy = true; relayError = ""
        Task {
            defer { busy = false }
            do {
                let r = try await relayControl.request(.init(.begin, profileID: profile.connectionID, revision: profile.revision))
                relayState = r.state; relayRunning = r.state.running
                if let error = r.error { relayError = error }
                if let url = r.authorizationURL, !NSWorkspace.shared.open(url) { relayError = "Die Anmeldung konnte nicht geöffnet werden." }
            } catch { relayError = error.localizedDescription }
        }
    }
    func resumeRelay() { startRelay() }
    func startRelay() {
        guard !busy, !relayRefreshing else { return }
        busy = true; relayError = ""
        Task {
            defer { busy = false }
            do {
                let r = try await relayControl.request(.init(.start)); relayState = r.state; relayRunning = r.state.running; relayError = r.error ?? ""
            } catch { relayError = error.localizedDescription }
        }
    }
    func disconnectRelay() {
        guard !busy, !relayRefreshing else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await relayControl.request(.init(.disconnect)); relayState = r.state; relayRunning = r.state.running
                relayError = r.error == nil ? "" : "Der Zugriff auf diesem Mac ist gestoppt. Falls die Online-Verbindung noch angezeigt wird, lösche sie zusätzlich im Verbindungsfenster."
            } catch { relayError = error.localizedDescription }
        }
    }
}
