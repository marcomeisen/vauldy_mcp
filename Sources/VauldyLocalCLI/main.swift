import Foundation
import VauldyCore
import VauldyOAuth
import VauldyMCPRuntime
import VauldyDemoDocuments

@main
struct VauldyLocalCLI {
    static func main() async {
        do { try await execute(Array(CommandLine.arguments.dropFirst())) }
        catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Lokaler Vorgang fehlgeschlagen. Bitte Eingabe und Zugriffsrechte prüfen."
            FileHandle.standardError.write(Data((message + "\n").utf8)); Foundation.exit(1)
        }
    }
    static func execute(_ args: [String]) async throws {
        if args == ["--build-info"] { try output(MCPBuildInformation()); return }
        if args == ["--version"] { print("vauldy-local \(MCPBuild.version)"); return }
        if args.first?.hasPrefix("oauth-") == true {
            guard args.count >= 3, args[1] == "--root", args[2].hasPrefix("/") else { throw OAuthFailure.invalidRequest }
            let store = OAuthStore(installation: MCPInstallation(root: URL(fileURLWithPath: args[2])))
            switch args[0] {
            case "oauth-configure":
                guard args.count == 7, args[3] == "--origin", args[5] == "--port", let port = Int(args[6]) else { throw OAuthFailure.invalidRequest }
                try store.configure(OAuthConfiguration(origin: args[4], port: port))
                try output(store.configuration())
            case "oauth-pending":
                guard args.count == 3 else { throw OAuthFailure.invalidRequest }; try output(store.pendingRequests())
            case "oauth-connections":
                guard args.count == 3 else { throw OAuthFailure.invalidRequest }; try output(store.connections())
            case "oauth-approve":
                guard args.count == 9, args[3] == "--request", let id = UUID(uuidString: args[4]), args[5] == "--profile", let profile = UUID(uuidString: args[6]), args[7] == "--revision", let revision = UUID(uuidString: args[8]) else { throw OAuthFailure.invalidRequest }
                try store.approve(id, profileID: profile, expectedRevision: revision)
            case "oauth-deny":
                guard args.count == 5, args[3] == "--request", let id = UUID(uuidString: args[4]) else { throw OAuthFailure.invalidRequest }; try store.deny(id)
            case "oauth-revoke":
                guard args.count == 5, args[3] == "--connection", let id = UUID(uuidString: args[4]) else { throw OAuthFailure.invalidRequest }; try store.revoke(connectionID: id)
            case "oauth-status":
                guard args.count == 3 else { throw OAuthFailure.invalidRequest }
                struct OAuthStatus: Encodable { let running: Bool; let resource: String? }
                try output(OAuthStatus(running: OAuthServiceController(store: store).isRunning(), resource: store.configuration()?.resource))
            case "oauth-start":
                guard args.count == 3 else { throw OAuthFailure.invalidRequest }
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("vauldy-mcp-http")
                try await OAuthServiceController(store: store).start(executable: executable)
            case "oauth-stop":
                guard args.count == 3 else { throw OAuthFailure.invalidRequest }; try OAuthServiceController(store: store).stop()
            default: throw OAuthFailure.invalidRequest
            }
            return
        }
        if args.first == "update-software" || args.first == "rollback-software" {
            let allowAdHoc = args.last == "--allow-ad-hoc"
            let parameters = allowAdHoc ? Array(args.dropLast()) : args
            let rollback = parameters.first == "rollback-software"
            guard parameters.count == (rollback ? 3 : 5), parameters[1] == "--root",
                  parameters[2].hasPrefix("/") else { throw MCPAccessError.invalidArguments }
            let installer = MCPInstallation(root: URL(fileURLWithPath: parameters[2]))
            if rollback {
                let version = try installer.rollbackSoftware(allowAdHoc: allowAdHoc)
                struct RolledBack: Encodable { let rolledBack = true; let version: String; let clientRestartRequired = true }
                try output(RolledBack(version: version))
            } else {
                guard parameters[3] == "--from-app", parameters[4].hasPrefix("/") else { throw MCPAccessError.invalidArguments }
                let version = try installer.updateSoftware(fromApp: URL(fileURLWithPath: parameters[4]), allowAdHoc: allowAdHoc)
                struct Updated: Encodable { let updated = true; let version: String; let clientRestartRequired = true }
                try output(Updated(version: version))
            }
            return
        }
        if args.first == "check-connection" {
            guard args.count == 3, args[1] == "--profile", args[2].hasPrefix("/") else { throw MCPAccessError.invalidArguments }
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("vauldy-mcp")
            try output(MCPLocalProbe.run(binary: binary, profile: URL(fileURLWithPath: args[2])))
            return
        }
        if args.first == "mcp-status" || args.first == "status-menu" || args.first == "status-menu-stop" {
            guard args.count == 3, args[1] == "--root", args[2].hasPrefix("/") else { throw MCPAccessError.invalidArguments }
            let root = URL(fileURLWithPath: args[2])
            if args[0] == "status-menu-stop" {
                struct Stop: Encodable { let stopping: Bool }
                try output(Stop(stopping: MCPProcessPresence.requestMenuStop(root: root)))
            } else if args[0] == "status-menu" {
                struct Launch: Encodable { let launched: Bool }
                try output(Launch(launched: MCPStatusApp.launch(root: root, beside: URL(fileURLWithPath: CommandLine.arguments[0]))))
            } else {
                struct Status: Encodable { let runningServerCount: Int; let statusMenuRunning: Bool }
                try output(Status(runningServerCount: MCPProcessPresence.serverCount(root: root), statusMenuRunning: MCPProcessPresence.menuIsRunning(root: root)))
            }
            return
        }
        if args.first == "logs" {
            guard (args.count == 3 || (args.count == 4 && args[3] == "--verify")),
                  args[1] == "--profile", args[2].hasPrefix("/") else { throw MCPAccessError.invalidArguments }
            let entries = try MCPAuditLog(profileURL: URL(fileURLWithPath: args[2])).readVerified()
            if args.count == 4 {
                print("Prüfkette im aufbewahrten Ausschnitt gültig: \(entries.count) Einträge. Kein revisionssicherer externer Nachweis.")
            } else {
                for entry in entries.suffix(100) { try output(entry) }
            }
            return
        }
        if args.first == "connect" {
            guard (args.count == 5 || args.count == 7), args[1] == "--client",
                  let client = MCPDesktopClient(rawValue: args[2]), args[3] == "--profile", args[4].hasPrefix("/"),
                  args.count == 5 || (args[5] == "--client-home" && args[6].hasPrefix("/")) else {
                throw MCPAccessError.invalidArguments
            }
            let home = args.count == 7 ? URL(fileURLWithPath: args[6]) : FileManager.default.homeDirectoryForCurrentUser
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("vauldy-mcp")
            let changed = try MCPClientRegistration(home: home).register(client, binary: binary, profile: URL(fileURLWithPath: args[4]))
            print("\(client.title): \(changed ? "Vauldy eingetragen" : "Vauldy bereits eingerichtet"). Client bei Bedarf neu starten.")
            return
        }
        if args.count == 3, args[0] == "example", args[1] == "--output", args[2].hasPrefix("/") {
            let url = URL(fileURLWithPath: args[2])
            guard !FileManager.default.fileExists(atPath: url.path) else { throw LocalImportError.storageUnavailable }
            if url.pathExtension.lowercased() == "png" { try ExampleDocument.writePNG(to: url) }
            else if url.pathExtension.lowercased() == "pdf" { try ExampleDocument.writePDF(to: url) }
            else { throw LocalImportError.unsupportedFile }
            return
        }
        guard args.count >= 3, args[1] == "--store", args[2].hasPrefix("/") else {
            FileHandle.standardError.write(Data("Aufruf: vauldy-local storage-activate-sqlite --store /bestand --prepared /gesicherte-uebertragung --expected FINGERPRINT\n        vauldy-local storage-recover-activation --store /bestand\n        vauldy-local create-sqlite --store /neuer-bestand\n        vauldy-local import --store /bestand /datei.pdf […]\n        vauldy-local status --store /bestand\n        vauldy-local import-folder --store /bestand /ordner [--recursive]\n        vauldy-local originals-preview|originals-migrate --store /bestand /quellordner […]\n        vauldy-local check-originals --store /bestand\n        vauldy-local watch-add --store /bestand /ordner […] [--recursive]\n        vauldy-local watch-list --store /bestand\n        vauldy-local watch-pause|watch-resume|watch-remove --store /bestand --folder UUID\n        vauldy-local watch-start --store /bestand\n        vauldy-local retry --store /bestand --document UUID\n        vauldy-local analyze --store /bestand --document UUID\n        vauldy-local example --output /neues-beispiel.pdf\n        vauldy-local connect --client chatgpt|claude --profile /pfad/profile.json\n        vauldy-local logs --profile /pfad/profile.json [--verify]\n        vauldy-local mcp-status --root /installation\n        vauldy-local status-menu --root /installation\n        vauldy-local status-menu-stop --root /installation\n".utf8))
            Foundation.exit(64)
        }
        let store = LocalDocumentStore(root: URL(fileURLWithPath: args[2]))
        let service = LocalImportWorker(store: store, executable: URL(fileURLWithPath: CommandLine.arguments[0]))
        switch args[0] {
        case "storage-activate-sqlite":
            guard args.count == 7, args[3] == "--prepared", args[4].hasPrefix("/"), args[5] == "--expected" else { throw MCPAccessError.invalidArguments }
            try output(LocalStorageMigration(source: store.root).activateSQLite(from: URL(fileURLWithPath: args[4]), expected: args[6]))
        case "storage-recover-activation":
            guard args.count == 3 else { throw MCPAccessError.invalidArguments }
            try output(LocalStorageMigration(source: store.root).recoverSQLiteActivation())
        case "storage-preview", "storage-migrate", "storage-restore":
            let migration = LocalStorageMigration(source: store.root)
            if args[0] == "storage-preview" {
                guard args.count == 5, args[3] == "--format", let format = LocalStorageMigration.Format(rawValue: args[4]) else { throw MCPAccessError.invalidArguments }
                try output(migration.preview(format: format))
            } else if args[0] == "storage-migrate" {
                guard args.count == 9, args[3] == "--format", let format = LocalStorageMigration.Format(rawValue: args[4]),
                      args[5] == "--to", args[6].hasPrefix("/"), args[7] == "--expected" else { throw MCPAccessError.invalidArguments }
                try output(migration.transfer(to: URL(fileURLWithPath: args[6]), format: format, expected: args[8]))
            } else {
                guard args.count == 7, args[3] == "--to", args[4].hasPrefix("/"), args[5] == "--expected" else { throw MCPAccessError.invalidArguments }
                try output(migration.transfer(to: URL(fileURLWithPath: args[4]), format: .same, expected: args[6], restoringBackup: true))
            }
        case "storage-rebuild-projections":
            guard args.count == 3 else { throw MCPAccessError.invalidArguments }
            try await store.rebuildSQLiteProjections()
            try output(["projections": "rebuilt"])
        case "create-sqlite":
            guard args.count == 3 else { throw LocalImportError.invalidDocument }
            let created = try LocalDocumentStore.createSQLite(at: store.root)
            struct Created: Encodable { let storage: String; let vaultPath: String; let created = true }
            try output(Created(storage: created.storageKind, vaultPath: created.snapshotURL.path))
        case "inventory-quality":
            guard args.count == 3 else { throw LocalImportError.invalidDocument }
            let report = try await MCPInventoryQualityService(store: store).report()
            struct Quality: Encodable {
                let total: Int, ready: Int, review: Int, blocked: Int
                let sourceAvailable: Int, sourceChanged: Int, sourceUnavailable: Int
                let snapshotDigest: String
            }
            try output(Quality(total: report.rows.count, ready: report.readyIDs.count, review: report.reviewIDs.count,
                blocked: report.rows.count - report.eligibleIDs.count, sourceAvailable: report.rows.filter { $0.original == .available }.count,
                sourceChanged: report.rows.filter { $0.original == .changed }.count, sourceUnavailable: report.rows.filter { $0.original == .unavailable }.count,
                snapshotDigest: report.snapshotDigest))
        case "watch-add":
            let recursive = args.last == "--recursive"
            let paths = Array(args.dropFirst(3).dropLast(recursive ? 1 : 0))
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { throw LocalWatchError.invalidFolder }
            let folders = try await LocalWatchedFolderStore(store: store).add(paths.map { URL(fileURLWithPath: $0) }, recursive: recursive)
            try await service.start()
            try output(folders)
        case "watch-list":
            guard args.count == 3 else { throw LocalWatchError.invalidConfiguration }
            struct WatchStatus: Encodable {
                let folders: [LocalWatchedFolder]
                let worker: LocalImportWorker.Status
                let scans: [LocalWatchScanStatus]
            }
            try output(await WatchStatus(folders: LocalWatchedFolderStore(store: store).folders(), worker: service.status(), scans: service.watchStatus()))
        case "watch-remove", "watch-pause", "watch-resume":
            guard args.count == 5, args[3] == "--folder", let id = UUID(uuidString: args[4]) else { throw LocalWatchError.invalidConfiguration }
            let folders = LocalWatchedFolderStore(store: store)
            if args[0] == "watch-remove" { try await folders.remove(id) }
            else {
                try await folders.setEnabled(args[0] == "watch-resume", id: id)
                if args[0] == "watch-resume" { try await service.start() }
            }
            try output(await folders.folders())
        case "watch-start":
            guard args.count == 3 else { throw LocalWatchError.invalidConfiguration }
            try await service.start()
            try output(await service.status())
        case "worker":
            guard args.count == 3 || (args.count == 4 && args[3] == "--no-watch") else { throw LocalImportError.invalidDocument }
            try await service.serve(watchFolders: !args.contains("--no-watch"))
        case "worker-status":
            try output(await service.status())
        case "worker-stop":
            try await service.stop()
        case "direct-import":
            guard args.count == 4 else { throw LocalImportError.invalidDocument }
            try output(await LocalImportService(store: store, ocr: NativeLocalDocumentOCR(baseline: true)).importFile(URL(fileURLWithPath: args[3])))
        case "import":
            guard args.count > 3, args.dropFirst(3).allSatisfy({ $0.hasPrefix("/") }) else { throw LocalImportError.unreadableFile }
            var outcomes: [LocalImportOutcome] = []
            for path in args.dropFirst(3) {
                outcomes.append(try await service.importFile(URL(fileURLWithPath: path), progress: showProgress))
            }
            try output(outcomes)
            if outcomes.contains(where: { $0.state != .completed }) { Foundation.exit(2) }
        case "import-folder":
            let recursive = args.last == "--recursive"
            let paths = Array(args.dropFirst(3).dropLast(recursive ? 1 : 0))
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { throw LocalWatchError.invalidFolder }
            var outcomes: [LocalImportOutcome] = []
            for path in paths { outcomes += try await service.importFolder(URL(fileURLWithPath: path), recursive: recursive, progress: showProgress) }
            try output(outcomes)
            if outcomes.contains(where: { $0.state != .completed }) { Foundation.exit(2) }
        case "originals-preview", "originals-migrate":
            let paths = Array(args.dropFirst(3))
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { throw LocalWatchError.invalidFolder }
            let migration = LocalOriginalMigrationService(store: store)
            let plan = try await migration.inspect(sourceFolders: paths.map { URL(fileURLWithPath: $0) })
            if args[0] == "originals-preview" { try output(plan.report) }
            else { try output(await migration.apply(plan)) }
        case "check-originals":
            guard args.count == 3 else { throw LocalImportError.invalidDocument }
            struct Availability: Encodable { let id: UUID; let state: LocalOriginalState? }
            try output(await store.checkOriginals().map { Availability(id: $0.id, state: $0.localImport?.originalState) })
        case "status":
            guard args.count == 3 else { throw LocalImportError.unreadableFile }
            try await store.recoverInterrupted()
            struct Status: Encodable { let id: UUID; let state: LocalImportState; let pageCount: Int?; let analysisStatus: String; let error: LocalImportError?; let originalState: LocalOriginalState? }
            try output(await store.documents().map { Status(id: $0.id, state: $0.localImport?.state ?? .failed,
                                                             pageCount: $0.pageCount, analysisStatus: $0.baseAnalysisStatus, error: $0.localImport?.error, originalState: $0.localImport?.originalState) })
        case "analyze":
            guard args.count == 5, args[3] == "--document", let id = UUID(uuidString: args[4]) else { throw LocalImportError.invalidDocument }
            let document = try await LocalBaseAnalysisService(store: store).analyze(documentID: id)
            struct AnalysisStatus: Encodable { let documentID: UUID; let status: String; let logicalDocuments: Int }
            try output(AnalysisStatus(documentID: id, status: document.baseAnalysisStatus, logicalDocuments: document.currentBaseAnalysis?.documents.count ?? 0))
            if document.baseAnalysisStatus != "completed" { Foundation.exit(2) }
        case "refine":
            guard args.count == 5, args[3] == "--document", let id = UUID(uuidString: args[4]),
                  let document = try await store.document(id: id) else { throw LocalImportError.invalidDocument }
            let preserving = try EvidencePreservingLocalOCR(document: document)
            let outcome = try await LocalImportService(store: store, ocr: preserving).retry(documentID: id, expected: document, progress: showProgress)
            try output(outcome)
            if outcome.state != .completed { Foundation.exit(2) }
        case "retry":
            guard (args.count == 5 || (args.count == 6 && args[5] == "--fresh")), args[3] == "--document", let id = UUID(uuidString: args[4]) else { throw LocalImportError.staleAttempt }
            let result = try await service.retry(documentID: id, fresh: args.count == 6, progress: showProgress)
            try output(result)
            if result.state != .completed { Foundation.exit(2) }
        default: throw LocalImportError.unsupportedFile
        }
    }
    static func showProgress(_ update: LocalImportProgress) {
        FileHandle.standardError.write(Data("\(update.stage): \(update.completedPages)/\(update.totalPages)\n".utf8))
    }
    static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
