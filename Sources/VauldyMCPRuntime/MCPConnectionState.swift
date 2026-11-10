import Foundation

/// Honest presentation of separate transport, permission, binding and software facts.
public struct MCPConnectionState: Sendable {
    public enum Tone: Sendable { case good, neutral, attention, unknown }
    public let profile: MCPAccessProfile
    public let instances: [MCPServerInstance]?
    public let expectedBuildID: String?
    public let binding: MCPClientBinding?
    public init(profile: MCPAccessProfile, instances: [MCPServerInstance]?, binding: MCPClientBinding? = nil, expectedBuildID: String? = nil) {
        self.profile = profile; self.instances = instances; self.binding = binding; self.expectedBuildID = expectedBuildID
    }
    public var matchingServers: [MCPServerInstance] {
        (instances ?? []).filter { !$0.diagnostic && $0.connectionID == profile.connectionID }
    }
    public var serverKnown: Bool {
        guard let instances else { return false }
        return !matchingServers.isEmpty || !instances.contains(where: { !$0.diagnostic && $0.connectionID == nil })
    }
    public var running: Bool { !matchingServers.isEmpty }
    public var restartRequired: Bool { matchingServers.contains { $0.version != MCPBuild.version || (expectedBuildID != nil && $0.buildID != expectedBuildID) } }
    public var requestObserved: Bool { matchingServers.contains { $0.lastRequestAt != nil } }
    public var headline: String {
        if !profile.enabled { return "Dokumentzugriff pausiert" }
        if restartRequired { return "Neustart im Chatbot erforderlich" }
        if !serverKnown { return "Serverstatus nicht eindeutig" }
        if running { return "Dokumentzugriff aktiv" }
        if binding == .conflict { return "Client-Zuordnung prüfen" }
        if binding == .notRegistered { return "Noch nicht im Chatbot eingetragen" }
        return "Wartet auf Chatbot"
    }
    public var serverLabel: String {
        if !serverKnown { return "Laufzeit nicht zugeordnet" }
        return running ? "Server aktiv" : "Wartet auf Chatbot"
    }
    public var accessLabel: String { profile.enabled ? "Dokumentzugriff freigegeben" : "Dokumentzugriff gesperrt" }
    public var tone: Tone {
        if !profile.enabled { return .neutral }
        if restartRequired || binding == .conflict { return .attention }
        if !serverKnown { return .unknown }
        return running ? .good : .neutral
    }
    public var symbol: String {
        if !profile.enabled { return "lock.shield" }
        if restartRequired { return "arrow.clockwise.circle" }
        if !serverKnown || binding == .conflict { return "exclamationmark.circle" }
        return running ? "checkmark.shield" : "clock"
    }
    public var explanation: String {
        if !profile.enabled { return "Dein Chatbot erhält aktuell keine Dokumentinhalte. Ein Server oder lokale Importe können trotzdem weiterlaufen." }
        if restartRequired { return "Der laufende Server stammt aus einem anderen oder nicht eindeutig erkennbaren Build. Prüfe zuerst den Softwarestand unter Einstellungen und starte danach die Vauldy-Verbindung im Chatbot neu. Deine Freigaben bleiben erhalten." }
        if !serverKnown { return "Mindestens ein Server meldet seine Verbindung noch nicht eindeutig. Starte ältere Verbindungen im Chatbot neu." }
        if running { return requestObserved ? "Der Server läuft und hat eine lokale MCP-Anfrage empfangen. Eine sichtbare Antwort im externen Chat ist damit nicht nachgewiesen. Nur die ausdrücklich ausgewählten Dokumente sind zugänglich." : "Der Server läuft für diese Verbindung. Eine MCP-Werkzeuganfrage aus dem Chatbot wurde noch nicht beobachtet." }
        if binding == .conflict { return "Der Chatbot-Eintrag verweist auf eine andere Verbindung. Bestehende Einträge wurden nicht überschrieben." }
        if binding == .notRegistered { return "Die Freigabe ist gespeichert. Trage diese Verbindung noch in deinem Chatbot ein." }
        return "Eine Verbindung wird vom Chatbot gestartet. Dieser Bereitschaftszustand ist kein Fehler." }
}
