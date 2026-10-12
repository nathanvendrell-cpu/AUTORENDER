import Foundation
import ImageIO
import CryptoKit

enum RenduStorage {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RenduBar", isDirectory: true)
    }

    static func ensure() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Previews"), withIntermediateDirectories: true)
    }

    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        ensure()
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: root.appendingPathComponent(name), options: .atomic)
    }
}

final class ExportFolderScanner {
    private struct Candidate {
        let url: URL
        let folder: URL
        let size: Int
        let modified: Date
        let ext: String
    }

    private struct Stamp {
        let size: Int64
        let modified: Date
        let seenAt: Date
    }

    private(set) var health = SourceHealth()
    private(set) var supportedFileCount = 0
    private(set) var listingTruncated = false
    private var stamps: [String: Stamp] = [:]
    private var validatedImages = Set<String>()
    private let allowed = Set(["png", "jpg", "jpeg", "tif", "tiff", "exr", "mov", "mp4", "m4v", "avi",
                               "wav", "aif", "aiff", "flac", "mp3", "m4a", "aac", "ogg",
                               "pdf", "glb", "gltf", "usdz"])
    private let decodableImages = Set(["png", "jpg", "jpeg", "tif", "tiff"])

    func scan(paths: [String], now: Date = Date(), limit: Int = 80, validateImages: Bool = true) -> [RenderEntry] {
        var candidates: [Candidate] = []
        var result: [RenderEntry] = []
        var liveIDs = Set<String>()
        var candidatePaths = Set<String>()
        var missing = 0
        for raw in paths {
            if Task.isCancelled { break }
            let folder = URL(fileURLWithPath: raw, isDirectory: true).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else { missing += 1; continue }
            candidates += children.compactMap { file -> Candidate? in
                let ext = file.pathExtension.lowercased()
                guard allowed.contains(ext),
                      !file.lastPathComponent.lowercased().contains("screenshot"),
                      !file.lastPathComponent.lowercased().contains("capture d’écran"),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0,
                      let modified = values.contentModificationDate else { return nil }
                guard candidatePaths.insert(file.standardizedFileURL.path).inserted else { return nil }
                return Candidate(url: file, folder: folder, size: size, modified: modified, ext: ext)
            }
        }
        supportedFileCount = candidates.count
        listingTruncated = candidates.count > limit
        health.online = !paths.isEmpty && missing < paths.count
        health.partial = missing > 0 && health.online
        health.isStale = !health.online
        health.checkedAt = now
        if health.online { health.lastGoodAt = now; health.observedAt = now }
        health.message = paths.isEmpty ? "Aucun dossier Mac ajouté" : "\(candidates.count) fichiers pris en charge · \(missing) dossier(s) indisponible(s)" + (listingTruncated ? " · \(limit) plus récents affichés" : "")
        var remainingValidations = validateImages ? 6 : 0
        for candidate in candidates.sorted(by: { $0.modified > $1.modified }).prefix(max(0, limit)) {
            if Task.isCancelled { break }
            let file = candidate.url
            let size = candidate.size
            let modified = candidate.modified
            let ext = candidate.ext
            let id = "mac-folder:" + file.standardizedFileURL.path + ":\(size):\(modified.timeIntervalSince1970)"
            liveIDs.insert(id)
            let previous = stamps[id]
            if previous == nil { validatedImages.remove(id) }
            let unchanged = previous?.size == Int64(size) && previous?.modified == modified
            let seenAt = unchanged ? (previous?.seenAt ?? now) : now
            stamps[id] = Stamp(size: Int64(size), modified: modified, seenAt: seenAt)
            let dwell = RenderKind.classify(file.lastPathComponent) == .image ? 5.0 : 20.0
            let stable = unchanged && now.timeIntervalSince(seenAt) >= dwell
                && now.timeIntervalSince(modified) >= dwell
            var state: RenderState = stable ? .stable : .pending
            if stable && decodableImages.contains(ext) {
                if validatedImages.contains(id) {
                    state = .complete
                } else if remainingValidations > 0 {
                    remainingValidations -= 1
                    if Self.canDecode(file, expectedSize: size, expectedModified: modified) {
                        validatedImages.insert(id)
                        state = .complete
                    }
                }
            }
            result.append(RenderEntry(id: id, source: .macFolder,
                                      job: candidate.folder.lastPathComponent,
                                      filename: file.lastPathComponent, modified: modified,
                                      state: state, path: file.path, previewURL: nil))
        }
        stamps = stamps.filter { liveIDs.contains($0.key) }
        validatedImages.formIntersection(liveIDs)
        return result
    }

    private static func canDecode(_ url: URL, expectedSize: Int, expectedModified: Date) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 64]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil,
              let after = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
        return after.fileSize == expectedSize && after.contentModificationDate == expectedModified
    }
}


struct FolderCollectionResult {
    let entries: [RenderEntry]
    let health: SourceHealth
}

actor FolderCollectionWorker {
    private let scanner = ExportFolderScanner()
    private let historyScanner = ExportFolderScanner()
    func scan(_ paths: [String]) -> FolderCollectionResult {
        let entries = scanner.scan(paths: paths)
        return FolderCollectionResult(entries: entries, health: scanner.health)
    }
    func history(_ paths: [String]) -> FolderCollectionResult {
        let entries = historyScanner.scan(paths: paths, limit: Int.max, validateImages: false)
        return FolderCollectionResult(entries: entries, health: historyScanner.health)
    }
}

struct RenderCatalogInput {
    let revision: UInt64
    let macJobs: [MacJob]
    let shadow: ShadowResponse?
    let declaration: ShadowDashboardDeclaration?
    let config: AppConfig
    let knownFolders: [String: String]
    let entries: [RenderEntry]
    let macEntries: [RenderEntry]
    let folderEntries: [RenderEntry]
    let shadowEntries: [RenderEntry]
    let shadowFolderEntries: [RenderEntry]
    let macHealth: SourceHealth
    let shadowHealth: SourceHealth
    let folderHealth: SourceHealth
    let remoteHealth: SourceHealth
    var preparedJobs: [RenderDashboardJob]? = nil
}

struct RenderCatalogRecord: Codable {
    var job: RenderDashboardJob
    var lastSeen: Date
}

struct RenderJobCatalogue: Codable {
    var schemaVersion = 1
    var revision: UInt64 = 0
    var records: [String: RenderCatalogRecord] = [:]
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, records }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard version <= 1 else { throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported catalogue schema") }
        records = try c.decodeIfPresent([String: RenderCatalogRecord].self, forKey: .records) ?? [:]
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        schemaVersion = 1
    }
}

private struct HistoryCursor: Codable {
    let jobID: String
    let fingerprint: String
    let offset: Int
}

actor RenderCatalogService {
    private var catalogue = RenderJobCatalogue()
    private var persistenceIssue: String?
    private var persistenceAllowed = true
    private let root: URL
    private var lastSaved: Data?
    private var histories: [String: [String: RenderEntry]] = [:]
    private var historyReadFailures = Set<String>()
    init(root: URL = RenduStorage.root.appendingPathComponent("Catalog", isDirectory: true)) {
        self.root = root
    }
    private var loaded = false
    private func loadCatalogue() {
        guard !loaded else { return }; loaded = true
        let file = root.appendingPathComponent("jobs.json")
        if let data = try? Data(contentsOf: file) {
            if let saved = try? JSONDecoder().decode(RenderJobCatalogue.self, from: data) { catalogue = saved; lastSaved = data }
            else { persistenceAllowed = false; persistenceIssue = "Catalogue existant illisible ou schéma futur · fichier préservé" }
        }
    }

    func build(_ input: RenderCatalogInput) -> RenderCatalogSnapshot? {
        guard !Task.isCancelled else { return nil }
        loadCatalogue()
        let current = Self.makeJobs(input)
        guard !Task.isCancelled else { return nil }
        for var job in current {
            let context = input.config.jobContexts[job.id]
            job.workID = job.sourceWorkID ?? context?.workID ?? job.workID ?? "job:" + job.id
            job.versionID = job.sourceVersionID ?? context?.versionID ?? job.versionID ?? job.id
            job.workTitle = context?.workTitle ?? job.workTitle ?? job.title
            job.versionLabel = context?.versionLabel ?? job.versionLabel
            if let project = context?.projectID { job.projectID = project }
            job.contextProvenance = context?.workID != nil ? "Configuration utilisateur explicite" : (job.contextProvenance)
            job.retainedHistorical = false
            job.estimatedRemainingSeconds = job.isFresh && job.activity == .running ? job.eta.flatMap { eta in job.observedAt.map { max(0, eta.timeIntervalSince($0)) } } : nil
            let seen = job.observedAt ?? Date()
            var persisted = job; persisted.previewEntries = []
            catalogue.records[job.id] = RenderCatalogRecord(job: persisted, lastSeen: seen)
        }
        let currentLookup = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _,new in new })
        var all: [RenderDashboardJob] = []
        for record in catalogue.records.values {
            var job = record.job
            let chosen = input.config.jobContexts[job.id]
            job.workID = job.sourceWorkID ?? chosen?.workID ?? ("job:" + job.id)
            job.versionID = job.sourceVersionID ?? chosen?.versionID ?? job.id
            job.workTitle = chosen?.workTitle ?? job.title
            job.versionLabel = chosen?.versionLabel
            job.projectID = chosen?.projectID ?? job.baseProjectID ?? job.projectID
            job.contextProvenance = job.sourceWorkID != nil ? "Métadonnée source workID" : (chosen?.workID != nil ? "Configuration utilisateur explicite" : "Job isolé · lien métier non déclaré")
            if let live = currentLookup[job.id] { job.previewEntries = live.previewEntries }
            else {
                job.retainedHistorical = true; job.isFresh = false
                job.historicalETA = job.historicalETA ?? job.eta; job.eta = nil; job.estimatedRemainingSeconds = nil
            }
            all.append(job)
            var stored = job; stored.previewEntries = []
            catalogue.records[job.id] = RenderCatalogRecord(job:stored,lastSeen:record.lastSeen)
        }
        all.sort { a,b in
            let pa = a.isFresh && a.activity == .running && !a.retainedHistorical
            let pb = b.isFresh && b.activity == .running && !b.retainedHistorical
            if pa != pb { return pa }
            if a.retainedHistorical != b.retainedHistorical { return !a.retainedHistorical }
            return (a.lastActivity ?? .distantPast) == (b.lastActivity ?? .distantPast) ? a.id < b.id : (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
        var counts = RenderCatalogStateCounts()
        for job in all {
            if job.retainedHistorical || !job.isFresh { counts.historical += 1; continue }
            switch job.activity { case .running: counts.running += 1; case .resumeRequired: counts.resumable += 1
            case .stopped: counts.stopped += 1; case .countsReached: counts.counted += 1; case .unknown: counts.unknown += 1 }
        }
        let grouped: [String:[RenderDashboardJob]] = Dictionary(grouping:all) { job -> String in
            let work = job.workID ?? ("job:" + job.id)
            return job.projectID + "\u{1f}" + work
        }
        var works: [RenderCatalogWork] = []
        for versions in grouped.values {
            guard let first = versions.first else { continue }
            var types = Set<RenderWorkType>()
            for version in versions { if let type = version.workType { types.insert(type) } }
            let type: RenderWorkType? = types.count == 1 ? types.first : nil
            let workID = first.workID ?? ("job:" + first.id)
            let work = RenderCatalogWork(id:workID,projectID:first.projectID,title:first.workTitle ?? first.title,workType:type,jobs:versions)
            works.append(work)
        }
        works.sort { (a:RenderCatalogWork,b:RenderCatalogWork) -> Bool in
            if a.projectID == b.projectID { return a.id < b.id }
            return a.projectID < b.projectID
        }
        catalogue.revision = max(catalogue.revision + 1, input.revision)
        guard !Task.isCancelled else { return nil }
        if persistenceAllowed {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(catalogue)
                if data != lastSaved {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try data.write(to: root.appendingPathComponent("jobs.json"), options: .atomic); lastSaved = data
                }
            } catch { persistenceIssue = "Catalogue non enregistré : " + error.localizedDescription }
        }
        return RenderCatalogSnapshot(revision: catalogue.revision, generatedAt: Date(), jobs: all,
            projects: RenderDashboard.projects(all), works: works, knownJobCount: all.count,
            observedJobCount: currentLookup.values.filter(\.isFresh).count, stateCounts: counts, persistenceIssue: persistenceIssue)
    }

    private static func makeJobs(_ input: RenderCatalogInput) -> [RenderDashboardJob] {
        if let prepared = input.preparedJobs { return prepared }
        let known = input.knownFolders; let config = input.config
        var jobs = input.macJobs.map { job -> RenderDashboardJob in
            let rep = RenderEntry(id: job.id, source: .macMonitor, job: job.titre, filename: "", modified: .distantPast,
                state: .pending, path: known[job.id].map { $0 + "/__job__" }, previewURL: nil, monitorJobID: job.id)
            let identity = RenderOrganization.projectID(for: rep, jobs: input.macJobs, knownFolders: known, labels: config.folderProjects)
            let type = RenderOrganization.workType(for: rep, jobs: input.macJobs, knownFolders: known, configured: config.folderWorkTypes)
            let previews = RenderDashboard.macHistory(jobID: job.id, root: known[job.id], folders: input.folderEntries, monitors: input.macEntries)
            var result = RenderDashboard.applyingProjectLink(RenderDashboard.mac(job, health: input.macHealth,
                projectID: identity, workType: type, previews: Array(previews.filter { $0.fileMediaType == .image }.prefix(2))), links: config.dashboardProjectLinks)
            result.latestOutput = previews.first
            if let folder=known[job.id] {
                result.openTargets = [folderTarget(folder,title:job.titre,remote:false,config:config,remoteHealth:input.remoteHealth)]
            }
            result.revealURL = verifiedOutputURL(result.latestOutput,targets:result.openTargets)
            result.workID = job.workID; result.versionID = job.versionID; result.sourceWorkID = job.workID; result.sourceVersionID = job.versionID
            if job.workID != nil { result.contextProvenance = "Métadonnée source workID" }
            if result.projectTitle == nil && identity.hasPrefix("label:") { result.projectTitle = String(identity.dropFirst(6)) }
            result.baseProjectID = result.projectID
            return result
        }
        if let payload = input.shadow {
            var result = RenderDashboard.shadow(payload, health:input.shadowHealth,declaration:input.declaration,previews:input.shadowEntries)
            if result.id == "shadow:unidentified", let configured=RenderDashboard.configuredShadowID(payload,config:config) { result.id=configured }
            result = RenderDashboard.applyingProjectLink(result,links:config.dashboardProjectLinks)
            let roots=config.dashboardJobFolders[result.id] ?? []
            result.openTargets = roots.map { folderTarget($0,title:($0.replacingOccurrences(of:"\\",with:"/") as NSString).lastPathComponent,remote:true,config:config,remoteHealth:input.remoteHealth) }
            result.latestOutput = RenderDashboard.shadowHistory(roots:roots,folders:input.shadowFolderEntries,monitors:[]).first
            result.revealURL = verifiedOutputURL(result.latestOutput,targets:result.openTargets)
            let types = Set((config.dashboardJobFolders[result.id] ?? []).compactMap { root in
                config.folderWorkTypes.sorted { $0.key.count > $1.key.count }.first { RenderOrganization.isInside(root + "/__job__", root: $0.key) }?.value
            })
            if !types.isEmpty { result.workType = types.count == 1 ? types.first : nil }
            result.workID = payload.workID; result.versionID = payload.versionID; result.sourceWorkID = payload.workID; result.sourceVersionID = payload.versionID
            if payload.workID != nil { result.contextProvenance = "Métadonnée source workID" }
            result.baseProjectID = result.projectID
            jobs.append(result)
        }
        let represented = Set(jobs.map(\.projectID))
        let grouped = Dictionary(grouping: input.entries) { RenderOrganization.projectID(for: $0, jobs: input.macJobs, knownFolders: known, labels: config.folderProjects) }
        for (identity, entries) in grouped where !represented.contains(identity) && entries.contains(where: { $0.source == .macFolder || $0.source == .shadowFolder }) {
            let title = entries.first.map { RenderOrganization.project(for: $0, jobs: input.macJobs, knownFolders: known, labels: config.folderProjects) } ?? "Projet non identifié"
            let types = Set(entries.compactMap { RenderOrganization.workType(for: $0, jobs: input.macJobs, knownFolders: known, configured: config.folderWorkTypes) })
            let summary = RenderProjectSummary(title: title, entries: entries, workType: types.count == 1 ? types.first : nil, id: identity)
            var folderJob=RenderDashboard.folder(summary,health:entries.contains { !$0.source.isShadow } ? input.folderHealth : input.remoteHealth)
            let configuredRoots = config.macFolders + config.shadowFolders
            folderJob.openTargets = configuredRoots.filter { root in entries.contains { $0.path.map { RenderOrganization.isInside($0,root:root) } ?? false } }.map {
                folderTarget($0,title:($0.replacingOccurrences(of:"\\",with:"/") as NSString).lastPathComponent,remote:config.shadowFolders.contains($0),config:config,remoteHealth:input.remoteHealth)
            }
            folderJob.latestOutput=summary.latest
            folderJob.revealURL=verifiedOutputURL(folderJob.latestOutput,targets:folderJob.openTargets)
            jobs.append(folderJob)
        }
        return jobs
    }

    private static func verifiedOutputURL(_ output:RenderEntry?,targets:[RenderFolderTarget]) -> URL? {
        guard let output, output.state != .pending, let path=output.path else { return nil }
        var url:URL?
        if !output.source.isShadow { url=URL(fileURLWithPath:path) }
        else {
            let normalized=path.replacingOccurrences(of:"\\",with:"/")
            if let target=targets.sorted(by:{ ($0.remoteDisplay?.count ?? 0) > ($1.remoteDisplay?.count ?? 0) }).first(where:{
                guard let root=$0.remoteDisplay else { return false }
                return $0.location != nil && RenderOrganization.isInside(path,root:root)
            }),let root=target.remoteDisplay?.replacingOccurrences(of:"\\",with:"/"),let location=target.location {
                let relative=String(normalized.dropFirst(root.count)).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
                url=location.appendingPathComponent(relative)
            }
        }
        guard let url,let values=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),
              values.isRegularFile==true,values.isSymbolicLink != true else { return nil }
        return url
    }

    private static func folderTarget(_ path:String,title:String,remote:Bool,config:AppConfig,remoteHealth:SourceHealth) -> RenderFolderTarget {
        let id=SHA256.hash(data:Data(path.utf8)).map { String(format:"%02x",$0) }.joined()
        if remote {
            if let explicit=config.remoteMirrors[path] {
                var directory:ObjCBool=false
                let url=URL(fileURLWithPath:explicit,isDirectory:true)
                let exists=FileManager.default.fileExists(atPath:url.path,isDirectory:&directory) && directory.boolValue
                return RenderFolderTarget(id:id,title:title,location:exists ? url : nil,remoteDisplay:path,isVerified:exists,verifiedAt:exists ? Date() : nil)
            }
            let verified=remoteHealth.online && !remoteHealth.partial
            return RenderFolderTarget(id:id,title:title,location:nil,remoteDisplay:path,isVerified:verified,verifiedAt:verified ? remoteHealth.observedAt : nil)
        }
        var directory:ObjCBool=false
        let url=URL(fileURLWithPath:path,isDirectory:true)
        let exists=FileManager.default.fileExists(atPath:url.path,isDirectory:&directory) && directory.boolValue
        return RenderFolderTarget(id:id,title:title,location:exists ? url : nil,remoteDisplay:nil,isVerified:exists,verifiedAt:exists ? Date() : nil)
    }

    func history(jobID: String, incoming: [RenderEntry], cursor: String?, limit: Int, coverage: String, scope: String) -> RenderHistoryPage {
        if histories[jobID] == nil {
            let file = historyURL(jobID)
            var saved:[RenderEntry] = []
            if let bytes=try? Data(contentsOf:file) {
                if let decoded=try? JSONDecoder().decode([RenderEntry].self,from:bytes) { saved=decoded }
                else { historyReadFailures.insert(jobID) }
            }
            histories[jobID] = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _,new in new })
        }
        for entry in incoming { histories[jobID]?[entry.id] = entry }
        let entries = Array((histories[jobID] ?? [:]).values).sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
        let fingerprint = SHA256.hash(data: Data((scope + entries.map(\.id).joined(separator: "\n")).utf8)).map { String(format:"%02x",$0) }.joined()
        let historyRevision = UInt64(fingerprint.prefix(16), radix:16) ?? 0
        var offset = 0
        if let cursor {
            guard let data = Data(base64Encoded: cursor), let token = try? JSONDecoder().decode(HistoryCursor.self, from: data),
                  token.jobID == jobID, token.fingerprint == fingerprint, token.offset >= 0, token.offset <= entries.count else {
                return RenderHistoryPage(entries: [], nextCursor: nil, totalKnown: entries.count, coverage: "Curseur périmé · recharger ce scope", snapshotRevision: historyRevision)
            }
            offset = token.offset
        }
        let size = min(max(1,limit),100); let page = Array(entries.dropFirst(offset).prefix(size)); let next = offset + page.count
        let token = next < entries.count ? (try? JSONEncoder().encode(HistoryCursor(jobID: jobID, fingerprint: fingerprint, offset: next)))?.base64EncodedString() : nil
        if !Task.isCancelled && persistenceAllowed && !historyReadFailures.contains(jobID) {
            do {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Outputs"), withIntermediateDirectories: true)
                try JSONEncoder().encode(entries).write(to: historyURL(jobID), options: .atomic)
            } catch { persistenceIssue = "Historique non enregistré : " + error.localizedDescription }
        }
        return RenderHistoryPage(entries: page, nextCursor: token, totalKnown: entries.count, coverage: coverage + (historyReadFailures.contains(jobID) ? " · ancien historique illisible préservé" : " · métadonnées connues conservées"), snapshotRevision: historyRevision)
    }
    private func historyURL(_ id: String) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format:"%02x",$0) }.joined()
        return root.appendingPathComponent("Outputs/" + hash + ".json")
    }
}
