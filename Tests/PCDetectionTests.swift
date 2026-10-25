import Foundation
import Combine

actor PCFixtureStream {
    var payload:Data?
    init(_ data:Data?){payload=data}
    var entered=false
    private var hold=false
    private var continuation:CheckedContinuation<Void,Never>?
    func arm(){hold=true;entered=false}
    func release(){continuation?.resume();continuation=nil}
    func next() async ->Data? {
        if hold {hold=false;entered=true;await withCheckedContinuation{continuation=$0}}
        return payload
    }
    func set(_ data:Data?){payload=data}
}
struct EmptyPCFixtureReader:NativeProcessReading {
    func read()->NativeProcessRead {NativeProcessRead()}
}
@main enum PCDetectionTests {
    static var checks=0
    static func check(_ condition:Bool,_ label:String)throws {checks += 1;if !condition {throw NSError(domain:label,code:1)}}
    @MainActor static func until(_ condition:()->Bool) async throws {
        for _ in 0..<1500 {if condition(){return};try await Task.sleep(for:.milliseconds(2))}
        throw NSError(domain:"fixture observation deadline",code:1)
    }
    static func input(_ jobs:[RenderDashboardJob],revision:UInt64)->RenderCatalogInput {
        var value=RenderCatalogInput(revision:revision,macJobs:[],shadow:nil,declaration:nil,config:AppConfig(),knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:SourceHealth(),shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth())
        value.shadowRunJobs=jobs;return value
    }
    @MainActor static func main() async throws {
        let fm=FileManager.default,base=URL(fileURLWithPath:CommandLine.arguments[1])
        let root=base.appendingPathComponent("pc-fixture-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:root)}
        let data=try Data(contentsOf:base.appendingPathComponent("standard.json"))
        let envelope=try JSONDecoder().decode(ShadowRunEnvelope.self,from:data)
        let process=envelope.processSnapshot!,at=RenderDate.parse(process.observedAt)
        try check(process.validated(at:Date()),"valid standard protocol rejected")
        try check(process.observations.count==50,"50 independent tasks truncated")
        let one=process.observations[0]
        try check(one.totalFrames==60 && one.completedFrames==nil,"Blender total invents output count")
        try check(one.dashboard(fresh:true).isDetectedActiveRender,"long frame task hidden without recent output")
        try check(one.dashboard(fresh:true).postProgress==nil,"single stage invents post pass")
        try check(!process.validated(at:at.addingTimeInterval(121)),"expired snapshot accepted")
        try check(!process.validated(at:at.addingTimeInterval(-1)),"future snapshot accepted")
        var altered=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        var p=altered["processSnapshot"] as! [String:Any],rows=p["observations"] as! [[String:Any]]
        rows[0]["pid"]=90000;p["observations"]=rows;altered["processSnapshot"]=p
        let invalid=try JSONDecoder().decode(ShadowRunEnvelope.self,from:JSONSerialization.data(withJSONObject:altered))
        try check(!invalid.processSnapshot!.validated(at:Date()),"PID identity mismatch accepted")
        let stream=PCFixtureStream(data)
        let discovery=ShadowRunDiscovery(root:root.appendingPathComponent("discovery"),loader:{_ in await stream.next()})
        defer {discovery.stop()}
        await discovery.refresh([],force:true)
        try check(discovery.health.online && !discovery.health.partial && !discovery.health.isStale,"complete generic channel not adopted")
        try check(discovery.jobs.filter(\.isDetectedActiveRender).count==50,"concurrent active tasks lost on discovery")
        try check(!discovery.isRefreshing,"refresh flag left set")
        let catalog=RenderCatalogService(root:root.appendingPathComponent("catalog"))
        let active=await catalog.build(input(discovery.jobs,revision:1))!
        try check(active.stateCounts.running==50 && active.jobs.count==50,"catalogue loses active standard channel")
        let presentation=MenuBarPresentation.make(snapshot:active,observation:.confirmed,now:Date())
        try check(presentation.activeIDs.count==50 && presentation.title.count<=40,"menu bar loses tasks or exceeds bound")
        try check(presentation.omittedTooltipJobs==38,"bounded tooltip omission count wrong")
        altered=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        altered["partial"]=true;altered["sourceErrors"]=["fixture"]
        let partial=try JSONSerialization.data(withJSONObject:altered)
        let sources=try JSONDecoder().decode([ShadowDeclaredSource].self,from:Data(contentsOf:base.appendingPathComponent("sources.json")))
        await stream.set(partial);await discovery.refresh(sources,force:true)
        try check(discovery.health.partial && discovery.jobs.filter(\.isDetectedActiveRender).count==50,"bad declared source hides positive standard tasks")
        try check(!discovery.activityHealth.partial && discovery.activityHealth.online,"legacy source error corrupts complete activity census")
        await stream.set(nil);await discovery.refresh(sources,force:true)
        try check(discovery.health.isStale && discovery.jobs.allSatisfy{!$0.isDetectedActiveRender && !$0.isFresh},"connection loss leaves active claims")
        try check(discovery.jobs.count==50 && discovery.jobs.allSatisfy{!$0.isFinishedRender},"loss erases history or fabricates finish")
        await stream.set(data);await discovery.refresh([],force:true)
        altered=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        p=altered["processSnapshot"] as! [String:Any];p["observations"]=[];altered["processSnapshot"]=p
        await stream.set(try JSONSerialization.data(withJSONObject:altered));await discovery.refresh([],force:true)
        try check(discovery.jobs.count==50 && discovery.jobs.allSatisfy{!$0.isFresh && !$0.isFinishedRender},"process exit manufactures terminal success")
        let ended=await catalog.build(input(discovery.jobs,revision:2))!
        try check(ended.stateCounts.running==0 && ended.knownJobCount==50,"catalogue forgets ended invocation history")
        let gui=try JSONDecoder().decode(ShadowRunEnvelope.self,from:Data(contentsOf:base.appendingPathComponent("gui.json")))
        try check(gui.processSnapshot!.validated(at:Date()),"native handler protocol rejected")
        let guiJobs=gui.processSnapshot!.observations.map{$0.dashboard(fresh:true)}
        try check(guiJobs[0].isDetectedActiveRender && guiJobs[0].currentFrame == -2,"negative current image lost or GUI not active")
        try check(guiJobs[0].renderStartedAt != nil && guiJobs[0].rawProgress==nil && guiJobs[0].eta==nil,"F12 timeline fabricated total or ETA")
        try check(guiJobs[1].isFinishedRender && guiJobs[1].canArchive && !guiJobs[1].isTerminalCounted,"native completion inferred via frame count")
        try check(guiJobs[2].activity == .stopped && !guiJobs[2].isFinishedRender,"cancel interpreted as completion")
        try check(Set(guiJobs.map(\.id)).count==3,"GUI invocations not independent")
        let historyData=try Data(contentsOf:base.appendingPathComponent("gui-history.json"))
        let historyEnvelope=try JSONDecoder().decode(ShadowRunEnvelope.self,from:historyData)
        try check(historyEnvelope.processSnapshot!.validated(at:Date()) && historyEnvelope.processSnapshot!.observations.count==2,"two short native completions lost in wire decode")
        let historyRoot=root.appendingPathComponent("gui-history")
        let historyDiscovery=ShadowRunDiscovery(root:historyRoot,loader:{_ in historyData})
        await historyDiscovery.refresh([],force:true)
        try check(historyDiscovery.jobs.count==2 && historyDiscovery.jobs.allSatisfy{$0.isFinishedRender && !$0.isDetectedActiveRender},"short native jobs lost on adoption")
        historyDiscovery.stop();await historyDiscovery.waitForShutdown()
        let reloaded=ShadowRunDiscovery(root:historyRoot,loader:{_ in nil})
        await reloaded.loadLastGood([])
        try check(reloaded.jobs.count==2 && reloaded.jobs.allSatisfy{$0.isFinishedRender && !$0.isFresh},"native short history not persisted or falsely active after reload")
        reloaded.stop();await reloaded.waitForShutdown()
        let fiftyHistory=try JSONDecoder().decode(ShadowRunEnvelope.self,from:Data(contentsOf:base.appendingPathComponent("fifty-history.json")))
        try check(fiftyHistory.processSnapshot!.validated(at:Date()),"bounded active-first protocol rejected")
        let many=fiftyHistory.processSnapshot!.observations.map{$0.dashboard(fresh:true)}
        try check(many.filter(\.isDetectedActiveRender).count==50 && many.count<=128,"history displaces fifty active GUI jobs")
        let background=try JSONDecoder().decode(ShadowRunEnvelope.self,from:Data(contentsOf:base.appendingPathComponent("background.json")))
        try check(background.processSnapshot!.validated(at:Date()) && background.processSnapshot!.observations[0].dashboard(fresh:true).isDetectedActiveRender,"background handler evidence rejected")
        try check(background.processSnapshot!.observations[0].invocationToken==nil,"background process split into native frame jobs")
        let unknown=try JSONDecoder().decode(ShadowRunEnvelope.self,from:Data(contentsOf:base.appendingPathComponent("candidate.json")))
        await stream.set(try JSONEncoder().encode(unknown));await discovery.refresh([],force:true)
        try check(discovery.hasUnattributedCandidates && discovery.jobs.allSatisfy{!$0.isDetectedActiveRender},"idle GUI claims active rendering")
        var estimate=QualifiedRenderEstimate();let start=Date().addingTimeInterval(-1000)
        var eta:Date?
        for i in 0...3 {
            if i>0 {
                let previous=start.addingTimeInterval(Double(i-1)*207)
                for delta in stride(from:15,through:195,by:15) {
                    _ = estimate.estimate(key:"long-frame",completed:Double(i-1),total:10,sampledAt:previous,observedAt:previous.addingTimeInterval(Double(delta)))
                }
            }
            let date=start.addingTimeInterval(Double(i)*207)
            eta=estimate.estimate(key:"long-frame",completed:Double(i),total:10,sampledAt:date,observedAt:date)
        }
        try check(eta==start.addingTimeInterval(2070),"207-second frame cadence ETA missing")
        let sampled=start.addingTimeInterval(621)
        try check(estimate.estimate(key:"long-frame",completed:3,total:10,sampledAt:sampled,observedAt:sampled.addingTimeInterval(15))==eta,"qualified long-frame ETA expires at 20 seconds")
        try check(estimate.estimate(key:"long-frame",completed:2,total:10,sampledAt:sampled,observedAt:sampled.addingTimeInterval(20))==nil,"counter regression retains previous ETA")
        try check(estimate.estimate(key:"unknown",completed:3,total:0,sampledAt:sampled,observedAt:sampled)==nil,"unknown total creates ETA")
        try check(estimate.estimate(key:"expired",completed:9,total:10,sampledAt:sampled,observedAt:sampled.addingTimeInterval(30),seededIntervals:[1,1,1])==nil,"expired projection creates zero ETA")
        try check(estimate.estimate(key:"raw",completed:5,total:10,sampledAt:sampled,observedAt:sampled,seededIntervals:[207,207,207])==sampled.addingTimeInterval(1035),"raw frame seed rejected")
        try check(estimate.estimate(key:"post",completed:1,total:10,sampledAt:sampled,observedAt:sampled)==nil,"raw cadence leaks into post")
        try check(estimate.estimate(key:"media",completed:30,total:60,sampledAt:sampled,observedAt:sampled,seededIntervals:[2,2,2])==sampled.addingTimeInterval(60),"media seconds throughput ETA wrong")
        let modelRoot=root.appendingPathComponent("model")
        let model=MonitorModel(storageRoot:modelRoot,collectionEnabled:true,nativeReader:EmptyPCFixtureReader(),shadowRunLoader:{_ in data})
        var failure:Error?
        do {
            await model.refreshShadowRunDiscovery(force:true)
            try await until {model.nativeRequestedGeneration>0 && model.nativeCatalogueGeneration==model.nativeRequestedGeneration && model.menuBarObservation(at:Date()) == .confirmed}
            try check(model.menuBarObservation(at:Date()) == .confirmed,"fresh confirmed zero unavailable")
            let before=model.observationRevision
            let ticket=model.refreshLocalDiscovery()
            try check(model.menuBarObservation(at:Date()) == .confirmed,"valid proof blinks to refreshing during unchanged native cycle")
            let joined=await model.waitForNativeDiscovery(ticket)
            try check(joined && model.observationRevision>before,"same empty catalogue cycle emits no observation signal")
            try check(model.menuBarObservation(at:Date().addingTimeInterval(31)) != .confirmed,"pure getter fails freshness expiry")
            let count=model.observationRevision
            for _ in 0..<10 {_ = model.menuBarObservation(at:Date())}
            try check(model.observationRevision==count,"pure getter mutates/starts probe")
        } catch {failure=error}
        model.stop();await model.waitForShutdown()
        if let failure {throw failure}
        try check(model.menuBarObservation(at:Date()) != .confirmed,"stopped model confirms zero")
        let pcRoot=root.appendingPathComponent("pc-model");try fm.createDirectory(at:pcRoot,withIntermediateDirectories:true)
        var configuration=AppConfig();configuration.shadowRunSources=sources
        try JSONEncoder().encode(configuration).write(to:pcRoot.appendingPathComponent("config.json"))
        let key=pcRoot.appendingPathComponent("fixture-key");try Data("fixture, no credential".utf8).write(to:key)
        try JSONSerialization.data(withJSONObject:["host":"fixture.invalid","user":"fixture","identityFile":key.path]).write(to:pcRoot.appendingPathComponent("connection.json"))
        altered=try JSONSerialization.jsonObject(with:partial) as! [String:Any]
        p=altered["processSnapshot"] as! [String:Any];p["observations"]=[];altered["processSnapshot"]=p
        let zero=try JSONSerialization.data(withJSONObject:altered)
        let pcFeed=PCFixtureStream(zero)
        let pcModel=MonitorModel(storageRoot:pcRoot,collectionEnabled:true,nativeReader:EmptyPCFixtureReader(),shadowRunLoader:{_ in await pcFeed.next()})
        var pending:Task<Void,Never>?
        failure=nil
        do {
            await pcModel.refreshShadowRunDiscovery(force:true)
            try await until {pcModel.menuBarObservation(at:Date()) == .confirmed}
            try check(pcModel.shadowRunHealth.partial && !pcModel.shadowActivityHealth.partial,"updater and activity coverage not separated")
            try check(pcModel.softwareUpdateSafety != .safe,"legacy source error makes updater safe")
            await pcFeed.arm()
            pending=Task {await pcModel.refreshShadowRunDiscovery(force:true)}
            for _ in 0..<1500 {if await pcFeed.entered {break};try await Task.sleep(for:.milliseconds(2))}
            try check(await pcFeed.entered,"pending PC fixture never entered")
            try check(pcModel.menuBarObservation(at:Date()) == .confirmed,"fresh complete PC census blinks during refresh")
            await pcFeed.release();await pending?.value;pending=nil
            p["coverageComplete"]=false;altered["processSnapshot"]=p
            await pcFeed.set(try JSONSerialization.data(withJSONObject:altered))
            await pcModel.refreshShadowRunDiscovery(force:true)
            try check(pcModel.menuBarObservation(at:Date()) != .confirmed,"partial process census confirms zero")
        } catch {failure=error}
        await pcFeed.release();await pending?.value;pcModel.stop();await pcModel.waitForShutdown()
        if let failure {throw failure}
        let legacyRoot=root.appendingPathComponent("legacy-registry-model");try fm.createDirectory(at:legacyRoot,withIntermediateDirectories:true)
        var legacyConfig=AppConfig();legacyConfig.dashboardProjectLinks["mac:historical"]="fixture-history"
        try JSONEncoder().encode(legacyConfig).write(to:legacyRoot.appendingPathComponent("config.json"))
        let registryModel=MonitorModel(storageRoot:legacyRoot,collectionEnabled:true,nativeReader:EmptyPCFixtureReader(),shadowRunLoader:{_ in nil})
        failure=nil
        do {
            await registryModel.refreshShadowRunDiscovery(force:true)
            try await until {registryModel.menuBarObservation(at:Date()) == .confirmed}
            try check(registryModel.registryDiscoveryError != nil,"legacy missing context fixture did not exercise strict updater gate")
            try check(registryModel.softwareUpdateSafety != .safe,"missing known registry makes updater safe")
            let registryFile=legacyRoot.appendingPathComponent("monitor-jobs.json")
            try Data("[]".utf8).write(to:registryFile)
            var ticket=registryModel.refreshLocalDiscovery();_ = await registryModel.waitForNativeDiscovery(ticket)
            try await until {registryModel.menuBarObservation(at:Date()) == .confirmed && registryModel.registryDiscoveryError==nil}
            try check(registryModel.menuBarObservation(at:Date()) == .confirmed,"present valid optional registry breaks confirmed census")
            try Data("{broken".utf8).write(to:registryFile)
            ticket=registryModel.refreshLocalDiscovery();_ = await registryModel.waitForNativeDiscovery(ticket)
            try await until {if case .uncertain=registryModel.menuBarObservation(at:Date()) {return true};return false}
            try check(registryModel.softwareUpdateSafety != .safe,"invalid registry makes updater safe")
        } catch {failure=error}
        registryModel.stop();await registryModel.waitForShutdown()
        if let failure {throw failure}
        discovery.stop();await discovery.waitForShutdown()
        print("PCDetectionTests: \(checks) assertions PASS; standard and GUI fixtures only, no PC/network/renderer/app")
    }
}
