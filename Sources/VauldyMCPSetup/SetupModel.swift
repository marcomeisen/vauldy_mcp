import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VauldyCore
import VauldyDemoDocuments
import VauldyMCPRuntime

@MainActor
final class SetupModel: ObservableObject {
    @Published var section: MCPSetupSection = .overview
    @Published var activeConnectionID: UUID?
    @Published var instances: [MCPServerInstance]?
    @Published var bindings: [UUID: MCPClientBinding] = [:]
    @Published var resolvedClients: [UUID: MCPDesktopClient] = [:]
    @Published var software: MCPSoftwareStatus?
    @Published var managementError = ""
    @Published var documentSearch = ""
    @Published var documentFilter: SetupDocumentFilter = .all
    @Published var showingSetup = false
    @Published var setupStep = 0
    @Published var resumeCandidate: MCPAccessProfile?
    @Published var diagnosisProfile: MCPAccessProfile?
    @Published var probeResults: [UUID: MCPLocalProbeResult] = [:]
    @Published var probeErrors: [UUID: String] = [:]
    @Published var probing: Set<UUID> = []
    @Published var accessChanges: Set<UUID> = []
    @Published var previewURL: URL?
    var monitoring: Task<Void, Never>?
    var refreshingManagement = false
    var lastInstalledStamp: Date?
    var lastFoldersRefresh = Date.distantPast
    var lastBindingsCheck = Date.distantPast
    private var loadGeneration = UUID()

    @Published var documents: [VaultDocument] = []
    @Published var selected: Set<UUID> = []
    @Published var vaultURL: URL?
    @Published var acknowledged = false
    @Published var busy = false
    @Published var message = ""
    @Published var failure = false
    @Published var configuration: URL?
    @Published var connections: [MCPAccessProfile] = []
    @Published var clientSelection = "chatgpt"
    @Published var registrationMessage = ""
    let registration: MCPClientRegistration
    @Published var connectionName = ""
    @Published var importProgress: LocalImportProgress?
    @Published var importing = false
    @Published var watchedFolders: [LocalWatchedFolder] = []
    @Published var watchScans: [LocalWatchScanStatus] = []
    @Published var watchRunning = false
    @Published var watchRecursive = false
    @Published var watchFailure = ""
    @Published var statusMenuFailure = ""
    private var importTask: Task<Void, Never>?
    var editing: MCPAccessProfile?
    var localStore: LocalDocumentStore { LocalDocumentStore(root: installation.root.appendingPathComponent("vault", isDirectory: true)) }

    var activeConnection: MCPAccessProfile? { connections.first { $0.connectionID == activeConnectionID } }
    var localExecutable: URL? { Bundle.main.resourceURL?.appendingPathComponent("vauldy-local") }
    var bundledBinary: URL? { Bundle.main.resourceURL?.appendingPathComponent("vauldy-mcp") }
    var bundledStatusApp: URL? { Bundle.main.resourceURL?.appendingPathComponent(MCPStatusApp.bundleName) }
    let installation: MCPInstallation

    init() {
        // Explicit developer/UI verification destination; never infer it from the user's archive.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--setup-root"), index + 1 < args.count, args[index + 1].hasPrefix("/") {
            let root = URL(fileURLWithPath: args[index + 1])
            installation = MCPInstallation(root: root)
            registration = MCPClientRegistration(home: root.appendingPathComponent("test-client-home"))
        } else { installation = MCPInstallation(); registration = MCPClientRegistration() }
        refreshConnections()
        showStatusMenu()
        startMonitoring()
    }
    func refreshConnections() {
        do {
            connections = try installation.profiles().sorted { $0.connectionName.localizedStandardCompare($1.connectionName) == .orderedAscending }
            if activeConnectionID == nil { activeConnectionID = connections.first?.connectionID }
            managementError = ""
        } catch { managementError = "Die gespeicherten Verbindungen konnten nicht gelesen werden. Bestehende Freigaben wurden nicht verändert." }
    }

    func showStatusMenu() {
        do {
            guard let binary = Bundle.main.resourceURL?.appendingPathComponent("vauldy-mcp") else { throw MCPAccessError.configuration }
            try MCPStatusApp.launch(root: installation.root, beside: binary)
            statusMenuFailure = ""
        } catch { statusMenuFailure = "Die Menüleistenanzeige konnte nicht gestartet werden. Bitte das vollständige MCP-Paket verwenden." }
    }

    private var localWorker: LocalImportWorker? {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("vauldy-local") else { return nil }
        return LocalImportWorker(store: localStore, executable: executable)
    }

    func refreshWatchedFolders(resume: Bool = false) async {
        do {
            watchedFolders = try await LocalWatchedFolderStore(store: localStore).folders()
            if let worker = localWorker {
                if resume && watchedFolders.contains(where: \.enabled) { try await worker.start() }
                watchRunning = try await worker.status().running
                watchScans = try await worker.watchStatus()
            }
            if !busy && vaultURL == localStore.snapshotURL { try await refreshLocalDocuments() }
            watchFailure = ""
        } catch { watchFailure = (error as? LocalizedError)?.errorDescription ?? "Die Ordnerüberwachung ist nicht verfügbar." }
    }

    func chooseWatchedFolders() {
        let panel = NSOpenPanel()
        panel.title = "Ordner beobachten"
        panel.message = "Vorhandene und neue PDFs und Bilder werden lokal importiert. Neue Dokumente benötigen weiterhin deine ausdrückliche Chatbot-Freigabe."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, recursive = watchRecursive
        busy = true
        Task {
            do {
                try await LocalWatchedFolderStore(store: localStore).add(urls, recursive: recursive)
                guard let worker = localWorker else { throw LocalImportError.storageUnavailable }
                try await worker.start()
                try await refreshLocalDocuments()
                message = "Ordner gespeichert. Vorhandene und neue Dokumente werden lokal importiert; bitte anschließend einzeln für MCP freigeben."
                failure = false
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Ordner konnten nicht gespeichert werden.") }
            busy = false
            await refreshWatchedFolders()
        }
    }

    func changeWatchedFolder(_ folder: LocalWatchedFolder, remove: Bool = false) {
        busy = true
        Task {
            do {
                let registry = LocalWatchedFolderStore(store: localStore)
                if remove { try await registry.remove(folder.id) }
                else {
                    try await registry.setEnabled(!folder.enabled, id: folder.id)
                    if !folder.enabled { try await localWorker?.start() }
                }
                message = remove ? "Ordner entfernt. Bereits importierte Dokumente bleiben erhalten." : "Ordnerüberwachung geändert. Bereits gestartete Importe werden abgeschlossen."
                failure = false
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Ordnerüberwachung konnte nicht geändert werden.") }
            busy = false
            await refreshWatchedFolders()
        }
    }

    func watchLabel(_ folder: LocalWatchedFolder) -> String {
        guard folder.enabled else { return "Pausiert" }
        guard watchRunning else { return "Importdienst gestoppt · zum Fortsetzen starten" }
        guard let scan = watchScans.first(where: { $0.folderID == folder.id }) else { return "Wartet auf erste Prüfung" }
        switch scan.issue {
        case .unavailable: return "Ordner nicht erreichbar · Zugriff prüfen"
        case .scanLimit: return "Zu viele Einträge · höchstens 20.000 pro Ordner"
        case .importFailed: return "Ein Import ist fehlgeschlagen · wird erneut geprüft"
        case nil: return "Aktiv · zuletzt geprüft: \(scan.scannedAt.formatted(date: .omitted, time: .standard))"
        }
    }

    func chooseVault() {
        let panel = NSOpenPanel()
        panel.title = "Vauldy-Bestand auswählen"
        panel.message = "Wähle einen kompatiblen documents.json-Snapshot. Er wird ausschließlich gelesen."
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileVaultSnapshotSource.defaultVaultURL().deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }


    func useExample() {
        do {
            let directory = installation.root.appendingPathComponent("example", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("MCP-Beispiel.pdf")
            if !FileManager.default.fileExists(atPath: url.path) {
                try ExampleDocument.writePDF(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            importFiles([url])
        } catch { showError("Das lokale PDF-Beispiel konnte nicht angelegt werden.") }
    }

    func chooseImports() {
        let panel = NSOpenPanel()
        panel.title = "Dokumente lokal importieren"
        panel.message = "PDFs und Bilder werden in den eigenen lokalen Bestand kopiert und auf diesem Mac gelesen. Der Import erteilt keine Chatbot-Freigabe."
        panel.allowedContentTypes = [UTType.pdf, .png, .jpeg, .tiff, .heic]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func openLocalStore() {
        busy = true
        Task {
            do {
                try await localStore.recoverInterrupted()
                try await refreshLocalDocuments()
                message = "Eigenständiger lokaler Bestand geladen. Neue Importe sind zunächst nicht für MCP freigegeben."
                failure = false
            } catch { showError((error as? LocalImportError)?.errorDescription ?? "Der lokale Bestand ist nicht lesbar.") }
            busy = false
        }
    }

    func importFiles(_ urls: [URL], retry: UUID? = nil) {
        guard !importing else { return }
        importing = true; failure = false; configuration = nil
        message = "Originale und Texterkennung bleiben auf diesem Mac."
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("vauldy-local") else {
            importing = false; showError("Das lokale Importprogramm fehlt im Paket."); return
        }
        let service = LocalImportWorker(store: localStore, executable: executable)
        importTask = Task { [self] in
            var completed = 0; var review = 0; var failed = 0; var reused = 0
            var analyzed = 0; var analysisReview = 0
            var lastError: String?
            let updates: @Sendable (LocalImportProgress) -> Void = { [weak self] update in
                Task { @MainActor in if self?.importing == true { self?.importProgress = update } }
            }
            do {
                for index in 0..<(retry == nil ? urls.count : 1) {
                    try Task.checkCancellation()
                    do {
                        let outcome: LocalImportOutcome
                        if let retry { outcome = try await service.retry(documentID: retry, fresh: true, progress: updates) }
                        else { outcome = try await service.importFile(urls[index], progress: updates) }
                        if outcome.analysisStatus == "completed" { analyzed += 1 } else { analysisReview += 1 }
                        if outcome.reusedOriginal { reused += 1 }
                        if outcome.state == .completed { completed += 1 }
                        else if outcome.state == .partial { review += 1 }
                        else { failed += 1 }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        failed += 1
                        lastError = (error as? LocalImportError)?.errorDescription ?? "Ein Dokument konnte nicht verarbeitet werden."
                    }
                }
                message = "Text erfasst: \(completed) · OCR prüfen: \(review) · Nicht abgeschlossen: \(failed) · Bereits vorhanden: \(reused). Basisanalyse vorhanden: \(analyzed) · Basisanalyse prüfen: \(analysisReview). Neue Dokumente bitte unten ausdrücklich freigeben."
                if let lastError { message += " " + lastError }
                failure = failed > 0 || review > 0 || analysisReview > 0
            } catch {
                message = "Import abgebrochen. Gesicherte Originale bleiben erhalten; ausstehende Texterkennung kann erneut gestartet werden."
            }
            do { try await refreshLocalDocuments() }
            catch { showError((error as? LocalImportError)?.errorDescription ?? "Der Bestand konnte nicht neu geladen werden.") }
            importProgress = nil; importing = false; importTask = nil
        }
    }

    func stopWorker() {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("vauldy-local") else { return }
        Task {
            do {
                try await LocalImportWorker(store: localStore, executable: executable).stop()
                message = "Der lokale Worker beendet sich nach dem laufenden Auftrag. Auch die Ordnerüberwachung stoppt bis zum nächsten Start."
            } catch { showError("Der lokale Worker konnte nicht gestoppt werden.") }
        }
    }
    func cancelImport() {
        importTask?.cancel()
        message = "Abbruch angefordert. Vauldy wartet auf das Ende der laufenden System-Texterkennung; Originale bleiben erhalten."
    }

    func refreshLocalDocuments() async throws {
        let loaded = try await localStore.documents()
        if vaultURL != localStore.snapshotURL { editing = nil; selected = []; acknowledged = false }
        vaultURL = localStore.snapshotURL
        documents = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        selected.formIntersection(Set(loaded.map(\.id)))
    }

    func importLabel(_ document: VaultDocument) -> String {
        guard let metadata = document.localImport else { return document.isSearchable ? "" : "noch nicht durchsuchbar" }
        switch metadata.state {
        case .completed: return "Text erfasst · \(SetupText.pages(document.pageCount ?? 0))"
        case .partial: return "Text teilweise erfasst · bitte prüfen"
        case .queued: return "Texterkennung ausstehend"
        case .recognizing: return "Texterkennung läuft"
        case .failed, .interrupted, .cancelled: return metadata.error?.errorDescription ?? "Texterkennung erneut starten"
        }
    }

    func load(_ url: URL, profile: MCPAccessProfile? = nil) {
        let generation = UUID(); loadGeneration = generation
        busy = true; message = "Bestand wird lokal gelesen …"; failure = false
        configuration = nil; acknowledged = false; registrationMessage = ""
        Task {
            do {
                let loaded = try await Task.detached { try FileVaultSnapshotSource(fileURL: url).loadDocuments() }.value
                guard generation == loadGeneration else { return }
                documents = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                vaultURL = url
                editing = profile
                selected = profile?.allowedDocumentIDs.intersection(Set(loaded.map(\.id))) ?? []
                if let profile { connectionName = profile.connectionName }
                message = "\(SetupText.documents(loaded.count)) lokal gefunden. Freigaben gelten nur für ausgewählte Dokumente; neue Importe bleiben gesperrt."
            } catch {
                guard generation == loadGeneration else { return }
                documents = []; vaultURL = nil; selected = []; editing = nil
                showError("Der Bestand ist nicht lesbar. Bitte die documents.json auswählen oder zuerst das Beispiel verwenden. Es wurde nichts verändert.")
            }
            busy = false
        }
    }

    func copyConfiguration() {
        guard let configuration, let text = try? String(contentsOf: configuration, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        message = "Konfiguration kopiert. Sie enthält lokale Programmpfade, aber keine Dokumentinhalte oder Zugangsdaten."
    }

    func showError(_ value: String) { message = value; failure = true }
}
