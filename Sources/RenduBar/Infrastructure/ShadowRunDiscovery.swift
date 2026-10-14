import Foundation
import Combine
import Darwin

@MainActor final class ShadowRunDiscovery:ObservableObject {
    typealias Loader=@Sendable ([ShadowDeclaredSource]) async -> Data?
    @Published private(set) var jobs:[RenderDashboardJob]=[]
    @Published private(set) var health=SourceHealth()
    private let root:URL;private let loader:Loader
    private var task:Task<Void,Never>?
    private var generation:UInt64=0;private var stopped=false;private var pending=false
    private var latest:[ShadowDeclaredSource]=[];private var lastAttempt:Date?
    private var restored=false
    private var cache:ShadowRunEnvelope?
    private let cacheIO=RenderBoundedIO()
    private var requestLife=RenderTaskLifetime()
    private var stamps:[String:(Int64,String,Date)]=[:]
    var allowedRoots:[String] {guard let cache,accepts(cache,sources:latest) else{return []};return cache.runs.flatMap{[$0.rawRoot,$0.postRoot]}}
    init(root:URL,loader:Loader?=nil) {
        self.root=root
        self.loader=loader ?? { sources in
            guard let data=try? JSONEncoder().encode(sources),let json=String(data:data,encoding:.utf8) else{return nil}
            return await CollectorProcess.asyncRun(arguments:["observe","--roots-json","[]","--sources-json",json],timeout:25)
        }
    }

    func refresh(_ sources:[ShadowDeclaredSource],force:Bool=false) async {
        guard !stopped else{return}
        if !force,lastAttempt.map({Date().timeIntervalSince($0)<60})==true{return}
        latest=sources;generation &+= 1;requestLife.invalidate();requestLife=RenderTaskLifetime()
        if task != nil {pending=true;return}
        let ticket=generation;let life=requestLife;lastAttempt=Date()
        task=Task { [weak self] in
            guard let self else{return}
            if !restored {
                restored=true;let file=root.appendingPathComponent("shadow-runs-last-good.json")
                if let bytes=try? await cacheIO.run(seconds:1,lifetime:life, {permit in try RenderRegularFile.read(file,maximumBytes:1024*1024,permit:permit,allowSymlink:false)}),
                   !stopped,ticket==generation,let saved=try? JSONDecoder().decode(ShadowRunEnvelope.self,from:bytes),saved.ok,accepts(saved,sources:sources) {
                    cache=saved;jobs=saved.runs.map{$0.dashboard(fresh:false)};health.isStale=true;health.message="Dernier relevé Shadow · nouvelle observation en attente"
                }
            }
            let data=await loader(sources)
            guard !Task.isCancelled,!stopped,ticket==generation else{return}
            guard let data,data.count<=1024*1024,let body=try? JSONDecoder().decode(ShadowRunEnvelope.self,from:data),body.ok,
                  body.runs.count<=8,accepts(body,sources:sources,requireQualifiedClaims:true),
                  let at=RenderDate.parseOptional(body.observedAt),Date().timeIntervalSince(at)<120,at.timeIntervalSinceNow<60 else {
                rejectObservation();return
            }
            guard Set(sources.map(\.id)).isSubset(of:Set(body.runs.map(\.sourceID))),Set(body.runs.map(\.id)).count==body.runs.count,body.runs.allSatisfy({run in
                guard let runAt=RenderDate.parseOptional(run.observedAt) else{return false}
                return abs(runAt.timeIntervalSince(at))<=30 && Date().timeIntervalSince(runAt)<120 && runAt.timeIntervalSinceNow<60 && run.processCoverage == !body.partial
            }) else{rejectObservation();return}
            var stable=Set<String>();let now=Date();var retained:[String:(Int64,String,Date)]=[:]
            for run in body.runs {for frame in run.frames {
                let key=run.runID+"|"+frame.path.lowercased();let old=stamps[key]
                let first=(old?.0==frame.bytes && old?.1==frame.modified) ? old!.2 : now
                retained[key]=(frame.bytes,frame.modified,first)
                if now.timeIntervalSince(first)>=8 && now.timeIntervalSince(RenderDate.parse(frame.modified))>=8 {stable.insert(key)}
            }}
            let historical=cache?.runs.filter{old in !body.runs.contains(where:{$0.id==old.id}) && (self.cache?.automaticSources ?? []).contains(where:{$0.matches(old)}) && !sources.contains(where:{$0.id==old.sourceID})} ?? []
            let kept=Array(historical.sorted{$0.observedAt>$1.observedAt}.prefix(max(0,8-body.runs.count)))
            var savedBody=body;savedBody=ShadowRunEnvelope(ok:body.ok,observedAt:body.observedAt,partial:body.partial,runs:body.runs+kept,automaticSources:(body.automaticSources ?? [])+(cache?.automaticSources ?? []).filter{a in kept.contains(where:{$0.id=="shadow:run:"+a.runID})})
            stamps=retained;cache=savedBody;jobs=body.runs.map{$0.dashboard(fresh:true,stableFrames:stable)}+kept.map{$0.dashboard(fresh:false)};health.online=true;health.isStale=false;health.observedAt=at;health.checkedAt=Date();health.lastGoodAt=at
            health.partial=body.partial;health.message=body.partial ? (body.runs.contains(where:{!$0.claims.isEmpty}) ? "Worker attribué · couverture des processus partielle" : "Processus partiellement accessibles · absence non démontrée") : "Observation des sources/processus Shadow"
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
    }
    private func accepts(_ envelope:ShadowRunEnvelope,sources:[ShadowDeclaredSource],requireQualifiedClaims:Bool=false) -> Bool {
        let autos=envelope.automaticSources ?? []
        func norm(_ path:String)->String {path.replacingOccurrences(of:"\\",with:"/").lowercased()}
        guard sources.count<=8,envelope.runs.count<=8,autos.count<=8,
              Set(sources.map(\.id)).count == sources.count,
              Set(envelope.runs.map(\.id)).count == envelope.runs.count,
              Set(autos.map{ $0.runID }).count == autos.count,
              Set(sources.map(\.id)).isSubset(of:Set(envelope.runs.map(\.sourceID))),
              autos.allSatisfy({a in !sources.contains(where:{$0.id==a.source.id || norm($0.launcherPath)==norm(a.source.launcherPath)}) && envelope.runs.contains(where:{a.matches($0)})}) else{return false}
        return envelope.runs.allSatisfy {run in
            guard run.validated() else{return false}
            if let source=sources.first(where:{$0.id == run.sourceID}) {return run.matches(source) && (!requireQualifiedClaims || run.qualifiedClaimsMatch(source))}
            return autos.contains(where:{$0.matches(run)})
        }
    }
    func hasConfiguredConnection() async -> Bool {
        guard !stopped,let data=try? await cacheIO.run(seconds:1,lifetime:requestLife,{[root] permit in try RenderRegularFile.read(root.appendingPathComponent("connection.json"),maximumBytes:16*1024,permit:permit,allowSymlink:false)}),
              let row=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let host=row["host"] as? String,let user=row["user"] as? String,let identity=row["identityFile"] as? String else{return false}
        guard host.range(of:"^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$",options:.regularExpression) != nil,
              user.range(of:"^[A-Za-z_][A-Za-z0-9_-]{0,31}$",options:.regularExpression) != nil,identity.hasPrefix("/") else{return false}
        return (try? await cacheIO.run(seconds:1,lifetime:requestLife,{permit in
            try permit.check();var directory=ObjCBool(false)
            return FileManager.default.fileExists(atPath:identity,isDirectory:&directory) && !directory.boolValue
        })) == true
    }
    private func rejectObservation() {
        health.online=false;health.isStale=true;health.checkedAt=Date();health.message="Observation Shadow invalide/indisponible · dernier relevé conservé"
        jobs=cache.flatMap{accepts($0,sources:latest) ? $0 : nil}?.runs.map{$0.dashboard(fresh:false)} ?? [];stamps=[:]
    }
    func loadLastGood(_ sources:[ShadowDeclaredSource]) async {
        latest=sources
        guard !restored,!stopped else{return};restored=true
        let ticket=generation;let life=requestLife;let file=root.appendingPathComponent("shadow-runs-last-good.json")
        if let data=try? await cacheIO.run(seconds:1,lifetime:life,{permit in try RenderRegularFile.read(file,maximumBytes:1024*1024,permit:permit,allowSymlink:false)}),
           !stopped,ticket==generation,let saved=try? JSONDecoder().decode(ShadowRunEnvelope.self,from:data),saved.ok,accepts(saved,sources:sources) {
            cache=saved;jobs=saved.runs.map{$0.dashboard(fresh:false)};health.isStale=true;health.message="Dernier relevé Shadow déclaré · activité actuelle inconnue"
            health.lastGoodAt=RenderDate.parseOptional(saved.observedAt)
        }
    }
    func stop(){stopped=true;requestLife.invalidate();generation &+= 1;pending=false;task?.cancel()}
    func waitForShutdown() async {await task?.value}
}
