import Foundation

final class NativeFixtureReader: NativeProcessReading {
    private let lock=NSLock()
    private var value=NativeProcessRead()
    func set(_ snapshots: [NativeProcessSnapshot], partial: Bool = false) {
        lock.lock();defer { lock.unlock() };value=NativeProcessRead(snapshots:snapshots,partial:partial)
    }
    func read() -> NativeProcessRead { lock.lock();defer { lock.unlock() };return value }
}

@main enum NativeDiscoveryTests {
    static var checks=0
    static func check(_ condition: Bool,_ message: String) { checks+=1;precondition(condition,message) }
    static func identity(_ pid:Int32, now:Date, executable:String="/Applications/Blender.app/Contents/MacOS/Blender",offset:UInt64=0) -> NativeProcessIdentity {
        NativeProcessIdentity(pid:pid,birthSeconds:UInt64(now.timeIntervalSince1970)-60+offset,birthMicroseconds:123,executable:executable)
    }
    static func sample(_ id:NativeProcessIdentity,_ args:[String]?) -> NativeProcessSnapshot { NativeProcessSnapshot(identity:id,arguments:args) }
    static func metadata(_ id:NativeProcessIdentity,root:URL,at:Date,total:Any=10,completed:Any=1) -> [String:Any] {
        ["schemaVersion":1,"source":"Blender","runID":"fixture-run","outputRoot":root.path,
         "processIdentity":["pid":id.pid,"birthSeconds":id.birthSeconds,"birthMicroseconds":id.birthMicroseconds,"executable":id.executable],
         "observedAt":ISO8601DateFormatter().string(from:at),"total":total,"completed":completed,"workType":"Vidéo"]
    }
    static func write(_ object:Any,to file:URL,at:Date) throws {
        try JSONSerialization.data(withJSONObject:object).write(to:file)
        try FileManager.default.setAttributes([.modificationDate:at],ofItemAtPath:file.path)
    }
    static func input(_ observations:[NativeRenderObservation], revision:UInt64, entries:[RenderEntry]=[],jobs:[MacJob]=[],known:[String:String]=[:]) -> RenderCatalogInput {
        var health=SourceHealth();health.online=true;health.observedAt=Date()
        var result=RenderCatalogInput(revision:revision,macJobs:jobs,shadow:nil,declaration:nil,config:AppConfig(),knownFolders:known,
            entries:entries,macEntries:[],folderEntries:entries,shadowEntries:[],shadowFolderEntries:[],macHealth:health,
            shadowHealth:SourceHealth(),folderHealth:health,remoteHealth:SourceHealth())
        result.nativeObservations=observations;return result
    }
    @MainActor static func main() async throws {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("autoren-native-tests-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let output=root.appendingPathComponent("renders");let second=root.appendingPathComponent("second")
        for path in [output,second] { try fm.createDirectory(at:path,withIntermediateDirectories:true) }
        let scene=root.appendingPathComponent("scene.blend").path;let now=Date()
        let a=identity(100,now:now);let b=identity(101,now:now)
        check(a.jobID != identity(100,now:now,offset:1).jobID,"PID reuse conflates runs")
        check(a.jobID != identity(100,now:now,executable:"/other/Blender").jobID,"executable excluded from identity")
        var parsed=NativeRenderCommandParser.parse(sample(a,[a.executable,"-b",scene,"-o",output.path+"/frame_####.png","-s","1","-e","10","-j","2","-a"]),at:now)!
        check(parsed.renderCommand && parsed.declaredTotal==5 && parsed.outputRoot==output.path,"explicit animation not qualified")
        check(parsed.matchesOutput(output.path+"/frame_0010.png") && !parsed.matchesOutput(output.path+"/other_0010.png"),"output attribution not bounded to pattern")
        let noTotal=NativeRenderCommandParser.parse(sample(a,[a.executable,"-b",scene,"-o",output.path+"/frame_####.png","-a"]),at:now)!
        check(noTotal.renderCommand && noTotal.declaredTotal==nil,"animation total invented from scene")
        let frames=NativeRenderCommandParser.parse(sample(a,[a.executable,"-b",scene,"-o",output.path+"/frame_####.png","-f","1,3..5"]),at:now)!
        check(frames.declaredTotal==4,"explicit frame set count incorrect")
        let relative=NativeRenderCommandParser.parse(sample(a,[a.executable,"-b",scene,"-f","-2"]),at:now)!
        check(relative.declaredTotal==nil,"relative frame total invented")
        let order=NativeRenderCommandParser.parse(sample(a,[a.executable,"-b","-o",output.path+"/x####",scene,"-f","1","-o",second.path+"/later####"]),at:now)!
        check(order.outputRoot==nil,"flags before scene/after action misattributed")
        let script=NativeRenderCommandParser.parse(sample(a,[a.executable,"--factory-startup","-b",scene,"-t","4","--python",root.path+"/render.py","--","--frames","all"]),at:now)!
        check(script.scene==scene && script.script != nil && !script.renderCommand && script.outputRoot==nil,"script process guessed as running render")
        check(script.dashboard(entries:[]).activity == .unknown,"script-only activity called running")
        let idle=NativeRenderCommandParser.parse(sample(a,[a.executable,scene]),at:now)!
        check(!idle.renderCommand && idle.dashboard(entries:[]).activity == .unknown,"idle UI called rendering")
        let player=NativeRenderCommandParser.parse(sample(a,[a.executable,scene,"-a"]),at:now)!
        check(!player.renderCommand,"animation playback mistaken for render")
        let registration=NativeRenderCommandParser.parse(sample(a,[a.executable,"-r"]),at:now)!
        check(!registration.renderCommand,"registration flag treated as render")
        check(NativeRenderCommandParser.parse(sample(a,nil),at:now)?.stage.contains("inaccessible")==true,"inaccessible argv dropped candidate")
        check(NativeRenderCommandParser.parse(sample(a,Array(repeating:"x",count:257)),at:now)?.renderCommand==false,"args bound ignored")
        check(NativeRenderCommandParser.parse(sample(identity(7,now:now,executable:"/bin/echo"),["echo"]),at:now)==nil,"unsupported executable accepted")
        check(NativeRenderPaths.root("/")==nil && NativeRenderPaths.root(fm.homeDirectoryForCurrentUser.path)==nil,"global disk/home scan allowed")
        let ff=identity(200,now:now,executable:"/opt/homebrew/bin/ffmpeg")
        let encoder=NativeRenderCommandParser.parse(sample(ff,[ff.executable,"-i",root.path+"/in.mp4","-c:v","libx264","-frames:v","20",second.path+"/out.mp4"]),at:now)!
        check(encoder.renderCommand && encoder.outputRoot==second.path && encoder.declaredTotal==20,"ffmpeg explicit local output not qualified")
        check(NativeRenderCommandParser.parse(sample(ff,[ff.executable,"-unknown",second.path+"/out.mp4"]),at:now)?.outputRoot==nil,"ambiguous ffmpeg args infer output")
        check(NativeRenderCommandParser.parse(sample(ff,[ff.executable,"-i","pipe:0","http://example.invalid/out"]),at:now)?.outputRoot==nil,"network output scanned as local")
        let store=RenderConfigStore(root:root.appendingPathComponent("prefs"))
        let reader=NativeFixtureReader();reader.set([sample(a,[a.executable,"-b",scene,"--python",root.path+"/render.py"])])
        let worker=NativeRenderDiscovery(reader:reader)
        let meta=root.appendingPathComponent(".autorender.json")
        // Work type uses the existing enum's source value, independent of PNG output extension.
        var doc=metadata(a,root:output,at:now);doc["workType"]=RenderWorkType.video.rawValue
        try write(doc,to:meta,at:now)
        var result=await worker.collect(store:store,links:[:],writable:true,at:now)
        check(result.observations.first?.outputRoot==output.path && result.config?.macFolders==[output.path],"generic metadata root not discovered independently of provider")
        check(result.observations.first?.workType == .video,"explicit work type lost")
        check(result.observations.first?.completed==1 && result.observations.first?.declaredTotal==10,"metadata counters lost")
        check(result.observations.first?.metadataAdvanced==false,"first metadata sample proves activity without motion")
        let contextual=RenderEntry(id:"context",source:.macFolder,job:"fixture",filename:"frame_0001.png",modified:now,state:.stable,path:output.path+"/frame_0001.png",previewURL:nil)
        let context=result.observations.first!.dashboard(entries:[contextual],now:now)
        check(context.previewEntries.count==1 && context.activity == .unknown,"metadata root loses previews or turns root context into activity")
        let later=now.addingTimeInterval(2);doc["completed"]=2;doc["observedAt"]=ISO8601DateFormatter().string(from:later)
        try write(doc,to:meta,at:later)
        result=await worker.collect(store:store,links:[:],writable:true,at:later)
        check(result.observations.first?.metadataAdvanced==true && result.observations.first?.dashboard(entries:[],now:later).activity == .running,"associated counter advance not observed")
        var wrong=doc;wrong["processIdentity"]=["pid":999,"birthSeconds":a.birthSeconds,"birthMicroseconds":a.birthMicroseconds,"executable":a.executable]
        try write(wrong,to:meta,at:later)
        result=await worker.collect(store:store,links:[:],writable:false,at:later)
        check(result.observations.first?.runID==nil && result.observations.first?.completed==nil,"wrong PID metadata attributed")
        var wrongBirth=doc;wrongBirth["processIdentity"]=["pid":a.pid,"birthSeconds":a.birthSeconds+1,"birthMicroseconds":a.birthMicroseconds,"executable":a.executable]
        try write(wrongBirth,to:meta,at:later)
        result=await worker.collect(store:store,links:[:],writable:false,at:later)
        check(result.observations.first?.runID==nil,"reused PID with different birth matches metadata")
        try Data(repeating:65,count:32*1024+1).write(to:meta)
        result=await worker.collect(store:store,links:[:],writable:false,at:later)
        check(result.observations.first?.runID==nil,"oversized metadata accepted")
        try write(doc,to:meta,at:now.addingTimeInterval(-120))
        result=await worker.collect(store:store,links:[:],writable:false,at:later)
        check(result.observations.first?.runID==nil,"wrong metadata mtime accepted")
        for total:Any in [0,-1,"not-a-total",true,1000001] {
            var invalid=doc;invalid["total"]=total
            try write(invalid,to:meta,at:later)
            result=await worker.collect(store:store,links:[:],writable:false,at:later)
            check(result.observations.first?.dashboard(entries:[],now:later).rawProgress==nil,"invalid total produces percentage")
        }
        var absent=doc;absent.removeValue(forKey:"total")
        try write(absent,to:meta,at:later)
        result=await worker.collect(store:store,links:[:],writable:false,at:later)
        check(result.observations.first?.declaredTotal==nil,"missing total inferred")
        try fm.removeItem(at:meta)
        reader.set([sample(a,[a.executable,"-b",scene,"-o",output.path+"/frame_####.png","-f","1"]),sample(b,[b.executable,"-b",scene,"-o",second.path+"/frame_####.png","-f","2"])])
        result=await worker.collect(store:store,links:[:],writable:true,at:now)
        check(result.observations.count==2 && Set(result.config?.macFolders ?? [])==[output.path,second.path],"two simultaneous render roots lost")
        let catalogue=RenderCatalogService(root:root.appendingPathComponent("Catalogue"))
        let snap=await catalogue.build(input(result.observations,revision:1))!
        check(snap.jobs.count==2 && snap.jobs.allSatisfy {$0.activity == .unknown},"process presence alone called running/completed")
        let existing=MacJob(id:"provider",titre:"fixture",sous:nil,total:0,faites:-1,en_cours:[],latest:[],times:[],proc:nil)
        let dedup=RenderCatalogService(root:root.appendingPathComponent("Dedup"))
        let dedupSnap=await dedup.build(input(result.observations,revision:1,jobs:[existing],known:["provider":output.path]))!
        check(dedupSnap.jobs.count==3 && dedupSnap.jobs.contains {$0.id==a.jobID && $0.activity == .unknown},"provider root equality masks a distinct candidate")
        reader.set([])
        let disappeared=await worker.collect(store:store,links:[:],writable:true,at:later)
        let stopped=await catalogue.build(input(disappeared.observations,revision:2))!
        check(stopped.jobs.count==2 && stopped.jobs.allSatisfy {$0.retainedHistorical && !$0.isTerminalCounted},"process disappearance marks completed or deletes history")
        let fresh=RenderEntry(id:"output",source:.macFolder,job:"fixture",filename:"frame_0001.png",modified:now,state:.pending,path:output.path+"/frame_0001.png",previewURL:nil)
        parsed=NativeRenderCommandParser.parse(sample(a,[a.executable,"-b",scene,"-o",output.path+"/frame_####.png","-f","1"]),at:now)!
        check(parsed.dashboard(entries:[fresh],sharedRoot:false,now:now).activity == .running,"exact recent output not observed")
        check(parsed.dashboard(entries:[fresh],sharedRoot:true,now:now).activity == .unknown,"shared root output claims both processes")
        var old=fresh;old=RenderEntry(id:old.id,source:old.source,job:old.job,filename:old.filename,modified:now.addingTimeInterval(-120),state:old.state,path:old.path,previewURL:nil)
        check(parsed.dashboard(entries:[old],sharedRoot:false,now:now).activity == .unknown,"old output means current activity")
        // Candidate remains visible without metadata or a provider. Explicit association is scoped to this run ID.
        reader.set([sample(a,[a.executable,"-b",scene,"--python",root.path+"/render.py"])])
        result=await worker.collect(store:store,links:[a.jobID:[second.path]],writable:true,at:now)
        check(result.observations.first?.outputRoot==second.path && result.observations.first?.dashboard(entries:[]).activity == .unknown,"explicit candidate link implies running")
        _=try store.update { $0.removeMacFolder(second.path) }
        result=await worker.collect(store:store,links:[a.jobID:[second.path]],writable:true,at:now)
        check(result.config?.macFolders.contains(second.path)==false,"native discovery resurrects dismissed output root")
        reader.set((1...65).map { sample(identity(Int32($0),now:now),nil) },partial:true)
        result=await worker.collect(store:store,links:[:],writable:false,at:now)
        check(result.observations.count==64 && result.health.partial,"candidate bound/partial health absent")
        let changedScene=NativeRenderCommandParser.parse(sample(a,[a.executable,"-b",scene,"-o",output.path+"/f####.png","-f","1",root.path+"/next.blend"]),at:now)!
        check(!changedScene.renderCommand && changedScene.outputRoot==nil,"scene loaded after render wrongly associated")
        let trailing=NativeRenderCommandParser.parse(sample(ff,[ff.executable,"-i",root.path+"/in.mp4",second.path+"/out.mp4","-frames:v","20"]),at:now)!
        check(!trailing.renderCommand && trailing.declaredTotal==nil,"trailing ffmpeg option attributed to earlier output")
        // Exercise the actual model's same-instance local path with injected process fixtures.
        let modelRoot=root.appendingPathComponent("Model")
        try fm.createDirectory(at:modelRoot,withIntermediateDirectories:true)
        try Data("[]".utf8).write(to:modelRoot.appendingPathComponent("monitor-jobs.json"))
        let modelReader=NativeFixtureReader();modelReader.set([])
        let model=MonitorModel(storageRoot:modelRoot,collectionEnabled:true,nativeReader:modelReader)
        defer { model.stop() }
        let initialTicket=model.nativeRequestedGeneration
        let initialAdopted=await model.waitForNativeDiscovery(initialTicket)
        check(initialAdopted,"initial native generation not adopted")
        modelReader.set([sample(a,[a.executable,"-b",scene,"--python",root.path+"/render.py"])])
        let candidateTicket=model.refreshLocalDiscovery()
        let candidateAdopted=await model.waitForNativeDiscovery(candidateTicket)
        check(candidateAdopted,"candidate generation not adopted")
        check(model.catalogSnapshot.jobs.contains {$0.id==a.jobID && $0.activity == .unknown},"actual model misses arriving script candidate")
        modelReader.set([sample(a,[a.executable,"-b",scene,"-o",output.path+"/frame_####.png","-f","1"])])
        let outputTicket=model.refreshLocalDiscovery()
        let outputAdopted=await model.waitForNativeDiscovery(outputTicket)
        check(outputAdopted,"output generation not adopted")
        check(model.config.macFolders.contains(output.path),"same model instance misses new CLI output root")
        check(model.macHealth.checkedAt==nil && model.shadowHealth.checkedAt==nil,"local discovery contacts provider")
        model.removeMacFolder(output.path);let removalTicket=model.refreshLocalDiscovery()
        let removalAdopted=await model.waitForNativeDiscovery(removalTicket)
        check(removalAdopted,"removal generation not adopted")
        check(!model.config.macFolders.contains(output.path) && model.config.dismissedMacFolders.contains(output.path),"model concurrent discovery resurrects user removal")
        model.stop();await model.waitForShutdown()
        print("NativeDiscoveryTests: \(checks) assertions PASS; isolated process/metadata/catalogue fixtures; no renderer/provider/UI")
    }
}
