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
    let localExecutable: URL
    @Published var profile: MCPAccessProfile
    let updatesChatGPT: Bool
    var createConnection: (@MainActor (MCPAccessProfile, String) async throws -> Void)?
    @Published var onlyUnshared = false
    @Published var localChoices: [UUID: String] = [:]
    private static var lastOverview: (url: URL, report: MCPInventoryQualityReport)?
    @Published var disclosureText: String?
    func showDisclosure(_ id: UUID) {
        let url = snapshotURL
        run("Chatbot-Vorschau wird lokal vorbereitet …") { [self] in
            let text = try await Task.detached {
                guard let document = try LocalInventoryFingerprint.selectedDocuments(url, ids: [id]).first else { throw MCPAccessError.unavailable }
                return try ReadOnlyMCPRuntime.disclosurePreview(document)
            }.value
            try Task.checkCancellation()
            disclosureText = text.isEmpty ? "Kein lesbarer Text verfügbar." : text
        }
    }
    var documentFingerprints: [UUID: String] = [:]
    var isNewConnection: Bool { createConnection != nil }
    var snapshotURL: URL { LocalDocumentStore.resolvedSnapshotURL(URL(fileURLWithPath: profile.vaultPath)) }
    var usesLocalStore: Bool { snapshotURL == store.snapshotURL }
    func currentReport(verifyOriginalIDs: Set<UUID>? = nil, grantScope: Set<UUID>? = nil) async throws -> MCPInventoryQualityReport {
        if usesLocalStore {
            return try await MCPInventoryQualityService(store: store).report(verifyOriginalIDs: verifyOriginalIDs, grantScope: grantScope,
                onOriginalCheck: { [weak self] index, total, name in
                    Task { @MainActor in
                        guard let self, self.busy, self.committing else { return }
                        self.reportCheckDone = index - 1
                        self.reportCheckTotal = total
                        self.currentOriginalName = name
                        self.currentOriginalStartedAt = Date()
                        self.progress = "Original \(index) von \(total) prüfen · \(name)"
                    }
                }) { [weak self] done, total in
                if done == total || done % 20 == 0 {
                    Task { @MainActor in
                        guard let self, self.busy, !self.reportPreparing else { return }
                        self.reportCheckDone = done
                        self.reportCheckTotal = total
                        if done == total {
                            self.currentOriginalName = ""; self.currentOriginalStartedAt = nil
                            self.progress = "\(done) Originale geprüft · Freigabe wird gespeichert …"
                        }
                    }
                }
            }
        }
        return try await MCPInventoryQualityService.archiveReport(at: snapshotURL, verifyOriginalIDs: verifyOriginalIDs, grantScope: grantScope)
    }
    var selectionChanged: Bool { selected != profile.allowedDocumentIDs }
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
    @Published var busy = false
    @Published var committing = false
    @Published var progress = ""
    @Published var reportCheckDone = 0
    @Published var reportCheckTotal = 0
    @Published var reportPreparing = false
    @Published var currentOriginalName = ""
    @Published var currentOriginalStartedAt: Date?
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
        selected = profile.allowedDocumentIDs
        localExecutable = executable
        store = .init(root: installation.root.appendingPathComponent("vault"))
        worker = .init(store: store, executable: executable, watchFolders: false)
    }
    var reviewCount: Int { report.map { selected.subtracting(profile.allowedDocumentIDs).intersection($0.selectionReviewIDs).count } ?? 0 }
    var addedCount: Int { selected.subtracting(profile.allowedDocumentIDs).count }
    var removedCount: Int { profile.allowedDocumentIDs.subtracting(selected).count }
    var visibleRows: [MCPInventoryQualityReport.Row] {
        report?.rows.filter { row in
            (!onlyUnshared || !profile.allowedDocumentIDs.contains(row.id))
                && (search.isEmpty || row.title.localizedCaseInsensitiveContains(search))
        }.sorted { left, right in
            let leftRank = profile.allowedDocumentIDs.contains(left.id) ? 2 : left.selectable ? 0 : 1
            let rightRank = profile.allowedDocumentIDs.contains(right.id) ? 2 : right.selectable ? 0 : 1
            return leftRank == rightRank ? left.title.localizedStandardCompare(right.title) == .orderedAscending : leftRank < rightRank
        } ?? []
    }
    var visibleNewEligibleIDs: Set<UUID> {
        let reviewIDs = report?.selectionReviewIDs ?? []
        return Set(visibleRows.filter {
            $0.selectable && !reviewIDs.contains($0.id) && !profile.allowedDocumentIDs.contains($0.id)
        }.map(\.id))
    }
    var visibleReviewSelectableIDs: Set<UUID> {
        let reviewIDs = report?.selectionReviewIDs ?? []
        return Set(visibleRows.filter {
            $0.selectable && reviewIDs.contains($0.id) && !profile.allowedDocumentIDs.contains($0.id)
        }.map(\.id))
    }
    var visibleReviewKeptLocalCount: Int { visibleReviewSelectableIDs.count(where: isKeptLocal) }
    var newSelectableCount: Int {
        report?.rows.count { $0.selectable && !profile.allowedDocumentIDs.contains($0.id) } ?? 0
    }
    var unavailableNewCount: Int {
        report?.rows.count { !$0.selectable && !profile.allowedDocumentIDs.contains($0.id) } ?? 0
    }
    var newlySelectedIDs: Set<UUID> { selected.subtracting(profile.allowedDocumentIDs) }
    var selectedOutsideVisibleRowsCount: Int {
        newlySelectedIDs.subtracting(Set(visibleRows.map(\.id))).count
    }
    func selectAllVisibleEligible() {
        guard !busy else { return }
        selected.formUnion(visibleNewEligibleIDs)
        acknowledged = false; acknowledgedReview = false
    }
    func selectAllVisibleReview() {
        guard !busy else { return }
        selected.formUnion(visibleReviewSelectableIDs)
        acknowledged = false; acknowledgedReview = false
    }
    func clearNewSelection() {
        guard !busy else { return }
        selected.subtract(newlySelectedIDs)
        acknowledged = false; acknowledgedReview = false
    }
    func loadSources() async {
        do { sources = try await LocalWatchedFolderStore(store: store).folders(); sourceIDs = Set(sources.filter(\.enabled).map(\.id)) }
        catch { self.error = error.localizedDescription }
    }
    func chooseSources() {
        let panel = NSOpenPanel(); panel.title = "Originalordner auswählen"
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
        let currentProfile = isNewConnection ? profile : try FileMCPProfileSource(url: installation.profileURL(profile.connectionID)).load()
        guard currentProfile.vaultPath == profile.vaultPath else { throw LocalInventoryError.wrongStore }
        profile = currentProfile
        report = nil; acknowledged = false; acknowledgedReview = false
        reportCheckDone = 0; reportCheckTotal = 0; reportPreparing = false
        currentOriginalName = ""; currentOriginalStartedAt = nil
        reportPreparing = true
        progress = "Freigabeübersicht wird vorbereitet …"
        let digest = try LocalInventoryFingerprint.snapshot(snapshotURL)
        let value: MCPInventoryQualityReport
        if let cached = Self.lastOverview, cached.url == snapshotURL, cached.report.snapshotDigest == digest {
            value = cached.report
        } else {
            if usesLocalStore { value = try await MCPInventoryQualityService(store: store).overview() }
            else { value = try await currentReport(verifyOriginalIDs: []) }
            Self.lastOverview = (snapshotURL, value)
        }
        documentFingerprints = Dictionary(uniqueKeysWithValues: value.rows.map { ($0.id, $0.localFingerprint) })
        report = value
        if !isNewConnection { localChoices = try MCPLocalDocumentChoices(installation: installation).load(for: profile.connectionID) }
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
        run("Dokumente und Originalzugriff werden geprüft …") { [self] in try await makeReport() }
    }
    func isKeptLocal(_ id: UUID) -> Bool {
        guard let fingerprint = documentFingerprints[id] else { return false }
        return localChoices[id] == "*" || localChoices[id] == fingerprint
    }
    func keepLocal(_ id: UUID) {
        guard !busy, !isNewConnection, !profile.allowedDocumentIDs.contains(id),
              let fingerprint = documentFingerprints[id] else { return }
        do {
            try MCPLocalDocumentChoices(installation: installation).keepLocal([id: fingerprint], for: profile)
            localChoices = try MCPLocalDocumentChoices(installation: installation).load(for: profile.connectionID)
            selected.remove(id)
            acknowledged = false
            didUpdate(nil)
        } catch { self.error = error.localizedDescription }
    }
    func preview(_ id: UUID) {
        run("Original wird geöffnet …") { [self] in
            previewAccess?.close()
            let access = try await store.openOriginal(for: id)
            previewAccess = access; previewURL = access.url
        }
    }
    func setSelected(_ value: Bool, id: UUID) {
        guard !busy, !value || profile.allowedDocumentIDs.contains(id) || report?.selectableIDs.contains(id) == true else { return }
        if value { selected.insert(id) } else { selected.remove(id) }
        acknowledged = false; acknowledgedReview = false
    }
    func prepareApproval() {
        guard !busy, acknowledged, let report, reviewCount == 0 || acknowledgedReview else { return }
        confirm(.init(profile: profile, ids: selected, digest: LocalInventoryFingerprint.grantDigest(Dictionary(uniqueKeysWithValues: report.rows.filter { newlySelectedIDs.contains($0.id) }.map { ($0.id, $0.version) })), acknowledgedReview: acknowledgedReview))
    }
    func confirm(_ frozen: InventoryGrantApproval) {
        run("Bestand und bestätigte Freigabe werden erneut geprüft …") { [self] in
            committing = true; defer { committing = false }
            let newlyGranted = frozen.ids.subtracting(frozen.profile.allowedDocumentIDs)
            reportPreparing = false; reportCheckDone = 0; reportCheckTotal = newlyGranted.count
            currentOriginalName = ""; currentOriginalStartedAt = nil
            progress = newlyGranted.isEmpty ? "Bestand und Freigabe werden gespeichert …" : "Ausgewählte Originale prüfen · 0 von \(newlyGranted.count)"
            let current = try await currentReport(verifyOriginalIDs: newlyGranted, grantScope: newlyGranted)
            guard current.snapshotDigest == frozen.digest else { throw LocalInventoryError.changed }
            try current.validateSelection(frozen.ids, acknowledgedReview: frozen.acknowledgedReview, preserving: frozen.profile.allowedDocumentIDs)
            if let createConnection {
                var created = frozen.profile
                try created.applySelection(frozen.ids, acknowledged: true, newConnection: true)
                try await createConnection(created, frozen.digest)
                updatedAccessEnabled = created.enabled
                completed = true
                didUpdate(nil)
                return
            }
            let state: RelayUIState?
            if updatesChatGPT {
                let response = try await RelayUIControl(installation: installation).request(.init(profileID: profile.connectionID,
                    revision: frozen.profile.revision, profileFingerprint: try frozen.profile.disclosureFingerprint(), documentIDs: frozen.ids, snapshotDigest: frozen.digest, nativeVerification: current.nativeVerification,
                    acknowledgedReview: frozen.acknowledgedReview))
                if let problem = response.error { didUpdate(response.state); throw InventoryWorkflowProblem(message: problem) }
                state = response.state
            } else {
                let update = {
                    try LocalInventoryFingerprint.checkGrant(frozen.digest, url: self.snapshotURL, ids: newlyGranted)
                    return try self.installation.updateSelection(frozen.ids, for: frozen.profile.connectionID, expectedRevision: frozen.profile.revision,
                        acknowledgedDisclosure: true, expectedFingerprint: frozen.profile.disclosureFingerprint())
                }
                if usesLocalStore { _ = try store.withGrant(frozen.digest, ids: newlyGranted, perform: update) }
                else { _ = try update() }
                state = nil
            }
            updatedAccessEnabled = try FileMCPProfileSource(url: installation.profileURL(profile.connectionID)).load().enabled
            completed = true; didUpdate(state)
        }
    }

}
struct InventoryWorkflowProblem: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SetupModel {
    func startInventoryWorkflow(profile requested: MCPAccessProfile? = nil, newDocuments: Bool = false, sources: Bool = false) {
        guard !busy, !importing, let target = requested ?? activeConnection, let executable = localExecutable else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var paired = false
                if target.connectionKind == .oauth {
                    let response = try await relayControl.request(.init(.status))
                    relayState = response.state; relayRunning = response.state.running
                    if response.state.keychainNeedsApproval {
                        section = .oauth
                        throw InventoryWorkflowProblem(message: "Bestätige unter Verbindungen den Schlüsselbundzugriff, damit Vauldy die zugehörige ChatGPT-Freigabe sicher aktualisieren kann.")
                    }
                    if let error = response.error { throw InventoryWorkflowProblem(message: error) }
                    paired = response.state.paired && response.state.profileID == target.connectionID
                    if paired && !response.state.supportsGrantUpdate {
                        section = .settings
                        throw InventoryWorkflowProblem(message: "Aktualisiere unter Einstellungen die Vauldy-Software, um diese Freigabe zu bearbeiten.")
                    }
                }
                let workflow = InventoryWorkflowModel(installation: installation, executable: executable, profile: target,
                    updatesChatGPT: paired) { [weak self] state in
                        guard let self else { return }
                        if let state { self.relayState = state; self.relayRunning = state.running }
                        self.refreshConnections()
                        self.refreshLocalChoices()
                        if self.activeConnectionID == target.connectionID,
                           let updated = self.activeConnection {
                            self.load(URL(fileURLWithPath: updated.vaultPath), profile: updated)
                        }
                    }
                workflow.onlyUnshared = newDocuments
                workflow.step = sources ? 0 : 1
                inventoryWorkflow = workflow
                if !sources { workflow.reportOnly() }
            } catch { showError(error.localizedDescription) }
        }
    }
}
