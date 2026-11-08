import Foundation

/// Per-vault worker IPC uses only private, bounded local files and exact document IDs. No network listener.
public struct LocalImportWorker: Sendable {
    public let store: LocalDocumentStore
    public let executable: URL
    public let watchFolders: Bool
    public init(store: LocalDocumentStore, executable: URL, watchFolders: Bool = true) { self.store = store; self.executable = executable; self.watchFolders = watchFolders }
    private var directory: URL { store.root.appendingPathComponent("worker", isDirectory: true) }
    private var stopURL: URL { directory.appendingPathComponent("stop") }
    private struct Job: Codable {
        var id: UUID
        var documentID: UUID
        var createdAt = Date()
        var state = "queued"
        var fresh = false
        var borrowedAccess: Data?
        var progress: LocalImportProgress?
        var outcome: LocalImportOutcome?
        var error: LocalImportError?
        var capacityError: LocalStoreCapacityError?
        var finishedAt: Date?
    }
    public struct Status: Codable, Sendable {
        public var running: Bool
        public var queued: Int
        public var processing: Int
        public var instance: UUID?
    }
    /// Explicit local action; resumes configured folders without creating MCP grants.
    public func start() async throws {
        try await prepare()
        _ = try LocalWatchedFolderStore(store: store).configuredFolders()
        try? FileManager.default.removeItem(at: stopURL)
        try await Task.detached { try startIfNeeded() }.value
    }
    public func watchStatus() async throws -> [LocalWatchScanStatus] {
        try await prepare()
        let url = directory.appendingPathComponent("watch-status")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try read(url, as: [LocalWatchScanStatus].self)
    }
    public func importFile(_ file: URL, storage: LocalOriginalStorage = .managedCopy, renewOriginalAccess: Bool = false, progress: @escaping @Sendable (LocalImportProgress) -> Void = { _ in }) async throws -> LocalImportOutcome {
        try Task.checkCancellation()
        let staged = try await store.stage(file: file, storage: storage, renewOriginalAccess: renewOriginalAccess)
        if staged.duplicate, staged.document.localImport?.state != .queued {
            return .init(documentID: staged.document.id, state: staged.document.localImport?.state ?? .failed,
                         reusedOriginal: true, pageCount: staged.document.pageCount, analysisStatus: staged.document.baseAnalysisStatus)
        }
        let outcome = try await submit(staged.document.id, progress: progress)
        guard staged.duplicate else { return outcome }
        return .init(documentID: outcome.documentID, state: outcome.state, reusedOriginal: true,
                     pageCount: outcome.pageCount, metrics: outcome.metrics, analysisStatus: outcome.analysisStatus)
    }
    public func importFolder(_ url: URL, recursive: Bool = false,
                             progress: @escaping @Sendable (LocalImportProgress) -> Void = { _ in }) async throws -> [LocalImportOutcome] {
        try await store.validateStorage()
        let (access, scan) = try await Task.detached { try folderFiles(url, recursive: recursive) }.value
        defer { access.close() }
        var outcomes: [LocalImportOutcome] = []
        for file in scan.supported {
            try Task.checkCancellation()
            outcomes.append(try await importFile(file, storage: .referenced, progress: progress))
        }
        return outcomes
    }

    /// Counts every distinct supported file before import and keeps folder access open until the caller finishes.
    public func folderImportBatch(_ urls: [URL], recursive: Bool) async throws -> LocalFolderImportBatch {
        try await store.validateStorage()
        // The detached scan is joined on cancellation so no folder access outlives the request.
        let scan = Task.detached {
            var files: [URL] = [], unsupported: [URL] = [], unavailable: [URL] = []
            var seen: Set<String> = []
            var accesses: [LocalOriginalAccess] = []
            for url in urls {
                try Task.checkCancellation()
                let access: LocalOriginalAccess
                let source: (supported: [URL], unsupported: [URL])
                do {
                    (access, source) = try folderFiles(url, recursive: recursive, includeUnsupported: true)
                }
                catch is CancellationError { throw CancellationError() }
                catch LocalWatchError.scanLimit { throw LocalWatchError.scanLimit }
                catch { unavailable.append(url); continue }
                let count = files.count
                for file in source.supported where seen.insert(file.resolvingSymlinksInPath().path).inserted {
                    guard files.count < 20_000 else { throw LocalWatchError.scanLimit }
                    files.append(file)
                }
                for file in source.unsupported where seen.insert(file.resolvingSymlinksInPath().path).inserted {
                    guard unsupported.count < 20_000 else { throw LocalWatchError.scanLimit }
                    unsupported.append(file)
                }
                if files.count > count { accesses.append(access) }
            }
            try Task.checkCancellation()
            return LocalFolderImportBatch(files: files, unsupportedFiles: unsupported, unavailableFolders: unavailable, accesses: accesses)
        }
        return try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    }

    private func folderFiles(_ url: URL, recursive: Bool, includeUnsupported: Bool = false) throws
        -> (LocalOriginalAccess, (supported: [URL], unsupported: [URL])) {
        let folder = try LocalWatchedFolder.authorizing(url, recursive: recursive)
        let access = try folder.openDirectory()
        return (access, try LocalWatchedFolderMonitor.scanFiles(folder, excluding: store.root, directory: access.url,
                                                               includeUnsupported: includeUnsupported))
    }

    /// Fresh reads bypass checkpoints and preserve existing literal evidence.
    /// A changed prior line keeps the previous page and remains reviewable.
    public func retry(documentID: UUID, fresh: Bool = false, progress: @escaping @Sendable (LocalImportProgress) -> Void = { _ in }) async throws -> LocalImportOutcome {
        try await submit(documentID, fresh: fresh, progress: progress)
    }
    public func status() async throws -> Status {
        try await prepare()
        return try await Task.detached {
            let jobs = try jobs()
            return Status(running: running(), queued: jobs.filter { $0.state == "queued" }.count,
                          processing: jobs.filter { $0.state == "running" }.count,
                          instance: running() ? (try? read(directory.appendingPathComponent("instance"), as: UUID.self)) : nil)
        }.value
    }
    /// Stop after the current native operation joins. Pending jobs remain durable for the next explicit import/retry.
    public func stop() async throws {
        try await prepare()
        try write(Data(), to: stopURL)
    }
    private func submit(_ id: UUID, fresh: Bool = false, progress: @escaping @Sendable (LocalImportProgress) -> Void) async throws -> LocalImportOutcome {
        try Task.checkCancellation()
        try await prepare()
        progress(.init(documentID: id, stage: "Wartet auf lokalen Worker"))
        let borrowed = try await store.borrowOriginal(for: id)
        let job = try await Task.detached {
            let job = try enqueue(id, fresh: fresh, borrowedAccess: borrowed)
            try startIfNeeded()
            return job
        }.value
        var cancelSent = false
        var lastProgress: LocalImportProgress?
        var restarts = 0
        while true {
            let current = try read(jobURL(job.id), as: Job.self)
            if let update = current.progress, update != lastProgress { progress(update); lastProgress = update }
            if let outcome = current.outcome { if cancelSent { throw CancellationError() }; return outcome }
            if let error = current.capacityError { throw error }
            if let error = current.error { if error == .cancelled { throw CancellationError() }; throw error }
            if Task.isCancelled && !cancelSent {
                try write(Data(), to: cancellationURL(job.id)); cancelSent = true
            }
            // Restart a crashed/idle-exiting process under the queue lock. An explicit stop is not undone.
            if !running() {
                if FileManager.default.fileExists(atPath: stopURL.path) || restarts >= 3 { throw LocalImportError.interrupted }
                restarts += 1
                try startIfNeeded()
            }
            await pause()
        }
    }
    private func enqueue(_ id: UUID, fresh: Bool = false, borrowedAccess: Data? = nil) throws -> Job {
        let lock = try LocalWorkerLease(url: directory.appendingPathComponent("queue.lock"), wait: true)
        defer { lock.release() }
        if running() {
            var compatible = false
            for _ in 0..<20 {
                if let details = try? read(directory.appendingPathComponent("instance-details"), as: InstanceDetails.self),
                   let instance = try? read(directory.appendingPathComponent("instance"), as: UUID.self),
                   details.id == instance, details.protocolVersion == 3 { compatible = true; break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard compatible else { throw LocalImportError.workerBusy }
        }
        let existing = try jobs()
        if let active = existing.first(where: { $0.documentID == id && $0.finishedAt == nil }), active.fresh != fresh { throw LocalImportError.workerBusy }
        var job = existing.first(where: { $0.documentID == id && $0.finishedAt == nil }) ?? Job(id: UUID(), documentID: id, fresh: fresh)
        guard existing.filter({ $0.finishedAt == nil }).count < 200 || existing.contains(where: { $0.id == job.id }) else { throw LocalImportError.workerBusy }
        if job.state == "queued", let borrowedAccess { job.borrowedAccess = borrowedAccess }
        if !existing.contains(where: { $0.id == job.id }) || (job.state == "queued" && borrowedAccess != nil) { try save(job) }
        return job
    }
    private func prepare() async throws {
        try await store.validateStorage() // Refuse foreign/corrupt stores before touching IPC state.
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LocalImportError.storageUnavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func running() -> Bool {
        do { let lease = try LocalWorkerLease(url: directory.appendingPathComponent("worker.lock")); lease.release(); return false }
        catch LocalImportError.workerBusy { return true }
        catch { return false }
    }
    private func startIfNeeded() throws {
        let launch = try LocalWorkerLease(url: directory.appendingPathComponent("launch.lock"), wait: true)
        defer { launch.release() }
        let watchRequest = directory.appendingPathComponent("watch-requested")
        if watchFolders { try write(Data(), to: watchRequest) }
        if running() { return }
        if !watchFolders { try? FileManager.default.removeItem(at: watchRequest) }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LocalImportError.storageUnavailable }
        try? FileManager.default.removeItem(at: stopURL)
        let process = Process(); process.executableURL = executable
        process.arguments = ["worker", "--store", store.root.path] + (watchFolders ? [] : ["--no-watch"])
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        // Bounded startup handshake; the process retains no client pipes and survives the requesting UI/CLI.
        for _ in 0..<100 {
            if running() { return }
            if !process.isRunning { throw LocalImportError.storageUnavailable }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw LocalImportError.workerBusy
    }
    private struct InstanceDetails: Codable { let id: UUID; var protocolVersion = 3 }
    public func serve(idleSeconds: Double = 120, ocr: (any LocalDocumentOCR)? = nil, watchInterval: Double = 5, watchFolders: Bool = true) async throws {
        try await prepare()
        let lease: LocalWorkerLease
        do { lease = try LocalWorkerLease(url: directory.appendingPathComponent("worker.lock")) }
        catch LocalImportError.workerBusy { return }
        defer { lease.release() }
        let instanceID = UUID()
        try write(JSONEncoder().encode(instanceID), to: directory.appendingPathComponent("instance"))
        try write(JSONEncoder().encode(InstanceDetails(id: instanceID)), to: directory.appendingPathComponent("instance-details"))
        try await store.recoverInterrupted()
        var idle = Date()
        let monitor = LocalWatchedFolderMonitor(store: store)
        var lastScan = Date.distantPast
        var folders: [LocalWatchedFolder] = []
        while !FileManager.default.fileExists(atPath: stopURL.path) {
            try Task.checkCancellation()
            if (watchFolders || FileManager.default.fileExists(atPath: directory.appendingPathComponent("watch-requested").path)), Date().timeIntervalSince(lastScan) >= max(0.1, watchInterval) {
                // Invalid configuration stops the worker rather than silently treating it as an empty list.
                folders = try LocalWatchedFolderStore(store: store).configuredFolders()
                let statuses = await monitor.scan(folders) { file in
                    guard !FileManager.default.fileExists(atPath: stopURL.path),
                          try jobs().filter({ $0.finishedAt == nil }).count < 200 else { throw LocalImportError.workerBusy }
                    let staged = try await store.stage(file: file, storage: .referenced)
                    if !staged.duplicate || staged.document.localImport?.state == .queued {
                        _ = try enqueue(staged.document.id)
                    }
                }
                try write(JSONEncoder().encode(statuses), to: directory.appendingPathComponent("watch-status"))
                lastScan = Date()
            }
            let watching = folders.contains(where: \.enabled)
            let lock = try LocalWorkerLease(url: directory.appendingPathComponent("queue.lock"), wait: true)
            var pending = try jobs()
            // A crash may have left a running job. The worker lease proves no other queue worker owns it.
            for index in pending.indices where pending[index].state == "running" { pending[index].state = "queued"; try save(pending[index]) }
            let next = pending.filter { $0.state == "queued" }.sorted { $0.createdAt < $1.createdAt }.first
            lock.release()
            if var job = next {
                idle = Date(); job.state = "running"; try save(job)
                let jobID = job.id, documentID = job.documentID, fresh = job.fresh, borrowedAccess = job.borrowedAccess
                let task = Task {
                    let previous = try await store.document(id: documentID)
                    var engine: (any LocalDocumentOCR)? = ocr ?? (fresh ? NativeLocalDocumentOCR() : nil)
                    if fresh, let previous, !previous.baseAnalysisPages.isEmpty {
                        engine = try EvidencePreservingLocalOCR(document: previous, candidate: engine ?? NativeLocalDocumentOCR())
                    }
                    return try await LocalImportService(store: store, ocr: engine).retry(documentID: documentID,
                        borrowedAccess: borrowedAccess, expected: fresh ? previous : nil) { update in
                        // Only this worker writes running-job progress; readers see atomic snapshots.
                        if var current = try? read(jobURL(jobID), as: Job.self) { current.progress = update; try? save(current) }
                    }
                }
                if FileManager.default.fileExists(atPath: cancellationURL(jobID).path) { task.cancel() }
                let monitor = Task {
                    while !Task.isCancelled {
                        if FileManager.default.fileExists(atPath: cancellationURL(jobID).path) { task.cancel(); return }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                do { job.outcome = try await task.value }
                catch {
                    job.capacityError = error as? LocalStoreCapacityError
                    job.error = error is CancellationError ? .cancelled : (error as? LocalImportError ?? .storageUnavailable)
                }
                monitor.cancel(); await monitor.value
                // Native cancellation has joined before publishing completion or processing another job.
                if job.error == .workerBusy { job.state = "queued"; job.error = nil; try save(job); await pause(); continue }
                if job.error == .cancelled { try await store.cancelPending(job.documentID) }
                job.state = "finished"; job.finishedAt = Date(); job.borrowedAccess = nil; try save(job)
                try? FileManager.default.removeItem(at: cancellationURL(jobID))
                idle = Date()
            } else {
                if !watching && Date().timeIntervalSince(idle) >= max(2, min(idleSeconds, 300)) { return }
                await pause()
            }
            // Retain results long enough for disconnected clients; purge only known finished job files.
            for old in pending where old.finishedAt.map({ Date().timeIntervalSince($0) > 3_600 }) == true {
                try? FileManager.default.removeItem(at: jobURL(old.id))
            }
        }
    }
    private func jobs() throws -> [Job] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard urls.count <= 5_000 else { throw LocalImportError.workerBusy }
        return try urls.map { try read($0, as: Job.self) }
    }
    private func jobURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func cancellationURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".cancel") }
    private func save(_ job: Job) throws { try write(JSONEncoder().encode(job), to: jobURL(job.id)) }
    private func write(_ data: Data, to url: URL) throws {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LocalImportError.storageUnavailable }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func read<T: Decodable>(_ url: URL, as type: T.Type) throws -> T {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= 160_000 else { throw LocalImportError.storageUnavailable }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func pause() async { await Task.detached { try? await Task.sleep(for: .milliseconds(150)) }.value }
}


public struct LocalFolderImportBatch: Sendable {
    public let files: [URL]
    public let unsupportedFiles: [URL]
    public let unavailableFolders: [URL]
    public var unavailableFolderCount: Int { unavailableFolders.count }
    fileprivate let accesses: [LocalOriginalAccess]

    public func close() { accesses.forEach { $0.close() } }
}
