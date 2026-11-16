import SwiftUI
import VauldyOAuth

struct SetupOAuthView: View {
    @ObservedObject var model: SetupModel
    @State private var enteredConfirmations: [UUID: String] = [:]
    @State private var revokeCandidate: OAuthConnection?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupRelayView(model: model)
            Text("Standard-OAuth für selbst betriebene Anschlüsse und Claude.").foregroundStyle(.secondary)
            if let configuration = model.oauthConfiguration {
                LabeledContent("Verbindungsadresse", value: configuration.resource).textSelection(.enabled)
                Text(model.oauthRunning ? "Verbindungsdienst läuft auf diesem Mac · öffentlicher Anschluss separat prüfen" : "Verbindungsdienst gestoppt").font(.callout)
                HStack {
                    if model.oauthRunning { Button("Verbindungsvorgang starten", action: model.armOAuth).buttonStyle(.borderedProminent) }
                    Button("Adresse kopieren", action: model.copyOAuthURL)
                    if model.oauthRunning { Button("Dienst stoppen", action: model.stopOAuth) }
                    else { Button("Dienst starten", action: model.startOAuth).buttonStyle(.borderedProminent) }
                    Button("Aktualisieren") { Task { await model.refreshOAuth() } }
                }.disabled(model.busy)
                Text("Starte hier zuerst den Verbindungsvorgang. Innerhalb von zehn Minuten: In ChatGPT Plugins → Benutzerdefinierten MCP-Server hinzufügen; in Claude Connectors → Add custom connector. Verwende die Adresse oben und OAuth. Gib die Kennung aus dem Browserfenster hier ein.").font(.callout).foregroundStyle(.secondary)
            } else {
                GroupBox("Einmalige Einrichtung durch den Betreiber") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Für normale ChatGPT- und Claude-Chats benötigt der Betreiber eine erreichbare HTTPS-Adresse mit TLS-Proxy zum lokalen Verbindungsdienst. Dieser Schritt richtet weder Router noch Hosting automatisch ein.")
                        TextField("Öffentliche HTTPS-Adresse", text: $model.oauthOrigin).textFieldStyle(.roundedBorder)
                        TextField("Lokaler Port", text: $model.oauthPort).textFieldStyle(.roundedBorder)
                        Button("Dienstadresse speichern", action: model.configureOAuth).disabled(model.busy)
                    }.padding(8)
                }
            }
            Divider()
            Text("Freigaben bestätigen").font(.title2).id("oauth-pending-requests")
            if model.oauthPending.isEmpty { Text("Keine offenen Verbindungsanfragen.").foregroundStyle(.secondary) }
            ForEach(model.oauthPending, id: \.id) { request in
                VStack(alignment: .leading, spacing: 10) {
                    Text("Verbindungsanfrage für \(request.provider.title)").font(.headline)
                    Text("Bestätige nur eine Anfrage, die du gerade selbst im Chatbot gestartet hast. Gib die Kennung aus dem Browserfenster ein.").font(.callout)
                    TextField("Kennung aus dem Browserfenster", text: Binding(get: { enteredConfirmations[request.id] ?? "" }, set: { enteredConfirmations[request.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Text(request.redirectURI).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Client-ID: \(request.clientID ?? "nicht gespeichert")").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Anfrage von \(request.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    Picker("Dokumentauswahl", selection: Binding<UUID?>(get: { model.oauthProfiles[request.id] }, set: { model.oauthProfiles[request.id] = $0 })) {
                        Text("Auswahl wählen").tag(nil as UUID?)
                        ForEach(model.connections.filter { $0.enabled }, id: \.connectionID) { profile in
                            Text("\(profile.connectionName) · \(profile.allowedDocumentIDs.count) Dokumente").tag(profile.connectionID as UUID?)
                        }
                    }
                    if let id = model.oauthProfiles[request.id], let profile = model.connections.first(where: { $0.connectionID == id }) {
                        Text("\(request.provider.title) darf die \(profile.allowedDocumentIDs.count) ausgewählten Dokumente lesen und deren bereinigte Inhalte an seinen Cloud-Anbieter übertragen. Neue Importe bleiben gesperrt.").font(.callout)
                    }
                    HStack {
                        Button("Ablehnen", role: .destructive) { model.denyOAuth(request) }
                        Button("Dokumentzugriff bestätigen") {
                            if let id = model.oauthProfiles[request.id], let profile = model.connections.first(where: { $0.connectionID == id }) {
                                model.oauthApproval = .init(request: request, profile: profile, confirmation: enteredConfirmations[request.id] ?? "")
                            }
                        }
                            .buttonStyle(.borderedProminent).disabled(model.oauthProfiles[request.id] == nil || enteredConfirmations[request.id]?.uppercased() != request.confirmation || model.busy)
                    }
                }.padding().background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Verbundene Chatbots").font(.title2)
            ForEach(model.oauthConnections.filter { !$0.revoked }, id: \.id) { connection in
                HStack {
                    Text(connection.provider.title)
                    Text(model.connections.first { $0.connectionID == connection.profileID }?.connectionName ?? "Dokumentauswahl nicht verfügbar").foregroundStyle(.secondary)
                    Spacer()
                    Button("Zugriff widerrufen", role: .destructive) { revokeCandidate = connection }
                }
            }
            if !model.oauthError.isEmpty { SetupNotice(text: model.oauthError, warning: true) }
            Text("Originale und Texterkennung bleiben auf diesem Mac. Angeforderte, freigegebene Inhalte werden lokal bereinigt und dem Chatbot übergeben. Du kannst den Zugriff hier jederzeit widerrufen.").font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.refreshOAuth() }
        .confirmationDialog("Dokumentzugriff für diesen Chatbot bestätigen?", isPresented: Binding(get: { model.oauthApproval != nil }, set: { if !$0 { model.oauthApproval = nil } }), titleVisibility: .visible) {
            if let approval = model.oauthApproval {
                Button("Ausgewählte Dokumente freigeben") { model.approveOAuth(approval); model.oauthApproval = nil }
            }
            Button("Abbrechen", role: .cancel) { model.oauthApproval = nil }
        } message: {
            if let approval = model.oauthApproval {
                Text("\(approval.request.provider.title) erhält lesenden Zugriff auf die \(approval.profile.allowedDocumentIDs.count) Dokumente aus „\(approval.profile.connectionName)“. Angeforderte Inhalte können an den Cloud-Anbieter übergeben werden.")
            }
        }
        .confirmationDialog("Chatbot-Zugriff widerrufen?", isPresented: Binding(get: { revokeCandidate != nil }, set: { if !$0 { revokeCandidate = nil } }), titleVisibility: .visible) {
            if let connection = revokeCandidate {
                Button("Zugriff widerrufen", role: .destructive) { model.revokeOAuth(connection); revokeCandidate = nil }
            }
            Button("Behalten", role: .cancel) { revokeCandidate = nil }
        } message: {
            if let connection = revokeCandidate {
                let name = model.connections.first { $0.connectionID == connection.profileID }?.connectionName ?? "nicht mehr verfügbare Dokumentauswahl"
                Text("\(connection.provider.title) verliert den Zugriff auf „\(name)“. Bereits übertragene Inhalte werden dadurch nicht zurückgerufen; deine Originale bleiben auf diesem Mac.")
            }
        }
    }
}
