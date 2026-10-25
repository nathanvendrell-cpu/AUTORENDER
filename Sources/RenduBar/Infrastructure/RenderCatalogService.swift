import Foundation
import CryptoKit

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
    var shadowRunJobs:[RenderDashboardJob] = []
    var preparedJobs: [RenderDashboardJob]? = nil
    var nativeObservations: [NativeRenderObservation] = []
    var nativeHistoryObservations: [NativeRenderObservation] = []
}

struct RenderCatalogRecord: Codable {
    var job: RenderDashboardJob
    var lastSeen: Date
}

struct RenderJobCatalogue: Codable {
    var schemaVersion = 1
    var revision: UInt64 = 0
    var historyRevision:UInt64=0
    var records: [String: RenderCatalogRecord] = [:]
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, historyRevision, records }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard version <= 1 else { throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported catalogue schema") }
        records = try c.decodeIfPresent([String: RenderCatalogRecord].self, forKey: .records) ?? [:]
        historyRevision = try c.decodeIfPresent(UInt64.self,forKey:.historyRevision) ?? 0
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
    private var lastSemantic: Data?
    private(set) var catalogueWriteCount = 0
    private(set) var historyWriteCount = 0
    private(set) var historySortCount = 0
    // Charge is encoded JSON bytes plus both value containers and an allowance for dictionary buckets.
    // This is a deterministic admission budget, not an exact RSS or transient decode bound.
    static let historyScopeLimit = 4
    static let historyEntryLimit = 10_000
    static let historyChargeLimit = 8 * 1024 * 1024
    private struct HistoryCache {
        let byID: [String:RenderEntry]
        let ordered: [RenderEntry]
        let scope: String
        let fingerprint: String
        let charge: Int
        var access: UInt64
    }
    private var historyCaches: [String:HistoryCache] = [:]
    private var historyClock: UInt64 = 0
    private var historyGeneration: UInt64 = 0

    func historyCacheStats() -> (scopes:Int, entries:Int, chargeBytes:Int, jobIDs:[String]) {
        (historyCaches.count, historyCaches.values.reduce(0) { $0 + $1.ordered.count },
         historyCaches.values.reduce(0) { $0 + $1.charge }, historyCaches.keys.sorted())
    }

    private func admitHistory(_ cache:HistoryCache, jobID:String) {
        historyCaches.removeValue(forKey:jobID)
        guard cache.ordered.count <= Self.historyEntryLimit, cache.charge <= Self.historyChargeLimit else { return }
        while !historyCaches.isEmpty {
            let stats=historyCacheStats()
            if stats.scopes < Self.historyScopeLimit && stats.entries + cache.ordered.count <= Self.historyEntryLimit
                && stats.chargeBytes + cache.charge <= Self.historyChargeLimit { break }
            guard let victim=historyCaches.min(by:{ $0.value.access < $1.value.access })?.key else { break }
            historyCaches.removeValue(forKey:victim)
        }
        historyCaches[jobID]=cache
    }
    init(root: URL = RenduStorage.root.appendingPathComponent("Catalog", isDirectory: true), lifetime:RenderTaskLifetime? = nil) {
        self.root = root;self.lifetime=lifetime
    }
    private let lifetime:RenderTaskLifetime?
    private struct HistoryIdentity:Equatable {
        let project:String;let subproject:String?;let scene:String?;let work:String?;let version:String?
        let projectTitle:String?;let subprojectTitle:String?;let sceneTitle:String?;let workTitle:String?;let versionLabel:String?
        let title:String;let context:String;let assignment:RenderContextAssignment?
        let terminal:Bool;let active:Bool;let archived:Date?;let output:RenderOutputAvailability?;let libraryVersion:String?
        init(_ job:RenderDashboardJob) {
            project=job.projectID;subproject=job.subprojectID;scene=job.sceneID;work=job.workID;version=job.versionID
            projectTitle=job.projectTitle;subprojectTitle=job.subprojectTitle;sceneTitle=job.sceneTitle;workTitle=job.workTitle;versionLabel=job.versionLabel
            title=job.title;context=job.contextProvenance;assignment=job.contextAssignment
            terminal=job.isTerminalRender;active=job.isDetectedActiveRender;archived=job.archivedAt;output=job.outputAvailability;libraryVersion=job.libraryVersion
        }
    }
    private struct ClassificationConfig:Equatable {
        let bindings:[RenderProjectBinding]?;let rules:[RenderContextRule]?;let roots:[String:String];let contexts:[String:RenderJobContext]
        init(_ c:AppConfig){bindings=c.projectBindings;rules=c.contextRules;roots=c.folderProjects;contexts=c.jobContexts}
    }
    private var classificationConfig:ClassificationConfig?
    private(set) var classificationPassCount=0
    private var historyIdentities:[String:HistoryIdentity]=[:]
    private var loaded = false
    private func loadCatalogue() {
        guard !loaded else { return }; loaded = true
        let file = root.appendingPathComponent("jobs.json")
        if let data = try? Data(contentsOf: file) {
            if let saved = try? JSONDecoder().decode(RenderJobCatalogue.self, from: data) { catalogue = saved; lastSaved = data; lastSemantic = Self.semanticData(data) }
            else { persistenceAllowed = false; persistenceIssue = "Catalogue existant illisible ou schéma futur · fichier préservé" }
        }
    }

    func build(_ input: RenderCatalogInput) -> RenderCatalogSnapshot? {
        guard !Task.isCancelled,lifetime?.isOpen != false else { return nil }
        loadCatalogue()
        let resolver=RenderContextResolver(config:input.config)
        let nextConfig=ClassificationConfig(input.config),reclassify=classificationConfig != nextConfig
        classificationConfig=nextConfig
        let current = Self.makeJobs(input)
        guard !Task.isCancelled else { return nil }
        for var job in current {
            if job.id.hasPrefix("shadow:run:") {
                let prior=catalogue.records[job.id]?.job
                if let start=job.renderStartedAt {
                    if let priorStart=prior?.renderStartedAt,prior?.isTerminalRender != true {job.renderStartedAt=priorStart;job.libraryStartedAtRaw=prior?.libraryStartedAtRaw}
                    job.libraryInvocationID=RenderContextPath.digest(job.id+"|"+String((job.renderStartedAt ?? start).timeIntervalSince1970))
                } else if job.finalOutputProof == .scriptFinalContract {
                    job.renderStartedAt=prior?.renderStartedAt;job.libraryStartedAtRaw=prior?.libraryStartedAtRaw;job.libraryInvocationID=prior?.libraryInvocationID
                }
                if let raw=job.libraryStartedAtRaw,job.remoteArtifact?.scriptProof != nil {job.remoteArtifact?.startedAt=raw;job.remoteArtifact?.invocationToken=String((job.libraryInvocationID ?? job.id).prefix(32))}
            }
            let context = input.config.jobContexts[job.id]
            job.workID = job.sourceWorkID ?? context?.workID ?? job.workID ?? "job:" + job.id
            job.versionID = job.sourceVersionID ?? context?.versionID ?? job.versionID ?? job.id
            job.workTitle = context?.workTitle ?? job.workTitle ?? job.title
            job.versionLabel = context?.versionLabel ?? job.versionLabel
            if let project = context?.projectID { job.projectID = project }
            job.contextProvenance = context?.workID != nil ? "Configuration utilisateur explicite" : (job.contextProvenance)
            job.retainedHistorical = !job.isFresh
            job.estimatedRemainingSeconds = job.isFresh && job.activity == .running ? job.eta.flatMap { eta in job.observedAt.map { max(0, eta.timeIntervalSince($0)) } } : nil
            job=resolver.apply(job);classificationPassCount += 1
            let seen = job.observedAt ?? Date()
            var persisted = job; persisted.previewEntries = []
            catalogue.records[job.id] = RenderCatalogRecord(job: persisted, lastSeen: seen)
        }
        let currentLookup = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _,new in new })
        var all: [RenderDashboardJob] = []
        var reactivatedArchives: [String] = []
        for record in catalogue.records.values {
            var job = record.job
            if reclassify && currentLookup[job.id]==nil {
            let chosen = input.config.jobContexts[job.id]
            job.workID = job.sourceWorkID ?? chosen?.workID ?? ("job:" + job.id)
            job.versionID = job.sourceVersionID ?? chosen?.versionID ?? job.id
            job.workTitle = chosen?.workTitle ?? job.workTitle ?? job.title
            job.versionLabel = chosen?.versionLabel ?? job.versionLabel
            job.projectID = chosen?.projectID ?? job.baseProjectID ?? job.projectID
            job.contextProvenance = job.sourceWorkID != nil ? "Métadonnée source workID" : (chosen?.workID != nil ? "Configuration utilisateur explicite" : job.contextProvenance)
                job=resolver.apply(job);classificationPassCount += 1
            }
            if let live = currentLookup[job.id] { job.previewEntries = live.previewEntries }
            else {
                job.retainedHistorical = true; job.isFresh = false
                job.historicalETA = job.historicalETA ?? job.eta; job.eta = nil; job.estimatedRemainingSeconds = nil
            }
            let requestedArchive = input.config.jobArchives[job.id]
            let confirmedReactivation = job.isDetectedActiveRender
            if requestedArchive != nil && confirmedReactivation { reactivatedArchives.append(job.id) }
            // Existing archive preference is independent from eligibility for a new archive.
            // Unknown/nonterminal freshness alone is not evidence of a confirmed reactivation.
            job.archivedAt = confirmedReactivation ? nil : requestedArchive
            all.append(job)
            var stored = job; stored.previewEntries = []
            catalogue.records[job.id] = RenderCatalogRecord(job:stored,lastSeen:record.lastSeen)
        }
        all.sort { a,b in
            let pa = a.isDetectedActiveRender
            let pb = b.isDetectedActiveRender
            if pa != pb { return pa }
            if a.retainedHistorical != b.retainedHistorical { return !a.retainedHistorical }
            return (a.lastActivity ?? .distantPast) == (b.lastActivity ?? .distantPast) ? a.id < b.id : (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
        var counts = RenderCatalogStateCounts()
        for job in all {
            if job.isArchived { counts.archived += 1; continue }
            if job.retainedHistorical || !job.isFresh { counts.historical += 1; continue }
            switch job.activity { case .running: if job.isDetectedActiveRender {counts.running += 1} else {counts.unknown += 1}; case .resumeRequired: counts.resumable += 1
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
        let identities=Dictionary(all.map{($0.id,HistoryIdentity($0))},uniquingKeysWith:{$1})
        if identities != historyIdentities {catalogue.historyRevision &+= 1;historyIdentities=identities}
        catalogue.revision = max(catalogue.revision + 1, input.revision)
        guard !Task.isCancelled else { return nil }
        if persistenceAllowed {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(catalogue)
                let semantic=Self.semanticData(data)
                if semantic != lastSemantic {
                    try Task.checkCancellation();try lifetime?.check()
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try Task.checkCancellation();try lifetime?.check()
                    try data.write(to: root.appendingPathComponent("jobs.json"), options: .atomic); lastSaved = data; lastSemantic=semantic; catalogueWriteCount += 1
                    persistenceIssue = nil
                }
            } catch is CancellationError {
                // Superseded snapshot/lifetime cancellation is not a durable write failure.
                return nil
            } catch { persistenceIssue = "Catalogue non enregistré : " + error.localizedDescription }
        }
        return RenderCatalogSnapshot(revision: catalogue.revision, generatedAt: Date(), jobs: all,
            projects: RenderDashboard.projects(all), works: works, knownJobCount: all.count,
            observedJobCount: currentLookup.values.filter(\.isFresh).count,stateCounts:counts,persistenceIssue:persistenceIssue ?? input.config.archivePayloadError,reactivatedArchiveIDs:reactivatedArchives,historyRevision:catalogue.historyRevision,libraryJobs:current.filter{$0.finalOutputProof != nil || $0.isDetectedActiveRender}.compactMap{catalogue.records[$0.id]?.job})
    }

    private static func semanticData(_ data:Data) -> Data? {
        guard var object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],var records=object["records"] as? [String:[String:Any]] else { return nil }
        object.removeValue(forKey:"revision")
        for id in records.keys {
            var record=records[id] ?? [:];record.removeValue(forKey:"lastSeen")
            if var job=record["job"] as? [String:Any] {
                for key in ["observedAt","eta","historicalETA","estimatedRemainingSeconds","process","gpu","gpuRaw"] { job.removeValue(forKey:key) }
                if let targets=job["openTargets"] as? [[String:Any]] {
                    job["openTargets"]=targets.map { target -> [String:Any] in var t=target;t.removeValue(forKey:"verifiedAt");return t }
                }
                record["job"]=job
            }
            records[id]=record
        }
        object["records"]=records
        return try? JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
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
        let monitoredRoots=Set(input.macJobs.compactMap { known[$0.id] }.map(AppConfig.normalizedMacFolder))
        let nativeRoots=Dictionary(input.nativeObservations.compactMap { $0.outputRoot }.map { ($0,1) },uniquingKeysWith:+)
        let dismissedRoots=Set(config.dismissedMacFolders.map(AppConfig.normalizedMacFolder))
        for observation in input.nativeObservations + input.nativeHistoryObservations {
            // A shared path is not a process/run identity link. Keep every distinct candidate.
            var result=observation.dashboard(entries:input.folderEntries,
                sharedRoot:observation.outputRoot.map { nativeRoots[$0,default:0]>1 || monitoredRoots.contains($0) } ?? false)
            if let root=observation.outputRoot,!dismissedRoots.contains(root) {
                result.openTargets=[folderTarget(root,title:observation.producer,remote:false,config:config,remoteHealth:input.remoteHealth)]
                result.latestOutput=observation.receiptBoundPreview ? observation.verifiedPreviewEntry:input.folderEntries.filter { $0.path.map(observation.previewScopeIncludes) ?? false }.max { $0.modified < $1.modified }
                result.revealURL=verifiedOutputURL(result.latestOutput,targets:result.openTargets)
            }
            result=RenderDashboard.applyingProjectLink(result,links:config.dashboardProjectLinks)
            result.baseProjectID=result.projectID
            jobs.append(result)
        }
        jobs.append(contentsOf:input.shadowRunJobs)
        let represented = Set(jobs.map(\.projectID))
        let grouped = Dictionary(grouping: input.entries) { RenderOrganization.projectID(for: $0, jobs: input.macJobs, knownFolders: known, labels: config.folderProjects) }
        for (identity, unclaimed) in grouped where !represented.contains(identity) {
            let entries=unclaimed.filter { entry in
                guard let path=entry.path else { return true }
                return !(input.nativeObservations + input.nativeHistoryObservations).contains { $0.previewScopeIncludes(path) }
            }
            guard entries.contains(where: { $0.source == .macFolder || $0.source == .shadowFolder }) else { continue }
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

    func history(jobID: String, incoming: [RenderEntry], cursor: String?, limit: Int, coverage: String, scope: String,
                 isCurrent: @Sendable () async -> Bool = { true }) async -> RenderHistoryPage {
        guard !Task.isCancelled, await isCurrent() else { return cancelledHistory() }
        historyGeneration &+= 1; let generation=historyGeneration
        let cached=historyCaches[jobID]
        var byID=cached?.byID ?? [:]
        var encoded:Data?
        var issue:String?
        if cached == nil {
            let file=historyURL(jobID)
            if FileManager.default.fileExists(atPath:file.path) {
                do {
                    let bytes=try Data(contentsOf:file)
                    let saved=try JSONDecoder().decode([RenderEntry].self,from:bytes)
                    byID=Dictionary(saved.map { ($0.id,$0) },uniquingKeysWith:{ _,new in new });encoded=bytes
                } catch { issue="Ancien historique illisible · fichier préservé : " + error.localizedDescription }
            }
        }
        var changed=false
        for entry in incoming {
            if byID[entry.id] != entry { changed=true;byID[entry.id]=entry }
        }
        let ordered:[RenderEntry];let fingerprint:String
        if !changed, let cached, cached.scope == scope {
            ordered=cached.ordered;fingerprint=cached.fingerprint
        } else {
            ordered=Array(byID.values).sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
            var hash=SHA256();hash.update(data:Data(scope.utf8))
            for (index,entry) in ordered.enumerated() {
                if index > 0 { hash.update(data:Data([10])) }
                hash.update(data:Data(entry.id.utf8))
            }
            fingerprint=hash.finalize().map { String(format:"%02x",$0) }.joined();historySortCount += 1
        }
        let historyRevision=UInt64(fingerprint.prefix(16),radix:16) ?? 0
        var offset=0
        if let cursor {
            guard let data=Data(base64Encoded:cursor),let token=try? JSONDecoder().decode(HistoryCursor.self,from:data),
                  token.jobID == jobID, token.fingerprint == fingerprint, token.offset >= 0, token.offset <= ordered.count else {
                return RenderHistoryPage(entries:[],nextCursor:nil,totalKnown:ordered.count,
                    coverage:"Curseur périmé · recharger ce scope",snapshotRevision:historyRevision)
            }
            offset=token.offset
        }
        // Recheck MainActor generation/scope after local preparation, before any durable write or admission.
        guard !Task.isCancelled, await isCurrent(), !Task.isCancelled, generation == historyGeneration else { return cancelledHistory() }
        if changed && issue == nil {
            if !persistenceAllowed { issue=persistenceIssue ?? "Persistance indisponible" }
            else {
                do {
                    let data=try JSONEncoder().encode(ordered)
                    guard !Task.isCancelled else { return cancelledHistory() }
                    try Task.checkCancellation();try lifetime?.check()
                    try FileManager.default.createDirectory(at:root.appendingPathComponent("Outputs"),withIntermediateDirectories:true)
                    try Task.checkCancellation();try lifetime?.check()
                    try data.write(to:historyURL(jobID),options:.atomic);encoded=data;historyWriteCount += 1
                } catch { issue="Historique non enregistré : " + error.localizedDescription }
            }
        }
        let size=min(max(1,limit),100)
        let page=Array(ordered.dropFirst(offset).prefix(size));let next=offset+page.count
        func token(_ position:Int) -> String? {
            (try? JSONEncoder().encode(HistoryCursor(jobID:jobID,fingerprint:fingerprint,offset:position)))?.base64EncodedString()
        }
        if let issue {
            // Keep the previously admitted durable cache intact. Unsaved metadata is not navigable as durable history.
            return RenderHistoryPage(entries:page,nextCursor:nil,totalKnown:ordered.count,
                coverage:coverage + " · métadonnées temporaires non sauvegardées · " + issue,
                snapshotRevision:historyRevision,persistenceError:issue)
        }
        guard !Task.isCancelled else { return cancelledHistory() }
        historyClock &+= 1
        if !changed, let cached, cached.scope == scope {
            var touched=cached;touched.access=historyClock;historyCaches[jobID]=touched
        } else {
            if encoded == nil { encoded=try? JSONEncoder().encode(ordered) }
            let containers=ordered.count.multipliedReportingOverflow(by:2 * MemoryLayout<RenderEntry>.stride + 128)
            let charge=(encoded?.count ?? 0).addingReportingOverflow(containers.partialValue)
            let chargedBytes=containers.overflow || charge.overflow || encoded == nil ? Int.max : charge.partialValue
            admitHistory(HistoryCache(byID:byID,ordered:ordered,scope:scope,fingerprint:fingerprint,
                charge:chargedBytes,access:historyClock),jobID:jobID)
        }
        return RenderHistoryPage(entries:page,nextCursor:next < ordered.count ? token(next) : nil,totalKnown:ordered.count,
            coverage:coverage + " · métadonnées connues conservées",snapshotRevision:historyRevision,
            previousCursor:offset > 0 ? token(max(0,offset-size)) : nil,pageCursor:token(offset))
    }

    private func cancelledHistory() -> RenderHistoryPage {
        RenderHistoryPage(entries:[],nextCursor:nil,totalKnown:nil,coverage:"Scope modifié ou demande annulée",snapshotRevision:0)
    }
    private func historyURL(_ id: String) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format:"%02x",$0) }.joined()
        return root.appendingPathComponent("Outputs/" + hash + ".json")
    }
}


