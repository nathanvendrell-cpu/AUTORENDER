import Foundation
@main enum ArchiveTests {
    static var count=0
    static func check(_ value:@autoclosure()->Bool,_ message:String) { count += 1;precondition(value(),message) }
    static func job(_ id:String,done:Int,total:Int,process:Bool=false)->RenderDashboardJob {
        var h=SourceHealth();h.online=true;h.observedAt=Date()
        var job=RenderDashboard.mac(MacJob(id:id,titre:"Neutral",sous:nil,total:total,faites:done,en_cours:[],latest:[],times:[],proc:process ? MacProcess(cpu:"1",ram_mo:1,duree:"00:01") : nil),health:h,projectID:"project",workType:nil)
        job.taskQualification=process ? .nativeRenderCommand:nil // SIMULATED reactivation evidence.
        return job
    }
    static func shadow(post:Int?,total:Int?)->RenderDashboardJob {
        let data=try! JSONSerialization.data(withJSONObject:["ok":true,"brut":10,"post":post as Any? ?? NSNull(),"total":total as Any? ?? NSNull(),"blender":0])
        var h=SourceHealth();h.online=true;h.observedAt=Date()
        return RenderDashboard.shadow(try! JSONDecoder().decode(ShadowResponse.self,from:data),health:h,declaration:nil)
    }
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-"+UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let completed=job("completed",done:10,total:10)
        let running=job("running",done:10,total:10,process:true)
        let unknown=job("unknown",done:10,total:0)
        let incomplete=job("incomplete",done:3,total:10)
        let shadowComplete=shadow(post:10,total:10)
        let shadowIncomplete=shadow(post:3,total:10)
        let shadowUnknown=shadow(post:nil,total:10)
        var stale=completed;stale.id="stale";stale.isFresh=false
        check(completed.canArchive,"terminal local job ineligible")
        check(!running.canArchive && !unknown.canArchive && !incomplete.canArchive && !stale.canArchive,"active/unknown/incomplete/stale automatically eligible")
        check(!shadowComplete.canArchive && !shadowIncomplete.canArchive && !shadowUnknown.canArchive,"legacy Shadow without run attribution cannot create archives, even with complete declared counts")
        let batch=[completed,running,unknown,incomplete,stale]
        let seed=RenderCatalogSnapshot(revision:1,generatedAt:Date(),jobs:batch,projects:RenderDashboard.projects(batch),works:[],knownJobCount:batch.count,observedJobCount:batch.count,stateCounts:RenderCatalogStateCounts(),persistenceIssue:nil)
        let model=MonitorModel.fixture(snapshot:seed,storageRoot:root)
        defer { model.stop() }
        let file=root.appendingPathComponent("config.json")
        var doc=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];doc["future_private_key"]="preserve"
        try JSONSerialization.data(withJSONObject:doc).write(to:file)
        check(!model.setJobArchived(true,forJobID:running.id),"running job archived")
        check(model.archiveCompletedJobs()==1,"bulk archived nonterminal rows")
        for _ in 0..<100 { if model.catalogSnapshot.archivedJobCount==1 { break };try await Task.sleep(for:.milliseconds(10)) }
        check(model.catalogSnapshot.archivedJobCount==1 && model.catalogSnapshot.stateCounts.archived==1,"archive snapshot/count missing")
        check(model.catalogSnapshot.knownJobCount==batch.count,"archive deletes catalogue records")
        check(model.setJobArchived(true,forJobID:completed.id),"already archived set is not idempotent")
        let cfg=try JSONDecoder().decode(AppConfig.self,from:Data(contentsOf:file))
        check(cfg.jobArchives.keys.contains(completed.id),"archive not persisted by stable ID")
        let preserved=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        check(preserved["future_private_key"] as? String=="preserve","archive overwrites unrelated config")
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        check(files.contains{$0.lastPathComponent.hasPrefix("config.before-preference-change-")},"archive lacks reversible backup")
        let rev=model.catalogSnapshot.revision
        _=model.setJobContext(nil,forJobID:completed.id)
        for _ in 0..<100 { if model.catalogSnapshot.revision>rev { break };try await Task.sleep(for:.milliseconds(10)) }
        check(model.catalogSnapshot.jobs.first{$0.id==completed.id}?.isArchived==true,"poll rebuild resurrected archived terminal job")
        check(model.setJobArchived(false,forJobID:completed.id),"restore failed")
        for _ in 0..<100 { if model.catalogSnapshot.archivedJobCount==0 { break };try await Task.sleep(for:.milliseconds(10)) }
        check(model.catalogSnapshot.archivedJobCount==0 && model.catalogSnapshot.knownJobCount==batch.count,"restore loses records")
        check(model.archiveCompletedJobs()==1,"second archive failed")
        for _ in 0..<100 { if model.catalogSnapshot.archivedJobCount==1 { break };try await Task.sleep(for:.milliseconds(10)) }
        check(model.restoreAllArchivedJobs()==1,"restore-all missed preference")
        let service=RenderCatalogService(root:root.appendingPathComponent("actor"))
        var config=AppConfig(jobArchives:[completed.id:Date()])
        func input(_ job:RenderDashboardJob)->RenderCatalogInput {
            var value=RenderCatalogInput(revision:1,macJobs:[],shadow:nil,declaration:nil,config:config,knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:SourceHealth(),shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth());value.preparedJobs=[job];return value
        }
        let archived=await service.build(input(completed))!
        check(archived.jobs[0].isArchived,"archive not effective in worker")
        let active=job("completed",done:3,total:10,process:true)
        let resumed=await service.build(input(active))!
        check(!resumed.jobs[0].isArchived && resumed.stateCounts.running==1,"real reactivation hidden by archive")
        let paused=job("completed",done:3,total:10)
        let pauseSnapshot=await service.build(input(paused))!
        check(pauseSnapshot.jobs[0].isArchived && pauseSnapshot.reactivatedArchiveIDs.isEmpty,"manual archive lost on fresh paused/nonterminal observation without attributed running")
        let finished=await service.build(input(completed))!
        check(finished.jobs[0].isArchived,"service retains preference until controller persists explicit running override")
        config.jobArchives=[:]
        let restored=await service.build(input(completed))!
        check(!restored.jobs[0].isArchived,"unarchive preference ignored")
        check(model.setJobArchived(false,forJobID:completed.id),"restore idempotence failed")
        let old=try JSONDecoder().decode(AppConfig.self,from:Data(#"{"macFolders":[],"shadowFolders":[]}"#.utf8))
        check(old.jobArchives.isEmpty,"old config migration invents archives")
        let corrupt=try JSONDecoder().decode(AppConfig.self,from:Data(#"{"macFolders":[],"shadowFolders":[],"jobArchives":{"schemaVersion":99,"records":{}}}"#.utf8))
        check(corrupt.archivePayloadError != nil,"future archive payload silently treated valid")
        let badRoot=root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at:badRoot,withIntermediateDirectories:true)
        let badData=Data(#"{"macFolders":[],"shadowFolders":[],"jobArchives":{"schemaVersion":99,"records":{}}}"#.utf8)
        try badData.write(to:badRoot.appendingPathComponent("config.json"))
        let badModel=MonitorModel.fixture(snapshot:seed,storageRoot:badRoot)
        defer { badModel.stop() }
        check(!badModel.setJobArchived(true,forJobID:completed.id),"corrupt archive overwritten")
        check(!badModel.setJobArchived(false,forJobID:completed.id) && badModel.archiveError != nil,"future payload restore falsely claims success")
        let badAfter=try JSONSerialization.jsonObject(with:Data(contentsOf:badRoot.appendingPathComponent("config.json"))) as! [String:Any]
        check((badAfter["jobArchives"] as? [String:Any])?["schemaVersion"] as? Int == 99,"future archive body not preserved")
        let resumedSnapshot=RenderCatalogSnapshot(revision:2,generatedAt:Date(),jobs:[active],projects:RenderDashboard.projects([active]),works:[],knownJobCount:1,observedJobCount:1,stateCounts:RenderCatalogStateCounts(),persistenceIssue:nil)
        let resumeRoot=root.appendingPathComponent("resume")
        let resumeModel=MonitorModel.fixture(snapshot:resumedSnapshot,storageRoot:resumeRoot)
        defer { resumeModel.stop() }
        let resumeFile=resumeRoot.appendingPathComponent("config.json")
        var resumeConfig=try JSONDecoder().decode(AppConfig.self,from:Data(contentsOf:resumeFile))
        resumeConfig.jobArchives[active.id]=Date()
        try JSONEncoder().encode(resumeConfig).write(to:resumeFile)
        _=resumeModel.setJobContext(nil,forJobID:active.id)
        for _ in 0..<100 {
            let saved=try JSONDecoder().decode(AppConfig.self,from:Data(contentsOf:resumeFile))
            if saved.jobArchives[active.id]==nil { break };try await Task.sleep(for:.milliseconds(10))
        }
        let afterResume=try JSONDecoder().decode(AppConfig.self,from:Data(contentsOf:resumeFile))
        check(afterResume.jobArchives[active.id]==nil,"confirmed running doesn't permanently restore archive preference")
        check(resumeModel.catalogSnapshot.jobs[0].isArchived==false,"resumed job hidden")
        print("ArchiveTests: \(count) assertions passed")
    }
}
