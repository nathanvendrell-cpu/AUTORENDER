import Foundation

final class UpdateFixtureReader:NativeProcessReading {
    private let lock=NSLock();private var value=NativeProcessRead();private var count=0
    func set(_ snapshots:[NativeProcessSnapshot],partial:Bool=false){lock.lock();defer{lock.unlock()};value=NativeProcessRead(snapshots:snapshots,partial:partial)}
    func read()->NativeProcessRead {lock.lock();defer{lock.unlock()};count += 1;return value}
    var calls:Int {lock.lock();defer{lock.unlock()};return count}
}
actor UpdateFixtureFeed {
    var data:Data?;var calls=0;var entered=false;private var suspend=false;private var continuation:CheckedContinuation<Void,Never>?
    init(_ data:Data?){self.data=data}
    func set(_ data:Data?){self.data=data}
    func arm(){suspend=true;entered=false}
    func next() async -> Data? {calls += 1;if suspend {suspend=false;entered=true;await withCheckedContinuation{continuation=$0}};return data}
    func release(){continuation?.resume();continuation=nil}
}
final class UpdateScopeBarrier:@unchecked Sendable {
    private let lock=NSLock();private let releaseGate=DispatchSemaphore(value:0)
    private var started=false;private var ended=false;private var main=false
    var entered:Bool {lock.lock();defer{lock.unlock()};return started}
    var finished:Bool {lock.lock();defer{lock.unlock()};return ended}
    var ranOnMainThread:Bool {lock.lock();defer{lock.unlock()};return main}
    func release(){releaseGate.signal()}
    func inspect(_ directory:URL,_ permit:RenderIOPermit) throws -> SoftwareUpdatePolicy.ShadowScope {
        lock.lock();started=true;main=Thread.isMainThread;lock.unlock()
        defer {lock.lock();ended=true;lock.unlock()}
        guard releaseGate.wait(timeout:.now()+3) == .success else{throw POSIXError(.ETIMEDOUT)}
        try permit.check()
        return .confirmedUnconfigured(checkedAt:Date())
    }
}
@main enum SoftwareUpdatePolicyTests {
    static var checks=0
    static func check(_ yes:Bool,_ message:String) throws {checks += 1;if !yes {throw NSError(domain:message,code:1)}}
    @MainActor static func until(detail:@autoclosure ()->String = "",_ condition:() -> Bool) async throws {
        let end=DispatchTime.now().uptimeNanoseconds+5_000_000_000
        while !condition(){guard DispatchTime.now().uptimeNanoseconds<end else{throw NSError(domain:"fixture deadline after \(checks) checks: \(detail())",code:1)};try await Task.sleep(for:.milliseconds(2))}
    }
    static func policy() throws {
        // Encoding fixture only. No release feed/key is written to an application or configuration.
        let key=Data(repeating:0x42,count:32).base64EncodedString()
        try check(SoftwareUpdatePolicy.configuration(feedURL:nil,publicEDKey:nil) == .unconfigured,"missing release settings enabled updater")
        for url in [nil,"http://fixture.invalid/feed.xml","file:///tmp/feed.xml","https:///feed.xml","https://user:pass@fixture.invalid/feed.xml","https://fixture.invalid/feed.xml#fragment"," https://fixture.invalid/feed.xml"] as [String?] {
            try check(SoftwareUpdatePolicy.configuration(feedURL:url,publicEDKey:key) == .unconfigured,"invalid feed accepted")
        }
        for bad in [nil,"placeholder",Data(repeating:1,count:31).base64EncodedString(),Data(repeating:0,count:32).base64EncodedString(),key+"\n"] as [String?] {
            try check(SoftwareUpdatePolicy.configuration(feedURL:"https://fixture.invalid/feed.xml",publicEDKey:bad) == .unconfigured,"missing/malformed public key accepted")
        }
        try check(SoftwareUpdatePolicy.configuration(feedURL:"https://fixture.invalid/feed.xml",publicEDKey:key) == .configured(feedURL:URL(string:"https://fixture.invalid/feed.xml")!,publicEDKey:key),"supplied structurally valid release settings rejected")
        try check(SoftwareUpdatePolicy.permitsUpdate(currentBuild:"71",candidateBuild:"72"),"newer integer build rejected")
        for candidate in ["71","70","","72.1","+72","-1"," 72","18446744073709551616","72beta"] {
            try check(!SoftwareUpdatePolicy.permitsUpdate(currentBuild:"71",candidateBuild:candidate),"same/downgrade/unknown build accepted")
        }
        try check(!SoftwareUpdatePolicy.permitsUpdate(currentBuild:"unknown",candidateBuild:"72"),"unknown installed build accepted")
        try check(SoftwareUpdatePolicy.permitsUpdate(currentVersion:"0.7.1",currentBuild:"71",candidateVersion:"0.7.1",candidateBuild:"72"),"new build of same release rejected")
        try check(SoftwareUpdatePolicy.permitsUpdate(currentVersion:"0.9.9",currentBuild:"71",candidateVersion:"1.0.0",candidateBuild:"72"),"major version advancement rejected")
        try check(!SoftwareUpdatePolicy.permitsUpdate(currentVersion:"0.7.1",currentBuild:"71",candidateVersion:"0.7.0",candidateBuild:"72"),"version downgrade accepted with higher build")
        try check(!SoftwareUpdatePolicy.permitsUpdate(currentVersion:"0.7.1",currentBuild:"71",candidateVersion:"0.8.0-beta",candidateBuild:"72"),"unsupported version format accepted")
        try check(!SoftwareUpdatePolicy.permitsUpdate(currentVersion:"0.7.1",currentBuild:"71",candidateVersion:"0.8.0",candidateBuild:"70"),"higher version bypasses build downgrade")
        let now=Date(timeIntervalSince1970:1_000_000)
        func source(age:Double=0,active:Bool=false,candidate:Bool=false,partial:Bool=false,online:Bool=true,stale:Bool=false,dated:Bool=true)->SoftwareUpdatePolicy.SourceEvidence {
            .init(online:online,stale:stale,partial:partial,observedAt:dated ? now.addingTimeInterval(-age) : nil,checkedAt:dated ? now.addingTimeInterval(-age) : nil,qualifiedActive:active,unattributedCandidate:candidate)
        }
        func safety(_ native:SoftwareUpdatePolicy.SourceEvidence?=nil,_ shadow:SoftwareUpdatePolicy.SourceEvidence?=nil,refreshing:Bool=false,converged:Bool=true,readable:Bool=true,enabled:Bool=true,stopping:Bool=false,scope:SoftwareUpdatePolicy.ShadowScope = .required)->SoftwareUpdateSafety {
            SoftwareUpdatePolicy.assess(.init(monitoringEnabled:enabled,stopping:stopping,configurationReadable:readable,refreshing:refreshing,generationsConverged:converged,native:native ?? source(),shadow:shadow ?? source(),shadowScope:scope),at:now).safety
        }
        try check(safety() == .safe,"fully observed absence is not safe")
        try check(safety(source(active:true)) == .busy,"fresh native render is not busy")
        try check(safety(nil,source(active:true,partial:true)) == .busy,"positive partial worker lost to coverage uncertainty")
        try check(safety(source(age:31,active:true)) == .uncertain,"expired active retained as busy or safe")
        try check(safety(nil,source(age:121)) == .uncertain,"expired Shadow absence is safe")
        try check(safety(source(age:-1)) == .uncertain,"future evidence establishes absence")
        try check(safety(source(candidate:true)) == .uncertain,"unattributed process permits installation")
        try check(safety(source(partial:true)) == .uncertain,"partial native coverage permits installation")
        try check(safety(nil,source(online:false)) == .uncertain,"unavailable connection permits installation")
        try check(safety(nil,source(stale:true)) == .uncertain,"cached source permits installation")
        try check(safety(nil,source(dated:false)) == .uncertain,"undated source permits installation")
        try check(safety(refreshing:true) == .uncertain,"refresh in flight permits installation")
        try check(safety(converged:false) == .uncertain,"unacknowledged observation permits installation")
        try check(safety(readable:false) == .uncertain,"unreadable config permits installation")
        try check(safety(enabled:false) == .uncertain,"preview-only fixture establishes safe")
        try check(safety(stopping:true) == .uncertain,"stopping monitor establishes safe")
        try check(safety(nil,source(online:false),scope:.confirmedUnconfigured(checkedAt:now)) == .safe,"confirmed unconfigured Shadow blocks Mac-only installation")
        try check(safety(nil,source(online:false),scope:.uncertain) == .uncertain,"unknown Shadow scope treated as unnecessary")
        try check(safety(nil,source(online:false),scope:.confirmedUnconfigured(checkedAt:now.addingTimeInterval(-31))) == .uncertain,"expired negative configuration evidence permits installation")
        try check(safety(nil,source(active:true),scope:.confirmedUnconfigured(checkedAt:now)) != .safe,"unconfigured scope overrides positive worker evidence")
    }
    @MainActor static func boundedLocalScope(_ root:URL) async throws {
        for scenario in ["stop","generation","cancellation","deadline"] {
            let barrier=UpdateScopeBarrier(),io=RenderBoundedIO()
            let worker=ShadowRunDiscovery(root:root.appendingPathComponent("bounded-"+scenario),loader:{_ in nil},cacheIO:io,localScopeReader:{directory,permit in try barrier.inspect(directory,permit)})
            let request=Task{await worker.softwareUpdateLocalScope()}
            var failure:Error?
            do {
                try await until{barrier.entered}
                try check(!barrier.finished && !barrier.ranOnMainThread,"local scope IO blocks the main actor")
                if scenario=="stop" {worker.stop()}
                if scenario=="generation" {await worker.refresh([],force:true)}
                if scenario=="cancellation" {request.cancel()}
                if scenario != "deadline" {barrier.release()}
                let result=await request.value
                let rejected:Bool
                if case .uncertain = result {rejected=true} else {rejected=false}
                try check(rejected,"invalidated local inspection publishes an absence proof")
                if scenario=="deadline" {try check(!barrier.finished,"deadline waits for blocked filesystem reader")}
            } catch {failure=error}
            // The blocked reader is released even on failure; join the exact test-owned IO.
            barrier.release();worker.stop();_=await request.value;await worker.waitForShutdown()
            try await until{!io.isOccupied && barrier.finished}
            if let failure {throw failure}
        }
        let directory=root.appendingPathComponent("scope-file-errors")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let cache=directory.appendingPathComponent("shadow-folders-last-good.json")
        let bytes=Data(repeating:65,count:1024*1024+1);try bytes.write(to:cache)
        let worker=ShadowRunDiscovery(root:directory,loader:{_ in nil})
        let result=await worker.softwareUpdateLocalScope()
        let rejected:Bool
        if case .uncertain = result {rejected=true} else {rejected=false}
        worker.stop();await worker.waitForShutdown()
        try check(rejected,"oversized local cache proves absence")
        try check(try Data(contentsOf:cache)==bytes,"scope inspection mutates rejected cache")
    }
    @MainActor static func main() async throws {
        try policy()
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),fm=FileManager.default
        try await boundedLocalScope(root)
        let sources=try JSONDecoder().decode([ShadowDeclaredSource].self,from:Data(contentsOf:root.appendingPathComponent("sources.json")))
        let neutral=try Data(contentsOf:root.appendingPathComponent("neutral.json")),active=try Data(contentsOf:root.appendingPathComponent("active.json"))
        let empty=try Data(contentsOf:root.appendingPathComponent("empty.json"))
        let storage=root.appendingPathComponent("live-model");try fm.createDirectory(at:storage,withIntermediateDirectories:true)
        try Data("[]".utf8).write(to:storage.appendingPathComponent("monitor-jobs.json"))
        var config=AppConfig();config.shadowRunSources=sources
        try JSONEncoder().encode(config).write(to:storage.appendingPathComponent("config.json"))
        func connection(_ folder:URL) throws {
            try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            let key=folder.appendingPathComponent("fixture-key");try Data("fixture only".utf8).write(to:key)
            try JSONSerialization.data(withJSONObject:["host":"fixture.invalid","user":"fixture","identityFile":key.path]).write(to:folder.appendingPathComponent("connection.json"))
        }
        try connection(storage)
        let reader=UpdateFixtureReader(),feed=UpdateFixtureFeed(neutral)
        let model=MonitorModel(storageRoot:storage,collectionEnabled:true,previewLoader:{_ in nil},nativeReader:reader,shadowRunLoader:{_ in await feed.next()})
        var models=[model];var pending:Task<Void,Never>?;var failure:Error?
        do {
            try check(model.softwareUpdateSafety != .safe,"startup without observations is safe")
            let initial=model.nativeRequestedGeneration
            try check(await model.waitForNativeDiscovery(initial),"initial native generation failed")
            await model.refreshShadowRunDiscovery(force:true)
            try await until{model.softwareUpdateSafety == .safe}
            let liveGate:@MainActor ()->SoftwareUpdateSafety = {model.softwareUpdateSafety}
            try check(liveGate() == .safe && !model.softwareUpdateSafetyReason.isEmpty,"fresh scoped absence not exposed with reason")
            let nativeCalls=reader.calls,shadowCalls=await feed.calls
            let configBytes=try Data(contentsOf:storage.appendingPathComponent("config.json"))
            let cacheBytes=try Data(contentsOf:storage.appendingPathComponent("shadow-runs-last-good.json"))
            for _ in 0..<20 {_=model.softwareUpdateSafety;_=model.softwareUpdateSafetyReason}
            let afterShadowCalls=await feed.calls
            try check(reader.calls==nativeCalls && afterShadowCalls==shadowCalls,"reading safety starts collection")
            try check(try Data(contentsOf:storage.appendingPathComponent("config.json"))==configBytes && Data(contentsOf:storage.appendingPathComponent("shadow-runs-last-good.json"))==cacheBytes,"reading safety mutates durable configuration/cache")
            // Download starts after an observed safe check. A new qualified observation arrives before install.
            let initialDownloadPermission=liveGate()
            let now=Date(),id=NativeProcessIdentity(pid:701,birthSeconds:UInt64(now.timeIntervalSince1970)-60,birthMicroseconds:1,executable:"/fixture/Blender")
            let scene=storage.appendingPathComponent("fixture.blend").path
            reader.set([.init(identity:id,arguments:[id.executable,"-b",scene,"-f","1"])])
            var ticket=model.refreshLocalDiscovery()
            try check(liveGate() == .uncertain,"collection starting during download reuses cached safe")
            try check(await model.waitForNativeDiscovery(ticket),"active generation not acknowledged")
            try check(initialDownloadPermission == .safe && liveGate() == .busy,"live install/relaunch gate ignores render observed after download check")
            try check(model.softwareUpdateSafety(at:Date().addingTimeInterval(20)) == .busy,"long frame without progress loses busy protection")
            try check(model.softwareUpdateSafety(at:Date().addingTimeInterval(31)) == .uncertain,"expired worker evidence becomes safe")
            reader.set([.init(identity:id,arguments:[id.executable,scene])]);ticket=model.refreshLocalDiscovery()
            try check(await model.waitForNativeDiscovery(ticket),"candidate generation failed")
            try check(liveGate() == .uncertain,"unattributed Blender process permits update")
            reader.set([],partial:true);ticket=model.refreshLocalDiscovery()
            try check(await model.waitForNativeDiscovery(ticket),"partial generation failed")
            try check(liveGate() == .uncertain,"partial absence permits update")
            reader.set([]);ticket=model.refreshLocalDiscovery()
            try check(await model.waitForNativeDiscovery(ticket),"completed absence generation failed")
            try await until{liveGate() == .safe}
            await feed.arm();pending=Task{await model.refreshShadowRunDiscovery(force:true)}
            while !(await feed.entered){try await Task.sleep(for:.milliseconds(2))}
            try check(liveGate() == .uncertain,"Shadow refresh during download retains safe")
            try fm.removeItem(at:storage.appendingPathComponent("connection.json"))
            await feed.release();await pending?.value;pending=nil
            try await until{model.shadowRunHealth.isStale}
            try check(liveGate() == .uncertain,"connection lost during download permits install or relaunch")
            try connection(storage);await feed.set(active);await model.refreshShadowRunDiscovery(force:true)
            try check(liveGate() == .busy,"fresh Shadow worker not busy")
            await feed.set(nil);await model.refreshShadowRunDiscovery(force:true)
            try check(liveGate() == .uncertain,"historical cached worker produces false busy or safe")
            await feed.set(neutral);await model.refreshShadowRunDiscovery(force:true)
            try await until{liveGate() == .safe}
            try check(model.catalogSnapshot.jobs.contains{$0.retainedHistorical && $0.id==id.jobID},"historical native fixture absent")
            try check(liveGate() == .safe,"retained native history causes false busy")
            let brokenRoot=root.appendingPathComponent("unreadable-config");try connection(brokenRoot)
            let broken=Data("{broken".utf8);try broken.write(to:brokenRoot.appendingPathComponent("config.json"))
            let invalid=MonitorModel(storageRoot:brokenRoot,collectionEnabled:true,previewLoader:{_ in nil},nativeReader:UpdateFixtureReader(),shadowRunLoader:{_ in empty});models.append(invalid)
            try check(await invalid.waitForNativeDiscovery(invalid.nativeRequestedGeneration),"unreadable-config native generation failed")
            await invalid.refreshShadowRunDiscovery(force:true)
            try check(invalid.nativeHealth.online && invalid.shadowRunHealth.online,"unreadable-config fixture lacks independent observation")
            try check(invalid.softwareUpdateSafety == .uncertain && invalid.softwareUpdateSafetyReason=="Configuration non vérifiée","healthy sources override unreadable config")
            try check(try Data(contentsOf:brokenRoot.appendingPathComponent("config.json"))==broken,"policy or fixture overwrites unreadable config")
            let macOnlyRoot=root.appendingPathComponent("mac-only")
            try fm.createDirectory(at:macOnlyRoot,withIntermediateDirectories:true)
            // Normal Mac-only folder refresh writes this empty cache; it is not a configured remote scope.
            try JSONSerialization.data(withJSONObject:["entries":[],"at":Date().timeIntervalSinceReferenceDate]).write(to:macOnlyRoot.appendingPathComponent("shadow-folders-last-good.json"))
            let macOnlyFeed=UpdateFixtureFeed(empty),macOnlyReader=UpdateFixtureReader()
            let macOnly=MonitorModel(storageRoot:macOnlyRoot,collectionEnabled:true,previewLoader:{_ in nil},nativeReader:macOnlyReader,shadowRunLoader:{_ in await macOnlyFeed.next()});models.append(macOnly)
            try check(await macOnly.waitForNativeDiscovery(macOnly.nativeRequestedGeneration),"Mac-only native absence not adopted")
            try check(macOnly.softwareUpdateSafety != .safe,"missing data alone proves Shadow unnecessary")
            await macOnly.refreshShadowRunDiscovery(force:true)
            try await until(detail:"fresh Mac-only: \(macOnly.softwareUpdateSafetyReason), registry=\(macOnly.registryDiscoveryError ?? "nil"), generations=\(macOnly.nativeRequestedGeneration)/\(macOnly.nativeCompletedGeneration)/\(macOnly.nativeCatalogueGeneration), native=\(macOnly.nativeHealth.message)"){macOnly.softwareUpdateSafety == .safe}
            try check(!macOnly.shadowRunHealth.online && macOnly.softwareUpdateSafety == .safe,"Mac-only safe requires fabricated fresh Shadow health")
            try check(!fm.fileExists(atPath:macOnlyRoot.appendingPathComponent("monitor-jobs.json").path) && macOnly.registryDiscoveryError==nil,"fresh installation requires a fabricated empty registry")
            try check(macOnly.softwareUpdateSafety(at:Date().addingTimeInterval(31)) == .uncertain,"expired optional absence remains safe")
            let readCount=macOnlyReader.calls
            for _ in 0..<20 {_=macOnly.softwareUpdateSafety;_=macOnly.softwareUpdateSafetyReason}
            try check(macOnlyReader.calls==readCount && !fm.fileExists(atPath:macOnlyRoot.appendingPathComponent("monitor-jobs.json").path),"optional absence getter performs discovery or creates registry")
            let noRemoteCalls=await macOnlyFeed.calls
            try check(noRemoteCalls==0,"unconfigured Shadow launches a remote loader")
            let providerFolder=macOnlyRoot.appendingPathComponent("provider-output")
            try fm.createDirectory(at:providerFolder,withIntermediateDirectories:true)
            let providerFolderPath=AppConfig.normalizedMacFolder(providerFolder.path)
            let registryFile=macOnlyRoot.appendingPathComponent("monitor-jobs.json")
            try JSONSerialization.data(withJSONObject:[["id":"known-provider","dossier":providerFolder.path]]).write(to:registryFile)
            var registryTicket=macOnly.refreshLocalDiscovery()
            try check(await macOnly.waitForNativeDiscovery(registryTicket),"new registry generation not acknowledged")
            try await until(detail:"arrived registry: \(macOnly.softwareUpdateSafetyReason), registry=\(macOnly.registryDiscoveryError ?? "nil"), generations=\(macOnly.nativeRequestedGeneration)/\(macOnly.nativeCompletedGeneration)/\(macOnly.nativeCatalogueGeneration), native=\(macOnly.nativeHealth.message), folders=\(macOnly.config.macFolders), expected=\(providerFolderPath)"){macOnly.config.macFolders.contains(providerFolderPath) && macOnly.softwareUpdateSafety == .safe}
            let preservedConfig=try Data(contentsOf:macOnlyRoot.appendingPathComponent("config.json"))
            try fm.removeItem(at:registryFile)
            registryTicket=macOnly.refreshLocalDiscovery()
            try check(await macOnly.waitForNativeDiscovery(registryTicket),"missing known registry generation failed")
            try await until(detail:"removed registry: \(macOnly.softwareUpdateSafetyReason)"){macOnly.registryDiscoveryError != nil}
            try check(macOnly.softwareUpdateSafety == .uncertain && macOnly.config.macFolders.contains(providerFolderPath),"disappeared registry permits install or loses imported folder")
            try check(try Data(contentsOf:macOnlyRoot.appendingPathComponent("config.json"))==preservedConfig,"missing known registry modifies preserved preferences")
            let historicalRoot=root.appendingPathComponent("historical-registry")
            try fm.createDirectory(at:historicalRoot,withIntermediateDirectories:true)
            var historicalConfig=AppConfig();historicalConfig.dashboardJobFolders["mac:old-provider"]=[providerFolder.path]
            let historicalBytes=try JSONEncoder().encode(historicalConfig)
            try historicalBytes.write(to:historicalRoot.appendingPathComponent("config.json"))
            let historical=MonitorModel(storageRoot:historicalRoot,collectionEnabled:true,previewLoader:{_ in nil},nativeReader:UpdateFixtureReader(),shadowRunLoader:{_ in empty});models.append(historical)
            try check(await historical.waitForNativeDiscovery(historical.nativeRequestedGeneration),"historical registry context generation failed")
            await historical.refreshShadowRunDiscovery(force:true)
            try await until(detail:"historical registry: \(historical.softwareUpdateSafetyReason)"){historical.registryDiscoveryError != nil}
            try check(historical.softwareUpdateSafety == .uncertain && historical.config.dashboardJobFolders==historicalConfig.dashboardJobFolders,"persisted provider context mistaken for never-used registry")
            try check(try Data(contentsOf:historicalRoot.appendingPathComponent("config.json"))==historicalBytes,"historical missing registry mutates preferences")
            try Data("{broken".utf8).write(to:macOnlyRoot.appendingPathComponent("connection.json"))
            await macOnly.refreshShadowRunDiscovery(force:true)
            try check(macOnly.softwareUpdateSafety == .uncertain,"invalid connection mistaken for unconfigured Shadow")
            try fm.removeItem(at:macOnlyRoot.appendingPathComponent("connection.json"))
            await macOnly.refreshShadowRunDiscovery(force:true)
            try check(macOnly.softwareUpdateSafety == .uncertain,"previous connection evidence forgotten on removal")
            model.stop();await model.waitForShutdown()
            try check(liveGate() == .uncertain,"stopped model leaves stale safe authorization")
        } catch {failure=error}
        // Release fixture continuations and join every task even when an assertion fails.
        await feed.release()
        for item in models {item.stop()}
        await pending?.value
        for item in models {await item.waitForShutdown()}
        if let failure {throw failure}
        print("SoftwareUpdatePolicyTests: \(checks) assertions PASS; live closure races, observed absence, stale/config/coverage gates, no UI/network/timer/producer")
    }
}
