import Foundation
import Combine
import Darwin

@MainActor final class ShadowRunDiscovery:ObservableObject {
    typealias Loader=@Sendable ([ShadowDeclaredSource]) async -> Data?
    @Published private(set) var jobs:[RenderDashboardJob]=[]
    @Published private(set) var health=SourceHealth()
    @Published private(set) var activityHealth=SourceHealth()
    @Published private(set) var isRefreshing=false
    private let mapper=ShadowJobMapper()
    var hasUnattributedCandidates:Bool {jobs.contains{$0.isFresh && !$0.retainedHistorical && $0.id.hasPrefix("shadow:process:") && $0.taskQualification==nil && $0.activity == .unknown}}
    private let root:URL;private let loader:Loader
    private var task:Task<Void,Never>?
    private var generation:UInt64=0;private var stopped=false;private var pending=false
    private var latest:[ShadowDeclaredSource]=[];private var lastAttempt:Date?
    private var connectionProof:Data?
    private var restored=false
    private var cache:ShadowRunEnvelope?
    typealias LocalScopeReader=@Sendable (URL,RenderIOPermit) throws -> SoftwareUpdatePolicy.ShadowScope
    private let cacheIO:RenderBoundedIO
    private let localScopeReader:LocalScopeReader
    private var requestLife=RenderTaskLifetime()
    private var stamps:[String:(Int64,String,Date)]=[:]
    var allowedRoots:[String] {guard let cache,accepts(cache,sources:latest) else{return []};return cache.runs.flatMap{[$0.rawRoot,$0.postRoot]}}
    init(root:URL,loader:Loader?=nil,cacheIO:RenderBoundedIO=RenderBoundedIO(),localScopeReader:LocalScopeReader?=nil) {
        self.root=root;self.cacheIO=cacheIO
        self.localScopeReader=localScopeReader ?? {directory,permit in try Self.inspectLocalSoftwareUpdateScope(directory,permit)}
        self.loader=loader ?? { sources in
            guard let data=try? JSONEncoder().encode(sources),let json=String(data:data,encoding:.utf8) else{return nil}
            return await CollectorProcess.asyncRun(arguments:["observe","--roots-json","[]","--sources-json",json],timeout:25)
        }
    }

    private var monitoringEnabled=true
    func setMonitoringEnabled(_ enabled:Bool) {
        guard enabled != monitoringEnabled else{return}
        monitoringEnabled=enabled;invalidateConnection(latest)
        if !enabled {health.online=false;health.isStale=true;health.message="Surveillance Shadow désactivée";activityHealth=health;isRefreshing=false}
    }
    func refresh(_ sources:[ShadowDeclaredSource],force:Bool=false) async {
        guard !stopped,monitoringEnabled else{return}
        let changed=sources != latest
        if changed { invalidateConnection(sources) }
        if !force,!changed,lastAttempt.map({Date().timeIntervalSince($0)<15})==true{return}
        latest=sources;generation &+= 1;requestLife.invalidate();requestLife=RenderTaskLifetime()
        let requiredConnection=connectionProof
        if task != nil {pending=true;return}
        let ticket=generation;let life=requestLife;lastAttempt=Date();isRefreshing=true
        task=Task { [weak self] in
            guard let self else{return}
            if !restored {
                restored=true;let file=root.appendingPathComponent("shadow-runs-last-good.json")
                if let bytes=try? await cacheIO.run(seconds:1,lifetime:life, {permit in try RenderRegularFile.read(file,maximumBytes:1024*1024,permit:permit,allowSymlink:false)}),
                   !stopped,ticket==generation,let saved=try? JSONDecoder().decode(ShadowRunEnvelope.self,from:bytes),saved.ok,!historicalJobs(saved).isEmpty {
                    cache=saved;jobs=historicalJobs(saved);health.isStale=true;health.message="Dernier relevé Shadow · nouvelle observation en attente"
                }
            }
            let data=await loader(sources)
            guard !Task.isCancelled,!stopped,ticket==generation else{return}
            if let requiredConnection {
                let current=await configuredConnection()
                guard !Task.isCancelled,!stopped,ticket==generation else{return}
                guard current==requiredConnection else {invalidateConnection(latest);return}
            }
            guard let data,data.count<=1024*1024,let body=try? JSONDecoder().decode(ShadowRunEnvelope.self,from:data),
                  let savedBody=adopt(body,sources:sources) else {rejectObservation();return}
            guard !Task.isCancelled,!stopped,ticket==generation else{return}
            guard let savedData=try? JSONEncoder().encode(savedBody),savedData.count<=1024*1024 else{return}
            let directory=root;let file=root.appendingPathComponent("shadow-runs-last-good.json")
            do {try await cacheIO.run(seconds:1,lifetime:life) { permit in
                try permit.check();try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let temporary=directory.appendingPathComponent("shadow-runs-"+UUID().uuidString+".tmp")
                defer {try? FileManager.default.removeItem(at:temporary)}
                try permit.check();try savedData.write(to:temporary,options:.withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path)
                try permit.check()
                if FileManager.default.fileExists(atPath:file.path) {_ = try RenderRegularFile.read(file,maximumBytes:1024*1024,permit:permit,allowSymlink:false)}
                try permit.check()
                guard rename(temporary.path,file.path)==0 else {throw NSError(domain:"ShadowCache",code:1)}
            }} catch {if !stopped && ticket==generation {health.message="Observation valide · cache privé non enregistré"}}

        }
        await task?.value;task=nil
        if pending && !stopped {pending=false;await refresh(latest,force:true)}
        if task==nil {isRefreshing=false}
    }
    private func historicalJobs(_ body:ShadowRunEnvelope)->[RenderDashboardJob] {
        let legacy=accepts(body,sources:latest) ? body.runs.map{$0.dashboard(fresh:false)}:[]
        let at=RenderDate.parseOptional(body.processSnapshot?.observedAt)
        let standard=at.flatMap{body.processSnapshot?.validated(at:$0)}==true ? (body.processSnapshot?.observations.map{$0.dashboard(fresh:false)} ?? []):[]
        return legacy+standard
    }

    private func adopt(_ body:ShadowRunEnvelope,sources:[ShadowDeclaredSource]) -> ShadowRunEnvelope? {
        let now=Date()
        guard body.ok,let at=RenderDate.parseOptional(body.observedAt),at<=now,now.timeIntervalSince(at)<120 else{return nil}
        let processValid=body.processSnapshot.map{snapshot in
            snapshot.validated(at:now) && RenderDate.parseOptional(snapshot.observedAt).map{abs($0.timeIntervalSince(at))<=30}==true
        }==true
        let coverage=body.processSnapshot?.coverageComplete ?? !body.partial
        let legacyValid=accepts(body,sources:sources,requireQualifiedClaims:true) && body.runs.allSatisfy {run in
            guard let runAt=RenderDate.parseOptional(run.observedAt) else{return false}
            return runAt<=now && abs(runAt.timeIntervalSince(at))<=30 && now.timeIntervalSince(runAt)<120 && run.processCoverage==coverage
        }
        guard legacyValid || processValid else{return nil}
        let currentRuns=legacyValid ? body.runs:[]
        var stable=Set<String>();var retained:[String:(Int64,String,Date)]=[:]
        for run in currentRuns {for frame in run.frames {
            let key=run.runID+"|"+frame.path.lowercased(),old=stamps[key]
            let first=(old?.0==frame.bytes && old?.1==frame.modified) ? old!.2:now
            retained[key]=(frame.bytes,frame.modified,first)
            if now.timeIntervalSince(first)>=8 && now.timeIntervalSince(RenderDate.parse(frame.modified))>=8 {stable.insert(key)}
        }}
        let kept=Array((cache?.runs ?? []).filter{old in
            !currentRuns.contains{$0.id==old.id} && (sources.contains{$0.id==old.sourceID && old.matches($0)} || (cache?.automaticSources ?? []).contains{$0.matches(old)})
        }.sorted{$0.observedAt>$1.observedAt}.prefix(max(0,8-currentRuns.count)))
        let standard=processValid ? body.processSnapshot?.observations ?? []:[]
        let oldProcesses=(cache?.processSnapshot?.observations ?? []).filter{old in !standard.contains{$0.id==old.id}}
        jobs=currentRuns.map{mapper.legacy($0,stableFrames:stable,fresh:true)}+kept.map{$0.dashboard(fresh:false)} +
            standard.map{mapper.standard($0,fresh:true)}+oldProcesses.map{$0.dashboard(fresh:false)}
        // The source contract is already validated against exact launcher/script hashes and stage roots.
        if let scope=body.processSnapshot?.connectionScope,scope.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil {
            let descriptors=sources+(body.automaticSources ?? []).map(\.source)
            for run in currentRuns {
                guard let source=descriptors.first(where:{$0.id==run.sourceID}),let i=jobs.firstIndex(where:{$0.id==run.id}) else{continue}
                jobs[i].sourceContext=RenderSourceContext(scriptPath:source.scriptPath,outputPath:source.postRoot,namespace:"shadow:"+scope,origin:.staticProducer)
                let proof=RenderScriptFinalProof(runID:run.runID,launcherPath:source.launcherPath,launcherSHA256:run.launcherHash,scriptPath:source.scriptPath,scriptSHA256:run.scriptHash,postScriptPath:source.postScriptPath,postScriptSHA256:run.postScriptHash,rawRoot:run.rawRoot,postRoot:run.postRoot,plans:run.plans)
                if jobs[i].finalOutputProof == .scriptFinalContract {
                    jobs[i].remoteArtifact=RenderRemoteArtifact(connectionScope:scope,path:run.postRoot+"/manifest-placeholder.png",processID:0,birthToken:"0",invocationToken:String(run.runID.prefix(32)),startedAt:run.observedAt,completedAt:run.observedAt,scriptProof:proof)
                }
            }
        }
        let autos=(legacyValid ? body.automaticSources ?? []:[])+(cache?.automaticSources ?? []).filter{a in kept.contains{$0.id=="shadow:run:"+a.runID}}
        var saved=ShadowRunEnvelope(ok:true,observedAt:body.observedAt,partial:body.partial,runs:currentRuns+kept,automaticSources:autos)
        saved.processSnapshot=processValid ? body.processSnapshot:nil;saved.sourceErrors=body.sourceErrors
        cache=saved;stamps=retained
        health.online=true;health.isStale=false;health.observedAt=at;health.checkedAt=now;health.lastGoodAt=at
        health.partial=body.partial || !legacyValid || (body.processSnapshot != nil && !processValid) || (processValid && !coverage)
        activityHealth=health
        activityHealth.partial=processValid ? !coverage:health.partial
        activityHealth.message=activityHealth.partial ? "Recensement PC incomplet":"Recensement PC complet · sources de fichiers évaluées séparément"
        health.message=health.partial ? "PC connecté · couverture partielle, absence globale non démontrée":"PC connecté · observation des processus compatible complète"
        return saved
    }

    private func accepts(_ envelope:ShadowRunEnvelope,sources:[ShadowDeclaredSource],requireQualifiedClaims:Bool=false) -> Bool {
        let autos=envelope.automaticSources ?? []
        func norm(_ path:String)->String {path.replacingOccurrences(of:"\\",with:"/").lowercased()}
        guard sources.count<=8,envelope.runs.count<=8,autos.count<=8,
              Set(sources.map(\.id)).count == sources.count,
              Set(envelope.runs.map(\.id)).count == envelope.runs.count,
              Set(autos.map{ $0.runID }).count == autos.count,
              Set(sources.map(\.id)).isSubset(of:Set(envelope.runs.map(\.sourceID)).union(envelope.sourceErrors ?? [])),
              (envelope.sourceErrors ?? []).count<=8,Set(envelope.sourceErrors ?? []).count==(envelope.sourceErrors ?? []).count,
              autos.allSatisfy({a in !sources.contains(where:{$0.id==a.source.id || norm($0.launcherPath)==norm(a.source.launcherPath)}) && envelope.runs.contains(where:{a.matches($0)})}) else{return false}
        return envelope.runs.allSatisfy {run in
            guard run.validated() else{return false}
            if let source=sources.first(where:{$0.id == run.sourceID}) {return run.matches(source) && (!requireQualifiedClaims || run.qualifiedClaimsMatch(source))}
            return autos.contains(where:{$0.matches(run)})
        }
    }
    // A connection loss/change invalidates claims, including an observation still in flight.
    private func invalidateConnection(_ sources:[ShadowDeclaredSource]) {
        latest=sources;generation &+= 1;requestLife.invalidate();requestLife=RenderTaskLifetime()
        task?.cancel();pending=false;lastAttempt=nil;stamps=[:];mapper.reset()
        rejectObservation()
    }
    func hasConfiguredConnection() async -> Bool {
        guard !stopped,monitoringEnabled else{return false}
        let proof=await configuredConnection()
        guard !stopped,monitoringEnabled else{return false}
        if proof==nil || (connectionProof != nil && proof != connectionProof) {invalidateConnection(latest)}
        connectionProof=proof
        return proof != nil
    }
    private func configuredConnection() async -> Data? {
        guard !stopped,monitoringEnabled,let data=try? await cacheIO.run(seconds:1,lifetime:requestLife,{[root] permit in try RenderRegularFile.read(root.appendingPathComponent("connection.json"),maximumBytes:16*1024,permit:permit,allowSymlink:false)}),
              let row=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let host=row["host"] as? String,let user=row["user"] as? String,let identity=row["identityFile"] as? String else{return nil}
        guard host.range(of:"^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$",options:.regularExpression) != nil,
              user.range(of:"^[A-Za-z_][A-Za-z0-9_-]{0,31}$",options:.regularExpression) != nil,identity.hasPrefix("/") else{return nil}
        let exists=(try? await cacheIO.run(seconds:1,lifetime:requestLife,{permit in
            try permit.check();var directory=ObjCBool(false)
            return FileManager.default.fileExists(atPath:identity,isDirectory:&directory) && !directory.boolValue
        })) == true
        return exists ? data : nil
    }
    // This reuses the private serial cache IO; the caller/main actor never reads the cache.
    func softwareUpdateLocalScope() async -> SoftwareUpdatePolicy.ShadowScope {
        guard !stopped,!Task.isCancelled else{return .uncertain}
        let ticket=generation;let life=requestLife;let directory=root;let inspect=localScopeReader
        do {
            let result=try await cacheIO.run(seconds:1,lifetime:life) {permit in
                try inspect(directory,permit)
            }
            guard !stopped,!Task.isCancelled,ticket==generation,life.isOpen else{return .uncertain}
            return result
        } catch {return .uncertain}
    }
    private struct LocalFolderScopeCache:Decodable {let entries:[RenderEntry];let at:Date}
    nonisolated private static func inspectLocalSoftwareUpdateScope(_ directory:URL,_ permit:RenderIOPermit) throws -> SoftwareUpdatePolicy.ShadowScope {
        for name in ["connection.json","shadow-runs-last-good.json","shadow-last-good.json","shadow-dashboard-declaration.json"] {
            try permit.check();var metadata=stat()
            let status=lstat(directory.appendingPathComponent(name).path,&metadata);let failure=errno
            try permit.check()
            if status==0 {return .required}
            guard failure==ENOENT else{return .uncertain}
        }
        let file=directory.appendingPathComponent("shadow-folders-last-good.json")
        try permit.check();var metadata=stat()
        let status=lstat(file.path,&metadata);let failure=errno
        try permit.check()
        if status==0 {
            let bytes=try RenderRegularFile.read(file,maximumBytes:1024*1024,permit:permit,allowSymlink:false)
            let saved=try JSONDecoder().decode(LocalFolderScopeCache.self,from:bytes)
            try permit.check()
            if !saved.entries.isEmpty {return .required}
        } else if failure != ENOENT {return .uncertain}
        try permit.check()
        return .confirmedUnconfigured(checkedAt:Date())
    }

    private func rejectObservation() {
        health.online=false;health.isStale=true;health.checkedAt=Date();health.message="Observation Shadow invalide/indisponible · dernier relevé conservé"
        activityHealth=health
        jobs=cache.map{historicalJobs($0)} ?? [];stamps=[:];mapper.reset()
    }
    func loadLastGood(_ sources:[ShadowDeclaredSource]) async {
        latest=sources
        guard !restored,!stopped else{return};restored=true
        let ticket=generation;let life=requestLife;let file=root.appendingPathComponent("shadow-runs-last-good.json")
        if let data=try? await cacheIO.run(seconds:1,lifetime:life,{permit in try RenderRegularFile.read(file,maximumBytes:1024*1024,permit:permit,allowSymlink:false)}),
           !stopped,ticket==generation,let saved=try? JSONDecoder().decode(ShadowRunEnvelope.self,from:data),saved.ok,!historicalJobs(saved).isEmpty {
            cache=saved;jobs=historicalJobs(saved);health.isStale=true;health.message="Dernier relevé Shadow déclaré · activité actuelle inconnue"
            health.lastGoodAt=RenderDate.parseOptional(saved.observedAt)
        }
    }
    func stop(){stopped=true;requestLife.invalidate();generation &+= 1;pending=false;task?.cancel();isRefreshing=false;mapper.reset()}
    func waitForShutdown() async {await task?.value}
}
