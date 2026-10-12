import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO

private struct CachedPayload: Codable {
    let data: Data
    let at: Date
}

private struct CachedRemote: Codable {
    let entries: [RenderEntry]
    let at: Date
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var entries: [RenderEntry] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var shadowHealth = SourceHealth()
    @Published private(set) var macHealth = SourceHealth()
    @Published private(set) var folderHealth = SourceHealth()
    @Published private(set) var remoteHealth = SourceHealth()
    @Published private(set) var shadowSummary = "Aucune mesure Shadow"
    @Published private(set) var macJobs: [MacJob] = []
    @Published private(set) var shadowTasks: [ShadowTask] = []
    @Published private(set) var config = AppConfig()
    @Published private(set) var lastScan = Date()
    @Published private(set) var organizationError: String?
    private var organizationBackupMade = false
    @Published private(set) var catalogSnapshot = RenderCatalogSnapshot.empty
    @Published private(set) var dashboardProjects: [RenderDashboardProject] = []
    private let catalogue: RenderCatalogService
    private let storageRoot: URL
    private let collectionEnabled: Bool
    private let folderWorker = FolderCollectionWorker()
    private var snapshotTask: Task<Void,Never>?
    private var snapshotGeneration: UInt64 = 0
    private var folderTask: Task<Void,Never>?
    private var folderBusy = false
    private var folderPending = false
    private var folderRevision: UInt64 = 0
    private var previewTasks: [String: Task<Void,Never>] = [:]
    private var requestedPreviews: [String: RenderEntry] = [:]
    private var previewGeneration: UInt64 = 0
    private var failedPreviews = Set<String>()
    private let imageCache = NSCache<NSString, NSImage>()

    @Published private(set) var shadowDeclaration: ShadowDashboardDeclaration?
    private var shadowPayload: ShadowResponse?
    private var shadowEntries: [RenderEntry] = []
    private var macEntries: [RenderEntry] = []
    private var folderEntries: [RenderEntry] = []
    private var shadowFolderEntries: [RenderEntry] = []
    private var shadowSeenAt: [String: Date] = [:]
    private var macSeenAt: [String: Date] = [:]
    private var timers: [Timer] = []
    private var shadowBusy = false
    private var macBusy = false
    private var shadowRemoteBusy = false
    private var remotePreviewQueueBusy = false
    private var previewBusy = Set<String>()
    private var stopping = false
    private var shadowFolderRevision = 0
    private var session: URLSession
    private let base = URL(string: "http://127.0.0.1:4420")!
    private let remote = ShadowFolderScanner()

    static func fixture(snapshot: RenderCatalogSnapshot, storageRoot: URL) -> MonitorModel {
        MonitorModel(storageRoot:storageRoot,initialSnapshot:snapshot,collectionEnabled:false)
    }

    init(storageRoot: URL? = nil, initialSnapshot: RenderCatalogSnapshot? = nil, collectionEnabled: Bool = true) {
        let selectedRoot = storageRoot ?? (collectionEnabled ? RenduStorage.root : FileManager.default.temporaryDirectory.appendingPathComponent("autoren-fixture-" + UUID().uuidString,isDirectory:true))
        if !collectionEnabled { precondition(selectedRoot.standardizedFileURL.path != RenduStorage.root.standardizedFileURL.path && !selectedRoot.standardizedFileURL.path.hasPrefix(RenduStorage.root.standardizedFileURL.path + "/"), "Fixture storage must be isolated") }
        self.storageRoot = selectedRoot; self.collectionEnabled = collectionEnabled
        self.catalogue = RenderCatalogService(root:selectedRoot.appendingPathComponent("Catalog",isDirectory:true))
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 8
        options.timeoutIntervalForResource = 10
        options.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: options)
        imageCache.totalCostLimit = 16 * 1024 * 1024
        imageCache.countLimit = 32
        ensureStorage()
        if !collectionEnabled {
            config = load("config.json",as:AppConfig.self) ?? AppConfig()
            if let seed=initialSnapshot {
                for job in seed.jobs where config.jobContexts[job.id] == nil && job.workID != nil && job.sourceWorkID == nil {
                    config.jobContexts[job.id] = RenderJobContext(projectID:job.projectID,workID:job.workID,versionID:job.versionID,workTitle:job.workTitle,versionLabel:job.versionLabel)
                }
            }
            save(config,name:"config.json")
            catalogSnapshot = initialSnapshot ?? .empty; dashboardProjects = catalogSnapshot.projects
            entries = catalogSnapshot.jobs.flatMap(\.previewEntries)
            return
        }
        if let saved = load("config.json", as: AppConfig.self) {
            config = saved
            if !config.importNewMacMonitorFolders(Array(knownFolders().values)).isEmpty {
                save(config, name: "config.json")
            }
        } else {
            config = AppConfig.bootstrap()
            save(config, name: "config.json")
        }
        shadowDeclaration = load("shadow-dashboard-declaration.json",as:ShadowDashboardDeclaration.self)
        if let cached: CachedPayload = load("shadow-last-good.json", as: CachedPayload.self),
           let response = try? JSONDecoder().decode(ShadowResponse.self, from: cached.data) {
            adoptShadow(response, at: cached.at, live: false)
        }
        if let cached: CachedPayload = load("mac-last-good.json", as: CachedPayload.self),
           let response = try? JSONDecoder().decode(MacResponse.self, from: cached.data) {
            adoptMac(response, at: cached.at, live: false)
        }
        if let cached: CachedRemote = load("shadow-folders-last-good.json", as: CachedRemote.self) {
            shadowFolderEntries = cached.entries.filter { entry in
                guard let path = entry.path else { return false }
                return config.shadowFolders.contains { Self.isInside(path, root: $0) }
            }
            remoteHealth.isStale = true
            remoteHealth.lastGoodAt = cached.at
            remoteHealth.message = "Dernier dossier Shadow enregistré"
            combine()
        }
        refreshFolders()
    }

    func start() {
        guard collectionEnabled, timers.isEmpty else { return }
        stopping = false
        Task { await refreshMac() }
        Task { await refreshShadow() }
        Task { await refreshShadowFolders() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFolders()
                await self?.refreshMac()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshShadow()
                await self?.refreshShadowFolders()
            }
        })
    }

    func stop() {
        stopping = true
        snapshotTask?.cancel(); folderTask?.cancel()
        requestedPreviews = [:]
        previewTasks.values.forEach { $0.cancel() }
        thumbnails = [:]
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        session.invalidateAndCancel()
        remote.cancel()
    }

    func refreshNow() {
        guard collectionEnabled else { return }
        failedPreviews.removeAll()
        refreshFolders()
        Task { await refreshMac() }
        Task { await refreshShadow() }
        Task { await refreshShadowFolders() }
    }

    func addMacFolder(_ url: URL) {
        folderRevision += 1
        config.addMacFolder(url.path)
        save(config, name: "config.json")
        refreshFolders()
    }

    func removeMacFolder(_ path: String) {
        folderRevision += 1
        config.removeMacFolder(path)
        save(config, name: "config.json")
        refreshFolders()
    }

    @discardableResult
    func setJobContext(_ context: RenderJobContext?, forJobID id: String) -> Bool {
        organizationError = nil
        guard let job = catalogSnapshot.jobs.first(where: { $0.id == id }) else { organizationError = "Rendu inconnu"; return false }
        if let source = job.sourceWorkID, let chosen = context?.workID, source != chosen { organizationError = "Identité de travail déclarée par la source · étiquette modifiable"; return false }
        if let source = job.sourceVersionID, let chosen = context?.versionID, source != chosen { organizationError = "Identité de version déclarée par la source · étiquette modifiable"; return false }
        if !organizationBackupMade {
            let target = storageRoot.appendingPathComponent("config.json")
            if FileManager.default.fileExists(atPath: target.path) {
                let backup = storageRoot.appendingPathComponent("config.before-work-organization-" + UUID().uuidString + ".json")
                do { try FileManager.default.copyItem(at:target,to:backup); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path) }
                catch { organizationError = "Sauvegarde configuration impossible : " + error.localizedDescription; return false }
            }
            organizationBackupMade = true
        }
        let target = storageRoot.appendingPathComponent("config.json")
        do {
            let before = try Data(contentsOf:target)
            var document = try JSONSerialization.jsonObject(with:before) as? [String:Any] ?? [:]
            var contexts = document["jobContexts"] as? [String:Any] ?? [:]
            if let context { contexts[id] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(context)) }
            else { contexts.removeValue(forKey:id) }
            document["jobContexts"] = contexts
            let data = try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys])
            let updated = try JSONDecoder().decode(AppConfig.self,from:data)
            guard try Data(contentsOf:target) == before else { organizationError="Configuration modifiée ailleurs · réessayer après relecture"; return false }
            try data.write(to:target,options:.atomic)
            let rootsChanged = config.macFolders != updated.macFolders || config.shadowFolders != updated.shadowFolders
            config = updated
            if rootsChanged { folderRevision += 1; shadowFolderRevision += 1; refreshFolders() }
            combine(); return true
        } catch { organizationError = "Organisation non enregistrée : " + error.localizedDescription; return false }
    }

    func setFolderWorkType(_ type: RenderWorkType?, path: String) {
        config.folderWorkTypes[path] = type
        save(config, name: "config.json")
        combine()
    }

    func projectID(for entry: RenderEntry) -> String {
        RenderOrganization.projectID(for: entry, jobs: macJobs, knownFolders: knownFolders(),
                                     labels: config.folderProjects)
    }

    func workType(for entry: RenderEntry) -> RenderWorkType? {
        RenderOrganization.workType(for: entry, jobs: macJobs, knownFolders: knownFolders(),
                                    configured: config.folderWorkTypes)
    }

    func workType(for job: MacJob) -> RenderWorkType? {
        if let folder = knownFolders()[job.id],
           let choice = config.folderWorkTypes.sorted(by: { $0.key.count > $1.key.count }).first(where: {
               folder == $0.key || RenderOrganization.isInside(folder, root: $0.key)
           }) { return choice.value }
        return job.workType
    }

    func addShadowFolder(_ path: String) -> Bool {
        guard ShadowFolderScanner.validRemotePath(path) else { return false }
        guard !config.shadowFolders.contains(path) else { return true }
        shadowFolderRevision += 1
        config.shadowFolders.append(path)
        save(config, name: "config.json")
        Task { await refreshShadowFolders() }
        return true
    }

    func removeShadowFolder(_ path: String) {
        shadowFolderRevision += 1
        config.shadowFolders.removeAll { $0 == path }
        save(config, name: "config.json")
        shadowFolderEntries.removeAll { $0.path.map { Self.isInside($0, root: path) } ?? false }
        save(CachedRemote(entries: shadowFolderEntries, at: remoteHealth.lastGoodAt ?? .distantPast),
                          name: "shadow-folders-last-good.json")
        combine()
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        RenderOrganization.isInside(path, root: root)
    }

    private func fetch(_ path: String) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func refreshShadow() async {
        guard collectionEnabled, !stopping else { return }
        guard !shadowBusy else { return }
        shadowBusy = true
        defer { shadowBusy = false }
        do {
            let data = try await fetch("api/status")
            let response = try JSONDecoder().decode(ShadowResponse.self, from: data)
            guard !Task.isCancelled, !stopping else { return }
            guard response.ok else {
                shadowHealth.online = false
                shadowHealth.isStale = true
                shadowHealth.checkedAt = Date()
                shadowHealth.message = response.error ?? "Shadow ne répond pas"
                combine(); return
            }
            let now = Date()
            save(CachedPayload(data: data, at: now), name: "shadow-last-good.json")
            if let page = try? await fetch(""), let declared=ShadowDashboardDeclaration.parse(page,sourceURL:base.absoluteString,checkedAt:now), declared.matches(response) {
                shadowDeclaration=declared; save(declared,name:"shadow-dashboard-declaration.json")
            } else if shadowDeclaration?.matches(response) != true { shadowDeclaration=nil }
            guard !Task.isCancelled, !stopping else { return }
            adoptShadow(response, at: now, live: true)

        } catch {
            guard !stopping else { return }
            shadowHealth.online = false
                shadowHealth.isStale = true
            shadowHealth.checkedAt = Date()
            shadowHealth.message = "Moniteur indisponible : \(error.localizedDescription)"
            combine()
        }
    }

    private func adoptShadow(_ data: ShadowResponse, at: Date, live: Bool) {
        shadowPayload = data
        shadowHealth.online = live
        shadowHealth.observedAt = RenderDate.parseOptional(data.now)
        shadowHealth.isStale = !live || shadowHealth.observedAt.map { at.timeIntervalSince($0) > 45 || $0.timeIntervalSince(at) > 60 } ?? true
        shadowHealth.checkedAt = Date()
        shadowHealth.lastGoodAt = at
        shadowHealth.message = live ? "Shadow connecté" : "Dernière mesure enregistrée"
        let running = (data.tasks ?? []).filter { $0.state == "Running" }.count
        shadowTasks = data.tasks ?? []
        shadowSummary = "\(data.brut.map(String.init) ?? "?") brutes · \(data.post.map(String.init) ?? "?") finales déclarées · \(running) tâche(s) actives"
        let now = Date()
        shadowEntries = (data.latest ?? []).filter { RenderKind.isSupportedExport($0.name) }.map { frame in
            let id = "shadow-monitor:" + frame.name + ":" + (frame.t ?? "")
            let modified = RenderDate.parse(frame.t)
            let firstSeen = shadowSeenAt[id] ?? at
            shadowSeenAt[id] = firstSeen
            let stable = live && modified != .distantPast && (now.timeIntervalSince(firstSeen) >= 8 && now.timeIntervalSince(modified) >= 8)
            return RenderEntry(id: id, source: .shadowMonitor,
                               job: "Rendu Shadow", filename: frame.name,
                               modified: modified,
                               state: stable ? .stable : .pending,
                               path: nil, previewURL: base.appendingPathComponent("api/frame/" + frame.name).absoluteString)
        }
        shadowSeenAt = shadowSeenAt.filter { key, _ in shadowEntries.contains { $0.id == key } }
        combine()
    }

    func refreshMac() async {
        guard collectionEnabled, !stopping else { return }
        guard !macBusy else { return }
        macBusy = true
        defer { macBusy = false }
        do {
            let data = try await fetch("api/mac")
            let response = try JSONDecoder().decode(MacResponse.self, from: data)
            guard !Task.isCancelled, !stopping else { return }
            guard response.ok else { throw URLError(.badServerResponse) }
            let now = Date()
            save(CachedPayload(data: data, at: now), name: "mac-last-good.json")
            adoptMac(response, at: now, live: true)

        } catch {
            guard !stopping else { return }
            macHealth.online = false
            macHealth.isStale = true
            macHealth.checkedAt = Date()
            macHealth.message = "Moniteur Mac indisponible : \(error.localizedDescription)"
            combine()
        }
    }

    private func adoptMac(_ data: MacResponse, at: Date, live: Bool) {
        macHealth.online = live
        macHealth.observedAt = RenderDate.parseOptional(data.now)
        macHealth.isStale = !live || macHealth.observedAt.map { at.timeIntervalSince($0) > 30 || $0.timeIntervalSince(at) > 60 } ?? true
        macHealth.checkedAt = Date()
        macHealth.lastGoodAt = at
        macHealth.message = live ? "Rendus Mac surveillés" : "Dernière mesure enregistrée"
        macJobs = data.jobs
        let now = Date()
        let knownFolders = knownFolders()
        macEntries = data.jobs.flatMap { job in
            job.latest.enumerated().compactMap { index, name -> RenderEntry? in
                guard RenderKind.isSupportedExport(name) else { return nil }
                let timeIndex = job.times.count - 1 - index
                let modified = timeIndex >= 0 ? RenderDate.parse(job.times[timeIndex]) : .distantPast
                let id = "mac-monitor:\(job.id):\(name):\(modified.timeIntervalSince1970)"
                let firstSeen = macSeenAt[id] ?? at
                macSeenAt[id] = firstSeen
                let stable = live && modified != .distantPast && (now.timeIntervalSince(firstSeen) >= 5 && now.timeIntervalSince(modified) >= 5)
                let remote = base.appendingPathComponent("api/mac/frame/\(job.id)/\(name)").absoluteString
                let filePath = knownFolders[job.id].flatMap { folder -> String? in
                    guard !name.isEmpty, name != ".", name != "..",
                          (name as NSString).lastPathComponent == name else { return nil }
                    return URL(fileURLWithPath: folder, isDirectory: true)
                        .appendingPathComponent(name).standardizedFileURL.path
                }
                return RenderEntry(id: id, source: .macMonitor, job: job.titre,
                                   filename: name, modified: modified,
                                   state: stable ? .stable : .pending,
                                   path: filePath, previewURL: remote, monitorJobID: job.id)
            }
        }
        macSeenAt = macSeenAt.filter { key, _ in macEntries.contains { $0.id == key } }
        combine()
    }

    func refreshFolders() {
        guard collectionEnabled, !stopping else { return }
        if folderBusy { folderPending = true; return }
        folderBusy = true
        let revision = folderRevision; let paths = config.macFolders
        folderTask = Task {
            defer {
                folderBusy = false
                if folderPending && !stopping { folderPending = false; refreshFolders() }
            }
            let result = await folderWorker.scan(paths)
            guard !Task.isCancelled, !stopping, revision == folderRevision else { folderPending = !stopping; return }
            folderEntries = result.entries; folderHealth = result.health; lastScan = Date(); combine()
        }
    }

    func refreshShadowFolders() async {
        guard collectionEnabled, !stopping else { return }
        guard !shadowRemoteBusy else { return }
        guard !config.shadowFolders.isEmpty else {
            remoteHealth = SourceHealth()
            remoteHealth.message = "Aucun dossier Shadow ajouté"
            shadowFolderEntries = []
            save(CachedRemote(entries: [], at: Date()), name: "shadow-folders-last-good.json")
            combine()
            return
        }
        shadowRemoteBusy = true
        defer { shadowRemoteBusy = false }
        let revision = shadowFolderRevision
        let roots = config.shadowFolders
        let result = await remote.scan(roots)
        guard revision == shadowFolderRevision, !stopping else {
            if !stopping { Task { await self.refreshShadowFolders() } }
            return
        }
        let previousGood = remoteHealth.lastGoodAt
        remoteHealth = remote.health
        if !remoteHealth.online { remoteHealth.lastGoodAt = previousGood }
        if remoteHealth.online {
            shadowFolderEntries = result.map { candidate in
                var entry = candidate
                if imageCache.object(forKey: entry.id as NSString) != nil { entry.state = .complete }
                return entry
            }
            save(CachedRemote(entries: shadowFolderEntries, at: Date()),
                              name: "shadow-folders-last-good.json")
        }
        combine()
    }

    private func combine() {
        let shadowListing = ShadowListing.entries(monitor: shadowEntries, folders: shadowFolderEntries,
                                                  remoteOnline: remoteHealth.online,
                                                  foldersConfigured: !config.shadowFolders.isEmpty)
        entries = RenderMerger.merge(folders: folderEntries + shadowListing, monitors: macEntries)
        rebuildSnapshot()
    }

    func setVisiblePreviewEntries(_ candidates: [RenderEntry]) {
        guard collectionEnabled, !stopping else { return }
        let images = candidates.filter {
            ["png","jpg","jpeg","tif","tiff"].contains(($0.filename as NSString).pathExtension.lowercased())
        }.prefix(2)
        let next = Dictionary(images.map { ($0.id,$0) }, uniquingKeysWith: { _,new in new })
        if Set(next.keys) != Set(requestedPreviews.keys) {
            previewGeneration += 1
            failedPreviews.removeAll()
            for (id,task) in previewTasks where next[id] == nil { task.cancel() }
        }
        requestedPreviews = next
        thumbnails = thumbnails.filter { next[$0.key] != nil }
        startRequestedPreviews()
    }

    private func startRequestedPreviews() {
        guard !stopping else { return }
        for (id,entry) in requestedPreviews where entry.state != .pending && previewTasks.count < 2 && previewTasks[id] == nil && !failedPreviews.contains(id) {
            if let cached = imageCache.object(forKey: id as NSString) { if thumbnails[id] == nil { thumbnails[id] = cached }; continue }
            let generation = previewGeneration
            let cache = cacheURL(id)
            let roots = config.shadowFolders
            previewTasks[id] = Task {
                var succeeded = false
                defer {
                    previewTasks.removeValue(forKey: id)
                    if !succeeded && generation == previewGeneration && !Task.isCancelled { failedPreviews.insert(id) }
                    if !stopping { startRequestedPreviews() }
                }
                var decoded = await Task.detached(priority:.utility) { Self.downsampleFile(cache) }.value
                if decoded == nil && !Task.isCancelled {
                    if entry.source == .macFolder, let path=entry.path {
                        decoded = await Task.detached(priority:.utility) { Self.downsampleFile(URL(fileURLWithPath:path)) }.value
                    } else {
                        var data: Data?
                        if entry.source == .shadowFolder, let path=entry.path { data = await remote.preview(path,roots:roots,id:id) }
                        else if let raw=entry.previewURL, let url=URL(string:raw), let result=try? await session.data(from:url),
                                (result.1 as? HTTPURLResponse)?.statusCode == 200 { data=result.0 }
                        if let data, !Task.isCancelled { decoded = await Task.detached(priority:.utility) { Self.downsampleData(data) }.value }
                    }
                }
                guard let decoded, !Task.isCancelled, !stopping, generation == previewGeneration, requestedPreviews[id] != nil else { return }
                imageCache.setObject(decoded.0,forKey:id as NSString,cost:Int(decoded.0.size.width * decoded.0.size.height * 4))
                thumbnails[id] = decoded.0; succeeded = true
                let bytes=decoded.1
                await Task.detached(priority:.utility) { try? bytes.write(to:cache,options:.atomic) }.value
            }
        }
    }

    private func cacheURL(_ id: String) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return storageRoot.appendingPathComponent("Previews/" + hash + ".jpg")
    }

    func thumbnail(for entry: RenderEntry) -> NSImage? { thumbnails[entry.id] }

    func openURL(for entry: RenderEntry) -> URL? {
        if (entry.source == .macFolder || entry.source == .macMonitor), let path = entry.path { return URL(fileURLWithPath: path) }
        // Remote paths have no Finder URL unless an explicitly configured mirror is verified.
        return nil
    }

    var projectSummaries: [RenderProjectSummary] {
        let known = knownFolders()
        return Dictionary(grouping: entries) {
            RenderOrganization.projectID(for: $0, jobs: macJobs, knownFolders: known, labels: config.folderProjects)
        }.map { identity, projectEntries in
            let title = projectEntries.first.map { RenderOrganization.project(for: $0, jobs: macJobs, knownFolders: known, labels: config.folderProjects) } ?? "Projet non identifié"
            let types = Set(projectEntries.compactMap {
                RenderOrganization.workType(for: $0, jobs: macJobs, knownFolders: known, configured: config.folderWorkTypes)
            })
            return RenderProjectSummary(title: title, entries: projectEntries, workType: types.count == 1 ? types.first : nil, id: identity)
        }
            .sorted { ($0.latest?.modified ?? .distantPast) > ($1.latest?.modified ?? .distantPast) }
    }

    func historyEntries(for job: RenderDashboardJob) -> [RenderEntry] {
        if job.source == .macMonitor {
            let rawID = String(job.id.dropFirst(4))
            let root = knownFolders()[rawID]
            return RenderDashboard.macHistory(jobID: rawID, root: root, folders: folderEntries, monitors: macEntries)
        }
        if job.source == .shadowMonitor {
            guard let payload = shadowPayload else { return [] }
            var currentID=RenderDashboard.shadow(payload,health:shadowHealth,declaration:shadowDeclaration).id
            if currentID == "shadow:unidentified" { currentID=RenderDashboard.configuredShadowID(payload,config:config) ?? currentID }
            guard currentID == job.id else { return [] }
            return RenderDashboard.shadowHistory(roots: config.dashboardJobFolders[job.id] ?? [], folders: shadowFolderEntries, monitors: shadowEntries)
        }
        return entries.filter { projectID(for: $0) == job.projectID }.sorted { $0.modified > $1.modified }
    }

    private func rebuildSnapshot() {
        guard !stopping else { return }
        snapshotGeneration += 1; let generation = snapshotGeneration
        snapshotTask?.cancel()
        var input = RenderCatalogInput(revision:generation,macJobs:macJobs,shadow:shadowPayload,declaration:shadowDeclaration,
            config:config,knownFolders:knownFolders(),entries:entries,macEntries:macEntries,folderEntries:folderEntries,
            shadowEntries:shadowEntries,shadowFolderEntries:shadowFolderEntries,macHealth:macHealth,shadowHealth:shadowHealth,
            folderHealth:folderHealth,remoteHealth:remoteHealth)
        if !collectionEnabled { input.preparedJobs = catalogSnapshot.jobs }
        snapshotTask = Task {
            guard let prepared = await catalogue.build(input), !Task.isCancelled, !stopping, generation == snapshotGeneration else { return }
            catalogSnapshot = prepared; dashboardProjects = prepared.projects
        }
    }

    func historyPage(for job: RenderDashboardJob, cursor: String? = nil, limit: Int = 40) async -> RenderHistoryPage {
        if !collectionEnabled {
            return await catalogue.history(jobID:job.id,incoming:job.previewEntries,cursor:cursor,limit:limit,
                coverage:"SIMULÉ · aucune collecte/réseau",scope:"fixture:" + job.id)
        }
        let revision = folderRevision; let shadowRevision = shadowFolderRevision
        var incoming = historyEntries(for:job); var coverage = "Liste récente bornée · historique complet non indexé"
        var roots: [String] = []
        if job.source == .macMonitor { roots = knownFolders()[String(job.id.dropFirst(4))].map { [$0] } ?? [] }
        else if job.source == .macFolder {
            roots = config.macFolders.filter { root in
                let sample = RenderEntry(id:"scope",source:.macFolder,job:"",filename:"",modified:.distantPast,state:.pending,path:root + "/__scope__",previewURL:nil)
                return projectID(for:sample) == job.projectID
            }
        }
        if job.source.isShadow {
            roots = config.dashboardJobFolders[job.id] ?? []
            if roots.isEmpty && job.source == .shadowFolder {
                roots = config.shadowFolders.filter { root in
                    let sample = RenderEntry(id:"scope",source:.shadowFolder,job:"",filename:"",modified:.distantPast,state:.pending,path:root + "/__scope__",previewURL:nil)
                    return projectID(for:sample) == job.projectID
                }
            }
        }
        if cursor == nil && !roots.isEmpty && !job.source.isShadow {
            let result = await folderWorker.history(roots)
            incoming = result.entries; coverage = result.health.online ? (result.health.partial ? "Inventaire partiel des dossiers liés" : "Inventaire du scope demandé") : "Dossier indisponible · métadonnées conservées"
        } else if cursor == nil && job.source.isShadow {
            if !roots.isEmpty {
                if let result = await remote.history(roots) { incoming = result.entries; coverage = result.coverage }
                else { coverage = "Shadow indisponible · métadonnées conservées" }
            }
        }
        guard !Task.isCancelled, !stopping, revision == folderRevision, shadowRevision == shadowFolderRevision else {
            return RenderHistoryPage(entries:[],nextCursor:nil,totalKnown:nil,coverage:"Scope modifié ou demande annulée",snapshotRevision:catalogSnapshot.revision)
        }
        if cursor != nil { incoming = []; coverage = "Page de l’inventaire chargé · sans nouveau scan" }
        let page = await catalogue.history(jobID:job.id,incoming:incoming,cursor:cursor,limit:limit,coverage:coverage,
            scope:job.projectID + "|" + roots.joined(separator:"|") + "|" + String(revision) + "|" + String(shadowRevision))
        guard !Task.isCancelled, !stopping, revision == folderRevision, shadowRevision == shadowFolderRevision else {
            return RenderHistoryPage(entries:[],nextCursor:nil,totalKnown:nil,coverage:"Scope modifié ou demande annulée",snapshotRevision:page.snapshotRevision)
        }
        return page
    }

    var macSummary: String {
        if let active = macJobs.first(where: { !$0.en_cours.isEmpty || $0.faites < $0.total }) {
            let current = active.en_cours.first.map { " · \($0)" } ?? ""
            return (active.progress.map { "\($0.countLabel) exports · \($0.percentLabel)" } ?? "Progression indéterminée") + current
        }
        return "\(macJobs.count) rendu(s) du moniteur · \(config.macFolders.count) dossier(s)"
    }

    private func knownFolders() -> [String:String] { collectionEnabled ? AppConfig.knownMacMonitorFolders() : [:] }
    private func ensureStorage() {
        try? FileManager.default.createDirectory(at:storageRoot,withIntermediateDirectories:true)
        try? FileManager.default.createDirectory(at:storageRoot.appendingPathComponent("Previews"),withIntermediateDirectories:true)
    }
    private func load<T:Decodable>(_ name:String,as:T.Type) -> T? {
        guard let data=try? Data(contentsOf:storageRoot.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self,from:data)
    }
    private func save<T:Encodable>(_ value:T,name:String) {
        ensureStorage(); guard let data=try? JSONEncoder().encode(value) else { return }
        try? data.write(to:storageRoot.appendingPathComponent(name),options:.atomic)
    }

    nonisolated private static func downsampleFile(_ url: URL) -> (NSImage,Data)? {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil) else { return nil }; return makeThumbnail(source)
    }
    nonisolated private static func downsampleData(_ data: Data) -> (NSImage,Data)? {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil) else { return nil }; return makeThumbnail(source)
    }
    nonisolated private static func makeThumbnail(_ source: CGImageSource) -> (NSImage,Data)? {
        let options:[CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:420,kCGImageSourceCreateThumbnailWithTransform:true]
        guard let cg=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { return nil }
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,"public.jpeg" as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,cg,[kCGImageDestinationLossyCompressionQuality:0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height)),output as Data)
    }
}
