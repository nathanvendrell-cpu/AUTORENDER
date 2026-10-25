import Foundation

@main enum CatalogTests {
    static var checks=0
    static func require(_ ok: @autoclosure ()->Bool,_ text:String) { checks += 1; precondition(ok(),text) }
    static func input(_ jobs:[MacJob], config:AppConfig=AppConfig(), revision:UInt64=1) -> RenderCatalogInput {
        var health=SourceHealth();health.online=true;health.observedAt=RenderDate.parse("2026-10-12T12:00:00Z")
        return RenderCatalogInput(revision:revision,macJobs:jobs,shadow:nil,declaration:nil,config:config,knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:health,shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth())
    }
    static func jobs(_ count:Int)->[MacJob] {
        let times=["2026-10-12T11:57:00Z","2026-10-12T11:58:00Z","2026-10-12T11:59:00Z"]
        return (0..<count).map { index in MacJob(id:"neutral-\(index)",titre:"Same display title",sous:nil,total:240,faites:31,en_cours:[],latest:[],times:times,proc:MacProcess(cpu:"1",ram_mo:100,duree:"00:01:00"),workType:.video,projectID:"neutral") }
    }
    static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("catalog-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let service=RenderCatalogService(root:root.appendingPathComponent("catalog"))
        let batch=jobs(50)
        let first=await service.build(input(batch))!
        require(first.knownJobCount==50 && first.jobs.count==50,"50 known jobs silently capped")
        require(first.works.count==50,"same title/extension must not merge undeclared work IDs")
        require(first.stateCounts.running==50 && first.observedJobCount==50,"fresh per-job process counts incorrect")
        require(Set(first.jobs.map(\.id)).count==50,"duplicate stable job IDs")
        require(first.jobs.allSatisfy{$0.estimatedRemainingSeconds != nil},"fresh valid running samples lost remaining time")
        require(first.jobs.allSatisfy{$0.workID=="job:"+$0.id && $0.versionID==$0.id},"isolated default identities changed")
        let file=root.appendingPathComponent("catalog/jobs.json")
        require(FileManager.default.fileExists(atPath:file.path),"catalog not durable")
        let recorded=try JSONDecoder().decode(RenderJobCatalogue.self,from:Data(contentsOf:file))
        require(recorded.records.count==50 && recorded.records.values.allSatisfy{$0.job.previewEntries.isEmpty},"catalog persists preview gallery or misses jobs")
        let second=await service.build(input(Array(batch.prefix(1)),revision:2))!
        require(second.knownJobCount==50 && second.observedJobCount==1,"disappeared jobs discarded or current count invented")
        require(second.jobs.filter(\.retainedHistorical).count==49,"missing jobs not historical")
        require(second.stateCounts.running==1 && second.stateCounts.historical==49,"historic running jobs counted active")
        require(second.jobs.filter(\.retainedHistorical).allSatisfy{!$0.isFresh && $0.eta==nil && $0.estimatedRemainingSeconds==nil},"historic ETA/process falsely current")
        let restoredService=RenderCatalogService(root:root.appendingPathComponent("catalog"))
        let restored=await restoredService.build(input([]))!
        require(restored.knownJobCount==50 && restored.stateCounts.running==0,"relaunch loses metadata history or resumes jobs")
        var config=AppConfig()
        config.jobContexts["mac:neutral-0"]=RenderJobContext(projectID:nil,workID:"chosen-work",versionID:nil,workTitle:"Declared work",versionLabel:"Version A")
        config.jobContexts["mac:neutral-1"]=RenderJobContext(projectID:nil,workID:"chosen-work",versionID:nil,workTitle:"Declared work",versionLabel:"Version B")
        let organized=await service.build(input([],config:config,revision:3))!
        require(organized.works.first{$0.id=="chosen-work"}?.jobs.count==2,"historical versions cannot be explicitly grouped")
        require(organized.jobs.first{$0.id=="mac:neutral-0"}?.versionLabel=="Version A","explicit version label lost")
        require(organized.jobs.first{$0.id=="mac:neutral-0"}?.id=="mac:neutral-0","organization changes source job ID")
        let cleared=await service.build(input([],revision:4))!
        require(cleared.works.count==50 && cleared.knownJobCount==50,"unset must isolate work without deleting history")
        var declared=batch[0];declared.workID="source-work";declared.versionID="source-version"
        let source=await service.build(input([declared],config:config,revision:5))!
        let declaredView=source.jobs.first{$0.id=="mac:neutral-0"}!
        require(declaredView.workID=="source-work" && declaredView.versionID=="source-version" && declaredView.contextIsSourceDeclared,"user aliases replace declared source identities")
        let oldConfig=try JSONDecoder().decode(AppConfig.self,from:Data(#"{"macFolders":[],"shadowFolders":[],"dismissedMacFolders":["/tmp/removed"]}"#.utf8))
        require(oldConfig.jobContexts.isEmpty && oldConfig.dismissedMacFolders==["/tmp/removed"],"config migration loses removal")
        let migrated=try JSONDecoder().decode(RenderJobCatalogue.self,from:Data(#"{"records":{},"revision":7}"#.utf8))
        require(migrated.schemaVersion==1 && migrated.revision==7,"legacy catalogue header not migrated")
        let futureRoot=root.appendingPathComponent("future");try FileManager.default.createDirectory(at:futureRoot,withIntermediateDirectories:true)
        let futureData=Data(#"{"schemaVersion":999,"records":{}}"#.utf8);try futureData.write(to:futureRoot.appendingPathComponent("jobs.json"))
        let future=await RenderCatalogService(root:futureRoot).build(input(batch))!
        require(future.persistenceIssue != nil && future.jobs.count==50,"future catalogue not explicitly qualified")
        let untouchedFuture = try Data(contentsOf:futureRoot.appendingPathComponent("jobs.json"))
        require(untouchedFuture==futureData,"future catalogue overwritten")
        let entries=(0..<120).map { index in RenderEntry(id:"file-\(index)",source:.macFolder,job:"neutral",filename:"file-\(index).png",modified:Date(timeIntervalSince1970:Double(index)),state:.stable,path:nil,previewURL:nil) }
        let page=await service.history(jobID:"mac:neutral-0",incoming:entries,cursor:nil,limit:40,coverage:"fixture scope",scope:"root-revision-1")
        require(page.entries.count==40 && page.totalKnown==120 && page.nextCursor != nil,"history pagination capped or missing count")
        _=await service.build(input(batch,revision:6))
        let next=await service.history(jobID:"mac:neutral-0",incoming:[],cursor:page.nextCursor,limit:40,coverage:"fixture scope",scope:"root-revision-1")
        require(next.snapshotRevision==page.snapshotRevision && next.entries.count==40,"polling invalidates stable history cursor")
        require(Set(next.entries.map(\.id)).isDisjoint(with:Set(page.entries.map(\.id))),"duplicate history page rows")
        let invalid=await service.history(jobID:"mac:neutral-0",incoming:[],cursor:page.nextCursor,limit:40,coverage:"fixture scope",scope:"root-revision-2")
        require(invalid.entries.isEmpty && invalid.coverage.contains("Curseur"),"config/scope revision allows late history data")
        let duplicate=await service.build(input([batch[0],batch[0]],revision:7))!
        require(duplicate.observedJobCount==1 && duplicate.knownJobCount==50,"repeated source ID crashes/duplicates catalogue")
        let before=try Data(contentsOf:file)
        let cancelled=Task { withUnsafeCurrentTask{$0?.cancel()};return await service.build(input(batch,revision:8)) }
        let cancelledValue=await cancelled.value
        require(cancelledValue==nil,"cancelled build creates snapshot")
        let afterCancelled = try Data(contentsOf:file)
        require(afterCancelled==before,"cancelled build persists late records")
        let folder=root.appendingPathComponent("chosen");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for index in 0..<120 { try Data([1]).write(to:folder.appendingPathComponent("frame-\(index).png")) }
        let collector=FolderCollectionWorker()
        let recent=await collector.scan([folder.path]);let history=await collector.history([folder.path])
        require(recent.entries.count==80 && history.entries.count==120,"explicit history cannot reach files older than recent limit")
        require(history.entries.allSatisfy{$0.state != .complete},"metadata history falsely validates images")
        let tasks=(0..<8).map { _ in Task.detached { (0..<100).compactMap { _ in RenderDate.parseOptional("2026-10-12T12:00:00Z") }.count } }
        var parses=0;for task in tasks { parses += await task.value }
        require(parses==800,"thread-safe parser cache loses dates")
        require(RenderDate.parseOptional("invalid")==nil,"date cache fabricates timestamps")
        let cold = try JSONDecoder().decode(ShadowResponse.self,from:Data(#"{"ok":true,"brut":3,"post":1,"blender":0,"tasks":[{"name":"Demo_v1_E1","state":"Ready"},{"name":"Demo_v1_E2","state":"Ready"}]}"#.utf8))
        var privateLinks=AppConfig(dashboardProjectLinks:["shadow:Demo_v1_":"User declared project"],dashboardJobFolders:["shadow:Demo_v1_":["C:/neutral/brut","C:/neutral/post"]])
        let shadowInput=RenderCatalogInput(revision:9,macJobs:[],shadow:cold,declaration:nil,config:privateLinks,knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:SourceHealth(),shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth())
        let coldSnapshot=await service.build(shadowInput)!
        let recovered=coldSnapshot.jobs.first{$0.id=="shadow:Demo_v1_"}!
        require(recovered.projectTitle=="User declared project" && recovered.rawProgress==nil,"cached identity either lost explicit private link or invented total")
        require(recovered.openTargets.count==2 && recovered.openTargets.allSatisfy{$0.location==nil && $0.remoteDisplay != nil},"remote paths masquerade as local Finder/cache targets")
        privateLinks.dashboardProjectLinks["shadow:Other_"]="Other project"
        require(RenderDashboard.configuredShadowID(cold,config:privateLinks)=="shadow:Demo_v1_","nonmatching source binding stole identity")
        privateLinks.dashboardProjectLinks["shadow:Demo_"]="Ambiguous"
        require(RenderDashboard.configuredShadowID(cold,config:privateLinks)==nil,"ambiguous private source prefixes fabricated identity")
        var localInput=input([batch[0]],revision:10)
        let output=RenderEntry(id:"actual-file",source:.macFolder,job:"neutral",filename:"frame-0.png",modified:Date(),state:.stable,path:folder.appendingPathComponent("frame-0.png").path,previewURL:nil)
        localInput=RenderCatalogInput(revision:10,macJobs:[batch[0]],shadow:nil,declaration:nil,config:AppConfig(),knownFolders:[batch[0].id:folder.path],entries:[output],macEntries:[],folderEntries:[output],shadowEntries:[],shadowFolderEntries:[],macHealth:localInput.macHealth,shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth())
        let localSnapshot=await service.build(localInput)!
        let local=localSnapshot.jobs.first{$0.id=="mac:neutral-0"}!
        require(local.openTargets.first?.location?.path==folder.path && local.openTargets.first?.isVerified==true,"folder target guesses ancestor or opens thumbnail cache")
        require(local.revealURL?.path==output.path,"known stable output cannot reveal actual file")
        let futureType = try JSONDecoder().decode(ShadowResponse.self,from:Data(#"{"ok":true,"workType":"future-type","brut":3,"post":1}"#.utf8))
        require(futureType.ok && futureType.workType==nil,"unknown work category disables otherwise valid source")
        print("CatalogTests: \(checks) assertions passed")
    }
}
