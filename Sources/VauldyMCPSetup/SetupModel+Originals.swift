import AppKit
import VauldyCore

extension SetupModel {
    func chooseFolderImport() {
        let panel = sourceFoldersPanel(title: "Ordner einmal importieren")
        panel.prompt = "Importieren"
        panel.message = "Die Originaldateien bleiben an ihrem Ort. Vauldy speichert Verweise und liest die Dateien lokal. Die Ordner werden einmal durchsucht."
        let includeSubfolders = NSButton(checkboxWithTitle: "Unterordner einbeziehen", target: nil, action: nil)
        includeSubfolders.state = .on
        includeSubfolders.sizeToFit()
        panel.accessoryView = includeSubfolders
        panel.isAccessoryViewDisclosed = true
        if panel.runModal() == .OK { importFiles(panel.urls, folderRecursive: includeSubfolders.state == .on) }
    }
    private func sourceFoldersPanel(title: String) -> NSOpenPanel {
        let panel = NSOpenPanel(); panel.title = title
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        return panel
    }
    func inspectOriginalMigration() {
        let panel = sourceFoldersPanel(title: "Quellordner für bestehende Kopien auswählen")
        panel.message = "Vergleicht jede lokale Kopie vollständig mit einem erreichbaren Original. Die Prüfung verändert keine Dateien. Unterordner werden einbezogen."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls; busy = true
        Task {
            defer { busy = false }
            do {
                let plan = try await LocalOriginalMigrationService(store: localStore).inspect(sourceFolders: urls)
                originalMigration = plan
                message = "\(plan.report.eligibleDocuments) Kopien geprüft · \(plan.report.items.count - plan.report.eligibleDocuments) nicht zur Entfernung freigegeben · \(plan.report.unavailableFolders) Ordner nicht erreichbar."
                failure = plan.report.unavailableFolders > 0
                if plan.report.eligibleDocuments > 0 { showingOriginalMigration = true }
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Kopienprüfung ist fehlgeschlagen.") }
        }
    }
    func applyOriginalMigration() {
        guard let plan = originalMigration else { return }
        originalMigration = nil; busy = true
        Task {
            defer { busy = false }
            do {
                let report = try await LocalOriginalMigrationService(store: localStore).apply(plan)
                message = "\(report.referencedDocuments) Dokumente auf Originale umgestellt · \(report.copiesRemoved) geprüfte Kopien entfernt · \(report.managedBytesRemoved) Bytes freigegeben. Weitere Kopien bleiben erhalten."
                failure = report.items.contains { [.copyRetained, .recordChanged, .busy].contains($0.status) }
                try await refreshLocalDocuments()
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Die Umstellung wurde nicht abgeschlossen. Nicht geprüfte Kopien bleiben erhalten.") }
        }
    }
    func checkOriginals() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let checked = try await localStore.checkOriginals()
                let issues = checked.filter { $0.localImport?.originalState == .changed || $0.localImport?.originalState == .unavailable }.count
                try await refreshLocalDocuments()
                originalsCheckedAt = Date()
                message = "Originalzugriff geprüft: \(issues) Dokumente benötigen Prüfung. Gespeicherter Text bleibt erhalten."
                failure = issues > 0
            } catch { showError((error as? LocalizedError)?.errorDescription ?? "Der Originalzugriff konnte nicht geprüft werden.") }
        }
    }
}
