import AppKit
import SwiftUI
import VauldyCore
import VauldyMCPRuntime
import VauldyRelay

struct InventoryGrantApproval {
    let profile: MCPAccessProfile
    let ids: Set<UUID>
    let digest: String
    let acknowledgedReview: Bool
}

@MainActor
final class InventoryWorkflowModel: ObservableObject, Identifiable {
    let id = UUID()
    let installation: MCPInstallation
    let store: LocalDocumentStore
    let worker: LocalImportWorker
    @Published var profile: MCPAccessProfile
    let updatesChatGPT: Bool
    let didUpdate: @MainActor (RelayUIState?) -> Void
    @Published var step = 0
    @Published var sources: [LocalWatchedFolder] = []
    @Published var sourceIDs: Set<UUID> = []
    @Published var recursive = true
    @Published var plan: LocalInventoryPlan?
    @Published var importIssues: [LocalInventoryPlan.Issue] = []
    @Published var report: MCPInventoryQualityReport?
    @Published var selected: Set<UUID> = []
    @Published var acknowledged = false
    @Published var acknowledgedReview = false
    @Published var approval: InventoryGrantApproval?
    @Published var busy = false
    @Published var committing = false
    @Published var progress = ""
    @Published var error = ""
    @Published var completed = false
    @Published var updatedAccessEnabled = false
    @Published var search = ""
    @Published var previewURL: URL?
    var previewAccess: LocalOriginalAccess?
    var task: Task<Void, Never>?

    init(installation: MCPInstallation, executable: URL, profile: MCPAccessProfile, updatesChatGPT: Bool,
         didUpdate: @escaping @MainActor (RelayUIState?) -> Void) {
        self.installation = installation; self.profile = profile; self.updatesChatGPT = updatesChatGPT; self.didUpdate = didUpdate
        store = .init(root: installation.root.appendingPathComponent("vault"))
        worker = .init(store: store, executable: executable, watchFolders: false)
    }
    var reviewCount: Int { report.map { selected.intersection($0.reviewIDs).count } ?? 0 }
    var addedCount: Int { selected.subtracting(profile.allowedDocumentIDs).count }
    var removedCount: Int { profile.allowedDocumentIDs.subtracting(selected).count }
    var visibleRows: [MCPInventoryQualityReport.Row] {
        report?.rows.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } ?? []
    }
    func loadSources() async {
        do { sources = try await LocalWatchedFolderStore(store: store).folders(); sourceIDs = Set(sources.filter(\.enabled).map(\.id)) }
        catch { self.error = error.localizedDescription }
    }
    func chooseSources() {
        let panel = NSOpenPanel(); panel.title = "Quellordner für den Bestandsabgleich"
        panel.message = "Originaldateien bleiben unverändert. Dieser einmalige Abgleich richtet keine Ordnerüberwachung ein."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            let service = LocalInventoryReconciler(store: store)
            for url in panel.urls {
                let folder = try service.source(url, recursive: recursive)
                if let prior = sources.firstIndex(where: { $0.path == folder.path }) { sourceIDs.remove(sources[prior].id); sources.remove(at: prior) }
                sources.append(folder); sourceIDs.insert(folder.id)
            }
            plan = nil; error = ""
        } catch { self.error = error.localizedDescription }
    }
    func run(_ message: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; progress = message; error = ""
        task = Task {
            defer { busy = false; task = nil; progress = "" }
            do { try await operation() }
            catch is CancellationError { self.error = "Abgebrochen. Bereits erfasste Dokumente bleiben erhalten; die Freigabe wurde nicht erweitert." }
            catch { self.error = error.localizedDescription }
        }
    }
    func inspect() {
        let chosen = sources.filter { sourceIDs.contains($0.id) }
        run("Quellen werden gelesen und mit dem Bestand verglichen …") { [self] in
            plan = try await LocalInventoryReconciler(store: store).inspect(chosen)
        }
    }
    func makeReport() async throws {
        let priorSelection = report == nil ? nil : selected
        let currentProfile = try FileMCPProfileSource(url: installation.profileURL(profile.connectionID)).load()
        guard URL(fileURLWithPath: currentProfile.vaultPath).standardizedFileURL == store.snapshotURL else { throw LocalInventoryError.wrongStore }
        profile = currentProfile
        report = nil; acknowledged = false; acknowledgedReview = false; approval = nil
        let observed = try await MCPInventoryQualityService(store: store).report { [weak self] done, total in
            if done == total || done % 20 == 0 { Task { @MainActor in self?.progress = "Originalzugriff prüfen: \(done) von \(total)" } }
        }
        let states = Dictionary(uniqueKeysWithValues: observed.rows.compactMap { row in row.original.map { (row.id, $0) } })
        let digest = try await store.recordOriginalVerification(states, expectedDigest: observed.snapshotDigest)
        let value = try await MCPInventoryQualityService(store: store).report(using: .init(snapshotDigest: digest,
            checkedAt: observed.createdAt, verifiedIDs: observed.nativeVerification.verifiedIDs))
        report = value
        selected = (priorSelection ?? profile.allowedDocumentIDs).intersection(value.eligibleIDs)
        step = 1
    }
    func importAndReport() {
        guard let plan else { return }
        run("Neue und geänderte Dateien werden lokal erfasst …") { [self] in
            let result = try await LocalInventoryReconciler(store: store).apply(plan, worker: worker) { [weak self] value in
                Task { @MainActor in self?.progress = value.stage }
            }
            importIssues = result.issues
            try await makeReport()
        }
    }
    func reportOnly() {
        run("Qualität des vorhandenen Bestands wird geprüft …") { [self] in try await makeReport() }
    }
    func preview(_ id: UUID) {
        run("Original wird geöffnet …") { [self] in
            previewAccess?.close()
            let access = try await store.openOriginal(for: id)
            previewAccess = access; previewURL = access.url
        }
    }
    func retry(_ id: UUID) {
        run("Text wird am Original erneut gelesen …") { [self] in
            _ = try await worker.retry(documentID: id, fresh: true)
            try await makeReport()
        }
    }
    func setSelected(_ value: Bool, id: UUID) {
        guard !busy, report?.eligibleIDs.contains(id) == true else { return }
        if value { selected.insert(id) } else { selected.remove(id) }
        acknowledged = false; acknowledgedReview = false
    }
    func selectReady() { selected = report?.readyIDs ?? []; acknowledged = false; acknowledgedReview = false }
    func selectReadable() { selected = report?.eligibleIDs ?? []; acknowledged = false; acknowledgedReview = false }
    func prepareApproval() {
        guard !busy, acknowledged, let report, reviewCount == 0 || acknowledgedReview else { return }
        approval = .init(profile: profile, ids: selected, digest: report.snapshotDigest, acknowledgedReview: acknowledgedReview)
    }
    func confirm(_ frozen: InventoryGrantApproval) {
        approval = nil
        run("Bestand und bestätigte Freigabe werden erneut geprüft …") { [self] in
            committing = true; defer { committing = false }
            let current = try await MCPInventoryQualityService(store: store).report()
            guard current.snapshotDigest == frozen.digest else { throw LocalInventoryError.changed }
            try current.validateSelection(frozen.ids, acknowledgedReview: frozen.acknowledgedReview)
            let state: RelayUIState?
            if updatesChatGPT {
                let response = try await RelayUIControl(installation: installation).request(.init(profileID: profile.connectionID,
                    revision: frozen.profile.revision, profileFingerprint: try frozen.profile.disclosureFingerprint(), documentIDs: frozen.ids, snapshotDigest: frozen.digest, nativeVerification: current.nativeVerification,
                    acknowledgedReview: frozen.acknowledgedReview))
                if let problem = response.error { didUpdate(response.state); throw InventoryWorkflowProblem(message: problem) }
                state = response.state
            } else {
                _ = try store.withUnchangedInventory(frozen.digest) {
                    try installation.updateSelection(frozen.ids, for: profile.connectionID, expectedRevision: frozen.profile.revision,
                        acknowledgedDisclosure: true, expectedFingerprint: frozen.profile.disclosureFingerprint())
                }
                state = nil
            }
            let updated = try FileMCPProfileSource(url: installation.profileURL(profile.connectionID)).load()
            updatedAccessEnabled = updated.enabled
            completed = true; didUpdate(state)
        }
    }
}
struct InventoryWorkflowProblem: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SetupModel {
    func startInventoryWorkflow() {
        guard !busy, !importing else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let response = try await relayControl.request(.init(.status))
                relayState = response.state; relayRunning = response.state.running
                refreshConnections()
                if response.state.keychainNeedsApproval {
                    relayError = response.error ?? "Bitte den Schlüsselbundzugriff bewusst bestätigen."
                    section = .oauth
                    throw InventoryWorkflowProblem(message: "Bitte zuerst unter ChatGPT & Claude den Schlüsselbundzugriff bestätigen. Die bestehende Freigabe bleibt erhalten.")
                }
                if let error = response.error { throw InventoryWorkflowProblem(message: error) }
                if response.state.paired, !response.state.supportsGrantUpdate {
                    section = .settings
                    throw InventoryWorkflowProblem(message: "Bitte zuerst unter Einstellungen die installierte MCP-Software aktualisieren. Die bestehende ChatGPT-Anmeldung und Auswahl bleiben erhalten.")
                }
                let profile: MCPAccessProfile
                if response.state.paired {
                    guard let paired = connections.first(where: { $0.connectionID == response.state.profileID }) else { throw RelayFailure.changedGrant }
                    profile = paired
                } else {
                    guard let activeConnection else { throw InventoryWorkflowProblem(message: "Bitte zuerst eine lokale Dokumentverbindung auswählen.") }
                    profile = activeConnection
                }
                guard let executable = localExecutable else { throw LocalImportError.storageUnavailable }
                let expected = installation.root.appendingPathComponent("vault/documents.json").standardizedFileURL
                guard URL(fileURLWithPath: profile.vaultPath).standardizedFileURL == expected else { throw LocalInventoryError.wrongStore }
                inventoryWorkflow = .init(installation: installation, executable: executable, profile: profile,
                    updatesChatGPT: response.state.paired && response.state.profileID == profile.connectionID) { [weak self] state in
                        if let state { self?.relayState = state; self?.relayRunning = state.running }
                        guard let self else { return }
                        self.refreshConnections()
                        if let updated = self.connections.first(where: { $0.connectionID == profile.connectionID }) {
                            self.load(URL(fileURLWithPath: updated.vaultPath), profile: updated)
                        }
                    }
            } catch { showError(error.localizedDescription) }
        }
    }
}
