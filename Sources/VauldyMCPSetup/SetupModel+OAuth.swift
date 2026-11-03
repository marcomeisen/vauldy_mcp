import AppKit
import VauldyOAuth
import VauldyMCPRuntime

struct OAuthApprovalSelection {
    let request: OAuthPendingRequest
    let profile: MCPAccessProfile
}

extension SetupModel {
    var oauthStore: OAuthStore { .init(installation: installation) }
    func refreshOAuth() async {
        let store = oauthStore
        do {
            let state = try await Task.detached { (try store.configuration(), try store.pendingRequests(), try store.connections(), OAuthServiceController(store: store).isRunning()) }.value
            oauthConfiguration = state.0; oauthPending = state.1; oauthConnections = state.2; oauthRunning = state.3
            oauthProfiles = oauthProfiles.filter { key, _ in state.1.contains { $0.id == key } }
            oauthError = ""
        } catch { oauthError = (error as? LocalizedError)?.errorDescription ?? "Die Verbindungsverwaltung ist nicht verfügbar." }
    }
    func configureOAuth() {
        busy = true
        let store = oauthStore, origin = oauthOrigin, port = Int(oauthPort) ?? 0
        Task {
            defer { busy = false }
            do { try await Task.detached { try store.configure(OAuthConfiguration(origin: origin, port: port)) }.value; await refreshOAuth() }
            catch { oauthError = (error as? LocalizedError)?.errorDescription ?? "Die Dienstadresse ist ungültig." }
        }
    }
    func startOAuth() {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("vauldy-mcp-http") else { return }
        busy = true; let store = oauthStore
        Task {
            defer { busy = false }
            do { try await OAuthServiceController(store: store).start(executable: executable); await refreshOAuth() }
            catch { oauthError = (error as? LocalizedError)?.errorDescription ?? "Der Verbindungsdienst konnte nicht gestartet werden." }
        }
    }
    func stopOAuth() {
        let store = oauthStore
        Task {
            do { try await Task.detached { try OAuthServiceController(store: store).stop() }.value }
            catch { oauthError = "Der Verbindungsdienst konnte nicht gestoppt werden." }
        }
    }
    func approveOAuth(_ approval: OAuthApprovalSelection) {
        let request = approval.request, profile = approval.profile, id = approval.profile.connectionID
        busy = true; let store = oauthStore
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try store.approve(request.id, profileID: id, expectedRevision: profile.revision) }.value
                message = "Zugriff für \(request.provider.title) bestätigt. Kehre zum Verbindungsfenster im Chatbot zurück."; failure = false
                await refreshOAuth()
            } catch { oauthError = (error as? LocalizedError)?.errorDescription ?? "Die Freigabe wurde nicht gespeichert." }
        }
    }
    func denyOAuth(_ request: OAuthPendingRequest) {
        let store = oauthStore
        Task { do { try await Task.detached { try store.deny(request.id) }.value; await refreshOAuth() } catch { oauthError = "Die Anfrage konnte nicht abgelehnt werden." } }
    }
    func revokeOAuth(_ connection: OAuthConnection) {
        let store = oauthStore
        Task { do { try await Task.detached { try store.revoke(connectionID: connection.id) }.value; await refreshOAuth() } catch { oauthError = "Der Zugriff konnte nicht widerrufen werden." } }
    }
    func copyOAuthURL() {
        guard let value = oauthConfiguration?.resource else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        message = "Verbindungsadresse kopiert. Im Chatbot OAuth und automatische Registrierung oder veröffentlichte Client-Identität wählen."; failure = false
    }
}
