import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VauldyCore
import VauldyOAuth
import VauldyRelay
import VauldyDemoDocuments
import VauldyMCPRuntime

@MainActor
final class SetupModel: ObservableObject {
    @Published var inventoryWorkflow: InventoryWorkflowModel?
    @Published var relayState = RelayUIState()
    @Published var relayProfileID: UUID?
    @Published var relayApproval: MCPAccessProfile?
    @Published var relayRunning = false
    @Published var relayError = ""
    @Published var relayAuthorizing = false
    var relayRefreshing = false
    var relayAuthorizationTask: Task<Void, Never>?
    @Published var oauthConfiguration: OAuthConfiguration?
    @Published var oauthOrigin = ""
    @Published var oauthPort = "48731"
    @Published var oauthPending: [OAuthPendingRequest] = []
    @Published var oauthConnections: [OAuthConnection] = []
    @Published var oauthProfiles: [UUID: UUID] = [:]
    @Published var oauthRunning = false
    @Published var oauthError = ""
    @Published var oauthApproval: OAuthApprovalSelection?
    @Published var section: MCPSetupSection = .overview
    @Published var activeConnectionID: UUID?
    @Published var instances: [MCPServerInstance]?
    @Published var bindings: [UUID: MCPClientBinding] = [:]
    @Published var resolvedClients: [UUID: MCPDesktopClient] = [:]
    @Published var software: MCPSoftwareStatus?
    @Published var managementError = ""
    @Published var documentSearch = ""
    @Published var documentFilter: SetupDocumentFilter = .all
    @Published var showingInstallation = false
    var connectAfterInstallation = false
    @Published var showingSetup = false
    @Published var setupStep = 0
    @Published var resumeCandidate: MCPAccessProfile?
    @Published var removalCandidate: MCPAccessProfile?
    @Published var diagnosisProfile: MCPAccessProfile?
    @Published var probeResults: [UUID: MCPLocalProbeResult] = [:]
    @Published var probeErrors: [UUID: String] = [:]
    @Published var probing: Set<UUID> = []
    @Published var accessChanges: Set<UUID> = []
    @Published var previewURL: URL?
    var previewAccess: LocalOriginalAccess?
    @Published var originalMigration: LocalOriginalMigrationPlan?
    @Published var showingOriginalMigration = false
    var monitoring: Task<Void, Never>?
    var refreshingManagement = false
    var lastInstalledStamp: Date?
    var lastFoldersRefresh = Date.distantPast
    var lastBindingsCheck = Date.distantPast
    private var loadGeneration = UUID()

    @Published var documents: [VaultDocument] = []
    @Published var selected: Set<UUID> = []
    @Published var ocrSelected: Set<UUID> = []
    @Published var editingDocumentGrants = false
    @Published var retryingOCR = false
    @Published var vaultURL: URL? { didSet { updateLocalVaultIdentity() } }
    @Published var localSnapshotURL: URL? { didSet { updateLocalVaultIdentity() } }
    @Published var isLocalVault = false
    @Published var acknowledged = false
    @Published var busy = false
    @Published var message = ""
    @Published var failure = false
    @Published var configuration: URL?
    @Published var connections: [MCPAccessProfile] = []
    @Published var clientSelection = "oauth-chatgpt"
    @Published var registrationMessage = ""
    let registration: MCPClientRegistration
    @Published var connectionName = ""
    @Published var importProgress: LocalImportProgress?
    @Published var importTotal: Int?
    @Published var importProcessed = 0
    @Published var importFileName: String?
    @Published var importCancelling = false
    @Published var importReport: SetupImportReport?
    @Published var shownImportDocumentIDs: Set<UUID>?
    private var importProgressToken: UUID?
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
        localSnapshotURL = localStore.snapshotURL
        refreshConnections()
        if FileManager.default.isExecutableFile(atPath: installation.binaryURL.path) {
            showStatusMenu()
        }
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
            if !busy && isLocalVault { try await refreshLocalDocuments() }
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
        panel.message = "Wähle documents.json oder records.sqlite aus einem geprüften lokalen Bestand. Er wird ausschließlich gelesen; bestehende Verbindungen bleiben unverändert."
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "sqlite") ?? .data]
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
        panel.prompt = "Importieren"
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
            } catch { showError((error as? LocalStoreCapacityError)?.errorDescription ?? (error as? LocalImportError)?.errorDescription ?? "Der lokale Bestand ist nicht lesbar.") }
            busy = false
        }
    }

    func importFiles(_ urls: [URL], retry: UUID? = nil, retries: [UUID] = [], folderRecursive: Bool? = nil) {
        let retryIDs = retry.map { [$0] } ?? retries
        let isRetry = !retryIDs.isEmpty
        guard !importing, isRetry || !urls.isEmpty else { return }
        guard !isRetry || isLocalVault else { return }
        let retryNames = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, documentDisplayName($0)) })
        guard let executable = localExecutable else {
            showError("Das lokale Importprogramm fehlt im Paket."); return
        }
        retryingOCR = isRetry
        importing = true; failure = false; configuration = nil
        importReport = nil; importFileName = nil; importCancelling = false
        importProcessed = 0
        importTotal = folderRecursive == nil ? (isRetry ? retryIDs.count : urls.count) : nil
        message = ""
        let service = LocalImportWorker(store: localStore, executable: executable, watchFolders: false)
        importTask = Task { [self] in
            var report = SetupImportReport(isRetry: isRetry)
            do {
                let batch: LocalFolderImportBatch?
                if let folderRecursive { batch = try await service.folderImportBatch(urls, recursive: folderRecursive) }
                else { batch = nil }
                defer { batch?.close() }
                let files = batch?.files ?? urls
                let total = isRetry ? retryIDs.count : files.count
                report.items += (batch?.unsupportedFiles ?? []).map {
                    .init(name: $0.lastPathComponent, result: .skipped, detail: "Dateityp wird nicht unterstützt.")
                }
                report.items += (batch?.unavailableFolders ?? []).map {
                    .init(name: $0.lastPathComponent, result: .unavailableFolder, detail: "Wähle den Ordner erneut aus und prüfe den Zugriff.")
                }
                importTotal = total

                for index in 0..<total {
                    try Task.checkCancellation()
                    let name = isRetry ? (retryNames[retryIDs[index]] ?? "Gespeichertes Dokument") : files[index].lastPathComponent
                    importFileName = name
                    let token = UUID()
                    importProgressToken = token
                    importProgress = nil
                    let updates: @Sendable (LocalImportProgress) -> Void = { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.importProgressToken == token else { return }
                            self.importProgress = update
                        }
                    }
                    do {
                        let outcome: LocalImportOutcome
                        if isRetry { outcome = try await service.retry(documentID: retryIDs[index], fresh: true, progress: updates) }
                        else {
                            outcome = try await service.importFile(files[index], storage: batch == nil ? .managedCopy : .referenced,
                                                                   progress: updates)
                        }
                        report.items.append(.init(name: name, outcome: outcome, isRetry: isRetry))
                    } catch is CancellationError {
                        report.items.append(.init(name: name, result: .cancelled, detail: "Der laufende Auftrag wurde abgebrochen.",
                            documentID: isRetry ? retryIDs[index] : nil))
                        throw CancellationError()
                    }
                    catch {
                        let result: SetupImportReport.Item.Result = (error as? LocalImportError) == .unsupportedFile ? .skipped : .failed
                        report.items.append(.init(name: name, result: result,
                            detail: (error as? LocalizedError)?.errorDescription ?? "Ein Dokument konnte nicht verarbeitet werden.",
                            documentID: isRetry ? retryIDs[index] : nil))
                        // A full store affects the remaining batch too; do not repeatedly reread it.
                        if error is LocalStoreCapacityError { throw error }
                    }
                    importProgressToken = nil
                    importProgress = nil
                    importProcessed += 1
                }
            } catch is CancellationError {
                report.cancelled = true
            } catch {
                report.batchError = (error as? LocalizedError)?.errorDescription ?? "Die ausgewählten Ordner konnten nicht gelesen werden."
            }
            importProgressToken = nil; importProgress = nil; importFileName = nil
            do { try await refreshLocalDocuments() }
            catch { showError((error as? LocalStoreCapacityError)?.errorDescription ?? (error as? LocalImportError)?.errorDescription ?? "Der Bestand konnte nicht neu geladen werden.") }
            if isRetry { ocrSelected.subtract(report.items.compactMap(\.documentID)) }
            importReport = report
            retryingOCR = false
            importTotal = nil; importing = false; importTask = nil; importCancelling = false
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
        guard !importCancelling, let importTask else { return }
        importCancelling = true
        importTask.cancel()
    }

    func refreshLocalDocuments() async throws {
        let loaded = try await localStore.documents()
        localSnapshotURL = localStore.snapshotURL
        if !isLocalVault { editing = nil; selected = []; acknowledged = false }
        vaultURL = localStore.snapshotURL
        documents = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        selected.formIntersection(Set(loaded.map(\.id)))
        ocrSelected.formIntersection(Set(loaded.map(\.id)))
    }

    func importLabel(_ document: VaultDocument, compact: Bool = false) -> String {
        let guidance = SetupDocumentGuidance(document)
        return compact ? guidance.textStatus : guidance.textStatus + (guidance.nextStep.map { " · " + $0 } ?? "")
    }

    func load(_ url: URL, profile: MCPAccessProfile? = nil) {
        let url = LocalDocumentStore.resolvedSnapshotURL(url)
        shownImportDocumentIDs = nil
        localSnapshotURL = localStore.snapshotURL
        let generation = UUID(); loadGeneration = generation
        busy = true; message = "Bestand wird lokal gelesen …"; failure = false
        configuration = nil; acknowledged = false; registrationMessage = ""
        Task {
            do {
                let loaded = try await Task.detached { try LocalVaultSnapshotSource(fileURL: url).loadDocuments() }.value
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
                showError("Der Bestand ist nicht lesbar. Bitte einen geprüften JSON- oder SQLite-Bestand auswählen oder zuerst das Beispiel verwenden. Es wurde nichts verändert.")
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
