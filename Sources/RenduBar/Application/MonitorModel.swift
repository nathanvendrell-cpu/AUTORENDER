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
    var thumbnails:[String:NSImage] {previews.thumbnails}
    @Published private(set) var shadowHealth = SourceHealth()
    @Published private(set) var macHealth = SourceHealth()
    @Published private(set) var folderHealth = SourceHealth()
    @Published private(set) var remoteHealth = SourceHealth()
    @Published private(set) var shadowSummary = "Aucune mesure Shadow"
    @Published private(set) var macJobs: [MacJob] = []
    @Published private(set) var shadowTasks: [ShadowTask] = []
    @Published private(set) var config = AppConfig()
    @Published private(set) var lastScan = Date()
    @Published private(set) var configurationError: String?
    private var configurationWritable = true
    @Published private(set) var compactPreviewVisible=false
    private let previews: RenderPreviewStore
    private var previewUpdates:AnyCancellable?
    @Published private(set) var archiveError: String?
    @Published private(set) var organizationError: String?
    @Published private(set) var catalogSnapshot = RenderCatalogSnapshot.empty
    private var lastCatalogHistoryRevision:UInt64=0
    @Published private(set) var historyRevision:UInt64=0
    @Published private(set) var activeRenderJobs:[RenderDashboardJob]=[]
    @Published private(set) var dashboardProjects: [RenderDashboardProject] = []
    @Published private(set) var libraryRecords:[RenderLibraryRecord]=[]
    @Published private(set) var libraryError:String?
    private let managedLibrary:ManagedRenderLibrary
    private let libraryCoordinator:RenderLibraryCoordinator
    private var libraryTask:Task<Void,Never>?
    @Published private(set) var libraryBusy=false
    @Published private(set) var libraryActivities:[RenderLibraryActivity]=[]
    var librarySettings:RenderLibrarySettings {config.librarySettings ?? .observation}
    @discardableResult
    func setLibraryMode(_ mode:RenderLibraryMode,rootPath:String?=nil,manageFutureJobs:Bool=false)->Bool {
        guard !stopping,!libraryBusy else{return false}
        let selected=rootPath ?? librarySettings.rootPath
        let root=URL(fileURLWithPath:RenderContextPath.absolute(selected) ?? selected)
        guard (rootPath ?? librarySettings.rootPath).hasPrefix("/"),!root.pathComponents.contains(where:{$0.caseInsensitiveCompare("BRAIN") == .orderedSame}),
              mode == .catalogueOnly || manageFutureJobs else{libraryError="Activation explicite des nouveaux jobs et bibliothèque hors BRAIN requises";return false}
        let settings=RenderLibrarySettings(mode:mode,rootPath:root.path,activatedAt:mode == .managedLibrary ? Date():nil,exportInMemory:librarySettings.exportInMemory)
        let saved=mutatePreferences{$0.librarySettings=settings}
        if saved {libraryError=nil;scheduleLibraryPolicy(settings)}
        return saved
    }
    @discardableResult
    func setInMemoryExportEnabled(_ enabled:Bool)->Bool {
        guard !stopping,!libraryBusy else{return false}
        var settings=librarySettings;settings.exportInMemory=enabled
        let saved=mutatePreferences{$0.librarySettings=settings}
        if saved {libraryError=nil;scheduleLibraryPolicy(settings)}
        return saved
    }
    @discardableResult
    func setProjectBindings(_ bindings:[RenderProjectBinding])->Bool {
        guard bindings.count<=128,Set(bindings.map(\.id)).count==bindings.count,bindings.allSatisfy(\.isValid) else{organizationError="Liaisons de projet invalides";return false}
        guard mutatePreferences({$0.projectBindings=bindings}) else{return false};combine();return true
    }
    @discardableResult
    func setContextRules(_ rules:[RenderContextRule])->Bool {
        guard rules.count<=128,Set(rules.map(\.id)).count==rules.count,rules.allSatisfy(\.isValid) else{organizationError="Règles explicites invalides ou ambiguës";return false}
        guard mutatePreferences({$0.contextRules=rules}) else{return false};combine();return true
    }
    func previewLibraryBatch(_ candidates:[RenderLibraryCandidate]) async->[RenderLibraryPlan] {
        guard !stopping,candidates.count<=200 else{return []}
        let jobs=Dictionary(catalogSnapshot.jobs.map{($0.id,$0)},uniquingKeysWith:{$1});var plans:[RenderLibraryPlan]=[]
        for candidate in candidates {
            guard let job=jobs[candidate.jobID] else{continue}
            plans.append(await managedLibrary.preview(job:job,candidate:candidate,settings:librarySettings))
        }
        return plans
    }
    func applyLibraryBatch(_ plans:[RenderLibraryPlan],approval:RenderLibraryApproval) async->[RenderLibraryRecord] {
        guard !stopping,!libraryBusy,!plans.isEmpty,plans.count<=200,approval.planIDs==Set(plans.map(\.id)) else{libraryError="Validation du lot exact requise";return []}
        libraryBusy=true;defer{libraryBusy=false}
        var result:[RenderLibraryRecord]=[]
        for plan in plans {
            do {let record=try await managedLibrary.execute(plan,approval:approval,settings:librarySettings);result.append(record)}
            catch {libraryError=String(describing:error);break}
        }
        libraryRecords=await managedLibrary.recentRecords();if !result.isEmpty {historyRevision &+= 1};return result
    }
    func reloadLibraryRecords() async {
        do {libraryRecords=try await managedLibrary.loadRecent(settings:librarySettings)}
        catch {libraryError=String(describing:error)}
    }
    func undoLibraryRecord(_ id:String,approvedRecordID:String) async->Bool {
        guard !stopping,!libraryBusy else{return false}
        libraryBusy=true;defer{libraryBusy=false}
        do {_ = try await libraryCoordinator.undo(id,approvedRecordID:approvedRecordID,settings:librarySettings,remoteMonitoringEnabled:config.shadowMonitoringEnabled);libraryRecords=await managedLibrary.recentRecords();historyRevision &+= 1;return true}
        catch {libraryError=String(describing:error);return false}
    }
    func libraryRecords(forJobID id:String,cursor:String?=nil,limit:Int=50) async->RenderLibraryJobPage {
        guard !stopping else{return .init(records:[],nextCursor:nil)}
        do{return try await managedLibrary.recordsForJob(id,cursor:cursor,limit:limit,settings:librarySettings)}
        catch{libraryError=String(describing:error);return .init(records:[],nextCursor:nil)}
    }
    func libraryLocation(forRecordID id:String) async->RenderLibraryLocation? {
        guard !stopping else{return nil}
        do{return try await managedLibrary.verifiedLocation(id,settings:librarySettings)}
        catch{libraryError="Sortie classée modifiée ou indisponible";return nil}
    }
    func revealLibraryRecord(_ id:String) async->Bool {
        guard let location=await libraryLocation(forRecordID:id),!stopping,let file=location.fileURL else{return false}
        NSWorkspace.shared.activateFileViewerSelecting([file]);return true
    }
    private let catalogue: RenderCatalogService
    private let storageRoot: URL
    private let collectionLifetime=RenderTaskLifetime()
    @Published private(set) var shutdownIssue:String?
    private let preferences: RenderConfigStore
    private let collectionEnabled: Bool
    private let folderWorker = FolderCollectionWorker()
    private let registryWorker = MacMonitorRegistryWorker()
    private let shadowRuns:ShadowRunDiscovery
    private var shadowRunUpdates:AnyCancellable?
    private var softwareUpdateShadowRequests=0
    private var softwareUpdateScopeGeneration:UInt64=0
    private var softwareUpdateShadowScope:SoftwareUpdatePolicy.ShadowScope = .uncertain
    private var softwareUpdateShadowWasConfigured=false
    private var softwareUpdateSnapshotGeneration:UInt64=0
    var shadowRunHealth:SourceHealth {shadowRuns.health}
    var shadowActivityHealth:SourceHealth {shadowRuns.activityHealth}
    @Published private(set) var observationRevision:UInt64=0

    // Pure coverage assessment: existing cycles publish freshness even with an unchanged catalogue.
    func menuBarObservation(at now:Date) -> MenuBarObservation {
        guard collectionEnabled,!stopping else{return .uncertain("Observation arrêtée ou simulée")}
        guard configurationWritable,configurationError==nil,config.archivePayloadError==nil,
              activityRegistryIsTrusted(at:now) else{return .uncertain("Configuration ou registre non confirmé")}
        let refreshing=libraryBusy || nativeTask != nil || registryTask != nil || registryPending || folderBusy || folderPending
            || macBusy || shadowBusy || shadowRemoteBusy || softwareUpdateShadowRequests>0 || shadowRuns.isRefreshing || declarationTask != nil
        func waiting(_ reason:String)->MenuBarObservation {refreshing ? .refreshing:.uncertain(reason)}
        // During an in-flight cycle, retain the last adopted proof while it is still fresh.
        let adopted=nativeCompletedGeneration>0 && nativeCatalogueGeneration>0
        let converged=nativeCompletedGeneration==nativeRequestedGeneration && softwareUpdateSnapshotGeneration==snapshotGeneration
        let nativeIDs=Set(nativeObservations.map{$0.dashboard(entries:[],now:now)}.filter(\.isDetectedActiveRender).map(\.id))
        let pcIDs=Set(shadowRuns.jobs.filter(\.isDetectedActiveRender).map(\.id))
        let shownNative=Set(catalogSnapshot.jobs.filter{$0.id.hasPrefix("mac:native:") && $0.isDetectedActiveRender}.map(\.id))
        let shownPC=Set(catalogSnapshot.jobs.filter{($0.id.hasPrefix("shadow:process:") || $0.id.hasPrefix("shadow:run:")) && $0.isDetectedActiveRender}.map(\.id))
        let unchangedActivity=nativeIDs==shownNative && pcIDs==shownPC
        guard adopted,(converged || unchangedActivity) else{return waiting("Catalogue en attente de la dernière observation")}
        func current(_ health:SourceHealth,_ window:Double)->Bool {
            guard health.online,!health.isStale,!health.partial,let at=health.observedAt else{return false}
            let age=now.timeIntervalSince(at);return age.isFinite && age>=0 && age<=window
        }
        guard current(nativeHealth,30) else{return waiting("Observation Mac incomplète ou périmée")}
        if nativeObservations.contains(where:{!$0.dashboard(entries:[],now:now).isDetectedActiveRender})
            || (current(macHealth,30) && macJobs.contains{$0.proc != nil}) {
            return .uncertain("Processus Mac candidat non attribué")
        }
        let required=softwareUpdateShadowWasConfigured || !config.shadowRunSources.isEmpty || !config.shadowFolders.isEmpty
            || !shadowRuns.jobs.isEmpty || shadowPayload != nil || shadowDeclaration != nil || !shadowFolderEntries.isEmpty
            || config.dashboardJobFolders.keys.contains{$0.hasPrefix("shadow:")}
            || config.dashboardProjectLinks.keys.contains{$0.hasPrefix("shadow:")} || !config.remoteMirrors.isEmpty
        if required {
            guard current(shadowRuns.activityHealth,120) else{return waiting("Observation PC incomplète ou périmée")}
            guard !shadowRuns.hasUnattributedCandidates,
                  !(current(shadowHealth,45) && shadowTasks.contains{$0.state=="Running"}) else{
                return .uncertain("Processus PC candidat non attribué")
            }
        } else {
            guard case .confirmedUnconfigured(let checked)=softwareUpdateShadowScope else{return .uncertain("Périmètre PC non confirmé")}
            let age=now.timeIntervalSince(checked)
            guard age.isFinite,age>=0,age<=120 else{return .uncertain("Périmètre PC à revérifier")}
        }
        return .confirmed
    }

    // Read-only, live input for each updater decision. It never refreshes a source.
    var softwareUpdateSafety:SoftwareUpdateSafety {softwareUpdateSafety(at:Date())}
    var softwareUpdateSafetyReason:String {softwareUpdateSafetyAssessment(at:Date()).reason}
    func softwareUpdateSafety(at now:Date) -> SoftwareUpdateSafety {
        softwareUpdateSafetyAssessment(at:now).safety
    }
    func softwareUpdateSafetyAssessment(at now:Date) -> SoftwareUpdatePolicy.SafetyAssessment {
        let nativeJobs=nativeObservations.map{$0.dashboard(entries:[],now:now)}
        let shadowJobs=shadowRuns.jobs.filter{$0.isFresh && !$0.retainedHistorical}
        func source(_ health:SourceHealth,active:Bool,candidate:Bool) -> SoftwareUpdatePolicy.SourceEvidence {
            SoftwareUpdatePolicy.SourceEvidence(online:health.online,stale:health.isStale,partial:health.partial,
                observedAt:health.observedAt,checkedAt:health.checkedAt,qualifiedActive:active,unattributedCandidate:candidate)
        }
        func recent(_ health:SourceHealth,window:Double) -> Bool {
            guard health.online,!health.isStale,let observed=health.observedAt else{return false}
            let age=now.timeIntervalSince(observed);return age.isFinite && age>=0 && age<=window
        }
        let legacyMacCandidate=recent(macHealth,window:30) && macJobs.contains{$0.proc != nil}
        let legacyShadowCandidate=recent(shadowHealth,window:45) && shadowTasks.contains{$0.state=="Running"}
        let native=source(nativeHealth,active:nativeJobs.contains(where: \.isDetectedActiveRender),
            candidate:nativeJobs.contains{!$0.isDetectedActiveRender} || legacyMacCandidate)
        let shadow=source(shadowRuns.health,active:shadowJobs.contains(where: \.isDetectedActiveRender),
            candidate:shadowJobs.contains{$0.activity == .running && $0.taskQualification==nil} || shadowRuns.hasUnattributedCandidates || legacyShadowCandidate)
        let refreshing=libraryBusy || nativeTask != nil || registryTask != nil || registryPending || folderBusy || folderPending
            || macBusy || shadowBusy || shadowRemoteBusy || softwareUpdateShadowRequests>0 || declarationTask != nil
        let converged=nativeRequestedGeneration>0 && nativeCompletedGeneration==nativeRequestedGeneration
            && nativeCatalogueGeneration==nativeRequestedGeneration && softwareUpdateSnapshotGeneration==snapshotGeneration
        let knownShadowScope=softwareUpdateShadowWasConfigured || !config.shadowRunSources.isEmpty || !config.shadowFolders.isEmpty
            || !shadowRuns.jobs.isEmpty || shadowPayload != nil || shadowDeclaration != nil || !shadowFolderEntries.isEmpty
            || config.dashboardJobFolders.keys.contains{$0.hasPrefix("shadow:")}
            || config.dashboardProjectLinks.keys.contains{$0.hasPrefix("shadow:")} || !config.remoteMirrors.isEmpty
        return SoftwareUpdatePolicy.assess(.init(monitoringEnabled:collectionEnabled,stopping:stopping,
            configurationReadable:configurationWritable && configurationError==nil && softwareUpdateRegistryIsTrusted(at:now) && config.archivePayloadError==nil,
            refreshing:refreshing,generationsConverged:converged,native:native,shadow:shadow,
            shadowScope:knownShadowScope ? .required : softwareUpdateShadowScope),at:now)
    }
    // Existing native folder scopes do not imply that the optional legacy registry was used.
    private var softwareUpdateHasRegistryContext:Bool {
        func providerID(_ id:String)->Bool {
            (id.hasPrefix("mac:") && !id.hasPrefix("mac:native:"))
                || (id.hasPrefix("job:") && !id.hasPrefix("job:native:"))
        }
        return !registryFolders.isEmpty || !macJobs.isEmpty
            || config.dashboardJobFolders.keys.contains(where:providerID)
            || config.dashboardProjectLinks.keys.contains(where:providerID)
            || config.jobContexts.keys.contains(where:providerID) || config.jobArchives.keys.contains(where:providerID)
            || catalogSnapshot.jobs.contains{$0.source == .macMonitor && providerID($0.id)}
    }
    private func softwareUpdateRegistryIsTrusted(at now:Date)->Bool {
        guard registryDiscoveryError==nil else{return false}
        switch softwareUpdateRegistryAvailability {
        case .available:return true
        case .confirmedAbsent(let checked):
            let age=now.timeIntervalSince(checked)
            return !softwareUpdateHasRegistryContext && age.isFinite && age>=0 && age<=30
        case .unavailable:return false
        }
    }
    private func activityRegistryIsTrusted(at now:Date)->Bool {
        guard activityRegistryError==nil else{return false}
        switch activityRegistryAvailability {
        case .available:return true
        case .confirmedAbsent(let checked):
            let age=now.timeIntervalSince(checked);return age.isFinite && age>=0 && age<=30
        case .unavailable:return false
        }
    }
    private let nativeWorker: NativeRenderDiscovery
    @Published private(set) var nativeRequestedGeneration:UInt64=0
    @Published private(set) var nativeCompletedGeneration:UInt64=0
    @Published private(set) var nativeCatalogueGeneration:UInt64=0
    private var nativeTask: Task<Void,Never>?
    @Published private(set) var nativeHealth = SourceHealth()
    private var nativeObservations: [NativeRenderObservation] = []
    private var nativeHistoryObservations:[NativeRenderObservation]=[]
    private let registryURL: URL
    private var registryFolders: [String:String] = [:]
    private var softwareUpdateRegistryAvailability:MacMonitorRegistryAvailability = .unavailable
    private var activityRegistryAvailability:MacMonitorRegistryAvailability = .unavailable
    private var activityRegistryError:String?
    private var registryTask: Task<Void,Never>?
    private var registryPending = false
    private var preferenceRevision: UInt64 = 0
    @Published private(set) var registryDiscoveryError: String?
    private var declarationTask: Task<Void,Never>?
    private var lastDeclarationAttempt: Date?
    private var declarationIdentity: String?
    private var snapshotTask: Task<Void,Never>?
    private var snapshotGeneration: UInt64 = 0
    private var historyRequestGeneration: UInt64 = 0
    private var folderTask: Task<Void,Never>?
    private var folderBusy = false
    private var folderPending = false
    private var folderRevision: UInt64 = 0

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

    init(storageRoot: URL? = nil, initialSnapshot: RenderCatalogSnapshot? = nil, collectionEnabled: Bool = true, previewLoader: RenderPreviewLoader? = nil, nativeReader: (any NativeProcessReading)? = nil, nativeIO:RenderBoundedIO? = nil, shadowRunLoader:ShadowRunDiscovery.Loader? = nil, macOnly:Bool=false) {
        let selectedRoot = storageRoot ?? (collectionEnabled ? RenduStorage.root : FileManager.default.temporaryDirectory.appendingPathComponent("autoren-fixture-" + UUID().uuidString,isDirectory:true))
        if !collectionEnabled { precondition(selectedRoot.standardizedFileURL.path != RenduStorage.root.standardizedFileURL.path && !selectedRoot.standardizedFileURL.path.hasPrefix(RenduStorage.root.standardizedFileURL.path + "/"), "Fixture storage must be isolated") }
        let libraryEngine=ManagedRenderLibrary(lifetime:collectionLifetime)
        self.managedLibrary=libraryEngine
        self.libraryCoordinator=RenderLibraryCoordinator(engine:libraryEngine,lifetime:collectionLifetime)
        self.shadowRuns=ShadowRunDiscovery(root:selectedRoot,loader:shadowRunLoader)
        self.storageRoot = selectedRoot; self.collectionEnabled = collectionEnabled
        self.registryURL = selectedRoot.appendingPathComponent("monitor-jobs.json")
        self.nativeWorker = NativeRenderDiscovery(reader:nativeReader ?? NativeProcessReader(),io:nativeIO ?? RenderBoundedIO())
        self.preferences=RenderConfigStore(root:selectedRoot,lifetime:collectionLifetime)
        self.catalogue = RenderCatalogService(root:selectedRoot.appendingPathComponent("Catalog",isDirectory:true),lifetime:collectionLifetime)
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 8
        options.timeoutIntervalForResource = 10
        options.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: options)
        previews=RenderPreviewStore(root:selectedRoot,session:session,remote:remote,enabled:collectionEnabled,loader:previewLoader,lifetime:collectionLifetime)
        previewUpdates=previews.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        shadowRunUpdates=shadowRuns.objectWillChange.sink { [weak self] _ in Task { @MainActor [weak self] in guard let self,!self.stopping else{return};self.combine() } }
        ensureStorage()
        let configLoad=RenderConfigurationLoad.read(selectedRoot.appendingPathComponent("config.json"))
        switch configLoad {
        case .missing: config = AppConfig()
        case .loaded(let saved): config=saved
        case .unavailable(let message): configurationError=message; configurationWritable=false; config=AppConfig()
        }
        if macOnly {
            config.shadowMonitoringEnabled=false
            if configurationWritable {
                do {config=try preferences.update{$0.shadowMonitoringEnabled=false}}
                catch {config.shadowMonitoringEnabled=false;configurationError="Surveillance Shadow coupée en mémoire · persistance non confirmée : \(error.localizedDescription)"}
            }
        }
        CollectorProcess.setRemoteAccessEnabled(config.shadowMonitoringEnabled)
        shadowRuns.setMonitoringEnabled(config.shadowMonitoringEnabled)
        if !collectionEnabled {
            if let seed=initialSnapshot {
                for job in seed.jobs where config.jobContexts[job.id] == nil && job.workID != nil && job.sourceWorkID == nil {
                    config.jobContexts[job.id] = RenderJobContext(projectID:job.projectID,workID:job.workID,versionID:job.versionID,workTitle:job.workTitle,versionLabel:job.versionLabel)
                }
            }
            save(config,name:"config.json")
            catalogSnapshot = initialSnapshot ?? .empty; dashboardProjects = catalogSnapshot.projects
            historyRevision=catalogSnapshot.historyRevision;lastCatalogHistoryRevision=catalogSnapshot.historyRevision;activeRenderJobs=catalogSnapshot.jobs.filter(\.isDetectedActiveRender)
            entries = catalogSnapshot.jobs.flatMap(\.previewEntries)
            return
        }
        if configurationWritable {
            switch configLoad {
            case .missing: save(config,name:"config.json")
            case .loaded: break
            case .unavailable: break
            }
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
        refreshMacRegistry()
        refreshNativeRenders()
        refreshFolders()
    }

    func start() {
        guard collectionEnabled, timers.isEmpty,collectionLifetime.isOpen else { return }
        stopping = false
        refreshMacRegistry()
        refreshNativeRenders()
        Task { await shadowRuns.loadLastGood(config.shadowRunSources) }
        Task { await refreshMac() }
        Task { await refreshShadow() }
        Task { await refreshShadowFolders() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMacRegistry()
                self?.refreshNativeRenders()
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
        observationRevision &+= 1
        stopping = true
        collectionLifetime.invalidate()
        previews.stop();shadowRuns.stop()
        libraryTask?.cancel()
        snapshotTask?.cancel(); folderTask?.cancel(); declarationTask?.cancel(); registryTask?.cancel(); nativeTask?.cancel()
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        session.invalidateAndCancel()
        remote.cancel()
    }

    func waitForShutdown() async {
        let native=nativeTask;let library=libraryTask
        let runs=shadowRuns
        let registry=registryTask;let snapshot=snapshotTask;let folders=folderTask;let declaration=declarationTask
        let finished=await RenderBoundedIO.wait(seconds:2) { [previews,remote] in
            await native?.value;await library?.value
            await registry?.value;await snapshot?.value;await folders?.value
            await runs.waitForShutdown();await previews.waitForShutdown();await declaration?.value;await remote.waitForShutdown()
        }
        if !finished { shutdownIssue="Arrêt borné · IO encore suspendue, aucune nouvelle publication autorisée" }
    }

    func refreshNow() {
        guard collectionEnabled else { return }
        retryVisiblePreviews()
        refreshMacRegistry()
        refreshNativeRenders()
        refreshFolders()
        Task { await refreshMac() }
        Task { await refreshShadow() }
        Task { await refreshShadowFolders();await refreshShadowRunDiscovery(force:true) }
    }

    func addMacFolder(_ url: URL) {
        guard configurationWritable else { return }
        folderRevision += 1
        guard mutatePreferences({ $0.addMacFolder(url.path) }) else { return }
        refreshFolders()
    }

    func removeMacFolder(_ path: String) {
        guard configurationWritable else { return }
        folderRevision += 1
        guard mutatePreferences({ $0.removeMacFolder(path) }) else { return }
        refreshFolders()
    }

    @discardableResult
    func setJobArchived(_ archived: Bool, forJobID id: String) -> Bool {
        archiveError = nil
        guard config.archivePayloadError == nil else { archiveError=config.archivePayloadError; return false }
        guard let job=catalogSnapshot.jobs.first(where:{$0.id==id}) else { archiveError="Rendu inconnu"; return false }
        if archived && job.isArchived { return true }
        if !archived && config.jobArchives[id] == nil { return true }
        if archived && !job.canArchive { archiveError="Achèvement non établi ou activité en cours · archivage refusé"; return false }
        return updateJobArchives([id], archived:archived)
    }

    @discardableResult
    func archiveCompletedJobs() -> Int {
        let ids=catalogSnapshot.jobs.filter(\.canArchive).map(\.id)
        guard !ids.isEmpty else { archiveError=nil; return 0 }
        return updateJobArchives(ids,archived:true) ? ids.count : 0
    }

    @discardableResult
    func restoreAllArchivedJobs() -> Int {
        guard config.archivePayloadError == nil else { archiveError=config.archivePayloadError; return 0 }
        let ids=Array(config.jobArchives.keys)
        guard !ids.isEmpty else { archiveError=nil; return 0 }
        return updateJobArchives(ids,archived:false) ? ids.count : 0
    }

    @discardableResult
    func restoreArchivedJobs() -> Int { restoreAllArchivedJobs() }

    private func updateJobArchives(_ ids:[String], archived:Bool) -> Bool {
        archiveError=nil
        guard configurationWritable else { archiveError=configurationError;return false }
        do {
            config=try preferences.update { config in
                guard config.archivePayloadError==nil else { throw NSError(domain:"Archives",code:1,userInfo:[NSLocalizedDescriptionKey:config.archivePayloadError!]) }
                for id in ids { if archived { config.jobArchives[id]=config.jobArchives[id] ?? Date() } else { config.jobArchives.removeValue(forKey:id) } }
            }
            preferenceRevision &+= 1
            combine();return true
        } catch { archiveError=error.localizedDescription;return false }
    }

    @discardableResult
    func setJobContext(_ context: RenderJobContext?, forJobID id: String) -> Bool {
        guard configurationWritable else { organizationError=configurationError; return false }
        organizationError = nil
        guard let job = catalogSnapshot.jobs.first(where: { $0.id == id }) else { organizationError = "Rendu inconnu"; return false }
        if let source = job.sourceWorkID, let chosen = context?.workID, source != chosen { organizationError = "Identité de travail déclarée par la source · étiquette modifiable"; return false }
        if let source = job.sourceVersionID, let chosen = context?.versionID, source != chosen { organizationError = "Identité de version déclarée par la source · étiquette modifiable"; return false }
        do {
            let prior=config
            config=try preferences.update { $0.jobContexts[id]=context }
            if prior.macFolders != config.macFolders || prior.shadowFolders != config.shadowFolders { folderRevision += 1;shadowFolderRevision += 1;refreshFolders() }
            combine();return true
        } catch { organizationError=error.localizedDescription;return false }
    }

    func setFolderWorkType(_ type: RenderWorkType?, path: String) {
        guard configurationWritable else { return }
        guard mutatePreferences({ $0.folderWorkTypes[path]=type }) else { return }
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
        guard configurationWritable else { return false }
        guard ShadowFolderScanner.validRemotePath(path) else { return false }
        guard !config.shadowFolders.contains(path) else { return true }
        shadowFolderRevision += 1
        guard mutatePreferences({ $0.shadowFolders.append(path) }) else { return false }
        Task { await refreshShadowFolders() }
        return true
    }

    func removeShadowFolder(_ path: String) {
        guard configurationWritable else { return }
        shadowFolderRevision += 1
        guard mutatePreferences({ $0.shadowFolders.removeAll { $0 == path } }) else { return }
        shadowFolderEntries.removeAll { $0.path.map { Self.isInside($0, root: path) } ?? false }
        save(CachedRemote(entries: shadowFolderEntries, at: remoteHealth.lastGoodAt ?? .distantPast),
                          name: "shadow-folders-last-good.json")
        combine()
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        RenderOrganization.isInside(path, root: root)
    }

    var shadowMonitoringEnabled:Bool {config.shadowMonitoringEnabled}
    @discardableResult func setShadowMonitoringEnabled(_ enabled:Bool)->Bool {
        guard mutatePreferences({$0.shadowMonitoringEnabled=enabled}) else{return false}
        CollectorProcess.setRemoteAccessEnabled(enabled);shadowRuns.setMonitoringEnabled(enabled)
        shadowFolderRevision += 1;softwareUpdateScopeGeneration &+= 1
        if !enabled {
            declarationTask?.cancel();declarationTask=nil;libraryTask?.cancel()
            remote.cancel()
            session.getAllTasks{tasks in
                for task in tasks where task.originalRequest?.url?.path.hasPrefix("/api/mac") != true {task.cancel()}
            }
            shadowHealth.online=false;shadowHealth.isStale=true;shadowHealth.message="Surveillance Shadow désactivée"
            remoteHealth.online=false;remoteHealth.isStale=true;remoteHealth.message="Surveillance Shadow désactivée"
            softwareUpdateShadowScope = .uncertain
            previews.setVisiblePreviewEntries(entries.filter{!$0.source.isShadow},roots:[])
        } else if collectionEnabled {Task{await refreshShadow();await refreshShadowFolders()}}
        combine();return true
    }

    private func fetch(_ path: String) async throws -> Data {
        guard config.shadowMonitoringEnabled || path.hasPrefix("api/mac") else{throw URLError(.cancelled)}
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func refreshShadow() async {
        guard config.shadowMonitoringEnabled,collectionEnabled, !stopping else { return }
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
            if shadowDeclaration?.matches(response) != true { shadowDeclaration=nil }
            guard config.shadowMonitoringEnabled,!Task.isCancelled, !stopping else { return }
            adoptShadow(response, at: now, live: true)
            refreshDeclarationInBackground(response)

        } catch {
            guard !stopping else { return }
            shadowHealth.online = false
                shadowHealth.isStale = true
            shadowHealth.checkedAt = Date()
            shadowHealth.message = "Moniteur indisponible : \(error.localizedDescription)"
            combine()
        }
    }

    private func refreshDeclarationInBackground(_ response:ShadowResponse) {
        guard config.shadowMonitoringEnabled else{return}
        let identity=response.tasks?.map(\.name).sorted().joined(separator:"|") ?? "unknown"
        if declarationIdentity != identity { declarationTask?.cancel();declarationTask=nil;lastDeclarationAttempt=nil;declarationIdentity=identity }
        guard declarationTask == nil, lastDeclarationAttempt.map({ Date().timeIntervalSince($0)>=300 }) ?? true else { return }
        lastDeclarationAttempt=Date()
        declarationTask=Task {
            defer { if declarationIdentity==identity { declarationTask=nil } }
            guard let page=try? await fetch(""),config.shadowMonitoringEnabled,!Task.isCancelled,!stopping,declarationIdentity==identity,
                  let current=shadowPayload,let declared=ShadowDashboardDeclaration.parse(page,sourceURL:base.absoluteString,checkedAt:Date()),declared.matches(current) else { return }
            shadowDeclaration=declared;save(declared,name:"shadow-dashboard-declaration.json");combine()
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
        // Keep unscoped api/frame previews out of current entries until the provider
        // supplies verifiable run/root/frame provenance. No root is hardcoded here.
        shadowEntries = []
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
        guard config.shadowMonitoringEnabled,collectionEnabled, !stopping else { return }
        defer {if !stopping {Task {await self.refreshShadowRunDiscovery()}}}
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
                if previews.isCached(entry) { entry.state = .complete }
                return entry
            }
            save(CachedRemote(entries: shadowFolderEntries, at: Date()),
                              name: "shadow-folders-last-good.json")
        }
        combine()
    }

    func refreshShadowRunDiscovery(force:Bool=false) async {
        guard config.shadowMonitoringEnabled,collectionEnabled,!stopping else{return}
        observationRevision &+= 1
        softwareUpdateShadowRequests += 1
        softwareUpdateScopeGeneration &+= 1
        let ticket=softwareUpdateScopeGeneration;let revision=preferenceRevision
        softwareUpdateShadowScope = .uncertain
        defer { softwareUpdateShadowRequests -= 1;observationRevision &+= 1 }
        let connected=await shadowRuns.hasConfiguredConnection()
        guard !stopping,!Task.isCancelled,ticket==softwareUpdateScopeGeneration,revision==preferenceRevision else{return}
        if connected {
            softwareUpdateShadowWasConfigured=true
            softwareUpdateShadowScope = .required
        } else {
            let scope:SoftwareUpdatePolicy.ShadowScope
            if softwareUpdateShadowWasConfigured {scope = .required}
            else {scope=await shadowRuns.softwareUpdateLocalScope()}
            guard !stopping,!Task.isCancelled,ticket==softwareUpdateScopeGeneration,revision==preferenceRevision else{return}
            if case .required = scope {softwareUpdateShadowWasConfigured=true}
            softwareUpdateShadowScope=scope
            return
        }
        await shadowRuns.refresh(config.shadowRunSources,force:force)
    }

    private func combine() {
        let shadowListing = ShadowListing.entries(monitor: shadowEntries, folders: shadowFolderEntries,
                                                  remoteOnline: remoteHealth.online,
                                                  foldersConfigured: !config.shadowFolders.isEmpty)
        entries = RenderMerger.merge(folders: folderEntries + shadowListing, monitors: macEntries)
        rebuildSnapshot()
    }

    func setVisiblePreviewEntries(_ entries:[RenderEntry]) { previews.setVisiblePreviewEntries(entries.filter{config.shadowMonitoringEnabled || !$0.source.isShadow},roots:config.shadowMonitoringEnabled ? config.shadowFolders+shadowRuns.allowedRoots:[]) }
    func setCompactPreviewVisibility(_ visible:Bool) {
        guard compactPreviewVisible != visible else{return}
        compactPreviewVisible=visible
        if visible {previews.reconcileVisiblePreviews(catalogSnapshot)}
        previews.setCompactPreviewsVisible(visible)
    }
    func setCompactPreviewsVisible(_ visible:Bool){setCompactPreviewVisibility(visible)}
    func setCompactPreview(_ entry:RenderEntry?,forJobID jobID:String) {
        let valid=entry.flatMap {value -> RenderEntry? in
            guard value.source == .macFolder,value.monitorJobID==jobID,
                  catalogSnapshot.jobs.first(where:{$0.id==jobID})?.previewEntries.contains(value)==true else{return nil}
            return value
        }
        previews.setCompactPreview(valid,forJobID:jobID)
    }
    func retryVisiblePreviews() { previews.retryVisiblePreviews() }
    func previewStatus(for entry:RenderEntry)->RenderPreviewStatus {previews.status(for:entry)}
    func thumbnail(for entry:RenderEntry)->NSImage? {previews.thumbnail(for:entry)}
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
        if job.id.hasPrefix("shadow:run:") {return job.previewEntries}
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
        input.nativeObservations = nativeObservations
        input.nativeHistoryObservations=nativeHistoryObservations
        input.shadowRunJobs = shadowRuns.jobs.map { original in
            var job=original
            if !config.shadowMonitoringEnabled {job.isFresh=false;job.retainedHistorical=true;job.taskQualification=nil}
            return job
        }
        if !collectionEnabled { input.preparedJobs = catalogSnapshot.jobs }
        let nativeGeneration=nativeCompletedGeneration
        snapshotTask = Task {
            guard let prepared = await catalogue.build(input), !Task.isCancelled, !stopping, generation == snapshotGeneration else { return }
            catalogSnapshot = prepared; dashboardProjects = prepared.projects
            if lastCatalogHistoryRevision != prepared.historyRevision {lastCatalogHistoryRevision=prepared.historyRevision;historyRevision &+= 1}
            activeRenderJobs=prepared.jobs.filter(\.isDetectedActiveRender)
            softwareUpdateSnapshotGeneration=generation
            observationRevision &+= 1
            previews.reconcileVisiblePreviews(prepared)
            nativeCatalogueGeneration=max(nativeCatalogueGeneration,nativeGeneration)
            scheduleLibraryCycle(prepared.libraryJobs)
            if !prepared.reactivatedArchiveIDs.isEmpty {
                _ = updateJobArchives(prepared.reactivatedArchiveIDs,archived:false)
            }
        }
    }

    private func scheduleLibraryPolicy(_ settings:RenderLibrarySettings) {
        guard config.shadowMonitoringEnabled,collectionEnabled,!stopping,!libraryBusy,libraryTask==nil else{return}
        libraryBusy=true
        libraryTask=Task { [weak self] in
            guard let self else{return};defer{libraryBusy=false;libraryTask=nil}
            guard await shadowRuns.hasConfiguredConnection(),!stopping,!Task.isCancelled else{return}
            do{try await libraryCoordinator.configurePolicy(settings:settings)}
            catch{if !stopping {libraryError="Politique PC non confirmée · ancien bail limité à120s"}}
        }
    }
    private func scheduleLibraryCycle(_ jobs:[RenderDashboardJob]) {
        guard collectionEnabled,!stopping,!libraryBusy,libraryTask==nil,librarySettings.mode == .managedLibrary else{return}
        let settings=librarySettings,contextConfig=config,remoteExpected=softwareUpdateShadowWasConfigured || shadowRuns.activityHealth.online;libraryBusy=true
        libraryTask=Task { [weak self] in
            guard let self else{return}
            defer{self.libraryBusy=false;self.libraryTask=nil}
            let result=await libraryCoordinator.cycle(jobs:jobs,settings:settings,contextConfig:contextConfig,remoteConnectionExpected:remoteExpected,remoteMonitoringEnabled:contextConfig.shadowMonitoringEnabled)
            guard !stopping,!Task.isCancelled,settings==librarySettings else{return}
            libraryRecords=result.records;libraryActivities=result.activities
            if result.changed {historyRevision &+= 1}
        }
    }
    private func historyRequestIsCurrent(_ request:UInt64, folder:UInt64, shadow:Int) -> Bool {
        !stopping && historyRequestGeneration == request && folderRevision == folder && shadowFolderRevision == shadow
    }

    func historyPage(for job: RenderDashboardJob, cursor: String? = nil, limit: Int = 40) async -> RenderHistoryPage {
        historyRequestGeneration &+= 1; let request=historyRequestGeneration
        let revision = folderRevision; let shadowRevision = shadowFolderRevision
        let current: @Sendable () async -> Bool = { [weak self] in
            guard let model=self else { return false }
            return await model.historyRequestIsCurrent(request,folder:revision,shadow:shadowRevision)
        }
        if !collectionEnabled {
            return await catalogue.history(jobID:job.id,incoming:cursor == nil ? job.previewEntries : [],cursor:cursor,limit:limit,
                coverage:"SIMULÉ · aucune collecte/réseau",scope:"fixture:" + job.id,isCurrent:current)
        }
        var incoming = cursor == nil ? historyEntries(for:job) : []; var coverage = "Liste récente bornée · historique complet non indexé"
        var roots: [String] = []
        if job.id.hasPrefix("mac:native:") { roots = nativeObservations.first { $0.id == job.id }?.outputRoot.map { [$0] } ?? [] }
        else if job.source == .macMonitor { roots = knownFolders()[String(job.id.dropFirst(4))].map { [$0] } ?? [] }
        else if job.source == .macFolder {
            roots = config.macFolders.filter { root in
                let sample = RenderEntry(id:"scope",source:.macFolder,job:"",filename:"",modified:.distantPast,state:.pending,path:root + "/__scope__",previewURL:nil)
                return projectID(for:sample) == job.projectID
            }
        }
        if job.source.isShadow {
            roots = job.id.hasPrefix("shadow:run:") ? job.openTargets.compactMap(\.remoteDisplay) : (config.dashboardJobFolders[job.id] ?? [])
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
        } else if cursor == nil && job.source.isShadow && config.shadowMonitoringEnabled {
            if !roots.isEmpty {
                if let result = await remote.history(roots) { incoming = result.entries; coverage = result.coverage }
                else { coverage = "Shadow indisponible · métadonnées conservées" }
            }
        }
        guard !Task.isCancelled, !stopping, revision == folderRevision, shadowRevision == shadowFolderRevision, request == historyRequestGeneration else {
            return RenderHistoryPage(entries:[],nextCursor:nil,totalKnown:nil,coverage:"Scope modifié ou demande annulée",snapshotRevision:catalogSnapshot.revision)
        }
        if cursor != nil { incoming = []; coverage = "Page de l’inventaire chargé · sans nouveau scan" }
        let page = await catalogue.history(jobID:job.id,incoming:incoming,cursor:cursor,limit:limit,coverage:coverage,
            scope:job.projectID + "|" + roots.joined(separator:"|") + "|" + String(revision) + "|" + String(shadowRevision),isCurrent:current)
        guard !Task.isCancelled, !stopping, revision == folderRevision, shadowRevision == shadowFolderRevision, request == historyRequestGeneration else {
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

    private func mutatePreferences(_ body:(inout AppConfig)->Void) -> Bool {
        guard configurationWritable else { return false }
        defer {observationRevision &+= 1}
        do { config=try preferences.update(body);preferenceRevision &+= 1;configurationError=nil;return true }
        catch { configurationError=error.localizedDescription;return false }
    }

    // The actor owns registry and directory IO. Repeated requests coalesce to one follow-up.
    private func refreshMacRegistry() {
        guard collectionEnabled, !stopping else { return }
        if registryTask != nil { registryPending = true; return }
        observationRevision &+= 1
        let revision = preferenceRevision
        registryTask = Task {
            defer {observationRevision &+= 1}
            let result = await registryWorker.reconcile(registry:registryURL, store:preferences,
                                                        writable:configurationWritable)
            guard !Task.isCancelled, !stopping else { registryTask = nil; return }
            registryDiscoveryError = result.issue
            activityRegistryAvailability=result.availability;activityRegistryError=result.issue
            softwareUpdateRegistryAvailability = result.availability
            if case .confirmedAbsent = result.availability,softwareUpdateHasRegistryContext {
                registryDiscoveryError="Registre Mac attendu absent · associations conservées"
                softwareUpdateRegistryAvailability = .unavailable
            }
            if let folders = result.folders { registryFolders = folders }
            if let updated = result.config {
                if revision == preferenceRevision {
                    let changed = updated.macFolders != config.macFolders
                    config = updated
                    if changed { preferenceRevision &+= 1; folderRevision &+= 1; refreshFolders() }
                } else { registryPending = true }
            }
            // Keep source freshness untouched; rebind only the local path association.
            macEntries = macEntries.map { entry in
                guard let id = entry.monitorJobID else { return entry }
                let name = entry.filename
                let path = registryFolders[id].flatMap { folder -> String? in
                    guard !name.isEmpty, name != ".", name != "..",
                          (name as NSString).lastPathComponent == name else { return nil }
                    return URL(fileURLWithPath:folder).appendingPathComponent(name).path
                }
                return RenderEntry(id:entry.id, source:entry.source, job:entry.job, filename:entry.filename,
                                   modified:entry.modified, state:entry.state, path:path,
                                   previewURL:entry.previewURL, monitorJobID:entry.monitorJobID)
            }
            combine()
            registryTask = nil
            if registryPending { registryPending = false; refreshMacRegistry() }
        }
    }

    // The existing catalogue displays these candidates, including unqualified script processes.
    // UI owners can call this explicit association interface without changing collectors/providers.
    func nativeProcessIdentity(forJobID id: String) -> NativeProcessIdentity? {
        nativeObservations.first { $0.id==id }?.identity
    }

    @discardableResult
    func setNativeRunOutputFolder(_ url: URL, forJobID id: String) -> Bool {
        guard nativeObservations.contains(where:{$0.id==id}),configurationWritable else { return false }
        let path=url.standardizedFileURL.path
        guard mutatePreferences({ $0.dashboardJobFolders[id]=[path] }) else { return false }
        refreshNativeRenders()
        return true
    }

    // The returned ticket is consumed by this collection or a coalesced later generation.
    @discardableResult
    func refreshLocalDiscovery() -> UInt64 {
        guard collectionEnabled,!stopping else { return nativeRequestedGeneration }
        refreshMacRegistry()
        let ticket=refreshNativeRenders()
        refreshFolders()
        return ticket
    }

    // Completion means the current health/config and catalogue adopted this ticket; inspect health for failures.
    func waitForNativeDiscovery(_ ticket:UInt64,timeout:Double=2) async -> Bool {
        guard timeout.isFinite,timeout>0,ticket>0 else { return false }
        let deadline=DispatchTime.now().uptimeNanoseconds+UInt64(min(timeout,10)*1_000_000_000)
        while !stopping,!Task.isCancelled,DispatchTime.now().uptimeNanoseconds<deadline {
            if nativeCatalogueGeneration>=ticket { return true }
            do { try await Task.sleep(for:.milliseconds(5)) } catch { return false }
        }
        return false
    }

    @discardableResult
    private func refreshNativeRenders() -> UInt64 {
        guard collectionEnabled,!stopping else { return nativeRequestedGeneration }
        observationRevision &+= 1
        nativeRequestedGeneration &+= 1
        if nativeTask==nil { launchNativeRenders() }
        return nativeRequestedGeneration
    }

    private func launchNativeRenders() {
        guard collectionEnabled,!stopping,nativeTask==nil else { return }
        let ticket=nativeRequestedGeneration
        let revision=preferenceRevision
        let links=config.dashboardJobFolders
        let historicalJobs=Array(catalogSnapshot.jobs.filter{$0.id.hasPrefix("mac:native:")}.prefix(64))
        nativeTask=Task {
            defer {observationRevision &+= 1}
            let result=await nativeWorker.collect(store:preferences,links:links,writable:configurationWritable,historicalJobs:historicalJobs)
            guard !Task.isCancelled,!stopping else { nativeTask=nil;return }
            nativeHealth=result.health;nativeObservations=result.observations;nativeHistoryObservations=result.historyObservations
            var preferencesAdopted=true
            if let updated=result.config {
                if revision==preferenceRevision {
                    let changed=updated.macFolders != config.macFolders
                    config=updated
                    if changed { preferenceRevision &+= 1;folderRevision &+= 1;refreshFolders() }
                } else { preferencesAdopted=false }
            }
            if preferencesAdopted { nativeCompletedGeneration=max(nativeCompletedGeneration,ticket) }
            else if nativeRequestedGeneration==ticket { nativeRequestedGeneration &+= 1 }
            combine()
            nativeTask=nil
            if nativeRequestedGeneration>ticket { launchNativeRenders() }
        }
    }

    private func knownFolders() -> [String:String] { collectionEnabled ? registryFolders : [:] }
    private func ensureStorage() {
        try? FileManager.default.createDirectory(at:storageRoot,withIntermediateDirectories:true)
        try? FileManager.default.createDirectory(at:storageRoot.appendingPathComponent("Previews"),withIntermediateDirectories:true)
    }
    private func load<T:Decodable>(_ name:String,as:T.Type) -> T? {
        guard let data=try? Data(contentsOf:storageRoot.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self,from:data)
    }
    private func save<T:Encodable>(_ value:T,name:String) {
        guard !stopping,collectionLifetime.isOpen else { return }
        if name == "config.json" && !configurationWritable { return }
        ensureStorage(); guard var data=try? JSONEncoder().encode(value) else { return }
        if let config=value as? AppConfig, config.archivePayloadError != nil {
            let target=storageRoot.appendingPathComponent(name)
            guard let old=try? Data(contentsOf:target),let previous=try? JSONSerialization.jsonObject(with:old) as? [String:Any],
                  var current=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
            current["jobArchives"]=previous["jobArchives"]
            guard let preserved=try? JSONSerialization.data(withJSONObject:current,options:.sortedKeys) else { return }
            data=preserved
        }
        try? data.write(to:storageRoot.appendingPathComponent(name),options:.atomic)
    }

}
