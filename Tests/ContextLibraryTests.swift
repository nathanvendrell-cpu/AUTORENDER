import Foundation
import SQLite3

@main enum ContextLibraryTests {
    static var checks=0
    static func check(_ condition:Bool,_ text:String)throws {checks += 1;if !condition {throw NSError(domain:text,code:1)}}
    static func job(_ id:String="mac:native:fixture",complete:Bool=false,count:Int=0,total:Int=10,source:RenderSource = .macMonitor,at:Date=Date())->RenderDashboardJob {
        var j=RenderDashboardJob(id:id,title:"SampleScene.blend",projectID:"native:"+id,source:source,workType:.video,rawCount:count,postCount:nil,rawProgress:RenderProgress(completed:count,total:total),postProgress:nil,totalProvenance:"fixture explicit",activity:complete ? .countsReached:.running,isFresh:true,observedAt:at,lastActivity:at,historicalMedianSeconds:nil,sampledOutputsLastHour:nil,eta:nil,process:nil,gpu:nil,gpuRaw:nil,plans:[],tasks:[],stageDescription:nil,previewEntries:[])
        j.taskQualification = .nativeRenderCommand;j.sourceContext=RenderSourceContext(filePath:"C:/ClientA/SampleScene.blend",sceneName:"Scene",origin:.nativeBlender)
        j.versionID="version:stable";j.renderStartedAt=at.addingTimeInterval(-60);j.singleStageRender=true
        return j
    }
    static func input(_ jobs:[RenderDashboardJob],_ config:AppConfig=AppConfig())->RenderCatalogInput {
        var v=RenderCatalogInput(revision:1,macJobs:[],shadow:nil,declaration:nil,config:config,knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:SourceHealth(),shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth());v.preparedJobs=jobs;return v
    }
    static func main() async throws {
        do {try await run()} catch {
            FileHandle.standardError.write(Data("ContextLibraryTests failed after \(checks) checks: \(error)\n".utf8));throw error
        }
    }
    static func run() async throws {
        let fm=FileManager.default;let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("context-fixture-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let original=job(),id=original.id,version=original.versionID
        let unknown=RenderContextResolver(config:AppConfig()).apply(original)
        try check(unknown.contextAssignment == .unknown && unknown.projectTitle=="À classer","unknown file name invents client")
        try check(unknown.subprojectID==nil && unknown.sourceContext?.sceneName=="Scene","unknown hierarchy or explicit scene lost")
        try check(unknown.id==id && unknown.versionID==version && unknown.rawCount==original.rawCount,"classification rewrites identity or counters")
        var c=AppConfig();c.folderProjects=["c:\\clienta":"ClientA","C:/ClientB":"ClientB"]
        let clienta=RenderContextResolver(config:c).apply(original)
        try check(clienta.projectTitle=="ClientA" && clienta.contextAssignment == .assigned,"configured Windows root not matched")
        var conflict=original;conflict.sourceContext?.outputPath="C:/ClientB/final.png"
        let ambiguous=RenderContextResolver(config:c).apply(conflict)
        try check(ambiguous.contextAssignment == .ambiguous && ambiguous.projectTitle=="À classer","contradictory clients merged")
        var other=original;other.id="mac:native:other";other.sourceContext?.filePath="C:/ClientB/SampleScene.blend"
        let jm=RenderContextResolver(config:c).apply(other)
        try check(jm.projectID != clienta.projectID && jm.sceneID != clienta.sceneID,"same Scene label merges clients")
        let chosen=RenderJobContext(projectID:"client:ClientA",projectTitle:"ClientA",subprojectID:"sub:subprojectone",subprojectTitle:"SubprojectOne",sceneID:"scene:samplescene",sceneTitle:"SampleScene",libraryVersion:"v050",workID:"work:declination",versionID:"version:stable",workTitle:"VariantOne",versionLabel:"v050")
        c.jobContexts[original.id]=chosen
        let assigned=RenderContextResolver(config:c).apply(conflict)
        try check(assigned.projectID=="client:ClientA" && assigned.subprojectTitle=="SubprojectOne" && assigned.sceneID=="scene:samplescene","explicit context not authoritative")
        try check(assigned.id==id && assigned.versionID==version,"explicit context mutates invocation/version")
        var rules=AppConfig();rules.contextRules=[RenderContextRule(id:"V50",rootPath:"C:/ClientA",exactFileName:"SampleScene.blend",context:chosen)]
        let ruled=RenderContextResolver(config:rules).apply(original)
        try check(ruled.projectID=="client:ClientA" && ruled.libraryVersion=="v050","explicit V50 rule ignored")
        var different=chosen;different.projectID="client:other"
        rules.contextRules!.append(RenderContextRule(id:"conflict",rootPath:"C:/ClientA",context:different))
        try check(RenderContextResolver(config:rules).apply(original).contextAssignment == .ambiguous,"conflicting rules guessed a project")
        let old=try JSONDecoder().decode(RenderJobContext.self,from:Data("{\"workID\":\"legacy\"}".utf8))
        try check(old.subprojectID==nil && old.workID=="legacy","old contexts not compatible")
        let malformed=try JSONDecoder().decode(RenderSourceContext.self,from:Data("[1,2]".utf8))
        try check(malformed.sanitized==nil,"malformed context treated as activity evidence")
        let identity=NativeProcessIdentity(pid:1,birthSeconds:1,birthMicroseconds:0,executable:"/fixture/blender")
        let parsed=NativeRenderCommandParser.parse(NativeProcessSnapshot(identity:identity,arguments:[identity.executable,"-b","/ClientA/SampleScene.blend","-S","SampleScene native","-f","1"]),at:Date())!
        try check(parsed.dashboard(entries:[]).sourceContext?.sceneName=="SampleScene native","native CLI scene not extracted")
        let catalogue=RenderCatalogService(root:root.appendingPathComponent("catalog"))
        let first=await catalogue.build(input([original],c))!
        let tick=await catalogue.build(input([job(count:3,at:Date().addingTimeInterval(3))],c))!
        try check(first.historyRevision==tick.historyRevision,"progress/observedAt tick rebuilds history")
        let end=await catalogue.build(input([job(complete:true,count:10)],c))!
        try check(end.historyRevision>tick.historyRevision,"completion does not revise history")
        c.jobContexts[original.id]?.sceneTitle="SampleScene renamed"
        let renamed=await catalogue.build(input([job(complete:true,count:10)],c))!
        try check(renamed.historyRevision>end.historyRevision,"classification rename does not revise history")
        let rootSource=root.appendingPathComponent("source");try fm.createDirectory(at:rootSource,withIntermediateDirectories:true)
        let file=rootSource.appendingPathComponent("finished.png");try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!.write(to:file)
        let now=Date();try fm.setAttributes([.modificationDate:now.addingTimeInterval(-20)],ofItemAtPath:file.path)
        var stamp=try RenderLibraryFileStamp.read(file)
        var done=assigned;done.nativeRenderOutcome="complete";done.renderStartedAt=now.addingTimeInterval(-60);done.libraryVersion="v050"
        func candidate(_ name:String,_ remote:String?=nil)->RenderLibraryCandidate {RenderLibraryCandidate(id:name,jobID:done.id,localFile:file,originalRemotePath:remote,runStartedAt:done.renderStartedAt,firstObservedAt:now.addingTimeInterval(-9),secondObservedAt:now,firstStamp:stamp,secondStamp:stamp,finalStageAttested:true,type:"image",take:name)}
        let settings=RenderLibrarySettings(mode:.managedLibrary,rootPath:root.appendingPathComponent("library").path,activatedAt:now.addingTimeInterval(-120))
        let library=ManagedRenderLibrary()
        let plan=await library.preview(job:done,candidate:candidate("take1"),settings:settings)
        try check(plan.state == .ready && !fm.fileExists(atPath:settings.rootPath),"preview mutates library or rejects attested new task")
        do {_ = try await library.execute(plan,approval:RenderLibraryApproval(planIDs:[]),settings:settings);throw NSError(domain:"unapproved lot executed",code:1)}catch ManagedRenderLibrary.Failure.notApproved {checks += 1}
        let copied=try await library.execute(plan,approval:RenderLibraryApproval(planIDs:[plan.id]),settings:settings)
        try check(copied.state == .copiedSourceKept && fm.fileExists(atPath:file.path) && fm.fileExists(atPath:plan.target!.path),"verified copy loses source or claims wrong state")
        try check(try Data(contentsOf:file)==Data(contentsOf:plan.target!),"copy bytes differ")
        let replay=try await library.execute(plan,approval:RenderLibraryApproval(planIDs:[plan.id]),settings:settings)
        try check(replay.id==copied.id,"exact replay is not idempotent")
        let colliding=await library.preview(job:done,candidate:candidate("collision"),settings:settings)
        try Data("do not overwrite".utf8).write(to:colliding.target!)
        do {_ = try await library.execute(colliding,approval:RenderLibraryApproval(planIDs:[colliding.id]),settings:settings);throw NSError(domain:"collision overwritten",code:1)}catch ManagedRenderLibrary.Failure.collision {checks += 1}
        let restarted=ManagedRenderLibrary();let records=try await restarted.loadRecent(settings:settings)
        try check(records.contains{$0.id==copied.id && $0.state == .copiedSourceKept},"journal not recoverable")
        _ = try await restarted.undo(copied.id,approvedRecordID:copied.id,settings:settings)
        try check(fm.fileExists(atPath:file.path) && !fm.fileExists(atPath:plan.target!.path),"copy undo loses source or leaves target")
        let move=await library.preview(job:done,candidate:candidate("take2"),settings:settings)
        let moved=try await library.execute(move,approval:RenderLibraryApproval(planIDs:[move.id],allowLocalMove:true),settings:settings)
        try check(moved.state == .moved && !fm.fileExists(atPath:file.path),"explicit local move not performed")
        _ = try await library.undo(moved.id,approvedRecordID:moved.id,settings:settings)
        try check(fm.fileExists(atPath:file.path) && !fm.fileExists(atPath:move.target!.path),"move undo not exact")
        stamp=try RenderLibraryFileStamp.read(file)
        let remote=await library.preview(job:done,candidate:candidate("remote","C:/renders/final.png"),settings:settings)
        let remoteRecord=try await library.execute(remote,approval:RenderLibraryApproval(planIDs:[remote.id],allowLocalMove:true),settings:settings)
        try check(remoteRecord.state == .copiedSourceKept && fm.fileExists(atPath:file.path),"remote staging source deleted")
        var memory=done;memory.outputAvailability = .inMemory
        try check(await library.preview(job:memory,candidate:candidate("memory"),settings:settings).state == .inMemory,"in-memory F12 claims a file import")
        var oldSettings=settings;oldSettings.activatedAt=now
        try check(await library.preview(job:done,candidate:candidate("old"),settings:oldSettings).state == .previewOnly,"activation imports older media automatically")
        try check(fm.fileExists(atPath:URL(fileURLWithPath:settings.rootPath).appendingPathComponent(".autoren-library-index.json").path),"lightweight local index missing")
        enum Injected:Error {case checkpoint}
        for phase in [RenderLibraryPhase.staged,.linked,.sourceHeld] {
            stamp=try RenderLibraryFileStamp.read(file)
            let interrupted=ManagedRenderLibrary(checkpoint:{value in if value==phase {throw Injected.checkpoint}})
            let crashPlan=await interrupted.preview(job:done,candidate:candidate("crash-"+phase.rawValue),settings:settings)
            do {_ = try await interrupted.execute(crashPlan,approval:RenderLibraryApproval(planIDs:[crashPlan.id],allowLocalMove:phase == .sourceHeld),settings:settings);throw NSError(domain:"checkpoint not reached",code:1)}catch Injected.checkpoint {checks += 1}
            let recovery=ManagedRenderLibrary();let pending=try await recovery.pendingRecovery(settings:settings)
            guard let row=pending.first(where:{$0.plan.id==crashPlan.id}) else{throw NSError(domain:"pending recovery missing",code:1)}
            let recovered=try await recovery.recover(row.id,approvedRecordID:row.id,settings:settings)
            try check(recovered.phase == .complete && fm.fileExists(atPath:crashPlan.target!.path),"interrupted transaction not recovered")
            _ = try await recovery.undo(recovered.id,approvedRecordID:recovered.id,settings:settings)
            try check(fm.fileExists(atPath:file.path),"recovery/undo loses source")
        }
        stamp=try RenderLibraryFileStamp.read(file)
        var sameProject=done;sameProject.projectTitle="ClientA display renamed"
        let namesBefore=await library.preview(job:done,candidate:candidate("name-check"),settings:settings)
        let namesAfter=await library.preview(job:sameProject,candidate:candidate("name-check"),settings:settings)
        try check(namesBefore.target==namesAfter.target,"display rename creates a second physical tree")
        var otherLibrary=settings;otherLibrary.rootPath=root.appendingPathComponent("tamper-library").path
        let secure=ManagedRenderLibrary();let securedPlan=await secure.preview(job:done,candidate:candidate("secure"),settings:otherLibrary)
        let secured=try await secure.execute(securedPlan,approval:RenderLibraryApproval(planIDs:[securedPlan.id]),settings:otherLibrary)
        var db:OpaquePointer?;try check(sqlite3_open(URL(fileURLWithPath:otherLibrary.rootPath).appendingPathComponent(".autoren-library.sqlite3").path,&db)==SQLITE_OK,"fixture SQLite open")
        try check(sqlite3_exec(db,"UPDATE tx SET data=x'7b7d'",nil,nil,nil)==SQLITE_OK,"fixture journal tamper")
        sqlite3_close(db)
        do {_ = try await secure.undo(secured.id,approvedRecordID:secured.id,settings:otherLibrary);throw NSError(domain:"tampered journal accepted",code:1)}catch RenderLibraryStore.Failure.tamperedRecord {checks += 1}
        try check(fm.fileExists(atPath:securedPlan.target!.path) && fm.fileExists(atPath:file.path),"tampered journal deletes files")
        var v50=original;v50.sourceContext?.filePath="C:/ClientA/source_v50.blend"
        var v51=v50;v51.id="mac:native:v51";v51.sourceContext?.filePath="C:/ClientA/source_v51.blend"
        var reusable=AppConfig();reusable.projectBindings=[RenderProjectBinding(id:"project:reusable",title:"ClientA",roots:[RenderProjectRoot(path:"C:/ClientA",namespace:"mac-local")])]
        let a50=RenderContextResolver(config:reusable).apply(v50),a51=RenderContextResolver(config:reusable).apply(v51)
        try check(a50.sceneID==a51.sceneID && a50.libraryVersion=="v050" && a51.libraryVersion=="v051","v50/v51 split scenes or need repeated manual classification")
        try check(RenderVersionToken.version("V50")=="v050","uppercase unpadded V50 not normalized")
        for phase in [RenderLibraryPhase.undoPrepared,.undoRestored] {
            stamp=try RenderLibraryFileStamp.read(file)
            let normal=ManagedRenderLibrary();let p=await normal.preview(job:done,candidate:candidate("undo-crash-"+phase.rawValue),settings:settings)
            let r=try await normal.execute(p,approval:.init(planIDs:[p.id],allowLocalMove:true),settings:settings)
            let fault=ManagedRenderLibrary(checkpoint:{value in if value==phase {throw Injected.checkpoint}})
            do {_ = try await fault.undo(r.id,approvedRecordID:r.id,settings:settings);throw NSError(domain:"undo checkpoint absent",code:1)}catch Injected.checkpoint {checks += 1}
            let resume=ManagedRenderLibrary();_ = try await resume.recover(r.id,approvedRecordID:r.id,settings:settings)
            try check(fm.fileExists(atPath:file.path) && !fm.fileExists(atPath:p.target!.path),"interrupted local undo not recovered")
        }
        // Historical progress ticks must not reclassify every retained row.
        let classificationBefore=await catalogue.classificationPassCount
        _ = await catalogue.build(input([job(complete:true,count:10)],c))
        let classificationAfter=await catalogue.classificationPassCount
        try check(classificationAfter-classificationBefore==1,"one current job reclassifies historical catalogue")
        let invalidExport=try JSONDecoder().decode(RenderExportArtifact.self,from:Data("{\"path\":1,\"sha256\":false}".utf8))
        try check(invalidExport.sanitized==nil,"malformed optional export breaks or attests a file")
        // Remote moves only become moved after an exact adapter proof; the source is never locally removed.
        stamp=try RenderLibraryFileStamp.read(file)
        let remoteEngine=ManagedRenderLibrary();var remoteJob=done
        let artifact=RenderRemoteArtifact(connectionScope:String(repeating:"a",count:64),path:"C:/renders/final.png",processID:42,birthToken:"133999999999999999",invocationToken:String(repeating:"b",count:32),startedAt:ISO8601DateFormatter().string(from:done.renderStartedAt!),completedAt:ISO8601DateFormatter().string(from:now.addingTimeInterval(-20)))
        // Native packets retain their ISO precision; use the same parsed start in job and artifact.
        remoteJob.renderStartedAt=RenderDate.parseOptional(artifact.startedAt);remoteJob.remoteArtifact=artifact
        let rc=RenderLibraryCandidate(id:"remote-durable",jobID:remoteJob.id,localFile:file,originalRemotePath:artifact.path,runStartedAt:remoteJob.renderStartedAt,firstObservedAt:now.addingTimeInterval(-9),secondObservedAt:now,firstStamp:stamp,secondStamp:stamp,finalStageAttested:true,type:"image",take:"remote-durable")
        let rp=await remoteEngine.preview(job:remoteJob,candidate:rc,settings:settings)
        let copiedRemote=try await remoteEngine.execute(rp,approval:.init(planIDs:[rp.id]),settings:settings)
        let pendingRemote=try await remoteEngine.prepareRemoteRetirement(copiedRemote.id,artifact:artifact,settings:settings)
        try check(pendingRemote.phase == .remotePrepared && pendingRemote.state == .awaitingTransfer,"unconfirmed remote retirement claims moved")
        let tx=pendingRemote.remoteTransactionID!
        let proof=RenderRemoteReturn(originalPath:artifact.path,returnPath:"C:/renders/.autoren-returns/"+tx+".png",sha256:pendingRemote.sha256,transactionID:tx,connectionScope:artifact.connectionScope)
        let committedRemote=try await remoteEngine.commitRemoteRetirement(pendingRemote.id,proof:proof,settings:settings)
        try check(committedRemote.state == .moved && fm.fileExists(atPath:file.path),"remote proof wrongly removes local staging")
        let remoteUndo=try await remoteEngine.prepareRemoteUndo(committedRemote.id,approvedRecordID:committedRemote.id,settings:settings)
        try check(remoteUndo.phase == .remoteUndoPrepared && fm.fileExists(atPath:rp.target!.path),"undo removes Mac copy before remote restore proof")
        _ = try await remoteEngine.completeRemoteUndo(committedRemote.id,proof:proof,settings:settings)
        try check(!fm.fileExists(atPath:rp.target!.path) && fm.fileExists(atPath:file.path),"verified remote undo retains wrong artifact")
        // Coordinator uses only the existing cycle: first stat, later stable stat, one move, then exact undo.
        let autoEngine=ManagedRenderLibrary();let life=RenderTaskLifetime();let coordinator=RenderLibraryCoordinator(engine:autoEngine,lifetime:life,remote:ForbiddenRemote())
        var autoJob=done;autoJob.id="mac:native:auto";autoJob.outputAvailability = .fileAttested;autoJob.finalOutputProof = .verifiedCounters;autoJob.outputExpectedCount=1;autoJob.sourceContext?.outputPath=file.path
        var autoSettings=settings;autoSettings.rootPath=root.appendingPathComponent("automatic-library").path
        let waiting=await coordinator.cycle(jobs:[autoJob],settings:autoSettings,now:now)
        try check(waiting.records.isEmpty && fm.fileExists(atPath:file.path),"first observation moves unstable output")
        let automatic=await coordinator.cycle(jobs:[autoJob],settings:autoSettings,now:now.addingTimeInterval(9))
        try check(automatic.records.first?.state == .moved && !fm.fileExists(atPath:file.path),"future attested stable job not automatically classified and moved")
        if let record=automatic.records.first {_ = try await coordinator.undo(record.id,approvedRecordID:record.id,settings:autoSettings)}
        try check(fm.fileExists(atPath:file.path),"automatic move undo fails")
        // Three files from one non-GUI counter-attested job, continued after the observation disappears.
        let sequenceRoot=root.appendingPathComponent("sequence");try fm.createDirectory(at:sequenceRoot,withIntermediateDirectories:true)
        for n in 1...3 {try Data("pixel-\(n)".utf8).write(to:sequenceRoot.appendingPathComponent(String(format:"f_%04d.png",n)))}
        func sequenceFixture(_ source:RenderSource)->RenderDashboardJob {
            var j=job("mac:native:sequence",complete:true,count:3,total:3,source:source)
            j.projectID=autoJob.projectID;j.projectTitle=autoJob.projectTitle;j.contextAssignment=autoJob.contextAssignment;j.hasVerifiedProjectContext=true;j.sceneID=autoJob.sceneID;j.sceneTitle=autoJob.sceneTitle;j.libraryVersion=autoJob.libraryVersion;j.sourceContext=autoJob.sourceContext;j.finalOutputProof = .verifiedCounters;j.outputAvailability = .fileAttested
            return j
        }
        var sequence=sequenceFixture(.macMonitor);sequence.nativeRenderOutcome=nil;sequence.outputExpectedCount=3;sequence.sourceContext?.outputPath=sequenceRoot.appendingPathComponent("f_%04d.png").path;sequence.libraryInvocationID="sequence-pass-1"
        var seqSettings=settings;seqSettings.rootPath=root.appendingPathComponent("sequence-library").path
        let seqEngine=ManagedRenderLibrary();let seqCoordinator=RenderLibraryCoordinator(engine:seqEngine,lifetime:RenderTaskLifetime(),remote:ForbiddenRemote())
        let seqPending=await seqCoordinator.cycle(jobs:[sequence],settings:seqSettings,now:now)
        try check(seqPending.records.isEmpty && seqPending.activities.first?.state != .moved,"sequence claims global move before stable outputs")
        let seqDone=await seqCoordinator.cycle(jobs:[],settings:seqSettings,now:now.addingTimeInterval(9))
        try check(seqDone.records.count==3 && seqDone.activities.contains{$0.id==sequence.id && $0.state == .moved},"durable job absent from next cycle loses sequence artifacts")
        try check(Set(seqDone.records.compactMap{$0.plan.target?.path}).count==3,"sequence artifacts collide")
        for r in seqDone.records {_ = try await seqCoordinator.undo(r.id,approvedRecordID:r.id,settings:seqSettings)}
        try check((try fm.contentsOfDirectory(atPath:sequenceRoot.path)).filter{$0.hasSuffix(".png")}.count==3,"sequence undo fails to restore every file")
        sequence.libraryInvocationID="sequence-pass-2"
        _ = await seqCoordinator.cycle(jobs:[sequence],settings:seqSettings,now:now.addingTimeInterval(20))
        let seqAgain=await seqCoordinator.cycle(jobs:[],settings:seqSettings,now:now.addingTimeInterval(29))
        let secondPass=seqAgain.records.filter{$0.state == .moved}
        try check(secondPass.count==3 && Set(secondPass.map(\.id)).isDisjoint(with:Set(seqDone.records.map(\.id))),"rerender borrows old artifact transaction")
        // Two remote pages (2+1 assets) prove that copied file one never implies whole job completion.
        var scripted=sequenceFixture(.shadowMonitor);scripted.outputExpectedCount=3;scripted.id="shadow:run:script-fixture";scripted.libraryInvocationID="script-pass-1";scripted.finalOutputProof = .scriptFinalContract;scripted.renderStartedAt=RenderDate.parseOptional(artifact.startedAt)
        let scriptProof=RenderScriptFinalProof(runID:String(repeating:"c",count:64),launcherPath:"C:/task/run.ps1",launcherSHA256:String(repeating:"a",count:64),scriptPath:"C:/task/source_v50.py",scriptSHA256:String(repeating:"a",count:64),postScriptPath:"C:/task/post.py",postScriptSHA256:String(repeating:"a",count:64),rawRoot:"C:/task/raw",postRoot:"C:/task/post",plans:["A":[1,3]])
        scripted.remoteArtifact=RenderRemoteArtifact(connectionScope:String(repeating:"a",count:64),path:"C:/task/post/manifest-placeholder.png",processID:0,birthToken:"0",invocationToken:String(repeating:"d",count:32),startedAt:artifact.startedAt,completedAt:artifact.completedAt,scriptProof:scriptProof)
        var scriptSettings=settings;scriptSettings.rootPath=root.appendingPathComponent("script-library").path
        let scriptEngine=ManagedRenderLibrary(),adapter=PagedFixtureRemote();let scriptCoordinator=RenderLibraryCoordinator(engine:scriptEngine,lifetime:RenderTaskLifetime(),remote:adapter)
        let pageOne=await scriptCoordinator.cycle(jobs:[scripted],settings:scriptSettings,now:now)
        try check(pageOne.records.count==2 && !pageOne.activities.contains{$0.state == .moved},"first remote page claims whole job moved")
        let pageTwo=await scriptCoordinator.cycle(jobs:[],settings:scriptSettings,now:now.addingTimeInterval(1))
        try check(pageTwo.records.count==3 && pageTwo.activities.contains{$0.id==scripted.id && $0.state == .moved},"remote page2 abandoned when job leaves current observation")
        try check(await adapter.staged==3,"remote artifact duplicated or missing")
        // Source-scoped rule cannot transfer a client to another PC with the same drive path.
        var scopedRule=RenderContextRule(id:"scoped",rootPath:"C:/ClientA",namespace:"shadow:pc1",context:chosen)
        var pcOne=original;pcOne.sourceContext?.namespace="shadow:pc1"
        var pcTwo=pcOne;pcTwo.sourceContext?.namespace="shadow:pc2"
        try check(scopedRule.matches(pcOne.sourceContext) && !scopedRule.matches(pcTwo.sourceContext),"rule crosses source namespace")
        scopedRule.namespace=nil;try check(!scopedRule.matches(pcOne.sourceContext),"legacy unscoped rule crosses PC sources")
        var archivedHistory=job(complete:true,count:10);archivedHistory.isFresh=false;archivedHistory.retainedHistorical=true
        try check(archivedHistory.canArchive,"verified historical terminal cannot be hidden reversibly")
        var contradictory=original;contradictory.nativeRenderOutcome="complete"
        try check(!contradictory.canArchive,"contradictory running/complete observation can be archived")
        var unknownHistory=original;unknownHistory.isFresh=false;unknownHistory.retainedHistorical=true
        try check(!unknownHistory.canArchive && !original.canArchive,"unknown or active task can be archived")
        var legacyPlusBinding=AppConfig();legacyPlusBinding.folderProjects=["C:/ClientA/v50":"old label","C:/ClientA/v51":"old label"]
        legacyPlusBinding.projectBindings=[RenderProjectBinding(id:"bound:ClientA",title:"ClientA",roots:[RenderProjectRoot(path:"C:/ClientA",namespace:"shadow:pc1")])]
        var bound50=pcOne;bound50.sourceContext?.filePath="C:/ClientA/v50/source_v50.blend"
        var bound51=bound50;bound51.sourceContext?.filePath="C:/ClientA/v51/source_v51.blend"
        let b50=RenderContextResolver(config:legacyPlusBinding).apply(bound50),b51=RenderContextResolver(config:legacyPlusBinding).apply(bound51)
        try check(b50.projectID=="bound:ClientA" && b51.projectID==b50.projectID && b50.sceneID==b51.sceneID,"explicit parent binding conflicts with legacy descendants")
        bound51.sourceContext?.namespace="shadow:pc2"
        try check(RenderContextResolver(config:legacyPlusBinding).apply(bound51).projectID != b50.projectID,"explicit project binding leaks across PC namespaces")
        let preferencesRoot=root.appendingPathComponent("preferences");try fm.createDirectory(at:preferencesRoot,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["customFutureKey":["keep":true],"macFolders":[]]).write(to:preferencesRoot.appendingPathComponent("config.json"))
        let preferenceStore=RenderConfigStore(root:preferencesRoot)
        for n in 1...5 {_ = try preferenceStore.update{$0.folderProjects["/fixture/\(n)"]="project\(n)"}}
        let backups=try fm.contentsOfDirectory(at:preferencesRoot,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("config.before-preference-change-")}
        let preferenceDocument=try JSONSerialization.jsonObject(with:Data(contentsOf:preferencesRoot.appendingPathComponent("config.json"))) as! [String:Any]
        try check(backups.count==2 && (preferenceDocument["customFutureKey"] as? [String:Bool])?["keep"]==true,"preference updates exceed two backups or lose unknown keys")
        // Confirmed QA regression: prior100 plans must not invalidate any of the current200.
        var cacheSettings=settings;cacheSettings.rootPath=root.appendingPathComponent("cache-library").path
        stamp=try RenderLibraryFileStamp.read(file);let batchEngine=ManagedRenderLibrary()
        for n in 0..<100 {_ = await batchEngine.preview(job:done,candidate:candidate("old-cache-\(n)"),settings:cacheSettings)}
        var batch:[RenderLibraryPlan]=[]
        for n in 0..<200 {batch.append(await batchEngine.preview(job:done,candidate:candidate("current-cache-\(n)"),settings:cacheSettings))}
        var accepted=0
        for plan in batch {_ = try await batchEngine.execute(plan,approval:.init(planIDs:[plan.id]),settings:cacheSettings);accepted+=1}
        try check(accepted==200 && fm.fileExists(atPath:file.path),"100 prior previews invalidate the current200 approved plans")
        let inactive=ManagedRenderLibrary(lifetime:RenderTaskLifetime())
        _ = inactive // Main model owns the cancellation lifetime; no worker/timer is started.
        print("ContextLibraryTests: \(checks) assertions PASS; local fixtures only, no real library/media/PC")
    }
}

private struct ForbiddenRemote:RenderLibraryRemoteTransferring {
    enum NoRemote:Error {case prohibited}
    func configure(settings:RenderLibrarySettings)async throws {throw NoRemote.prohibited}
    func manifest(artifact:RenderRemoteArtifact,activation:Date,cursor:Int)async throws->RenderLibraryRemotePage {throw NoRemote.prohibited}
    func stage(artifact:RenderRemoteArtifact,activation:Date,destination:URL)async throws->RenderLibraryTransferProof {throw NoRemote.prohibited}
    func retire(artifact:RenderRemoteArtifact,activation:Date,transactionID:String,sha256:String)async throws->RenderRemoteReturn {throw NoRemote.prohibited}
    func restore(artifact:RenderRemoteArtifact,activation:Date,transactionID:String,sha256:String)async throws->RenderRemoteReturn {throw NoRemote.prohibited}
}

private actor PagedFixtureRemote:RenderLibraryRemoteTransferring {
    private(set) var staged=0
    func configure(settings:RenderLibrarySettings)async throws {}
    func manifest(artifact:RenderRemoteArtifact,activation:Date,cursor:Int)async throws->RenderLibraryRemotePage {
        let descriptor=RenderRemoteManifestDescriptor(id:artifact.invocationToken,indexPath:"C:/fixture/Manifests/"+artifact.invocationToken+"/index.json",sha256:String(repeating:"e",count:64),expectedCount:3,complete:true)
        let end=min(3,cursor+2)
        let outputs=(cursor..<end).map{n -> RenderLibraryArtifact in
            let path=String(format:"C:/task/post/A_%04d.png",n+1);var a=artifact;a.path=path;a.manifest=descriptor;a.manifestPagePath="C:/fixture/page.json";a.manifestPageSHA256=String(repeating:"f",count:64)
            return RenderLibraryArtifact(id:RenderContextPath.digest(artifact.invocationToken+"|"+path),path:path,frame:n+1,remote:a)
        }
        return RenderLibraryRemotePage(descriptor:descriptor,artifacts:outputs,nextCursor:end==3 ? nil:end,complete:true)
    }
    func stage(artifact:RenderRemoteArtifact,activation:Date,destination:URL)async throws->RenderLibraryTransferProof {
        staged+=1;try Data("fixture-pixel".utf8).write(to:destination)
        let hash=try RenderLibraryFilesystem.hash(destination,lifetime:nil),at=Date()
        let f=ISO8601DateFormatter()
        return RenderLibraryTransferProof(sha256:hash,bytes:13,localFile:destination.path,firstObservedAt:f.string(from:at.addingTimeInterval(-9)),secondObservedAt:f.string(from:at))
    }
    func retire(artifact:RenderRemoteArtifact,activation:Date,transactionID:String,sha256:String)async throws->RenderRemoteReturn {
        let normalized=artifact.path.replacingOccurrences(of:"\\",with:"/") as NSString
        let held=(normalized.deletingLastPathComponent as NSString).appendingPathComponent(".autoren-returns/"+transactionID+"."+normalized.pathExtension)
        return RenderRemoteReturn(originalPath:artifact.path,returnPath:held,sha256:sha256,transactionID:transactionID,connectionScope:artifact.connectionScope)
    }
    func restore(artifact:RenderRemoteArtifact,activation:Date,transactionID:String,sha256:String)async throws->RenderRemoteReturn {try await retire(artifact:artifact,activation:activation,transactionID:transactionID,sha256:sha256)}
}
