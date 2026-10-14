import Foundation

@main enum FixtureModelTests {
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("fixture-model-test-"+UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var health=SourceHealth();health.online=true;health.observedAt=Date()
        let jobs=(0..<50).map { i in RenderDashboard.mac(MacJob(id:"fixture-\(i)",titre:"Neutral fixture",sous:nil,total:240,faites:31,en_cours:[],latest:[],times:[],proc:nil),health:health,projectID:"fixture-project",workType:nil) }
        let seed=RenderCatalogSnapshot(revision:1,generatedAt:Date(),jobs:jobs,projects:RenderDashboard.projects(jobs),works:[],knownJobCount:50,observedJobCount:50,stateCounts:RenderCatalogStateCounts(),persistenceIssue:nil)
        let model=MonitorModel.fixture(snapshot:seed,storageRoot:root)
        defer { model.stop() }
        model.start();model.refreshNow();await model.refreshMac();await model.refreshShadow();await model.refreshShadowFolders();model.refreshFolders()
        model.setVisiblePreviewEntries([])
        precondition(model.catalogSnapshot.knownJobCount==50 && model.macJobs.isEmpty && model.entries.isEmpty,"fixture collection leaked into production path")
        precondition(model.setJobContext(RenderJobContext(projectID:nil,workID:"named-work",versionID:nil,workTitle:"User declared",versionLabel:"v1"),forJobID:"mac:fixture-0"),"fixture cannot organize locally")
        for _ in 0..<100 {
            if model.catalogSnapshot.jobs.first(where:{$0.id=="mac:fixture-0"})?.workID=="named-work" { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        precondition(model.catalogSnapshot.knownJobCount==50 && model.catalogSnapshot.jobs.first(where:{$0.id=="mac:fixture-0"})?.workID=="named-work","fixture snapshot doesn't preserve seed jobs")
        let configFile=root.appendingPathComponent("config.json")
        let config=try JSONDecoder().decode(AppConfig.self,from:Data(contentsOf:configFile))
        precondition(config.jobContexts["mac:fixture-0"]?.versionLabel=="v1","fixture writes outside injected store or loses label")
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        precondition(files.contains{$0.lastPathComponent.hasPrefix("config.before-preference-change-")},"organization lacks reversible backup")
        let before=model.catalogSnapshot.revision;model.stop();model.refreshNow();model.refreshFolders()
        try await Task.sleep(for:.milliseconds(30))
        precondition(model.catalogSnapshot.revision==before,"stopped fixture publishes late collection")
        let remote=ShadowFolderScanner()
        defer { remote.cancel() }
        let cancelled=Task { @MainActor in
            withUnsafeCurrentTask{$0?.cancel()}
            return await remote.history(["C:/neutral/exports"])
        }
        let cancelledValue=await cancelled.value
        precondition(cancelledValue==nil,"cancelled remote operation started helper")
        print("FixtureModelTests: isolated 50 jobs, inert collection, temp-only organization/backup, stop and cancelled remote PASS")
    }
}
